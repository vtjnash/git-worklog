#!/usr/bin/env python3
"""Unread tracking, replacing per-event email notification.

Email's real value here is one bit per thread: have you seen it. Everything else
it carries - titles, bodies, who spoke - `gh` can answer live, so none of it is
stored. The only persisted state is `read.json`: per item, the timestamp you have
seen up to. That is precisely the bit an inbox was providing and the one thing
that cannot be re-derived from GitHub.

Finding what is unread costs one query per repo: `issues?since=` returns every
item touched in the window, with its `updated_at` and comment count already in
the payload. Comment bodies are fetched only when you ask to read one.
"""

import datetime as dt
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
READ = ROOT / "read.json"
NOW = dt.datetime.now(dt.timezone.utc)


def _get(path):
    p = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout)[:200])
    v = json.loads(p.stdout)
    return v if isinstance(v, list) else [v]


def _api(path, paginate=True, per_page=100, max_pages=60):
    """Page explicitly rather than with `gh api --paginate`.

    --paginate follows Link headers over a list that is being reordered
    underneath it. With the default descending `sort=updated`, an item touched
    mid-walk jumps to page 1 and shifts a whole page past the cursor, so entries
    are silently dropped: the same query returned 168 items on one attempt and
    612 on the next. Ascending order is stable for a `since` window - a
    concurrent update moves an item toward the end, which can duplicate but
    never skip - and explicit paging plus a short-page stop makes the walk
    deterministic. Dedupe by id to absorb the duplicates that ordering allows.
    """
    if not paginate:
        return _get(path)
    sep = "&" if "?" in path else "?"
    out, seen = [], set()
    for page in range(1, max_pages + 1):
        rows = _get("%s%sper_page=%d&page=%d" % (path, sep, per_page, page))
        for r in rows:
            k = r.get("id", r.get("url"))
            if k not in seen:
                seen.add(k)
                out.append(r)
        if len(rows) < per_page:
            break
    return out


def load_read():
    return json.loads(READ.read_text()) if READ.exists() else {}


def mark_read(urls):
    read = load_read()
    stamp = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")
    for u in urls:
        read[u] = stamp
    READ.write_text(json.dumps(read, indent=1, sort_keys=True))
    return len(urls)


def unread(cfg, login, verbose=True):
    """Items touched in the lookback window that you have not marked read.

    One query per repo, nothing cached. An item you have never marked is unread
    only if it moved inside the window - otherwise turning this on would present
    every thread in the repo as new mail.
    """
    cfge = cfg.get("events", {})
    repos = cfge.get("repos", [])
    if not repos:
        return []
    since = (NOW - dt.timedelta(days=cfge.get("lookback_days", 30))
             ).strftime("%Y-%m-%dT%H:%M:%SZ")
    read, out = load_read(), []
    for repo in repos:
        try:
            rows = _api("/repos/%s/issues?since=%s&state=all&sort=updated"
                        "&direction=asc" % (repo, since))
        except RuntimeError as e:
            print("    %-24s FAILED: %s" % (repo, e), file=sys.stderr)
            continue
        for r in rows:
            url = r["html_url"]
            if r["updated_at"] <= read.get(url, ""):
                continue
            out.append({
                "url": url, "repo": repo, "number": r["number"],
                "title": r["title"],
                "is_pr": "pull_request" in r,
                "state": r["state"],
                "author": (r.get("user") or {}).get("login"),
                "updated": r["updated_at"],
                "comments": r.get("comments", 0),
                "labels": [l["name"] for l in r.get("labels", [])],
                "mine": (r.get("user") or {}).get("login") == login,
            })
    out.sort(key=lambda e: e["updated"], reverse=True)
    if verbose:
        print("  %-16s %4d unread across %d repo(s)" % ("activity", len(out), len(repos)),
              file=sys.stderr)
    return out


def thread(url, limit=10):
    """Fetch a thread's recent comments live - the part email used to hand you."""
    owner_repo = "/".join(url.split("/")[3:5])
    num = url.rsplit("/", 1)[-1]
    body = _api("/repos/%s/issues/%s" % (owner_repo, num), paginate=False)[0]
    cs = _api("/repos/%s/issues/%s/comments" % (owner_repo, num))
    try:
        cs += _api("/repos/%s/pulls/%s/comments" % (owner_repo, num))
    except RuntimeError:
        pass                                 # not a PR, or no review comments
    cs.sort(key=lambda c: c["created_at"])
    return body, cs[-limit:]
