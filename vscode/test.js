// `node vscode/test.js`: the handler against a stub of the two APIs it
// touches, since an extension host is not something a test can start.
const assert = require('assert');
const Module = require('module');

const calls = [];
class Uri { constructor(s, p) { this.scheme = s; this.fsPath = p; this.path = p; }
            static file(p) { return new Uri('file', p); } }
class Range { constructor(a, b, c, d) { this.start = [a, b]; this.end = [c, d]; } }
const have = new Set(['deadbeef', 'refs/remotes/origin/master']);
const commits = {
    c0ffee12: { hash: 'c0ffee1200000000000000000000000000000000', message: 'fix the thing\n\nbody', parents: ['deadbeef'] },
    abad1dea: { hash: 'abad1dea', message: 'first', parents: [] },
    ba5eba11: { hash: 'ba5eba11', message: 'empty', parents: ['deadbeef'] },
};
const repo = {
    rootUri: Uri.file('/w'),
    getCommit: async r => { if (commits[r]) return commits[r]; if (!have.has(r)) throw new Error('bad'); },
    diffBetween: async (a, b) => (calls.push(['diffBetween', a, b]), b === 'ba5eba11' ? [] : [
        { uri: Uri.file('/w/m.jl'), originalUri: Uri.file('/w/m.jl'), status: 5 },
        { uri: Uri.file('/w/new.jl'), originalUri: Uri.file('/w/new.jl'), status: 1 },
        { uri: Uri.file('/w/gone.jl'), originalUri: Uri.file('/w/gone.jl'), status: 6 },
        { uri: Uri.file('/w/to.jl'), originalUri: Uri.file('/w/from.jl'), status: 3 },
    ]),
};
const git = {
    getRepository: u => u.fsPath === '/w' || u.fsPath.startsWith('/w/') ? repo : null,
    openRepository: async u => (calls.push(['openRepository', u.fsPath]), repo),
    toGitUri: (u, ref) => new Uri('git', `${u.fsPath}?${ref}`),
};
const vscode = {
    Uri, Range,
    window: { registerUriHandler: h => (calls.push(['register']), { dispose() {} }),
              showWarningMessage: m => calls.push(['warn', m]),
              showErrorMessage: m => calls.push(['error', m]),
              showInformationMessage: m => calls.push(['info', m]),
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

    // A commit: every file it changed against its first parent, in one
    // editor - no left for an addition, no right for a deletion, and a
    // rename from where it was.
    await ext.handleUri(uri('/commit', 'root=/w&sha=c0ffee12'));
    assert.deepStrictEqual(calls.shift(), ['diffBetween', 'deadbeef', commits.c0ffee12.hash]);
    c = calls.shift();
    assert.strictEqual(c[0], 'vscode.changes');
    assert.strictEqual(c[1], 'c0ffee12 fix the thing');
    const side = u => u && u.path;
    assert.deepStrictEqual(c[2].map(r => r.map(side)), [
        ['/w/m.jl', '/w/m.jl?deadbeef', `/w/m.jl?${commits.c0ffee12.hash}`],
        ['/w/new.jl', undefined, `/w/new.jl?${commits.c0ffee12.hash}`],
        ['/w/gone.jl', '/w/gone.jl?deadbeef', undefined],
        ['/w/to.jl', '/w/from.jl?deadbeef', `/w/to.jl?${commits.c0ffee12.hash}`],
    ]);
    // One that changes nothing, one with no parent, and one not there: said.
    await ext.handleUri(uri('/commit', 'root=/w&sha=ba5eba11'));
    calls.shift();
    assert.deepStrictEqual(calls.shift(), ['info', 'worklog: ba5eba11 empty changes no files']);
    await ext.handleUri(uri('/commit', 'root=/w&sha=abad1dea'));
    assert.deepStrictEqual(calls.shift(), ['error', 'worklog: abad1dea is a root commit, with nothing to diff against']);
    await ext.handleUri(uri('/commit', 'root=/w&sha=0123456789'));
    assert.deepStrictEqual(calls.shift(), ['error', 'worklog: no commit 0123456789 in /w']);
    await ext.handleUri(uri('/commit', 'root=/w'));
    assert.deepStrictEqual(calls.shift(), ['error', 'worklog: no sha']);

    // Anything else is an error, not silence.
    await ext.handleUri(uri('/frobnicate', ''));
    assert.deepStrictEqual(calls.shift(), ['error', 'worklog: nothing called /frobnicate']);
    await ext.handleUri(uri('/diff', 'line=1'));
    assert.deepStrictEqual(calls.shift(), ['error', 'worklog: no path']);
    assert.deepStrictEqual(calls, []);
    console.log('ok');
})().catch(e => { console.error(e); process.exit(1); });
