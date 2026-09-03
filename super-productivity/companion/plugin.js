(() => {
  'use strict';

  const SCHEMA_VERSION = 1;
  const PROTOCOL_VERSION = 1;
  const COMPANION_VERSION = '1.0.2';
  const BRIDGE_NAME = 'noctalia-super-productivity';
  const COMMAND_POLL_MS = 700;
  const SNAPSHOT_REFRESH_MS = 10000;
  const MAX_UPCOMING = 50;
  const MAX_COMMAND_BYTES = 64 * 1024;
  const MAX_COMMAND_LIFETIME_MS = 30000;
  const MAX_FUTURE_SKEW_MS = 5000;
  const TEMP_FILE_MAX_AGE_MS = 5 * 60 * 1000;
  const MAX_TITLE_CHARS = 1000;
  const MAX_NOTES_CHARS = 16000;
  const MAX_LABEL_CHARS = 200;
  const MAX_TAGS = 32;
  const ACTIONS = new Set([
    'refresh',
    'add',
    'complete',
    'restore',
    'select',
    'timer_start',
    'timer_stop',
    'snooze',
  ]);

  let phase = 'starting';
  let lifecycleGeneration = 0;
  let processingCommands = false;
  let refreshPromise = null;
  let refreshAgain = false;
  let refreshTimer = null;
  let initRetryTimer = null;
  let initAttempts = 0;
  let commandInterval = null;
  let snapshotInterval = null;
  let currentTaskId = null;
  const responseQueue = [];

  const log = (...args) => console.log('[Noctalia companion]', ...args);
  const errorText = (error) => error instanceof Error ? error.message : String(error || 'Unknown error');

  // executeNodeScript is the only sanctioned filesystem boundary. this generated
  // program accepts plain JSON operations, never evaluates command-file content,
  // and owns atomic transitions between commands, processing, and responses.
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
      const cleanup = (dir, maxFiles = 100, maxAgeMs = 7 * 24 * 60 * 60 * 1000) => {
        const files = fs.readdirSync(dir).map((name) => {
          try {
            const target = path.join(dir, name);
            const stat = fs.statSync(target);
            return stat.isFile() ? { name, target, mtimeMs: stat.mtimeMs } : null;
          } catch (error) {
            console.error('[Noctalia companion] cleanup stat failed', dir, name, error);
            return null;
          }
        }).filter(Boolean).sort((a, b) => b.mtimeMs - a.mtimeMs);
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
          if (!(name.endsWith('.tmp') || name.includes('.tmp-'))) continue;
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
                action: command.action || 'unknown',
                ok: false,
                outcome: 'unknown',
                completedAt: Date.now(),
                error: 'The companion restarted while this command was running. Check task state before retrying.',
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
      let output;
      if (input.op === 'init') {
        cleanupTemporary(root);
        cleanupTemporary(commands);
        cleanup(failed);
        cleanup(responses);
        recoverProcessing();
        atomicWrite(path.join(root, 'connection.json'), input.connection);
        output = { root };
      } else if (input.op === 'claim') {
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
              const bad = fs.existsSync(target) ? target : source;
              if (fs.existsSync(bad)) fs.renameSync(bad, path.join(failed, name + '.invalid'));
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
      } else if (input.op === 'snapshot') {
        atomicWrite(path.join(root, 'snapshot.json'), input.snapshot);
        atomicWrite(path.join(root, 'connection.json'), input.connection);
        const errorPath = path.join(root, 'bridge-error.json');
        if (fs.existsSync(errorPath)) fs.unlinkSync(errorPath);
        output = { root };
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
    const raw = result.result;
    if (typeof raw === 'string') return JSON.parse(raw);
    return raw;
  }

  function connection(status = 'ready') {
    return {
      schemaVersion: SCHEMA_VERSION,
      protocolVersion: PROTOCOL_VERSION,
      companionVersion: COMPANION_VERSION,
      status,
      pid: null,
      updatedAt: Date.now(),
    };
  }

  function dayEndMs(day) {
    if (typeof day !== 'string') return null;
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
    if (!match) return null;
    const year = Number(match[1]);
    const month = Number(match[2]);
    const dayOfMonth = Number(match[3]);
    const nextDay = new Date(year, month - 1, dayOfMonth, 0, 0, 0, 0);
    if (nextDay.getFullYear() !== year
      || nextDay.getMonth() !== month - 1
      || nextDay.getDate() !== dayOfMonth) return null;
    nextDay.setDate(nextDay.getDate() + 1);
    const value = nextDay.getTime() - 1;
    return Number.isFinite(value) ? value : null;
  }

  function dateString(date) {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }
  function boundedText(value, maximum) {
    const text = String(value || '');
    if (text.length <= maximum) return text;
    const characters = Array.from(text);
    return characters.length <= maximum ? text : characters.slice(0, maximum - 1).join('') + '…';
  }
  function normalizeTask(task, projects, tags) {
    const dueWithTime = Number.isFinite(task.dueWithTime) ? task.dueWithTime : null;
    const dueAt = dueWithTime !== null ? dueWithTime : dayEndMs(task.dueDay);
    return {
      id: String(task.id || ''),
      title: boundedText(task.title, MAX_TITLE_CHARS),
      notes: boundedText(task.notes, MAX_NOTES_CHARS),
      isDone: task.isDone === true,
      project: boundedText(task.projectId && projects.get(task.projectId), MAX_LABEL_CHARS),
      tags: (Array.isArray(task.tagIds) ? task.tagIds : [])
        .slice(0, MAX_TAGS)
        .map((id) => boundedText(tags.get(id), MAX_LABEL_CHARS))
        .filter(Boolean),
      dueDay: task.dueDay || null,
      dueAt,
      dueKind: dueWithTime !== null ? 'time' : task.dueDay ? 'day' : null,
      timeEstimate: Number(task.timeEstimate) || 0,
      timeSpent: Number(task.timeSpent) || 0,
      created: Number(task.created) || 0,
    };
  }

  function compareDue(left, right) {
    if (left.dueAt !== right.dueAt) return left.dueAt - right.dueAt;
    if (left.dueKind !== right.dueKind) return left.dueKind === 'time' ? -1 : 1;
    if (left.created !== right.created) return left.created - right.created;
    return left.id.localeCompare(right.id);
  }

  async function buildSnapshot() {
    const [tasks, projectList, tagList] = await Promise.all([
      PluginAPI.getTasks(),
      PluginAPI.getAllProjects(),
      PluginAPI.getAllTags(),
    ]);
    const projects = new Map(projectList.map((project) => [project.id, project.title || '']));
    const tags = new Map(tagList.map((tag) => [tag.id, tag.title || '']));
    const normalized = tasks.map((task) => normalizeTask(task, projects, tags));
    const dueTasks = normalized.filter((task) => !task.isDone && Number.isFinite(task.dueAt));
    const now = Date.now();
    const upcoming = dueTasks.sort(compareDue).slice(0, MAX_UPCOMING);
    const currentTask = currentTaskId
      ? normalized.find((task) => task.id === currentTaskId) || null
      : null;
    return {
      schemaVersion: SCHEMA_VERSION,
      protocolVersion: PROTOCOL_VERSION,
      companionVersion: COMPANION_VERSION,
      generatedAt: now,
      currentTask,
      upcoming,
      counts: {
        active: normalized.filter((task) => !task.isDone).length,
        due: dueTasks.length,
        overdue: dueTasks.filter((task) => task.dueAt < now).length,
      },
    };
  }

  async function reportBridgeError(error) {
    try {
      await runNode({
        op: 'error',
        error: {
          schemaVersion: SCHEMA_VERSION,
          companionVersion: COMPANION_VERSION,
          updatedAt: Date.now(),
          error: errorText(error),
        },
      });
    } catch (reportError) {
      console.error('[Noctalia companion] could not write bridge error', reportError);
    }
  }
  async function runRefreshLoop(generation) {
    do {
      refreshAgain = false;
      try {
        const snapshot = await buildSnapshot();
        if (phase !== 'ready' || generation !== lifecycleGeneration) return false;
        await runNode({ op: 'snapshot', snapshot, connection: connection() });
      } catch (error) {
        if (phase === 'ready' && generation === lifecycleGeneration) {
          console.error('[Noctalia companion] snapshot failed', error);
          await reportBridgeError(error);
        }
        return false;
      }
    } while (refreshAgain && phase === 'ready' && generation === lifecycleGeneration);
    return phase === 'ready' && generation === lifecycleGeneration;
  }

  function refreshSnapshot() {
    if (phase !== 'ready') return Promise.resolve(false);
    refreshAgain = true;
    if (refreshPromise === null) {
      const generation = lifecycleGeneration;
      refreshPromise = runRefreshLoop(generation).finally(() => {
        refreshPromise = null;
      });
    }
    return refreshPromise;
  }

  function scheduleRefresh(delay = 200) {
    if (phase !== 'ready') return;
    const generation = lifecycleGeneration;
    if (refreshTimer !== null) clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => {
      refreshTimer = null;
      if (phase === 'ready' && generation === lifecycleGeneration) void refreshSnapshot();
    }, delay);
  }

  async function requireTask(taskId) {
    if (typeof taskId !== 'string' || taskId.length === 0 || taskId.length > 200) {
      throw new Error('A valid task id is required');
    }
    const tasks = await PluginAPI.getTasks();
    const task = tasks.find((candidate) => candidate.id === taskId);
    if (!task) throw new Error('Task not found');
    return task;
  }

  function commandPayload(command, fileName) {
    if (!command || command.schemaVersion !== SCHEMA_VERSION) throw new Error('Schema version mismatch');
    if (command.protocolVersion !== PROTOCOL_VERSION) throw new Error('Protocol version mismatch');
    if (typeof command.id !== 'string' || !/^[A-Za-z0-9._-]{1,160}$/.test(command.id)) {
      throw new Error('Invalid command id');
    }
    if (fileName !== command.id + '.json') throw new Error('Command file identity mismatch');
    if (!ACTIONS.has(command.action)) throw new Error('Unsupported action');
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

    if (command.action === 'refresh') {
      if (!await refreshSnapshot()) throw new Error('Snapshot refresh failed');
      return {};
    }

    if (command.action === 'add') {
      const title = String(payload.input || '').trim();
      if (!title) throw new Error('Task text cannot be empty');
      if (title.length > 5000) throw new Error('Task text is too long');
      const taskId = await PluginAPI.addTask({ title });
      scheduleRefresh(400);
      return { taskId };
    }

    const taskId = String(payload.taskId || '');

    if (command.action === 'select') {
      await requireTask(taskId);
      await PluginAPI.selectTask(taskId);
      return { taskId };
    }

    if (command.action === 'complete') {
      const task = await requireTask(taskId);
      if (task.isDone === true) throw new Error('Task is already complete');
      await PluginAPI.updateTask(taskId, { isDone: true });
      if (currentTaskId === taskId) currentTaskId = null;
      scheduleRefresh(150);
      return { taskId };
    }

    if (command.action === 'restore') {
      await PluginAPI.updateTask(taskId, { isDone: false, doneOn: null });
      scheduleRefresh(150);
      return { taskId };
    }

    if (command.action === 'timer_start') {
      await requireTask(taskId);
      PluginAPI.dispatchAction({ type: '[Task] SetCurrentTask', id: taskId });
      currentTaskId = taskId;
      scheduleRefresh(100);
      return { taskId, tracking: true };
    }

    if (command.action === 'timer_stop') {
      if (currentTaskId !== taskId) throw new Error('This task is not the tracked task');
      PluginAPI.dispatchAction({ type: '[Task] Toggle start' });
      currentTaskId = null;
      scheduleRefresh(100);
      return { taskId, tracking: false };
    }

    if (command.action === 'snooze') {
      await requireTask(taskId);
      const mode = String(payload.mode || '');
      if (mode === 'hour') {
        await PluginAPI.updateTask(taskId, {
          dueWithTime: Date.now() + 60 * 60 * 1000,
          dueDay: null,
          remindAt: null,
        });
      } else if (mode === 'tomorrow' || mode === 'week') {
        const date = new Date();
        date.setHours(0, 0, 0, 0);
        date.setDate(date.getDate() + (mode === 'tomorrow' ? 1 : 7));
        await PluginAPI.updateTask(taskId, {
          dueDay: dateString(date),
          dueWithTime: null,
          remindAt: null,
        });
      } else {
        throw new Error('Unsupported snooze option');
      }
      scheduleRefresh(150);
      return { taskId, mode };
    }

    throw new Error('Unsupported action');
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

  // a claimed mutation is never executed twice. its terminal response remains
  // queued until the processing-file cleanup succeeds, and new claims wait.
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
            action: command && command.action || 'unknown',
            ok: false,
            completedAt: Date.now(),
            error: errorText(error),
          };
        }
        responseQueue.push({ fileName: item.fileName, id, response });
      }
      await flushResponses();
      if (claimed.length > 0 && phase === 'ready' && generation === lifecycleGeneration) scheduleRefresh(250);
    } catch (error) {
      if (phase === 'ready' && generation === lifecycleGeneration) {
        console.error('[Noctalia companion] command polling failed', error);
        await reportBridgeError(error);
      }
    } finally {
      processingCommands = false;
    }
  }

  const taskHook = () => scheduleRefresh(180);
  PluginAPI.registerHook(PluginAPI.Hooks.TASK_COMPLETE, taskHook);
  PluginAPI.registerHook(PluginAPI.Hooks.TASK_UPDATE, taskHook);
  PluginAPI.registerHook(PluginAPI.Hooks.TASK_DELETE, taskHook);
  PluginAPI.registerHook(PluginAPI.Hooks.CURRENT_TASK_CHANGE, (payload) => {
    currentTaskId = payload && payload.current ? payload.current.id : null;
    scheduleRefresh(80);
  });
  PluginAPI.registerHook(PluginAPI.Hooks.ACTION, (payload) => {
    const action = payload && (payload.action || payload.type);
    const type = typeof action === 'string' ? action : action && action.type;
    if (typeof type === 'string' && (type.includes('Task') || type.includes('Project') || type.includes('Tag'))) {
      scheduleRefresh(300);
    }
  });

  function startIntervals(generation) {
    if (phase !== 'ready' || generation !== lifecycleGeneration) return;
    if (commandInterval === null) {
      commandInterval = setInterval(() => {
        if (phase === 'ready' && generation === lifecycleGeneration) void processCommands();
      }, COMMAND_POLL_MS);
    }
    if (snapshotInterval === null) {
      snapshotInterval = setInterval(() => {
        if (phase === 'ready' && generation === lifecycleGeneration) void refreshSnapshot();
      }, SNAPSHOT_REFRESH_MS);
    }
  }

  async function initialize() {
    if (phase === 'ready' || phase === 'unloaded') return;
    const generation = ++lifecycleGeneration;
    phase = 'starting';
    try {
      await runNode({ op: 'init', connection: connection('starting') });
      if (phase === 'unloaded' || generation !== lifecycleGeneration) return;
      phase = 'ready';
      if (initRetryTimer !== null) clearTimeout(initRetryTimer);
      initRetryTimer = null;
      if (!await refreshSnapshot()) throw new Error('Initial snapshot failed');
      if (phase !== 'ready' || generation !== lifecycleGeneration) return;
      initAttempts = 0;
      startIntervals(generation);
      void processCommands();
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
      buildSnapshot,
      commandPayload,
      compareDue,
      connection,
      dateString,
      dayEndMs,
      executeCommand,
      nodeScript: nodeScript(),
      normalizeTask,
      constants: { MAX_UPCOMING, SCHEMA_VERSION, PROTOCOL_VERSION },
    });
  }

  plugin.onReady(() => void initialize());

  if (typeof plugin.onUnload === 'function') {
    plugin.onUnload(() => {
      lifecycleGeneration += 1;
      phase = 'unloaded';
      if (refreshTimer !== null) clearTimeout(refreshTimer);
      if (initRetryTimer !== null) clearTimeout(initRetryTimer);
      if (commandInterval !== null) clearInterval(commandInterval);
      if (snapshotInterval !== null) clearInterval(snapshotInterval);
      refreshTimer = null;
      initRetryTimer = null;
      commandInterval = null;
      snapshotInterval = null;
      refreshPromise = null;
      refreshAgain = false;
    });
  }
})();
