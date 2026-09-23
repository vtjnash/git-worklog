// The half of `o` that `code`'s command line cannot do.
//
// `code --goto file:line` opens a file at a line, and `code --diff a b` opens
// a diff, but the two do not compose: the CLI parses the `:line` in diff mode
// and the workbench drops it (`NativeWindow.openResources` builds the diff
// input with `options: { pinned: true }` and nothing else). And there is no
// `code --command`: the remote CLI's socket carries `open`, `openExternal`,
// `status` and `extensionManagement`, so the only way in is a URI handler,
// which is an extension. This is that extension, with two verbs.
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
// `vscode://vtjnash.worklog/commit?root=<checkout>&sha=<sha>`
//
// opens every file the commit changed, against its first parent, in one
// multi-file diff editor - GitHub's page for the commit, and what `o` on a row
// of a list of commits in `wl` asks for. First parent, as GitHub measures a
// merge. `wl` has fetched the commit when the checkout lacked it; one that is
// still missing is an error, since there is no file to fall back to.
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
        if (uri.path === '/commit') return await commit(new URLSearchParams(uri.query));
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
    const repo = git && await repositoryFor(git, q.get('root'), fileUri);
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

// The git extension's `Status` values that mean a side is missing: a file the
// commit added has no left, one it deleted no right.
const INDEX_ADDED = 1, DELETED = 6;

async function commit(q) {
    const sha = q.get('sha');
    const root = q.get('root');
    if (!sha) throw new Error('no sha');
    if (!root) throw new Error('no root');
    const git = await gitApi();
    if (!git) throw new Error('no git extension');
    const repo = await repositoryFor(git, root);
    if (!repo) throw new Error(`${root} is not a git repository VS Code can see`);
    let c;
    try { c = await repo.getCommit(sha); } catch (e) {
        throw new Error(`no commit ${short(sha)} in ${repo.rootUri.fsPath}: ${gitError(e)}`);
    }
    const title = `${short(c.hash)} ${c.message.split('\n')[0]}`;
    const parent = c.parents[0];
    if (!parent) throw new Error(`${short(c.hash)} is a root commit, with nothing to diff against`);
    const changes = await repo.diffBetween(parent, c.hash);
    if (!changes.length) {
        vscode.window.showInformationMessage(`worklog: ${title} changes no files`);
        return;
    }
    return vscode.commands.executeCommand('vscode.changes', title, changes.map(ch => [
        ch.uri,
        ch.status === INDEX_ADDED ? undefined : git.toGitUri(ch.originalUri, parent),
        ch.status === DELETED ? undefined : git.toGitUri(ch.uri, c.hash),
    ]));
}

// A sha is shortened; a branch name is itself.
const short = ref => /^[0-9a-f]{40}$/.test(ref) ? ref.slice(0, 8) : ref;

async function gitApi() {
    const ext = vscode.extensions.getExtension('vscode.git');
    if (!ext) return null;
    const exports = ext.isActive ? ext.exports : await ext.activate();
    return exports.getAPI(1);
}

// The repository `wl` names, and not merely one the path is inside:
// `getRepository` answers with the deepest repository *open in the window*
// that contains the path, so a checkout that is not open itself but sits
// inside one that is - a worktree under another project, a home directory
// kept in git - was asked of the outer one, which has none of its commits.
// Opened here when it is not open, without adding it to the workspace, so a
// window on some other folder still resolves its `git:` side. Without a root,
// the file's own.
async function repositoryFor(git, root, fileUri) {
    if (!root) return fileUri ? git.getRepository(fileUri) : null;
    const rootUri = vscode.Uri.file(root);
    const open = git.getRepository(rootUri);
    if (open && samePath(open.rootUri.fsPath, root)) return open;
    return await git.openRepository(rootUri);
}

const samePath = (a, b) => path.resolve(a) === path.resolve(b);

// What git said, which is the only thing that tells a missing object from a
// repository that could not be read: the git extension rejects with its own
// error, whose `stderr` is git's.
const gitError = e => ((e && (e.stderr || e.message)) || String(e)).trim().split('\n')[0];

async function hasCommit(repo, ref) {
    try { await repo.getCommit(ref); return true; } catch { return false; }
}

module.exports = { activate, handleUri };
