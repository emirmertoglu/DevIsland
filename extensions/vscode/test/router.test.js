'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const { createRouter } = require('../router');
const { createFake } = require('./fake-vscode');
const crypto = require('node:crypto');
function root(t) { const root = fs.mkdtempSync('/tmp/di-vsc-test-'); t.after(() => fs.rmSync(root, { recursive: true, force: true })); return root; }
function record(router) { return JSON.parse(fs.readFileSync(router.registryPath)); }
function request(record, terminal = record.terminals[0], extra = {}) {
  return { version: 1, action: 'focus', requestID: 'test-request', windowID: record.windowID, terminalID: terminal.id, processID: terminal.processID, token: record.token, ...extra };
}
function send(record, message) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(record.socketPath); let buffer = '';
    socket.setTimeout(2200, () => { socket.destroy(); reject(new Error('timeout')); });
    socket.on('error', reject);
    socket.on('connect', () => socket.write(JSON.stringify(message) + '\n'));
    socket.on('data', chunk => { buffer += chunk; if (buffer.includes('\n')) { socket.end(); resolve(JSON.parse(buffer.split('\n')[0])); } });
  });
}
test('two windows with same project and same terminal labels focus their exact instance', async t => {
  const dir = root(t), group = [], a = createFake([101, 102], group), b = createFake([201, 202], group);
  const ra = await createRouter(a, { root: dir }), rb = await createRouter(b, { root: dir });
  t.after(() => { ra.dispose(); rb.dispose(); });
  const wa = record(ra), wb = record(rb);
  let reply = await send(wb, request(wb, wb.terminals[1]));
  assert.equal(reply.ok, true); assert.equal(reply.windowID, wb.windowID);
  assert.equal(b.window.activeTerminal, b.window.terminals[1]); assert.equal(a.window.activeTerminal, undefined);
  reply = await send(wa, request(wa));
  assert.equal(reply.ok, true); assert.equal(a.window.activeTerminal, a.window.terminals[0]);
  assert.equal(a.window.state.focused, true); assert.equal(b.window.state.focused, false);
  assert.deepEqual(a.commands.calls, ['workbench.action.focusWindow']);
});
test('wrong token, instance or PID never executes a focus', async t => {
  const fake = createFake([101]), router = await createRouter(fake, { root: root(t) }); t.after(() => router.dispose());
  const r = record(router);
  for (const extra of [{ token: '0'.repeat(64) }, { windowID: 'other' }, { processID: 999 }, { terminalID: 'missing' }, { action: 'execute-command' }]) {
    const reply = await send(r, request(r, undefined, extra)); assert.equal(reply.ok, false);
  }
  assert.equal(fake.commands.calls.length, 0); assert.equal(fake.window.activeTerminal, undefined);
});
test('closed terminals are rejected, registry refresh removes them', async t => {
  const fake = createFake([101]), router = await createRouter(fake, { root: root(t) }); t.after(() => router.dispose());
  const r = record(router); fake.window.terminals[0].exitStatus = { code: 0 };
  assert.equal((await send(r, request(r))).ok, false);
  fake.window.terminals = []; await router.refresh(); assert.deepEqual(record(router).terminals, []);
  assert.equal(fake.commands.calls.length, 0);
});
test('missing shell PID, dead terminals and non-file workspaces are excluded', async t => {
  const fake = createFake([101, 102]); fake.window.terminals[0].processId = Promise.resolve(undefined); fake.window.terminals[1].exitStatus = { code: 0 };
  fake.workspace.workspaceFolders.push({ uri: { scheme: 'vscode-remote', fsPath: '/remote' } });
  const router = await createRouter(fake, { root: root(t) }); t.after(() => router.dispose());
  assert.deepEqual(record(router).terminals, []); assert.deepEqual(record(router).workspaceFolders, ['/Projects/same-project']);
});
test('unavailable focus command fails without selecting another terminal', async t => {
  const fake = createFake([101]); fake.commands.getCommands = async () => [];
  const router = await createRouter(fake, { root: root(t) }); t.after(() => router.dispose());
  const r = record(router), reply = await send(r, request(r));
  assert.equal(reply.error, 'focus-unavailable'); assert.equal(fake.window.activeTerminal, undefined);
});
test('a focus that was not confirmed is an explicit failure', async t => {
  const fake = createFake([101]); fake.commands.executeCommand = async () => {};
  const router = await createRouter(fake, { root: root(t) }); t.after(() => router.dispose());
  const r = record(router), reply = await send(r, request(r));
  assert.equal(reply.ok, false); assert.equal(reply.selected, true); assert.equal(reply.windowFocused, false);
});
test('private permissions and per-window disposal preserve the other connection', async t => {
  const dir = root(t), a = await createRouter(createFake([101]), { root: dir }), b = await createRouter(createFake([201]), { root: dir });
  t.after(() => { a.dispose(); b.dispose(); });
  const r = record(a);
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(a.registryPath).mode & 0o777, 0o600);
  assert.equal(fs.statSync(r.socketPath).mode & 0o777, 0o600);
  a.dispose(); assert.equal(fs.existsSync(a.registryPath), false); assert.equal(fs.existsSync(b.registryPath), true);
});
test('an insecure or symlinked root is rejected', async t => {
  const dir = root(t); fs.chmodSync(dir, 0o755);
  await assert.rejects(createRouter(createFake([101]), { root: dir }), /Unsafe/);
  fs.chmodSync(dir, 0o700); const link = dir + '-link'; fs.symlinkSync(dir, link); t.after(() => fs.unlinkSync(link));
  await assert.rejects(createRouter(createFake([101]), { root: link }), /Unsafe/);
});
test('malformed and oversized input cannot cause an editor action', async t => {
  const fake = createFake([101]), router = await createRouter(fake, { root: root(t) }); t.after(() => router.dispose());
  const r = record(router);
  const reply = await new Promise((resolve,reject) => {
    const socket = net.createConnection(r.socketPath);let data='';socket.on('error',reject);
    socket.on('connect',()=>socket.write('not-json\n'));
    socket.on('data',chunk=>{data+=chunk;if(data.includes('\n')){socket.end();resolve(JSON.parse(data));}});
  });
  assert.equal(reply.ok,false);
  await new Promise(resolve=>{const socket=net.createConnection(r.socketPath);socket.on('connect',()=>socket.write('x'.repeat(5000)));socket.on('error',resolve);socket.on('close',resolve);});
  assert.equal(fake.commands.calls.length,0);
});
test('external Claude PTY routes to its exact live webview and unregisters cleanly', async t => {
  const fake = createFake([101]);const router = await createRouter(fake, {root:root(t)});t.after(()=>router.dispose());
  let focused=false,alive=true;
  const id=crypto.randomUUID();const registration=router.registerExternalTerminal({id,processID:303,name:'Living Terminal',isAlive:()=>alive,focus:async()=>{focused=true;return true;}});
  await router.refresh();const r=record(router),target=r.terminals.find(x=>x.id===id);
  assert.equal(target.kind,'external');assert.equal((await send(r,request(r,target))).ok,true);assert.equal(focused,true);assert.equal(fake.window.activeTerminal,undefined);
  focused=false;assert.equal((await send(r,request(r,target,{processID:304}))).ok,false);assert.equal(focused,false);
  alive=false;assert.equal((await send(r,request(r,target))).ok,false);
  registration.dispose();await router.refresh();assert.equal(record(router).terminals.some(x=>x.id===id),false);
});
test('external terminal must acknowledge focus and remain alive', async t => {
  const fake=createFake([]),router=await createRouter(fake,{root:root(t)});t.after(()=>router.dispose());
  const id=crypto.randomUUID();router.registerExternalTerminal({id,processID:303,name:'Living',isAlive:()=>true,focus:async()=>false});await router.refresh();const r=record(router);
  assert.equal((await send(r,request(r))).ok,false);
  assert.throws(()=>router.registerExternalTerminal({id,processID:404,isAlive:()=>true,focus:async()=>true}),/Invalid/);
});
test('registry reports window focus and the active terminal', async t => {
  const fake = createFake([101, 102]), router = await createRouter(fake, { root: root(t) }); t.after(() => router.dispose());
  let r = record(router);
  assert.equal(r.focused, false); assert.equal(r.activeTerminalID, undefined);
  fake.window.state.focused = true; fake.window.activeTerminal = fake.window.terminals[1]; await router.refresh();
  r = record(router);
  assert.equal(r.focused, true); assert.equal(r.activeTerminalID, r.terminals[1].id);
});
