// `node vscode/test.js`: the handler against a stub of the two APIs it
// touches, since an extension host is not something a test can start.
const assert = require('assert');
const Module = require('module');

const calls = [];
class Uri { constructor(s, p) { this.scheme = s; this.fsPath = p; this.path = p; }
            static file(p) { return new Uri('file', p); } }
class Range { constructor(a, b, c, d) { this.start = [a, b]; this.end = [c, d]; } }
const have = new Set(['deadbeef', 'refs/remotes/origin/master']);
const repo = { rootUri: Uri.file('/w'), getCommit: async r => { if (!have.has(r)) throw new Error('bad'); } };
const git = {
    getRepository: u => u.fsPath.startsWith('/w/') ? repo : null,
    openRepository: async u => (calls.push(['openRepository', u.fsPath]), repo),
    toGitUri: (u, ref) => new Uri('git', `${u.fsPath}?${ref}`),
};
const vscode = {
    Uri, Range,
    window: { registerUriHandler: h => (calls.push(['register']), { dispose() {} }),
              showWarningMessage: m => calls.push(['warn', m]),
              showErrorMessage: m => calls.push(['error', m]),
              showTextDocument: (u, o) => calls.push(['show', u.fsPath, o.selection && o.selection.start[0]]) },
    commands: { executeCommand: (c, ...a) => calls.push([c, ...a]) },
    extensions: { getExtension: id => id === 'vscode.git' ? { isActive: true, exports: { getAPI: () => git } } : null },
};
const load = Module._load;
Module._load = (r, ...a) => r === 'vscode' ? vscode : load(r, ...a);
const ext = require('./extension.js');

(async () => {
    ext.activate({ subscriptions: [] });
    assert.deepStrictEqual(calls.shift(), ['register']);

    const uri = (path, query) => ({ path, query });

    // The diff, at the line, working tree on the right.
    await ext.handleUri(uri('/diff', 'root=/w&path=/w/a.jl&line=12&left=deadbeef'));
    let c = calls.shift();
    assert.strictEqual(c[0], 'vscode.diff');
    assert.strictEqual(c[1].path, '/w/a.jl?deadbeef');
    assert.strictEqual(c[2].scheme, 'file');
    assert.strictEqual(c[3], 'a.jl (deadbeef ↔ working tree)');
    assert.deepStrictEqual(c[4].selection.start, [11, 0]);

    // Two refs: neither side is the working tree.
    await ext.handleUri(uri('/diff', 'root=/w&path=/w/a.jl&line=1&left=deadbeef&right=refs/remotes/origin/master'));
    c = calls.shift();
    assert.strictEqual(c[2].path, '/w/a.jl?refs/remotes/origin/master');
    assert.strictEqual(c[3], 'a.jl (deadbeef ↔ refs/remotes/origin/master)');

    // A file outside any open repository: the named root is opened for it.
    await ext.handleUri(uri('/diff', 'root=/elsewhere&path=/elsewhere/b.jl&line=3&left=deadbeef'));
    assert.deepStrictEqual(calls.shift(), ['openRepository', '/elsewhere']);
    assert.strictEqual(calls.shift()[0], 'vscode.diff');

    // A ref the checkout lacks: said, and the file still opens at the line.
    await ext.handleUri(uri('/diff', 'root=/w&path=/w/a.jl&line=7&left=0123456789012345678901234567890123456789'));
    c = calls.shift();
    assert.strictEqual(c[0], 'warn');
    assert.ok(c[1].includes('no commit 01234567 in /w'), c[1]);
    assert.deepStrictEqual(calls.shift(), ['show', '/w/a.jl', 6]);

    // No ref at all is the same fallback.
    await ext.handleUri(uri('/diff', 'root=/w&path=/w/a.jl&line=2'));
    assert.strictEqual(calls.shift()[0], 'warn');
    assert.deepStrictEqual(calls.shift(), ['show', '/w/a.jl', 1]);

    // Anything else is an error, not silence.
    await ext.handleUri(uri('/frobnicate', ''));
    assert.deepStrictEqual(calls.shift(), ['error', 'worklog: nothing called /frobnicate']);
    await ext.handleUri(uri('/diff', 'line=1'));
    assert.deepStrictEqual(calls.shift(), ['error', 'worklog: no path']);
    assert.deepStrictEqual(calls, []);
    console.log('ok');
})().catch(e => { console.error(e); process.exit(1); });
