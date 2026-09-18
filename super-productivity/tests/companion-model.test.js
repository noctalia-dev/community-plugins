const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

async function main() {
  const sourcePath = path.join(__dirname, '..', 'companion', 'plugin.js');
  const source = fs.readFileSync(sourcePath, 'utf8');
  const dataHome = fs.mkdtempSync(path.join(os.tmpdir(), 'noctalia-sp-node-test-'));
  const bridgeRoot = path.join(dataHome, 'noctalia-super-productivity');
  const hooks = {};
  const calls = [];
  const nodeOperations = [];
  let model;
  let unload;
  let sustainedHooks;
  const companionTimeouts = new Set();
  const companionIntervals = new Set();
  const pendingNodeWork = new Set();

  const sandboxFs = new Proxy(fs, {
    get(target, property) {
      if (property === 'existsSync') {
        return (filePath) => filePath === '/proc/self/environ' || target.existsSync(filePath);
      }
      if (property === 'readFileSync') {
        return (filePath, ...args) => filePath === '/proc/self/environ'
          ? `XDG_DATA_HOME=${dataHome}${String.fromCharCode(0)}`
          : target.readFileSync(filePath, ...args);
      }
      return target[property];
    },
  });
  const allowedModules = { fs: sandboxFs, path, os };
  const runNodeScript = async (script, input, requiredModules = []) => vm.runInNewContext(
    `(async () => { ${script} })()`,
    {
      args: [input],
      console,
      require(name) {
        assert.ok(Object.hasOwn(allowedModules, name), `unexpected bridge module: ${name}`);
        requiredModules.push(name);
        return allowedModules[name];
      },
    },
  );

  const context = {
    console,
    setTimeout(callback, delay) {
      const timer = setTimeout(() => {
        companionTimeouts.delete(timer);
        callback();
      }, delay);
      companionTimeouts.add(timer);
      return timer;
    },
    clearTimeout(timer) {
      companionTimeouts.delete(timer);
      clearTimeout(timer);
    },
    setInterval() {
      const timer = {};
      companionIntervals.add(timer);
      return timer;
    },
    clearInterval(timer) { companionIntervals.delete(timer); },
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
      async selectTask(id) {
        calls.push(['selectTask', id]);
      },
    },
    __NOCTALIA_SP_TEST_HOOK__(value) {
      model = value;
    },
    plugin: {
      executeNodeScript({ script, args }) {
        nodeOperations.push(args[0]);
        const work = (async () => {
          try {
            // keep the filesystem boundary asynchronous, including unload writes.
            await new Promise((resolve) => setImmediate(resolve));
            return { success: true, result: await runNodeScript(script, args[0]) };
          } catch (error) {
            return { success: false, error: error.message };
          }
        })();
        pendingNodeWork.add(work);
        void work.then(() => pendingNodeWork.delete(work));
        return work;
      },
      onReady() {},
      onUnload(handler) {
        unload = handler;
      },
    },
  };

  try {
    vm.createContext(context);
    vm.runInContext(source, context, { filename: sourcePath });
    assert.ok(model, 'model functions were exposed');

    assert.doesNotMatch(
      source,
      /PluginAPI\.(?:getTasks|getAllProjects|getAllTags|addTask|updateTask|dispatchAction)\b/,
      'the companion must not read or mutate task data',
    );
    assert.doesNotMatch(source, /input\.op === 'snapshot'/, 'snapshot generation must be removed');

    const connection = model.connection('starting');
    assert.equal(connection.status, 'starting');
    assert.equal(connection.schemaVersion, 1);
    assert.equal(connection.protocolVersion, 2);
    assert.equal(typeof connection.companionVersion, 'string');

    const combinedReason = model.boundedReason(['taskUpdate', 'taskComplete']);
    assert.equal(combinedReason, 'taskUpdate+taskComplete');
    assert.equal(
      Array.from(model.boundedReason(['x'.repeat(model.constants.MAX_REASON_CHARS + 20)])).length,
      model.constants.MAX_REASON_CHARS,
    );

    fs.mkdirSync(bridgeRoot, { recursive: true });
    fs.writeFileSync(path.join(bridgeRoot, 'snapshot.json'), '{"legacy":true}');
    const validResponsePath = path.join(bridgeRoot, 'responses', 'abc.tmp-def.json');
    fs.mkdirSync(path.dirname(validResponsePath), { recursive: true });
    fs.writeFileSync(validResponsePath, '{}');
    const oldTimestamp = new Date(Date.now() - 6 * 60 * 1000);
    fs.utimesSync(validResponsePath, oldTimestamp, oldTimestamp);
    const oldTemporaryPaths = ['connection.json.tmp-123-abc', 'change.json.tmp-123-abc']
      .map((name) => path.join(bridgeRoot, name));
    for (const file of oldTemporaryPaths) {
      fs.writeFileSync(file, '{}');
      fs.utimesSync(file, oldTimestamp, oldTimestamp);
    }
    const freshTemporaryPath = path.join(bridgeRoot, 'connection.json.tmp-124-def');
    fs.writeFileSync(freshTemporaryPath, '{}');
    const requiredModules = [];
    const initResult = await runNodeScript(
      model.nodeScript,
      { op: 'init', connection },
      requiredModules,
    );
    assert.deepEqual(requiredModules, ['fs', 'path', 'os']);
    assert.equal(JSON.parse(initResult).root, bridgeRoot);
    assert.equal(fs.existsSync(path.join(bridgeRoot, 'snapshot.json')), false, 'legacy snapshots are removed');
    assert.ok(fs.existsSync(validResponsePath), 'valid ids containing .tmp- survive temporary cleanup');
    for (const file of oldTemporaryPaths) {
      assert.equal(fs.existsSync(file), false, 'the generated script removes old timestamped temporary files');
    }
    assert.ok(fs.existsSync(freshTemporaryPath), 'fresh genuine temporary files survive cleanup');
    fs.unlinkSync(freshTemporaryPath);

    const connectionPath = path.join(bridgeRoot, 'connection.json');
    assert.ok(fs.existsSync(connectionPath));
    assert.equal(fs.statSync(connectionPath).mode & 0o777, 0o600);

    await runNodeScript(model.nodeScript, { op: 'change', reason: 'x'.repeat(300) });
    const firstChange = JSON.parse(fs.readFileSync(path.join(bridgeRoot, 'change.json'), 'utf8'));
    assert.equal(firstChange.schemaVersion, 1);
    assert.equal(firstChange.protocolVersion, 2);
    assert.equal(firstChange.companionVersion, connection.companionVersion);
    assert.ok(Number.isSafeInteger(firstChange.sequence));
    assert.ok(Number.isSafeInteger(firstChange.changedAt));
    assert.equal(Array.from(firstChange.reason).length, model.constants.MAX_REASON_CHARS);

    await runNodeScript(model.nodeScript, { op: 'change', reason: 'taskDelete' });
    const secondChange = JSON.parse(fs.readFileSync(path.join(bridgeRoot, 'change.json'), 'utf8'));
    assert.ok(secondChange.sequence > firstChange.sequence, 'change sequence is monotonic');
    assert.equal(secondChange.reason, 'taskDelete');
    assert.equal(
      fs.readdirSync(bridgeRoot).some((name) => name.includes('.tmp-')),
      false,
      'atomic writes leave no temporary files',
    );

    const commandDirectory = path.join(bridgeRoot, 'commands');
    for (let index = 0; index < 105; index += 1) {
      fs.writeFileSync(path.join(commandDirectory, `queued-${String(index).padStart(3, '0')}.json`), '{}');
    }
    await runNodeScript(model.nodeScript, { op: 'claim' });
    assert.ok(
      fs.readdirSync(commandDirectory).length <= 99,
      'command polling caps the on-disk queue before claiming work',
    );

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

    const badSchema = validCommand('bad-schema', 'select', { taskId: 'task-1' });
    badSchema.schemaVersion += 1;
    await assert.rejects(model.executeCommand(badSchema, 'bad-schema.json'), /Schema version mismatch/);

    const badProtocol = validCommand('bad-protocol', 'select', { taskId: 'task-1' });
    badProtocol.protocolVersion += 1;
    await assert.rejects(model.executeCommand(badProtocol, 'bad-protocol.json'), /Protocol version mismatch/);

    await assert.rejects(
      model.executeCommand(
        validCommand('unsupported-complete', 'complete', { taskId: 'task-1' }),
        'unsupported-complete.json',
      ),
      /Unsupported action/,
    );

    await assert.rejects(
      model.executeCommand(validCommand('bad-task', 'select', { taskId: '' }), 'bad-task.json'),
      /valid task id/,
    );
    await model.executeCommand(
      validCommand('select-1', 'select', { taskId: 'task-1' }),
      'select-1.json',
    );
    assert.deepEqual(calls, [['selectTask', 'task-1']], 'selection does not read the task list first');

    nodeOperations.length = 0;
    await model.initialize();
    await new Promise((resolve) => setTimeout(resolve, 30));
    nodeOperations.length = 0;
    hooks.taskUpdate();
    hooks.taskComplete();
    hooks.currentTaskChange();
    hooks.action({ type: '[Task] Update' });
    hooks.action({ type: '[Settings] Update' });
    await new Promise((resolve) => setTimeout(resolve, 260));
    const changeOperations = nodeOperations.filter((operation) => operation.op === 'change');
    assert.equal(changeOperations.length, 1, 'a hook burst writes one coalesced notification');
    assert.equal(
      changeOperations[0].reason,
      'taskUpdate+taskComplete+currentTaskChange+action',
    );

    nodeOperations.length = 0;
    sustainedHooks = setInterval(() => hooks.taskUpdate(), 50);
    await new Promise((resolve) => setTimeout(resolve, 330));
    assert.ok(
      nodeOperations.some((operation) => operation.op === 'change'),
      'a sustained hook stream cannot postpone notifications indefinitely',
    );
    clearInterval(sustainedHooks);
    await new Promise((resolve) => setTimeout(resolve, 250));

    assert.equal(typeof unload, 'function');
  } finally {
    clearInterval(sustainedHooks);
    try {
      if (typeof unload === 'function') unload();
      for (const timer of companionTimeouts) clearTimeout(timer);
      companionTimeouts.clear();
      companionIntervals.clear();
      do {
        await Promise.all([...pendingNodeWork]);
        await new Promise((resolve) => setImmediate(resolve));
      } while (pendingNodeWork.size > 0);
      if (typeof unload === 'function') {
        const connection = JSON.parse(fs.readFileSync(path.join(bridgeRoot, 'connection.json'), 'utf8'));
        assert.equal(connection.status, 'unloaded');
      }
    } finally {
      fs.rmSync(dataHome, { recursive: true, force: true });
    }
  }
  console.log('companion change-notification and select transport tests passed');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
