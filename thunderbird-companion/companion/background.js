"use strict";

const HOST_NAME = "dev.noctalia.thunderbird_companion";
const SNAPSHOT_MESSAGE_LIMIT = 50;
const SNAPSHOT_INTERVAL_MS = 60000;
const COMMAND_POLL_INTERVAL_MS = 1500;
const RECONNECT_DELAY_MS = 5000;
const EXCLUDED_ACCOUNT_TYPES = new Set(["nntp", "rss"]);
const EXCLUDED_FOLDER_TYPES = new Set([
  "drafts",
  "junk",
  "outbox",
  "sent",
  "templates",
  "trash",
]);

let nativePort = null;
let reconnectTimer = null;
let syncTimer = null;
let syncRunning = false;
let syncAgain = false;
let commandChain = Promise.resolve();

function postNative(message) {
  if (!nativePort) {
    return false;
  }
  try {
    nativePort.postMessage(message);
    return true;
  } catch (error) {
    console.warn("Thunderbird Companion: native message failed", error);
    return false;
  }
}

function connectNative() {
  if (nativePort) {
    return;
  }

  try {
    const port = messenger.runtime.connectNative(HOST_NAME);
    nativePort = port;

    port.onMessage.addListener(onNativeMessage);
    port.onDisconnect.addListener(() => {
      const error = messenger.runtime.lastError;
      if (error) {
        console.warn("Thunderbird Companion: native bridge disconnected", error.message);
      }
      if (nativePort === port) {
        nativePort = null;
      }
      if (!reconnectTimer) {
        reconnectTimer = setTimeout(() => {
          reconnectTimer = null;
          connectNative();
        }, RECONNECT_DELAY_MS);
      }
    });

    postNative({ type: "hello", extensionVersion: messenger.runtime.getManifest().version });
    scheduleSync(0);
  } catch (error) {
    console.warn("Thunderbird Companion: native bridge unavailable", error);
    if (!reconnectTimer) {
      reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        connectNative();
      }, RECONNECT_DELAY_MS);
    }
  }
}

async function collectUnreadMessages() {
  const messages = [];
  let page = await messenger.messages.query({ unread: true });

  while (page) {
    if (Array.isArray(page.messages)) {
      messages.push(...page.messages);
    }
    if (!page.id) {
      break;
    }
    page = await messenger.messages.continueList(page.id);
  }

  return messages.filter((message) => {
    const folder = message.folder || {};
    const specialUse = Array.isArray(folder.specialUse)
      ? folder.specialUse
      : (folder.type ? [folder.type] : []);
    return !specialUse.some((type) => EXCLUDED_FOLDER_TYPES.has(type));
  });
}

function serializeMessage(message, accountsById) {
  const folder = message.folder || {};
  const accountId = folder.accountId || "";
  const account = accountsById.get(accountId);
  const date = message.date instanceof Date ? message.date : new Date(message.date);

  return {
    id: message.id,
    headerMessageId: message.headerMessageId || "",
    subject: message.subject || "",
    author: message.author || "",
    date: Number.isNaN(date.getTime()) ? 0 : date.getTime(),
    flagged: message.flagged === true,
    accountId,
    accountName: account ? account.name : "",
    folderName: folder.name || "",
    folderPath: folder.path || "",
  };
}

async function collectMailboxState() {
  const accounts = await messenger.accounts.list();
  const accountsById = new Map(accounts.map((account) => [account.id, account]));
  const unread = (await collectUnreadMessages()).filter((message) => {
    const accountId = message.folder && message.folder.accountId;
    const account = accountId ? accountsById.get(accountId) : null;
    return !account || !EXCLUDED_ACCOUNT_TYPES.has(account.type);
  });
  return { accounts, accountsById, unread };
}

async function buildSnapshot() {
  const { accounts, accountsById, unread } = await collectMailboxState();
  unread.sort((left, right) => {
    const leftDate = left.date instanceof Date ? left.date.getTime() : new Date(left.date).getTime();
    const rightDate = right.date instanceof Date ? right.date.getTime() : new Date(right.date).getTime();
    return (rightDate || 0) - (leftDate || 0);
  });

  return {
    schemaVersion: 1,
    generatedAt: Date.now(),
    unreadCount: unread.length,
    accounts: accounts.map((account) => ({
      id: account.id,
      name: account.name || "",
      type: account.type || "",
    })),
    messages: unread
      .slice(0, SNAPSHOT_MESSAGE_LIMIT)
      .map((message) => serializeMessage(message, accountsById)),
  };
}

async function markAllRead() {
  const { unread } = await collectMailboxState();
  const batchSize = 25;
  for (let offset = 0; offset < unread.length; offset += batchSize) {
    await Promise.all(
      unread
        .slice(offset, offset + batchSize)
        .map((message) => messenger.messages.update(message.id, { read: true })),
    );
  }
}

async function syncSnapshot() {
  if (syncRunning) {
    syncAgain = true;
    return;
  }
  syncRunning = true;

  try {
    const snapshot = await buildSnapshot();
    postNative({ type: "snapshot", data: snapshot });
  } catch (error) {
    console.error("Thunderbird Companion: mailbox snapshot failed", error);
    postNative({ type: "snapshot_error", error: String(error) });
  } finally {
    syncRunning = false;
    if (syncAgain) {
      syncAgain = false;
      scheduleSync(0);
    }
  }
}

function scheduleSync(delayMs = 500) {
  if (syncTimer) {
    clearTimeout(syncTimer);
  }
  syncTimer = setTimeout(() => {
    syncTimer = null;
    syncSnapshot();
  }, delayMs);
}

function validMessageId(value) {
  const id = Number(value);
  return Number.isInteger(id) && id >= 0 ? id : null;
}

async function executeCommand(command) {
  const op = command && command.op;
  const seq = command && command.seq;

  try {
    if (op === "open_message") {
      const id = validMessageId(command.id);
      if (id === null) {
        throw new Error("invalid message id");
      }
      await messenger.messageDisplay.open({ messageId: id, location: "tab", active: true });
    } else if (op === "mark_read") {
      const id = validMessageId(command.id);
      if (id === null) {
        throw new Error("invalid message id");
      }
      await messenger.messages.update(id, { read: true });
    } else if (op === "mark_all_read") {
      await markAllRead();
    } else if (op === "archive") {
      const id = validMessageId(command.id);
      if (id === null) {
        throw new Error("invalid message id");
      }
      await messenger.messages.archive([id]);
    } else if (op === "compose") {
      await messenger.compose.beginNew();
    } else if (op === "reply") {
      const id = validMessageId(command.id);
      if (id === null) {
        throw new Error("invalid message id");
      }
      await messenger.compose.beginReply(id, "replyToSender");
    } else if (op !== "refresh") {
      throw new Error(`unsupported operation: ${String(op)}`);
    }

    postNative({ type: "action_result", seq, op, ok: true });
    await syncSnapshot();
  } catch (error) {
    console.error(`Thunderbird Companion: ${String(op)} failed`, error);
    postNative({
      type: "action_result",
      seq,
      op,
      ok: false,
      error: String(error && error.message ? error.message : error),
    });
  }
}

function onNativeMessage(message) {
  if (!message || message.type !== "commands" || !Array.isArray(message.commands)) {
    return;
  }
  for (const command of message.commands) {
    commandChain = commandChain.then(() => executeCommand(command));
  }
}

function mailboxChanged() {
  scheduleSync();
}

messenger.messages.onNewMailReceived.addListener(mailboxChanged);
messenger.messages.onUpdated.addListener(mailboxChanged);
messenger.messages.onMoved.addListener(mailboxChanged);
messenger.messages.onDeleted.addListener(mailboxChanged);
messenger.accounts.onCreated.addListener(mailboxChanged);
messenger.accounts.onDeleted.addListener(mailboxChanged);
messenger.accounts.onUpdated.addListener(mailboxChanged);

setInterval(() => {
  if (nativePort) {
    postNative({ type: "poll" });
  }
}, COMMAND_POLL_INTERVAL_MS);

setInterval(() => {
  if (nativePort) {
    syncSnapshot();
  }
}, SNAPSHOT_INTERVAL_MS);

connectNative();
