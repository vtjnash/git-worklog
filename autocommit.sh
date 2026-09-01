#!/usr/bin/env bash
# Commit and push the worklog on session end, invoked by the Stop hook.
#
# Exits 0 unconditionally: a Stop hook that fails or hangs degrades the session,
# and nothing here is important enough to be worth that. Every step is a no-op
# when its precondition is missing, so this is safe to run before the remote
# exists.
set -u
REPO=/root/.claude/worklog

cd "$REPO" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git add -A 2>/dev/null
    git commit -q -m "worklog: $(date -u +%Y-%m-%d) snapshot

Automated by the Stop hook." 2>/dev/null
fi

# No remote yet (the sandbox cannot create the repo) -> committed locally, done.
git remote get-url origin >/dev/null 2>&1 || exit 0

# Bounded: a hung push must not outlive the session it belongs to.
timeout 45 git push -q origin HEAD 2>/dev/null
exit 0
