# worklog, the VS Code half

One URI handler, for the thing `code`'s command line cannot do: `o` in `wl`
under `d` or `p` opens the diff of the file at the line the cursor is on.
`code --goto` takes a line and `code --diff` takes two files, and the two do
not compose - the workbench drops the line in diff mode - and there is no
`code --command`, so this is the way in.

```
vscode://vtjnash.worklog/diff?root=<checkout>&path=<file>&line=<n>&left=<ref>[&right=<ref>]
```

`left` and `right` are refs `git` in `root` resolves; `right` absent is the
working tree. `wl` sends the merge base with the pull request's base under
`d`, and the head you last read under `p`. A ref the checkout does not have
is said in a notification, and the file opens at the line by itself.

## Installing

```
vscode/package.sh                                  # writes vscode/worklog-<version>.vsix
code --install-extension vscode/worklog-0.1.0.vsix
```

It is a workspace extension: under Remote-SSH, `code` in the remote terminal
installs it on the remote, which is where the checkout is and where it has to
run. Without it, `o` on a diff line falls back to `code --goto` and says so.

`node vscode/test.js` is its test, against a stub of the two APIs it touches.
