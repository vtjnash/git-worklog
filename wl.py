#!/usr/bin/env python3
"""Edit state.toml safely.

Line-based on purpose: it rewrites only the keys you name, inside only the block
you name, and leaves every other block, comment and blank line byte-identical.
A TOML round-trip library would reformat the whole file and lose the comments.

  wl.py next    [n]                       # pull the next untagged backlog items
  wl.py track   julia#62452 close         # close | normal | loose | background
  wl.py dismiss julia#62452               # retire from the backlog until it moves
  wl.py snooze  julia#62452 on-change     # or a date, or "off"
  wl.py note    julia#62452 "rebase after #62396 lands"
  wl.py deadline julia#62452 2026-09-30
  wl.py agent   julia#62452 "rebase + rerun Compiler tests"
  wl.py bucket  julia#62452 needs-agents
  wl.py clear   julia#62452
  wl.py show    julia#62452
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATE = ROOT / "state.toml"
FIELDS = {"snooze", "note", "deadline", "agent_task", "bucket", "blocked_on", "track"}
ALIAS = {"agent": "agent_task", "blocked": "blocked_on"}
TRACK = ("close", "normal", "loose", "background")


def resolve(ref):
    """Accept a full URL, owner/repo#N, repo#N, or #N (Julia)."""
    if ref.startswith("http"):
        return ref.rstrip("/")
    facts = ROOT / "facts.json"
    if not facts.exists():
        sys.exit("no facts.json yet - run refresh.py first")
    items = json.loads(facts.read_text())["items"]
    if "#" not in ref:
        sys.exit("cannot parse ref %r" % ref)
    repo, num = ref.rsplit("#", 1)
    hits = [u for u, r in items.items()
            if str(r["number"]) == num
            and (not repo or r["repo"] == repo or r["repo"].split("/")[-1] == repo
                 or (repo == "" and r["repo"] == "JuliaLang/julia"))]
    if not hits:
        sys.exit("no tracked item matches %r" % ref)
    if len(hits) > 1:
        sys.exit("ambiguous %r:\n  %s" % (ref, "\n  ".join(hits)))
    return hits[0]


def load_lines():
    return STATE.read_text().splitlines() if STATE.exists() else []


def block_span(lines, url):
    """Line range [start, end) of the [\"url\"] table, or None."""
    header = '["%s"]' % url
    try:
        i = next(k for k, l in enumerate(lines) if l.strip() == header)
    except StopIteration:
        return None
    j = i + 1
    while j < len(lines) and not lines[j].lstrip().startswith("["):
        j += 1
    return i, j


def fmt(value):
    if isinstance(value, list):
        return "[%s]" % ", ".join(json.dumps(v) for v in value)
    return json.dumps(value)


def set_fields(url, updates):
    lines = load_lines()
    span = block_span(lines, url)
    if span is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.append('["%s"]' % url)
        lines += ["%s = %s" % (k, fmt(v)) for k, v in updates.items() if v is not None]
        STATE.write_text("\n".join(lines) + "\n")
        return "added"
    i, j = span
    body = lines[i + 1:j]
    for k, v in updates.items():
        pat = re.compile(r"^\s*%s\s*=" % re.escape(k))
        body = [b for b in body if not pat.match(b)]
        if v is not None:
            body.append("%s = %s" % (k, fmt(v)))
    # An emptied block is removed entirely rather than left as a bare header.
    keep = [b for b in body if b.strip()]
    new = lines[:i] + ([] if not keep else [lines[i]] + keep) + lines[j:]
    STATE.write_text("\n".join(new).rstrip("\n") + "\n")
    return "updated" if keep else "cleared"


def disarm(url):
    """Drop any armed fingerprint so a re-snooze re-arms from the current state."""
    f = ROOT / "snooze.json"
    if not f.exists():
        return
    d = json.loads(f.read_text())
    if d.pop(url, None) is not None:
        f.write_text(json.dumps(d, indent=1, sort_keys=True))


def next_batch(n):
    """Hand back the next slice of untagged backlog, oldest-unseen first.

    Pull, never push: nothing from the backlog reaches the dashboard on its own.
    You ask for work when you want it. Items you have already tagged in
    state.toml are considered triaged and never come back here.
    """
    import tomllib
    facts = ROOT / "facts.json"
    if not facts.exists():
        sys.exit("no facts.json yet - run refresh.py first")
    items = json.loads(facts.read_text())["items"]
    state = tomllib.loads(STATE.read_text()) if STATE.exists() else {}
    seen_path = ROOT / "queue.json"
    seen = json.loads(seen_path.read_text()) if seen_path.exists() else {}
    seen = {u: d for u, d in seen.items() if u in items}

    pool = [u for u, r in items.items()
            if r.get("backlog") and not r.get("snoozed") and not state.get(u)]
    if not pool:
        print("backlog is fully triaged")
        return
    def last_activity(u):
        r = items[u]
        return max([t for t in (r.get("head_at"), r.get("last_comment_at")) if t]
                   or [r["updated"]])
    # Never-shown first; then your areas, so a thousand-PR pile still hands you
    # the relevant end of it; then quietest first.
    import tomllib as _t
    areas = set(_t.loads((ROOT / "config.toml").read_text())["firehose"].get("areas", []))
    def rank(u):
        r = items[u]
        return (seen.get(u, ""),
                not (areas & set(r.get("labels") or [])),
                last_activity(u), u)
    pool.sort(key=rank)
    batch = pool[:n]
    print("%d untagged backlog items (%d shown)\n" % (len(pool), len(batch)))
    for u in batch:
        r = items[u]
        ref = "%s#%s" % (r["repo"].split("/")[-1], r["number"])
        hit = areas & set(r.get("labels") or [])
        print("%-22s %-8s %s" % (ref, r["bucket"], r["title"][:74]))
        if hit:
            print("%-22s %s" % ("", ", ".join(sorted(hit))))
        print("%-22s %s\n" % ("", u))
        seen[u] = str(__import__("datetime").date.today())
    seen_path.write_text(json.dumps(seen, indent=1, sort_keys=True))
    print("tag each:  wl.py dismiss <ref> | track <ref> loose | note <ref> \"...\" | snooze <ref> <date>")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if sys.argv[1] == "next":
        next_batch(int(sys.argv[2]) if len(sys.argv) > 2 else 10)
        return
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, ref = sys.argv[1], sys.argv[2]
    url = resolve(ref)
    cmd = ALIAS.get(cmd, cmd)

    if cmd == "show":
        import tomllib
        st = tomllib.loads(STATE.read_text()) if STATE.exists() else {}
        print(url)
        print(json.dumps(st.get(url, {}), indent=1))
        return
    if cmd == "dismiss":
        # Retire a backlog item: stop caring about churn, but do not go blind to
        # it. Loose tracking plus an on-change snooze means it comes back only if
        # something that actually matters happens to it.
        disarm(url)
        set_fields(url, {"track": "loose", "snooze": "on-change"})
        print("dismissed %s (returns only on a review, reply or close)" % url)
        return
    if cmd == "clear":
        disarm(url)
        print("%s %s" % (set_fields(url, {k: None for k in FIELDS}), url))
        return
    if cmd not in FIELDS:
        sys.exit("unknown field %r; one of: %s, clear, show" % (cmd, ", ".join(sorted(FIELDS))))
    if len(sys.argv) < 4:
        sys.exit("need a value")
    value = " ".join(sys.argv[3:])
    if cmd == "track":
        if value not in TRACK:
            sys.exit("track must be one of: %s" % ", ".join(TRACK))
        disarm(url)          # a level change redefines "moved"; re-arm from now
    if cmd == "snooze":
        disarm(url)
        if value in ("off", "none", ""):
            value = None
    elif cmd == "blocked_on":
        value = value.split(",")
    print("%s %s %s" % (set_fields(url, {cmd: value}), cmd, url))


if __name__ == "__main__":
    main()
