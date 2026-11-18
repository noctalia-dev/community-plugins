(() => {
  'use strict';

  const SCHEMA_VERSION = 1;
  const PROTOCOL_VERSION = 2;
  const COMPANION_VERSION = '2.0.0';
  const BRIDGE_NAME = 'noctalia-super-productivity';
  const COMMAND_POLL_MS = 700;
  const CHANGE_COALESCE_MS = 200;
  const CONNECTION_HEARTBEAT_MS = 10000;
  const MAX_COMMAND_BYTES = 64 * 1024;
  const MAX_COMMAND_FILES = 100;
  const MAX_COMMAND_LIFETIME_MS = 30000;
  const MAX_FUTURE_SKEW_MS = 5000;
  const TEMP_FILE_MAX_AGE_MS = 5 * 60 * 1000;
  const MAX_REASON_CHARS = 160;

  let phase = 'starting';
  let lifecycleGeneration = 0;
  let processingCommands = false;
  let writingChange = false;
  let changeTimer = null;
  let initRetryTimer = null;
  let initAttempts = 0;
  let connectionInterval = null;
  let commandInterval = null;
  const pendingReasons = new Set();
  const responseQueue = [];

  const log = (...args) => console.log('[Noctalia companion]', ...args);
  const errorText = (error) => error instanceof Error ? error.message : String(error || 'Unknown error');

  // executeNodeScript is the only filesystem boundary. the generated program
  // accepts plain JSON operations and writes bridge files atomically.
  function nodeScript() {
    return `
      const fs = require('fs');
      const path = require('path');
      const os = require('os');
      const input = args[0];
      const environment = Object.create(null);
      if (fs.existsSync('/proc/self/environ')) {
        for (const entry of fs.readFileSync('/proc/self/environ', 'utf8').split(String.fromCharCode(0))) {
          const separator = entry.indexOf('=');
          if (separator > 0) environment[entry.slice(0, separator)] = entry.slice(separator + 1);
        }
      }
      const base = environment.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share');
      const root = path.join(base, ${JSON.stringify(BRIDGE_NAME)});
      const commands = path.join(root, 'commands');
      const processing = path.join(root, 'processing');
      const responses = path.join(root, 'responses');
      const failed = path.join(root, 'failed');
      for (const dir of [root, commands, processing, responses, failed]) fs.mkdirSync(dir, { recursive: true });

      const atomicWrite = (target, value) => {
        const tmp = target + '.tmp-' + Date.now() + '-' + Math.random().toString(16).slice(2);
        fs.writeFileSync(tmp, JSON.stringify(value, null, 2), { encoding: 'utf8', mode: 0o600 });
        fs.renameSync(tmp, target);
      };
      const safeName = (value) => typeof value === 'string' && /^[A-Za-z0-9._-]{1,180}$/.test(value);
      const boundedText = (value, maximum) => {
        const characters = Array.from(String(value || ''));
        return characters.length <= maximum ? characters.join('') : characters.slice(0, maximum).join('');
      };
      const cleanup = (dir, maxFiles = 100, maxAgeMs = 7 * 24 * 60 * 60 * 1000) => {
        const files = fs.readdirSync(dir).map((name) => {
          try {
            const target = path.join(dir, name);
            const stat = fs.statSync(target);
            return stat.isFile() ? { target, mtimeMs: stat.mtimeMs } : null;
          } catch (error) {
            console.error('[Noctalia companion] cleanup stat failed', dir, name, error);
            return null;
          }
        }).filter(Boolean).sort((left, right) => right.mtimeMs - left.mtimeMs);
        const now = Date.now();
        files.forEach((file, index) => {
          if (index >= maxFiles || now - file.mtimeMs > maxAgeMs) {
            try { fs.unlinkSync(file.target); }
            catch (error) { console.error('[Noctalia companion] cleanup unlink failed', file.target, error); }
          }
        });
      };
      const cleanupTemporary = (dir) => {
        const now = Date.now();
        for (const name of fs.readdirSync(dir)) {
          if (!(name.endsWith('.tmp') || /[.]tmp-[0-9]+-[0-9a-f]+$/.test(name))) continue;
          const target = path.join(dir, name);
          try {
            const stat = fs.statSync(target);
            if (stat.isFile() && now - stat.mtimeMs > ${TEMP_FILE_MAX_AGE_MS}) fs.unlinkSync(target);
          } catch (error) {
            console.error('[Noctalia companion] temporary cleanup failed', target, error);
          }
        }
      };
      const recoverProcessing = () => {
        for (const name of fs.readdirSync(processing).filter((value) => value.endsWith('.json'))) {
          if (!safeName(name)) continue;
          const target = path.join(processing, name);
          try {
            const command = JSON.parse(fs.readFileSync(target, 'utf8'));
            const id = command && command.id;
            if (safeName(id) && !fs.existsSync(path.join(responses, id + '.json'))) {
              atomicWrite(path.join(responses, id + '.json'), {
                schemaVersion: ${SCHEMA_VERSION},
                protocolVersion: ${PROTOCOL_VERSION},
                id,
                action: typeof command.action === 'string' ? boundedText(command.action, 80) : 'unknown',
                ok: false,
                outcome: 'unknown',
                completedAt: Date.now(),
                error: 'The companion restarted while this command was running. Try opening the task again.',
              });
            }
            fs.renameSync(target, path.join(failed, name + '.recovered-' + Date.now()));
          } catch (error) {
            console.error('[Noctalia companion] processing recovery failed', name, error);
            try { fs.renameSync(target, path.join(failed, name + '.recovery-failed-' + Date.now())); }
            catch (moveError) { console.error('[Noctalia companion] recovery quarantine failed', name, moveError); }
          }
        }
      };
      const removeFile = (target) => {
        if (fs.existsSync(target)) fs.unlinkSync(target);
      };

      let output;
      if (input.op === 'init') {
        for (const dir of [root, commands, processing, responses, failed]) cleanupTemporary(dir);
        cleanup(commands, ${MAX_COMMAND_FILES}, ${MAX_COMMAND_LIFETIME_MS * 2});
        cleanup(failed);
        cleanup(responses);
        recoverProcessing();
        removeFile(path.join(root, 'snapshot.json'));
        removeFile(path.join(root, 'bridge-error.json'));
        atomicWrite(path.join(root, 'connection.json'), input.connection);
        output = { root };
      } else if (input.op === 'connection') {
        atomicWrite(path.join(root, 'connection.json'), input.connection);
        output = { root };
      } else if (input.op === 'claim') {
        cleanup(commands, ${MAX_COMMAND_FILES}, ${MAX_COMMAND_LIFETIME_MS * 2});
        cleanup(failed);
        cleanup(responses);
        const claimed = [];
        const names = fs.readdirSync(commands).filter((name) => name.endsWith('.json')).sort().slice(0, 1);
        for (const name of names) {
          if (!safeName(name)) continue;
          const source = path.join(commands, name);
          const target = path.join(processing, name);
          try {
            const stat = fs.statSync(source);
            if (!stat.isFile() || stat.size > ${MAX_COMMAND_BYTES}) {
              fs.renameSync(source, path.join(failed, name + '.oversize'));
              continue;
            }
            fs.renameSync(source, target);
            const command = JSON.parse(fs.readFileSync(target, 'utf8'));
            claimed.push({ fileName: name, command });
          } catch (error) {
            console.error('[Noctalia companion] command claim failed', name, error);
            try {
              const invalid = fs.existsSync(target) ? target : source;
              if (fs.existsSync(invalid)) fs.renameSync(invalid, path.join(failed, name + '.invalid'));
            } catch (moveError) {
              console.error('[Noctalia companion] could not quarantine invalid command', name, moveError);
            }
          }
        }
        output = { root, claimed };
      } else if (input.op === 'respond') {
        if (!safeName(input.fileName) || !safeName(input.id)) throw new Error('Invalid response identity');
        atomicWrite(path.join(responses, input.id + '.json'), input.response);
        const claimedPath = path.join(processing, input.fileName);
        if (fs.existsSync(claimedPath)) fs.unlinkSync(claimedPath);
        output = { root };
      } else if (input.op === 'change') {
        const changePath = path.join(root, 'change.json');
        let previousSequence = 0;
        if (fs.existsSync(changePath)) {
          try {
            const previous = JSON.parse(fs.readFileSync(changePath, 'utf8'));
            if (Number.isSafeInteger(previous.sequence) && previous.sequence >= 0) previousSequence = previous.sequence;
          } catch (error) {
            console.error('[Noctalia companion] could not read previous change sequence', error);
          }
        }
        const changedAt = Date.now();
        const sequence = Math.max(previousSequence + 1, changedAt);
        if (!Number.isSafeInteger(sequence)) throw new Error('Change sequence exhausted');
        const change = {
          schemaVersion: ${SCHEMA_VERSION},
          protocolVersion: ${PROTOCOL_VERSION},
          companionVersion: ${JSON.stringify(COMPANION_VERSION)},
          sequence,
          changedAt,
          reason: boundedText(input.reason || 'change', ${MAX_REASON_CHARS}),
        };
        atomicWrite(changePath, change);
        removeFile(path.join(root, 'bridge-error.json'));
        output = { root, sequence, changedAt };
      } else if (input.op === 'error') {
        atomicWrite(path.join(root, 'bridge-error.json'), input.error);
        output = { root };
      } else {
        throw new Error('Unknown node operation');
      }
      return JSON.stringify(output);
    `;
  }

  async function runNode(input, timeout = 5000) {
    const result = await plugin.executeNodeScript({ script: nodeScript(), args: [input], timeout });
    if (!result || result.success !== true) {
      throw new Error(result && (result.error || result.message) || 'Node execution failed');
    }
    return typeof result.result === 'string' ? JSON.parse(result.result) : result.result;
  }

  function connection(status = 'ready') {
    return {
      schemaVersion: SCHEMA_VERSION,
      protocolVersion: PROTOCOL_VERSION,
      companionVersion: COMPANION_VERSION,
      status,
      updatedAt: Date.now(),
    };
  }

  function boundedReason(reasons) {
    const values = Array.from(reasons, (reason) => String(reason || '').trim()).filter(Boolean);
    const characters = Array.from(values.length > 0 ? values.join('+') : 'change');
    return characters.slice(0, MAX_REASON_CHARS).join('');
  }

  async function reportBridgeError(error) {
    try {
      await runNode({
        op: 'error',
        error: {
          schemaVersion: SCHEMA_VERSION,
          protocolVersion: PROTOCOL_VERSION,
          companionVersion: COMPANION_VERSION,
          updatedAt: Date.now(),
          error: errorText(error),
        },
      });
    } catch (reportError) {
      console.error('[Noctalia companion] could not write bridge error', reportError);
    }
  }

  function armChangeTimer(delay = CHANGE_COALESCE_MS) {
    if (phase !== 'ready' || changeTimer !== null) return;
    const generation = lifecycleGeneration;
    changeTimer = setTimeout(() => {
      changeTimer = null;
      if (phase === 'ready' && generation === lifecycleGeneration) void flushChanges(generation);
    }, delay);
  }

  function scheduleChange(reason, delay = CHANGE_COALESCE_MS) {
    if (phase !== 'ready') return;
    pendingReasons.add(reason);
    armChangeTimer(delay);
  }

  async function flushChanges(generation = lifecycleGeneration) {
    if (phase !== 'ready' || generation !== lifecycleGeneration || writingChange) return false;
    if (pendingReasons.size === 0) return true;

    const reasons = Array.from(pendingReasons);
    pendingReasons.clear();
    writingChange = true;
    try {
      await runNode({ op: 'change', reason: boundedReason(reasons) });
      return true;
    } catch (error) {
      reasons.forEach((reason) => pendingReasons.add(reason));
      if (phase === 'ready' && generation === lifecycleGeneration) {
        console.error('[Noctalia companion] change notification failed', error);
        await reportBridgeError(error);
      }
      return false;
    } finally {
      writingChange = false;
      if (phase === 'ready' && generation === lifecycleGeneration && pendingReasons.size > 0) {
        armChangeTimer(CHANGE_COALESCE_MS);
      }
    }
  }

  function commandPayload(command, fileName) {
    if (!command || command.schemaVersion !== SCHEMA_VERSION) throw new Error('Schema version mismatch');
    if (command.protocolVersion !== PROTOCOL_VERSION) throw new Error('Protocol version mismatch');
    if (typeof command.id !== 'string' || !/^[A-Za-z0-9._-]{1,160}$/.test(command.id)) {
      throw new Error('Invalid command id');
    }
    if (fileName !== command.id + '.json') throw new Error('Command file identity mismatch');
    if (command.action !== 'select') throw new Error('Unsupported action');
    if (!command.payload || typeof command.payload !== 'object' || Array.isArray(command.payload)) {
      throw new Error('Invalid command payload');
    }
    if (!Number.isSafeInteger(command.issuedAt) || !Number.isSafeInteger(command.expiresAt)) {
      throw new Error('Invalid command lifetime');
    }
    const now = Date.now();
    if (command.issuedAt > now + MAX_FUTURE_SKEW_MS
      || command.expiresAt <= command.issuedAt
      || command.expiresAt - command.issuedAt > MAX_COMMAND_LIFETIME_MS) {
      throw new Error('Invalid command lifetime');
    }
    if (command.expiresAt < now) throw new Error('Command expired before it could run');
    return command.payload;
  }

  async function executeCommand(command, fileName) {
    const payload = commandPayload(command, fileName);
    if (typeof payload.taskId !== 'string' || payload.taskId.length === 0 || payload.taskId.length > 200) {
      throw new Error('A valid task id is required');
    }
    await PluginAPI.selectTask(payload.taskId);
    return { taskId: payload.taskId };
  }

  async function flushResponses() {
    while (responseQueue.length > 0) {
      const item = responseQueue[0];
      try {
        await runNode({ op: 'respond', fileName: item.fileName, id: item.id, response: item.response });
        responseQueue.shift();
      } catch (error) {
        console.error('[Noctalia companion] response write failed; retrying before another command', error);
        return false;
      }
    }
    return true;
  }

  // a claimed selection is never executed twice. its terminal response stays
  // queued until processing-file cleanup succeeds, and new claims wait.
  async function processCommands() {
    if (phase !== 'ready' || processingCommands) return;
    const generation = lifecycleGeneration;
    processingCommands = true;
    try {
      if (!await flushResponses()) return;
      if (phase !== 'ready' || generation !== lifecycleGeneration) return;
      const result = await runNode({ op: 'claim' });
      if (phase !== 'ready' || generation !== lifecycleGeneration) return;
      const claimed = result && Array.isArray(result.claimed) ? result.claimed : [];
      for (const item of claimed) {
        const command = item.command;
        const fileMatch = typeof item.fileName === 'string' && /^([A-Za-z0-9._-]{1,160})\.json$/.exec(item.fileName);
        const id = fileMatch ? fileMatch[1] : 'invalid-' + Date.now();
        let response;
        try {
          const data = await executeCommand(command, item.fileName);
          response = {
            schemaVersion: SCHEMA_VERSION,
            protocolVersion: PROTOCOL_VERSION,
            id,
            action: command.action,
            ok: true,
            completedAt: Date.now(),
            data,
          };
        } catch (error) {
          response = {
            schemaVersion: SCHEMA_VERSION,
            protocolVersion: PROTOCOL_VERSION,
            id,
            action: command && typeof command.action === 'string' ? command.action : 'unknown',
            ok: false,
            completedAt: Date.now(),
            error: errorText(error),
          };
        }
        responseQueue.push({ fileName: item.fileName, id, response });
      }
      await flushResponses();
    } catch (error) {
      if (phase === 'ready' && generation === lifecycleGeneration) {
        console.error('[Noctalia companion] command polling failed', error);
        await reportBridgeError(error);
      }
    } finally {
      processingCommands = false;
    }
  }

  const registerChangeHook = (hook, reason) => {
    PluginAPI.registerHook(hook, () => scheduleChange(reason));
  };
  registerChangeHook(PluginAPI.Hooks.TASK_COMPLETE, 'taskComplete');
  registerChangeHook(PluginAPI.Hooks.TASK_UPDATE, 'taskUpdate');
  registerChangeHook(PluginAPI.Hooks.TASK_DELETE, 'taskDelete');
  registerChangeHook(PluginAPI.Hooks.CURRENT_TASK_CHANGE, 'currentTaskChange');
  PluginAPI.registerHook(PluginAPI.Hooks.ACTION, (payload) => {
    const action = payload && (payload.action || payload.type);
    const type = typeof action === 'string' ? action : action && action.type;
    if (typeof type === 'string' && (type.includes('Task') || type.includes('Project') || type.includes('Tag'))) {
      scheduleChange('action');
    }
  });

  function startIntervals(generation) {
    if (phase !== 'ready' || generation !== lifecycleGeneration) return;
    if (commandInterval === null) {
      commandInterval = setInterval(() => {
        if (phase === 'ready' && generation === lifecycleGeneration) void processCommands();
      }, COMMAND_POLL_MS);
    }
    if (connectionInterval === null) {
      connectionInterval = setInterval(() => {
        if (phase !== 'ready' || generation !== lifecycleGeneration) return;
        void runNode({ op: 'connection', connection: connection() }).catch((error) => {
          console.error('[Noctalia companion] connection heartbeat failed', error);
        });
      }, CONNECTION_HEARTBEAT_MS);
    }
  }

  async function initialize() {
    if (phase === 'ready' || phase === 'unloaded') return;
    const generation = ++lifecycleGeneration;
    phase = 'starting';
    try {
      await runNode({ op: 'init', connection: connection() });
      if (phase === 'unloaded' || generation !== lifecycleGeneration) return;
      phase = 'ready';
      if (initRetryTimer !== null) clearTimeout(initRetryTimer);
      initRetryTimer = null;
      initAttempts = 0;
      startIntervals(generation);
      void processCommands();
      scheduleChange('ready', 0);
      log('ready');
    } catch (error) {
      if (phase === 'unloaded' || generation !== lifecycleGeneration) return;
      phase = 'failed';
      initAttempts += 1;
      console.error('[Noctalia companion] initialization failed', error);
      await reportBridgeError(error);
      if (phase === 'unloaded' || generation !== lifecycleGeneration) return;
      const delay = Math.min(30000, 1000 * 2 ** Math.min(initAttempts - 1, 5));
      initRetryTimer = setTimeout(() => {
        initRetryTimer = null;
        if (phase !== 'unloaded' && generation === lifecycleGeneration) void initialize();
      }, delay);
    }
  }

  if (typeof globalThis.__NOCTALIA_SP_TEST_HOOK__ === 'function') {
    globalThis.__NOCTALIA_SP_TEST_HOOK__({
      boundedReason,
      connection,
      executeCommand,
      initialize,
      nodeScript: nodeScript(),
      constants: { MAX_REASON_CHARS, SCHEMA_VERSION, PROTOCOL_VERSION },
    });
  }

  plugin.onReady(() => void initialize());

  if (typeof plugin.onUnload === 'function') {
    plugin.onUnload(() => {
      lifecycleGeneration += 1;
      phase = 'unloaded';
      if (changeTimer !== null) clearTimeout(changeTimer);
      if (initRetryTimer !== null) clearTimeout(initRetryTimer);
      if (commandInterval !== null) clearInterval(commandInterval);
      if (connectionInterval !== null) clearInterval(connectionInterval);
      changeTimer = null;
      initRetryTimer = null;
      commandInterval = null;
      connectionInterval = null;
      pendingReasons.clear();
      responseQueue.length = 0;
      void runNode({ op: 'connection', connection: connection('unloaded') }).catch((error) => {
        console.error('[Noctalia companion] could not mark connection unloaded', error);
      });
    });
  }
})();
