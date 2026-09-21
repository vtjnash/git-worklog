// The half of `o` that `code`'s command line cannot do.
//
// `code --goto file:line` opens a file at a line, and `code --diff a b` opens
// a diff, but the two do not compose: the CLI parses the `:line` in diff mode
// and the workbench drops it (`NativeWindow.openResources` builds the diff
// input with `options: { pinned: true }` and nothing else). And there is no
// `code --command`: the remote CLI's socket carries `open`, `openExternal`,
// `status` and `extensionManagement`, so the only way in is a URI handler,
// which is an extension. This is that extension, kept to the one verb.
//
// `vscode://vtjnash.worklog/diff?root=<checkout>&path=<file>&line=<n>
//                                &left=<ref>[&right=<ref>]`
//
// opens the diff of `path` between `left` and `right` - `right` absent is the
// working tree - in the git extension's diff editor, at `line` on the right.
// The refs are whatever `git` in `root` resolves: `wl` sends the merge base
// under `d` and the head you last read under `p`. A ref the checkout does not
// have is said, and the file opens at the line by itself rather than the
// editor showing an error page: a fallback that still lands somewhere.
//
// `extensionKind: workspace`, so under Remote-SSH this runs where the checkout
// is and the git extension can read it. The git API is reached lazily: the
// extension is activated by the URI, and `vscode.git` may not be yet.

const vscode = require('vscode');
const path = require('path');

function activate(context) {
    context.subscriptions.push(vscode.window.registerUriHandler({ handleUri }));
}

async function handleUri(uri) {
    try {
        if (uri.path === '/diff') return await diff(new URLSearchParams(uri.query));
        vscode.window.showErrorMessage(`worklog: nothing called ${uri.path}`);
    } catch (e) {
        vscode.window.showErrorMessage(`worklog: ${e.message || e}`);
    }
}

async function diff(q) {
    const file = q.get('path');
    if (!file) throw new Error('no path');
    const fileUri = vscode.Uri.file(file);
    const line = parseInt(q.get('line') || '0', 10);
    const left = q.get('left') || '';
    const right = q.get('right') || '';
    const options = {
        preview: false,
        selection: line > 0 ? new vscode.Range(line - 1, 0, line - 1, 0) : undefined,
    };
    const git = await gitApi();
    const repo = git && await repositoryFor(git, fileUri, q.get('root'));
    let missing = !left ? 'no ref to diff against' : !git ? 'no git extension' :
                  !repo ? 'not in a git repository VS Code can see' : '';
    if (!missing) {
        for (const ref of [left, right]) {
            if (ref && !(await hasCommit(repo, ref))) { missing = `no commit ${short(ref)} in ${repo.rootUri.fsPath}`; break; }
        }
    }
    if (missing) {
        vscode.window.showWarningMessage(`worklog: ${missing}; opened the file alone`);
        return vscode.window.showTextDocument(fileUri, options);
    }
    const name = path.basename(file);
    const title = `${name} (${short(left)} ↔ ${right ? short(right) : 'working tree'})`;
    return vscode.commands.executeCommand('vscode.diff',
        git.toGitUri(fileUri, left), right ? git.toGitUri(fileUri, right) : fileUri,
        title, options);
}

// A sha is shortened; a branch name is itself.
const short = ref => /^[0-9a-f]{40}$/.test(ref) ? ref.slice(0, 8) : ref;

async function gitApi() {
    const ext = vscode.extensions.getExtension('vscode.git');
    if (!ext) return null;
    const exports = ext.isActive ? ext.exports : await ext.activate();
    return exports.getAPI(1);
}

// The repository the file is in: the one already open for it, else the one
// `wl` names, opened here without adding it to the workspace - so a diff in a
// window on some other folder still resolves its `git:` side.
async function repositoryFor(git, fileUri, root) {
    return git.getRepository(fileUri) ||
        (root ? await git.openRepository(vscode.Uri.file(root)) : null);
}

async function hasCommit(repo, ref) {
    try { await repo.getCommit(ref); return true; } catch { return false; }
}

module.exports = { activate, handleUri };
