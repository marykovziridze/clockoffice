import * as path from 'node:path';
import Mocha from 'mocha';

// Entry point VS Code calls inside the isolated test instance.
export function run(): Promise<void> {
  const mocha = new Mocha({ ui: 'tdd', timeout: 60_000, color: false });
  mocha.addFile(path.join(__dirname, 'reply.vscode.test.js'));
  return new Promise((resolve, reject) => {
    mocha.run((failures) => (failures ? reject(new Error(`${failures} test(s) failed`)) : resolve()));
  });
}
