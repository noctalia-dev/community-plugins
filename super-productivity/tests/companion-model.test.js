const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');

async function main() {
  const sourcePath = path.join(__dirname, '..', 'companion', 'plugin.js');
  const source = fs.readFileSync(sourcePath, 'utf8');

  const hooks = {};
  const calls = [];
  let tasks = [];
  let model;
  const context = {
    console,
    setTimeout,
    clearTimeout,
    setInterval: () => 1,
    clearInterval: () => {},
    PluginAPI: {
      Hooks: {
        TASK_COMPLETE: 'taskComplete',
        TASK_UPDATE: 'taskUpdate',
        TASK_DELETE: 'taskDelete',
        CURRENT_TASK_CHANGE: 'currentTaskChange',
        ACTION: 'action',
      },
      registerHook(name, handler) {
        hooks[name] = handler;
      },
      async getTasks() {
        return tasks;
      },
      async getAllProjects() {
        return [{ id: 'p1', title: 'Work' }];
      },
      async getAllTags() {
        return [{ id: 't1', title: 'urgent' }];
      },
      async addTask(input) {
        calls.push(['addTask', input]);
        return 'created';
      },
      async updateTask(id, changes) {
        calls.push(['updateTask', id, changes]);
      },
      async selectTask(id) {
        calls.push(['selectTask', id]);
      },
      dispatchAction(action) {
        calls.push(['dispatchAction', action]);
      },
    },
    __NOCTALIA_SP_TEST_HOOK__(value) {
      model = value;
    },
    plugin: {
      onReady() {},
    },
  };
  vm.createContext(context);
  vm.runInContext(source, context, { filename: sourcePath });

  assert.ok(model, 'model functions were exposed');

  const bridgeRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'noctalia-sp-node-test-'));
  try {
    const input = { op: 'init', connection: model.connection('starting') };
    const script = model.nodeScript;
    const sandboxFs = new Proxy(fs, {
      get(target, property) {
        if (property === 'existsSync') {
          return (filePath) => filePath === '/proc/self/environ' || target.existsSync(filePath);
        }
        if (property === 'readFileSync') {
          return (filePath, ...args) => filePath === '/proc/self/environ'
            ? `XDG_DATA_HOME=${bridgeRoot}${String.fromCharCode(0)}`
            : target.readFileSync(filePath, ...args);
        }
        return target[property];
      },
    });
    const requiredModules = [];
    const allowedModules = { fs: sandboxFs, path, os };
    const sandboxRequire = (name) => {
      assert.ok(Object.hasOwn(allowedModules, name), `unexpected bridge module: ${name}`);
      requiredModules.push(name);
      return allowedModules[name];
    };
    assert.doesNotMatch(
      script,
      /\b(?:eval|Function|process\.exit)\b/,
      'bridge script must not use dynamic execution',
    );
    const result = await vm.runInNewContext(`(async () => { ${script} })()`, {
      args: [input],
      console,
      require: sandboxRequire,
    });
    assert.deepEqual(
      requiredModules,
      ['fs', 'path', 'os'],
      'bridge script uses only direct executor modules',
    );
    assert.equal(JSON.parse(result).root, path.join(bridgeRoot, 'noctalia-super-productivity'));
    assert.ok(fs.existsSync(path.join(bridgeRoot, 'noctalia-super-productivity', 'connection.json')));
  } finally {
    fs.rmSync(bridgeRoot, { recursive: true, force: true });
  }

  const dayEnd = model.dayEndMs('2026-08-20');
  const nextDay = new Date(2026, 7, 21, 0, 0, 0, 0).getTime();
  assert.equal(dayEnd, nextDay - 1);
  assert.equal(model.dayEndMs('bad-date'), null);
  assert.equal(model.dayEndMs('2026-02-31'), null);
  assert.equal(model.dayEndMs('2024-02-29'), new Date(2024, 2, 1, 0, 0, 0, 0).getTime() - 1);

  const projects = new Map([['p1', 'Work']]);
  const tags = new Map([['t1', 'urgent']]);
  const timed = model.normalizeTask({
    id: 'a',
    title: 'Timed',
    notes: 'note',
    timeEstimate: 30 * 60 * 1000,
    timeSpent: 5 * 60 * 1000,
    isDone: false,
    projectId: 'p1',
    tagIds: ['t1'],
    subTaskIds: [],
    created: 2,
    dueWithTime: 1000,
  }, projects, tags);
  assert.equal(timed.project, 'Work');
  assert.deepEqual(Array.from(timed.tags), ['urgent']);
  assert.equal(timed.dueAt, 1000);
  assert.equal(timed.dueKind, 'time');

  const sameTimeDay = { id: 'b', dueAt: 1000, dueKind: 'day', created: 1 };
  assert.ok(model.compareDue(timed, sameTimeDay) < 0, 'timed task wins an equal timestamp');
  const earlier = { id: 'c', dueAt: 500, dueKind: 'time', created: 10 };
  assert.ok(model.compareDue(earlier, timed) < 0, 'earlier due timestamp sorts first');

  tasks = Array.from({ length: 60 }, (_, index) => ({
    id: `task-${index}`,
    title: `Task ${index}`,
    notes: '',
    timeEstimate: 0,
    timeSpent: 0,
    isDone: false,
    projectId: 'p1',
    tagIds: [],
    subTaskIds: [],
    created: index,
    dueWithTime: Date.now() - index - 1,
  }));
  const snapshot = await model.buildSnapshot();
  assert.equal(snapshot.upcoming.length, 50, 'wire payload is bounded');
  assert.equal(snapshot.counts.due, 60, 'diagnostic count uses the full due set');
  assert.equal(snapshot.counts.overdue, 60);
  hooks.currentTaskChange({ current: tasks[55] });
  const trackedSnapshot = await model.buildSnapshot();
  assert.equal(
    trackedSnapshot.currentTask.id,
    tasks[55].id,
    'tracked task remains available outside the bounded list',
  );
  hooks.currentTaskChange({ current: null });

  const validCommand = (id, action, payload) => {
    const issuedAt = Date.now();
    return {
      schemaVersion: model.constants.SCHEMA_VERSION,
      protocolVersion: model.constants.PROTOCOL_VERSION,
      id,
      action,
      issuedAt,
      expiresAt: issuedAt + 12000,
      payload,
    };
  };
  const badSchema = validCommand('bad-schema', 'add', { input: 'Task' });
  badSchema.schemaVersion += 1;
  await assert.rejects(model.executeCommand(badSchema, 'bad-schema.json'), /Schema version mismatch/);

  const badProtocol = validCommand('bad-protocol', 'add', { input: 'Task' });
  badProtocol.protocolVersion += 1;
  await assert.rejects(model.executeCommand(badProtocol, 'bad-protocol.json'), /Protocol version mismatch/);

  const unsupported = validCommand('unsupported', 'delete_all', {});
  await assert.rejects(model.executeCommand(unsupported, 'unsupported.json'), /Unsupported action/);

  const badPayload = validCommand('bad-payload', 'add', []);
  await assert.rejects(model.executeCommand(badPayload, 'bad-payload.json'), /Invalid command payload/);

  const futureCommand = validCommand('future', 'add', { input: 'Task' });
  futureCommand.issuedAt += 6000;
  futureCommand.expiresAt += 6000;
  await assert.rejects(model.executeCommand(futureCommand, 'future.json'), /Invalid command lifetime/);

  await assert.rejects(
    model.executeCommand(validCommand('wrong-file', 'add', { input: 'Task' }), 'other.json'),
    /identity mismatch/,
  );
  const expiredCommand = validCommand('expired', 'add', { input: 'Task' });
  expiredCommand.issuedAt -= 20000;
  expiredCommand.expiresAt -= 20000;
  await assert.rejects(model.executeCommand(expiredCommand, 'expired.json'), /expired/);
  tasks = [tasks[0]];
  await model.executeCommand(
    validCommand('select-1', 'select', { taskId: tasks[0].id }),
    'select-1.json',
  );
  assert.equal(JSON.stringify(calls.at(-1)), JSON.stringify(['selectTask', tasks[0].id]));

  await model.executeCommand(
    validCommand('add-1', 'add', { input: 'Ship +Work #urgent @tomorrow 30m' }),
    'add-1.json',
  );
  assert.equal(
    JSON.stringify(calls.at(-1)),
    JSON.stringify(['addTask', { title: 'Ship +Work #urgent @tomorrow 30m' }]),
  );

  await model.executeCommand(
    validCommand('timer-1', 'timer_start', { taskId: tasks[0].id }),
    'timer-1.json',
  );
  assert.equal(
    JSON.stringify(calls.at(-1)),
    JSON.stringify(['dispatchAction', { type: '[Task] SetCurrentTask', id: tasks[0].id }]),
  );

  await model.executeCommand(
    validCommand('timer-2', 'timer_stop', { taskId: tasks[0].id }),
    'timer-2.json',
  );
  assert.equal(JSON.stringify(calls.at(-1)), JSON.stringify(['dispatchAction', { type: '[Task] Toggle start' }]));
  await assert.rejects(
    model.executeCommand(
      validCommand('timer-3', 'timer_stop', { taskId: tasks[0].id }),
      'timer-3.json',
    ),
    /not the tracked task/,
  );

  await model.executeCommand(
    validCommand('complete-1', 'complete', { taskId: tasks[0].id }),
    'complete-1.json',
  );
  assert.equal(
    JSON.stringify(calls.at(-1)),
    JSON.stringify(['updateTask', tasks[0].id, { isDone: true }]),
  );
  tasks[0].isDone = true;
  const callCount = calls.length;
  await assert.rejects(
    model.executeCommand(
      validCommand('complete-2', 'complete', { taskId: tasks[0].id }),
      'complete-2.json',
    ),
    /already complete/,
  );
  assert.equal(calls.length, callCount, 'an already-complete task must not be updated again');
  await model.executeCommand(
    validCommand('restore-1', 'restore', { taskId: tasks[0].id }),
    'restore-1.json',
  );
  assert.equal(
    JSON.stringify(calls.at(-1)),
    JSON.stringify(['updateTask', tasks[0].id, { isDone: false, doneOn: null }]),
  );

  const snoozeStart = Date.now() + 60 * 60 * 1000;
  await model.executeCommand(
    validCommand('snooze-1', 'snooze', { taskId: tasks[0].id, mode: 'hour' }),
    'snooze-1.json',
  );
  const snoozeEnd = Date.now() + 60 * 60 * 1000;
  const [snoozeCall, snoozeTaskId, snoozeChanges] = calls.at(-1);
  assert.equal(snoozeCall, 'updateTask');
  assert.equal(snoozeTaskId, tasks[0].id);
  assert.ok(
    snoozeChanges.dueWithTime >= snoozeStart && snoozeChanges.dueWithTime <= snoozeEnd,
  );
  assert.equal(snoozeChanges.dueDay, null);
  assert.equal(snoozeChanges.remindAt, null);

  await assert.rejects(
    model.executeCommand(
      validCommand('snooze-2', 'snooze', { taskId: tasks[0].id, mode: 'later' }),
      'snooze-2.json',
    ),
    /Unsupported snooze option/,
  );

  console.log('companion model, bridge, and command tests passed');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
