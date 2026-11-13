'use strict';
function createFake(pids, group = []) {
  const handlers = new Set();
  const event = callback => { handlers.add(callback); return { dispose() { handlers.delete(callback); } }; };
  const fake = {
    workspace: { workspaceFolders: [{ uri: { scheme: 'file', fsPath: '/Projects/same-project' } }], onDidChangeWorkspaceFolders: event },
    window: { terminals: [], activeTerminal: undefined, state: { focused: false }, onDidOpenTerminal: event, onDidCloseTerminal: event,
      onDidChangeActiveTerminal: event, onDidChangeWindowState: event },
    commands: { calls: [], async getCommands() { return ['workbench.action.focusWindow']; }, async executeCommand(command) {
      fake.commands.calls.push(command);
      for (const item of group) item.window.state.focused = false;
      fake.window.state.focused = true;
    } }
  };
  fake.window.terminals = pids.map(processID => {
    const terminal = { name: 'same-name', processId: Promise.resolve(processID), exitStatus: undefined,
      show(preserveFocus) { if (preserveFocus !== false) throw new Error('Must focus the terminal'); fake.window.activeTerminal = terminal; } };
    return terminal;
  });
  group.push(fake);
  return fake;
}
module.exports = { createFake };
