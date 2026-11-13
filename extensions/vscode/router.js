'use strict';
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const boundedPID = promise => Promise.race([Promise.resolve(promise).catch(() => undefined), delay(500).then(() => undefined)]);
const validPID = pid => Number.isSafeInteger(pid) && pid > 1 && pid <= 2147483647;
const defaultRoot = () => `/tmp/dev-island-vscode-${os.userInfo().uid}`;

async function createRouter(vscode, options = {}) {
  const root = options.root || defaultRoot();
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  const attrs = fs.lstatSync(root);
  if (!attrs.isDirectory() || attrs.isSymbolicLink() || attrs.uid !== os.userInfo().uid || (attrs.mode & 0o077)) throw new Error('Unsafe local router directory');
  const windowID = crypto.randomUUID();
  const socketPath = path.join(root, `${windowID}.sock`);
  if (Buffer.byteLength(socketPath) >= 104) throw new Error('Local socket path is too long');
  const registryPath = path.join(root, `${windowID}.json`);
  const token = crypto.randomBytes(32).toString('hex');
  const terminalIDs = new Map();
  const externalTargets = new Map();
  let disposed = false, generation = 0;
  const subscriptions = [];
  const commands = await vscode.commands.getCommands(true);
  const canFocus = commands.includes('workbench.action.focusWindow');

  async function refresh() {
    const run = ++generation;
    const current = [...vscode.window.terminals];
    for (const terminal of terminalIDs.keys()) if (!current.includes(terminal)) terminalIDs.delete(terminal);
    const terminals = (await Promise.all(current.slice(0, 256).map(async terminal => {
      if (!terminalIDs.has(terminal)) terminalIDs.set(terminal, crypto.randomUUID());
      const processID = await boundedPID(terminal.processId);
      if (!validPID(processID) || terminal.exitStatus !== undefined || !vscode.window.terminals.includes(terminal)) return undefined;
      return { id: terminalIDs.get(terminal), processID, name: String(terminal.name).slice(0, 160) };
    }))).filter(Boolean);
    for (const target of [...externalTargets.values()].slice(0, 128)) {
      try { if (target.isAlive()) terminals.push({ id: target.id, processID: target.processID, name: target.name, kind: 'external' }); } catch {}
    }
    if (disposed || run !== generation) return;
    // Lets Dev Island skip alerts for the terminal the user is already looking at.
    const active = vscode.window.activeTerminal;
    const activeTerminalID = active && terminals.some(item => item.id === terminalIDs.get(active)) ? terminalIDs.get(active) : undefined;
    const record = { version: 1, windowID, bundleID: 'com.microsoft.VSCode', socketPath, token, canFocus,
      focused: !!(vscode.window.state && vscode.window.state.focused), activeTerminalID,
      updatedAt: Date.now() / 1000, workspaceFolders: (vscode.workspace.workspaceFolders || []).filter(f => f.uri.scheme === 'file').slice(0, 64).map(f => f.uri.fsPath), terminals };
    const temp = registryPath + '.tmp';
    fs.writeFileSync(temp, JSON.stringify(record), { mode: 0o600 });
    fs.renameSync(temp, registryPath);
  }
  async function handle(request) {
    const base = { version: 1, requestID: request.requestID, windowID, terminalID: request.terminalID, ok: false, selected: false, windowFocused: false };
    if (request.version !== 1 || typeof request.token !== 'string' || request.token.length !== 64 || !/^[a-f0-9]{64}$/.test(request.token) ||
      !crypto.timingSafeEqual(Buffer.from(request.token), Buffer.from(token)) || request.windowID !== windowID || request.action !== 'focus' ||
      typeof request.requestID !== 'string' || request.requestID.length > 64 || !validPID(request.processID)) return { ...base, error: 'unauthorized' };
    const terminal = [...terminalIDs].find(([terminal, id]) => id === request.terminalID && vscode.window.terminals.includes(terminal))?.[0];
    const external = externalTargets.get(request.terminalID);
    const externalAlive = () => { try { return external && externalTargets.get(request.terminalID) === external && external.processID === request.processID && external.isAlive(); } catch { return false; } };
    if ((!terminal || terminal.exitStatus !== undefined || await boundedPID(terminal.processId) !== request.processID) && !externalAlive()) return { ...base, error: 'terminal-closed' };
    if (!canFocus) return { ...base, error: 'focus-unavailable' };
    await vscode.commands.executeCommand('workbench.action.focusWindow');
    if (external && externalAlive()) {
      const selected = await external.focus() === true && externalAlive() && !disposed;
      const windowFocused = !!vscode.window.state.focused;
      return { ...base, ok: selected && windowFocused, selected, windowFocused, error: selected && windowFocused ? undefined : 'focus-failed' };
    }
    if (disposed || !vscode.window.terminals.includes(terminal) || terminal.exitStatus !== undefined || await boundedPID(terminal.processId) !== request.processID) return { ...base, error: 'terminal-closed' };
    terminal.show(false);
    for (let i = 0; i < 30; i++) {
      if (vscode.window.activeTerminal === terminal && vscode.window.state.focused) break;
      await delay(20);
    }
    const selected = vscode.window.activeTerminal === terminal;
    const windowFocused = !!vscode.window.state.focused;
    return { ...base, ok: selected && windowFocused, selected, windowFocused, error: selected && windowFocused ? undefined : 'focus-failed' };
  }
  const server = net.createServer(socket => {
    let buffer = Buffer.alloc(0), handled = false;
    socket.on('error', () => {});
    socket.setTimeout(1800, () => socket.destroy());
    socket.on('data', chunk => {
      if (handled) return;
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > 4096) { handled = true; socket.destroy(); return; }
      const newline = buffer.indexOf(10);
      if (newline < 0) return;
      handled = true;
      let request;
      try { request = JSON.parse(buffer.subarray(0, newline).toString('utf8')); if (!request || Array.isArray(request)) throw new Error(); }
      catch { socket.end(JSON.stringify({ version: 1, ok: false, error: 'malformed' }) + '\n'); return; }
      handle(request).then(reply => socket.end(JSON.stringify(reply) + '\n')).catch(() => socket.end(JSON.stringify({ version: 1, ok: false, error: 'focus-failed' }) + '\n'));
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
  fs.chmodSync(socketPath, 0o600);
  server.on('error', () => {});
  const changed = () => refresh().catch(() => {});
  for (const event of [vscode.window.onDidOpenTerminal, vscode.window.onDidCloseTerminal, vscode.window.onDidChangeActiveTerminal,
    vscode.window.onDidChangeWindowState, vscode.workspace.onDidChangeWorkspaceFolders]) if (typeof event === 'function') subscriptions.push(event(changed));
  const heartbeat = setInterval(changed, 10000); heartbeat.unref();
  function dispose() {
    if (disposed) return;
    disposed = true; generation++; clearInterval(heartbeat);
    externalTargets.clear();
    for (const sub of subscriptions) sub.dispose();
    server.close();
    for (const file of [registryPath, registryPath + '.tmp', socketPath]) { try { fs.unlinkSync(file); } catch {} }
  }
  try { await refresh(); } catch (error) { dispose(); throw error; }
  function registerExternalTerminal(target) {
    if (disposed || !target || typeof target.id !== 'string' || !/^[a-f0-9-]{36}$/.test(target.id) || !validPID(target.processID) || typeof target.isAlive !== 'function' || typeof target.focus !== 'function' || externalTargets.has(target.id)) throw new Error('Invalid external terminal registration');
    const entry = { id: target.id, processID: target.processID, name: String(target.name || 'Canlı Terminal').slice(0, 160), isAlive: target.isAlive, focus: target.focus };
    externalTargets.set(entry.id, entry); refresh().catch(() => {});
    return { dispose() { if (externalTargets.get(entry.id) === entry) { externalTargets.delete(entry.id); refresh().catch(() => {}); } } };
  }
  return { windowID, registryPath, refresh, dispose, registerExternalTerminal };
}
module.exports = { createRouter, defaultRoot };
