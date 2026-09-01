#!/usr/bin/env python3
"""Refresh the work dashboard from GitHub.

Deterministic half of the dashboard: fetches live facts over GraphQL, derives a
bucket for every item from rules, expires snoozes, diffs against the previous
snapshot and renders DASHBOARD.md.

File ownership is strict, because it is what keeps your notes safe:
  config.toml  state.toml   -- yours. Read here, NEVER written here.
  facts.json   prev.json    -- machine. Overwritten every run.
  snooze.json               -- machine. Fingerprints for "snooze until it moves".
  DASHBOARD.md              -- machine. Overwritten every run.

Judgement calls this script deliberately does not make (they belong to the model
running the /dash skill, which writes them into state.toml): whether a red CI is
mechanical enough to delegate, what the real next action is, and priority order.
"""

import datetime as dt
import hashlib
import json
import subprocess
import sys
import time
import tomllib
from pathlib import Path

import events

ROOT = Path(__file__).resolve().parent
NOW = dt.datetime.now(dt.timezone.utc)
TODAY = NOW.date()

PR_FIELDS = """
      url number title isDraft createdAt updatedAt
      repository { nameWithOwner }
      author { login }
      reviewDecision
      mergeable
      milestone { title dueOn }
      labels(first: 20) { nodes { name } }
      commits(last: 1) { nodes { commit {
        committedDate
        statusCheckRollup { state }
      } } }
      reviewThreads(first: 100) { nodes { isResolved isOutdated } }
      comments(last: 1) { nodes { author { login } createdAt } }
      reviews(last: 20) { nodes { author { login } state submittedAt } }
"""

ISSUE_FIELDS = """
      url number title createdAt updatedAt
      repository { nameWithOwner }
      author { login }
      milestone { title dueOn }
      labels(first: 20) { nodes { name } }
      comments(last: 1) { nodes { author { login } createdAt } }
"""

# The firehose is ~1000 PRs, so it drops the expensive nested connections
# (review threads, review history, comments). Background items are never
# bucketed on those fields, and shedding them buys 100 nodes/page at 2 points.
FIREHOSE_QUERY = """
query($q: String!, $cursor: String) {
  rateLimit { cost remaining }
  search(query: $q, type: ISSUE, first: 100, after: $cursor) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { __typename ... on PullRequest {
      url number title isDraft createdAt updatedAt
      repository { nameWithOwner }
      author { login }
      reviewDecision mergeable
      milestone { title dueOn }
      labels(first: 20) { nodes { name } }
      commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
      comments(last: 1) { nodes { author { login } createdAt } }
    }
    ... on Issue {
      url number title createdAt updatedAt
      repository { nameWithOwner }
      author { login }
      milestone { title dueOn }
      labels(first: 20) { nodes { name } }
      comments(last: 1) { nodes { author { login } createdAt } }
    } }
  }
}
"""

QUERY = """
query($q: String!, $cursor: String) {
  rateLimit { cost remaining }
  search(query: $q, type: ISSUE, first: 50, after: $cursor) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      __typename
      ... on PullRequest {
%s
      }
      ... on Issue {
%s
      }
    }
  }
}
""" % (PR_FIELDS, ISSUE_FIELDS)


def search(q, cap=1000, query=None):
    """Paginate one search lane. Returns (items, points_spent)."""
    out, cursor, spent = [], None, 0
    while True:
        body = json.dumps({"query": query or QUERY,
                           "variables": {"q": q, "cursor": cursor}})
        # Long paginations (the firehose is ~10 sequential pages) reliably hit
        # transient 5xx from the GraphQL endpoint. Retry the page rather than
        # losing the whole refresh.
        for attempt in range(7):
            p = subprocess.run(["gh", "api", "graphql", "--input", "-"],
                               input=body, capture_output=True, text=True)
            if p.returncode == 0:
                break
            err = (p.stderr or p.stdout)[:200]
            if attempt == 6 or not any(c in err for c in ("502", "503", "504", "timeout")):
                raise FetchError("GraphQL failed for %r: %s" % (q, err))
            time.sleep(min(2 ** attempt, 30))
            print("    retry %d after: %s" % (attempt + 1, err.strip()), file=sys.stderr)
        d = json.loads(p.stdout)
        if "errors" in d:
            raise FetchError("GraphQL errors for %r: %s" % (q, json.dumps(d["errors"])[:2000]))
        spent += d["data"]["rateLimit"]["cost"]
        s = d["data"]["search"]
        out.extend(n for n in s["nodes"] if n and n.get("url"))
        if cursor is None:
            search.last_total = s["issueCount"]
        if not s["pageInfo"]["hasNextPage"] or len(out) >= cap:
            return out[:cap], spent
        cursor = s["pageInfo"]["endCursor"]


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def days_since(s):
    t = ts(s)
    return None if t is None else (NOW - t).days


class FetchError(Exception):
    """A lane could not be fetched. Fatal for the active lanes, survivable for
    the bulk ones, which fall back to their previous cached contents."""


def activity_at(r):
    """Last real human activity: a push or a comment, falling back to updatedAt.

    updatedAt moves on label and milestone edits too, so it overstates liveness.
    """
    return max([t for t in (r.get("head_at"), r.get("last_comment_at")) if t]
               or [r["updated"]])


def activity_age(r):
    return days_since(activity_at(r))


def normalize(n, lane, login):
    """Flatten one GraphQL node into the record the rest of the script uses."""
    is_pr = n.get("__typename", "PullRequest") == "PullRequest"
    labels = [l["name"] for l in n["labels"]["nodes"]]
    ms = n.get("milestone") or {}
    rec = {
        "type": n.get("__typename", "PullRequest"),
        "lane": lane,
        "url": n["url"],
        "number": n["number"],
        "title": n["title"],
        "repo": n["repository"]["nameWithOwner"],
        "author": (n.get("author") or {}).get("login") or "?",
        "created": n["createdAt"],
        "updated": n["updatedAt"],
        "labels": labels,
        "milestone": ms.get("title"),
        "milestone_due": ms.get("dueOn"),
        "mine": ((n.get("author") or {}).get("login") == login),
    }
    lastc = (n.get("comments") or {}).get("nodes") or []
    rec["last_comment_by"] = (lastc[0].get("author") or {}).get("login") if lastc else None
    rec["last_comment_at"] = lastc[0]["createdAt"] if lastc else None
    rec["human_comment_at"] = (None if (rec["last_comment_by"] or "").endswith("[bot]")
                               else rec["last_comment_at"])

    if is_pr:
        commits = n["commits"]["nodes"]
        commit = commits[0]["commit"] if commits else {}
        roll = commit.get("statusCheckRollup") or {}
        threads = (n.get("reviewThreads") or {}).get("nodes")
        reviews = (n.get("reviews") or {}).get("nodes") or []
        light = threads is None          # firehose record: no thread/review data
        threads = threads or []
        mine_reviews = [r for r in reviews
                        if (r.get("author") or {}).get("login") == login and r.get("submittedAt")]
        rec.update({
            "draft": n["isDraft"],
            "review_decision": n.get("reviewDecision"),
            "mergeable": n.get("mergeable"),
            "head_at": commit.get("committedDate"),
            "ci": roll.get("state"),
            "unresolved": (None if light else
                           sum(1 for t in threads if not t["isResolved"] and not t["isOutdated"])),
            "review_count": len(reviews),
            "my_last_review_at": max((r["submittedAt"] for r in mine_reviews), default=None),
            "my_last_review_state": (sorted(mine_reviews, key=lambda r: r["submittedAt"])[-1]["state"]
                                     if mine_reviews else None),
        })
    return rec


# How closely you are tracking an item decides what counts as it having moved.
# A loosely-tracked PR should not wake you because CI flapped or someone
# relabelled it; a closely-tracked one should wake on anything at all.
TRACK_KEYS = {
    "close":      ("head_at", "review_decision", "mergeable", "ci", "unresolved",
                   "review_count", "last_comment_at", "labels"),
    "normal":     ("head_at", "review_decision", "ci", "unresolved",
                   "review_count", "last_comment_at"),
    "loose":      ("review_decision", "review_count", "human_comment_at"),
    "background": (),          # empty key set -> constant -> never wakes
}
TRACK_ORDER = ("close", "normal", "loose", "background")


def fingerprint(rec, level="close"):
    """What counts as 'this item moved', at the given tracking level."""
    keys = TRACK_KEYS.get(level, TRACK_KEYS["normal"])
    key = [sorted(rec.get("labels") or []) if k == "labels" else rec.get(k)
           for k in keys]
    return hashlib.sha256(json.dumps(key, sort_keys=True, default=str).encode()).hexdigest()[:16]


def resolve_track(st, bucket):
    """Explicit setting wins; otherwise the lane picks a sensible default."""
    t = st.get("track")
    if t in TRACK_KEYS:
        return t
    if bucket in ("stale", "firehose", "mentioned"):
        return "background"
    if bucket in ("issue", "reviewed", "blocked"):
        return "loose"
    return "normal"


# --- bucketing -------------------------------------------------------------
# Every rule below is a fact GitHub already knows. Anything requiring judgement
# is left to the model via a state.toml override.

def derive_bucket(r, st, cfg):
    if st.get("bucket"):
        return st["bucket"], "override"
    L = set(r.get("labels", []))
    if r["lane"] == "firehose":
        return "firehose", "discovery"
    if r["lane"].startswith(("mentioned", "commented")):
        # The only thing in this pile worth interrupting for: someone named you
        # recently and the last word is theirs, so a question is probably owed an
        # answer. Everything else - including your own old comments, and the
        # repos where you are effectively the maintainer and touch every PR -
        # stays in the background where you pull it on your own schedule.
        age = activity_age(r)
        if (r["lane"].startswith("mentioned")
                and age is not None and age <= cfg["thresholds"]["reply_days"]
                and r.get("last_comment_by") not in (None, cfg["login"])):
            return "needs-reply", "mentioned you %dd ago; last word is theirs" % age
        return "mentioned", "mention or comment history"
    # Only after the lanes: an Issue reached via `assigned` is yours to act on,
    # while the same Issue reached via a mention is background.
    if r["type"] == "Issue":
        return "issue", "assigned issue"

    if r["mine"]:
        claimed = any(st.get(k) for k in ("note", "deadline", "agent_task", "snooze"))
        age = activity_age(r)
        if not claimed and age is not None and age >= cfg["thresholds"]["stale_days"]:
            return "stale", "quiet %dd, unclaimed" % age
        if "status: blocked by upstream" in L:
            return "blocked", "labelled blocked by upstream"
        if st.get("agent_task"):
            return "needs-agents", "you queued an agent task"
        if r.get("mergeable") == "CONFLICTING":
            return "needs-stacking", "merge conflict"
        if r.get("review_decision") == "CHANGES_REQUESTED":
            return "needs-edits", "changes requested"
        if r.get("unresolved"):
            return "needs-edits", "%d unresolved thread(s)" % r["unresolved"]
        if r.get("ci") in ("FAILURE", "ERROR"):
            return "needs-edits", "CI %s" % r["ci"].lower()
        if "status: waiting for PR author" in L:
            return "needs-edits", "labelled waiting for author"
        if r.get("draft"):
            return "draft", "draft"
        if r.get("review_decision") == "APPROVED" and r.get("ci") == "SUCCESS":
            return "needs-merge", "approved and green"
        if age is not None and age >= cfg["thresholds"]["nudge_days"]:
            return "needs-nudge", "quiet %d days" % age
        return "waiting", "waiting on reviewer"

    # Someone else's PR that asked for you.
    head, mine_rev = ts(r.get("head_at")), ts(r.get("my_last_review_at"))
    if mine_rev and head and mine_rev > head:
        return "reviewed", "you reviewed after their last push"
    if mine_rev and head and mine_rev <= head:
        return "needs-review", "they pushed after your review"
    return "needs-review", "review requested"


def snooze_active(url, st, fp, snz):
    """Returns (is_snoozed, reason). Arms an on-change snooze on first sight."""
    s = st.get("snooze")
    if not s:
        return False, None
    if s in ("on-change", "until-review"):
        armed = snz.get(url)
        if armed is None:
            snz[url] = fp          # arm now; wake when the fingerprint differs
            return True, "until it moves"
        if armed == "WOKE":
            # Stay awake once woken. Re-arming here would re-hide the item on the
            # very next refresh, giving you a single window to notice it moved.
            # `wl.py snooze <ref> on-change` re-arms deliberately.
            return False, "woke earlier; re-snooze to re-arm"
        if armed != fp:
            snz[url] = "WOKE"
            return False, "woke: it moved"
        return True, "until it moves"
    try:
        until = dt.date.fromisoformat(str(s))
    except ValueError:
        return False, "bad snooze value %r" % s
    if until <= TODAY:
        return False, "woke: snooze expired"
    return True, "until %s" % until


def fetch_bulk(cfg, force=False):
    """Run every [bulk.queries] entry, cached on a slow cadence.

    These are ~2000 items that move slowly and never surface on their own, so
    per-refresh freshness buys nothing and costs minutes of wall clock.

    GitHub's search API truncates at 1000 results and the Julia firehose is
    already at ~993, so any query approaching the cap is re-run partitioned by
    creation year and the slices unioned.
    """
    cache = ROOT / "bulk.json"
    hours = cfg["bulk"].get("refresh_hours", 6)
    if cache.exists() and not force:
        c = json.loads(cache.read_text())
        age_h = (NOW - ts(c["fetched_at"])).total_seconds() / 3600
        if age_h < hours:
            return c["lanes"], 0, "cached %.1fh old" % age_h

    # Start from whatever is cached so one flaky lane cannot discard the others.
    # These fetches take minutes; losing a completed lane to a later 502 is the
    # difference between a slow refresh and a wasted one.
    prev = json.loads(cache.read_text())["lanes"] if cache.exists() else {}
    lanes, spent, failed = dict(prev), 0, []
    for lane, q in cfg["bulk"]["queries"].items():
        try:
            nodes, c = search(q, cap=1000, query=FIREHOSE_QUERY)
            spent += c
            total = getattr(search, "last_total", len(nodes))
            if total > 950:
                seen, merged = set(), []
                for y in range(2011, NOW.year + 1):
                    part, pc = search("%s created:%d-01-01..%d-12-31" % (q, y, y),
                                      cap=1000, query=FIREHOSE_QUERY)
                    spent += pc
                    for n in part:
                        if n["url"] not in seen:
                            seen.add(n["url"])
                            merged.append(n)
                nodes = merged
        except FetchError as e:
            failed.append(lane)
            print("    %-16s FAILED, keeping %d cached: %s"
                  % (lane, len(prev.get(lane, [])), str(e)[:80]), file=sys.stderr)
            continue
        lanes[lane] = nodes
        print("    %-16s %4d of %s" % (lane, len(nodes), total), file=sys.stderr)
        # Persist after every lane, not at the end.
        cache.write_text(json.dumps({"fetched_at": NOW.isoformat(), "lanes": lanes}))
    cache.write_text(json.dumps({"fetched_at": NOW.isoformat(), "lanes": lanes}))
    how = "fetched %d" % sum(len(v) for v in lanes.values())
    if failed:
        how += ", %d lane(s) stale" % len(failed)
    return lanes, spent, how


def main():
    cfg = tomllib.loads((ROOT / "config.toml").read_text())
    login = cfg["login"]
    state_path = ROOT / "state.toml"
    state = tomllib.loads(state_path.read_text()) if state_path.exists() else {}
    prev = json.loads((ROOT / "facts.json").read_text()) if (ROOT / "facts.json").exists() else {}
    prev_items = prev.get("items", {})
    snz_path = ROOT / "snooze.json"
    snz = json.loads(snz_path.read_text()) if snz_path.exists() else {}

    items, spent = {}, 0
    for lane, q in cfg["lanes"].items():
        nodes, c = search(q)
        spent += c
        for n in nodes:
            items[n["url"]] = normalize(n, lane, login)
        print("  %-9s %3d items (%d pts)" % (lane, len(nodes), c), file=sys.stderr)

    unread = events.unread(cfg, login)
    bulk, c, how = fetch_bulk(cfg, force="--firehose" in sys.argv)
    spent += c
    for lane, nodes in bulk.items():
        kept = 0
        for n in nodes:
            if n["url"] in items:
                continue                   # already yours in an active lane
            items[n["url"]] = normalize(n, lane, login)
            kept += 1
        print("  %-16s %4d new (%s)" % (lane, kept, how), file=sys.stderr)

    # Bucket, then tracking level, then a fingerprint at that level, then snooze.
    # Order matters: the level decides the fingerprint, which decides the wake.
    changes = []
    for url, r in items.items():
        st = state.get(url, {})
        # GitHub computes mergeability lazily: the first read of a PR returns
        # UNKNOWN and only schedules the real computation. Treating that as fact
        # flaps the needs-stacking lane between refreshes and, worse, spuriously
        # wakes on-change snoozes. Carry the last known value forward until a
        # real one arrives - this read warms it for the next refresh.
        if r.get("mergeable") == "UNKNOWN":
            carried = (prev_items.get(url) or {}).get("mergeable")
            r["mergeable"] = carried if carried != "UNKNOWN" else None
        r["bucket"], r["why"] = derive_bucket(r, st, cfg)
        r["track"] = resolve_track(st, r["bucket"])
        r["fp"] = fingerprint(r, r["track"])
        r["fp_full"] = fingerprint(r, "close")
        r["note"] = st.get("note")
        r["deadline"] = st.get("deadline")
        r["blocked_on"] = st.get("blocked_on", [])
        r["agent_task"] = st.get("agent_task")
        snoozed, sreason = snooze_active(url, st, r["fp"], snz)
        r["snoozed"], r["snooze_why"] = snoozed, sreason
        # The backlog is everything you are not actively carrying: the stale pile,
        # the discovery feed, and anything you explicitly pushed to background.
        r["backlog"] = (r["bucket"] in ("stale", "firehose", "mentioned")
                        or r["track"] == "background")
        old = prev_items.get(url)
        r["moved"] = bool(old) and old.get("fp_full") != r["fp_full"]
        if old is None:
            r["new"] = True
            changes.append((url, r, "new"))
        else:
            r["new"] = False
            if old.get("fp") != r["fp"]:
                d = []
                for f, lab in (("ci", "CI"), ("review_decision", "review"),
                               ("mergeable", "mergeable"), ("unresolved", "unresolved"),
                               ("head_at", "new push"), ("last_comment_at", "new comment")):
                    if old.get(f) != r.get(f):
                        d.append(lab if f in ("head_at", "last_comment_at")
                                 else "%s %s->%s" % (lab, old.get(f), r.get(f)))
                if d:
                    changes.append((url, r, ", ".join(d)))
    for url, old in prev_items.items():
        if url not in items:
            changes.append((url, old, "closed or merged"))
            snz.pop(url, None)

    snapshot = {"fetched_at": NOW.isoformat(), "points": spent, "items": items}
    (ROOT / "facts.json").write_text(json.dumps(snapshot, indent=1, sort_keys=True))
    snz_path.write_text(json.dumps(snz, indent=1, sort_keys=True))
    (ROOT / "DASHBOARD.md").write_text(render(items, changes, cfg, spent, unread))
    print("  %d items, %d changes, %d rate-limit points" % (len(items), len(changes), spent),
          file=sys.stderr)


# --- rendering -------------------------------------------------------------

SECTIONS = [
    ("needs-reply",   "Needs a reply",     "You were mentioned and the last word is theirs."),
    ("needs-edits",   "Needs edits",       "Review feedback, red CI, or you're the blocker."),
    ("needs-agents",  "Needs agents",      "Mechanical work you queued for delegation."),
    ("needs-stacking","Needs stacking",    "Conflicts; rebase or restack with `gh stack`."),
    ("needs-review",  "Needs review",      "Waiting on you to review someone else."),
    ("needs-merge",   "Ready to merge",    "Approved and green."),
    ("needs-nudge",   "Needs a nudge",     "Yours, quiet, waiting on a reviewer."),
    ("waiting",       "Waiting on others", "Yours, in flight, nothing for you to do."),
    ("blocked",       "Blocked",           "Blocked upstream."),
    ("draft",         "Drafts",            "Yours, not yet proposed."),
    ("issue",         "Assigned issues",   ""),
    ("reviewed",      "Reviewed, waiting", "You reviewed; ball is with the author."),
]


def line(r):
    tag = "%s#%s" % (r["repo"].split("/")[-1], r["number"])
    bits = []
    if r.get("ci") and r["ci"] != "SUCCESS":
        bits.append("CI %s" % r["ci"].lower())
    if r.get("unresolved"):
        bits.append("%d unresolved" % r["unresolved"])
    if r.get("mergeable") == "CONFLICTING":
        bits.append("conflicts")
    if r.get("milestone"):
        bits.append(r["milestone"])
    if r.get("deadline"):
        bits.append("**due %s**" % r["deadline"])
    if r.get("blocked_on"):
        bits.append("blocked on %s" % ", ".join(r["blocked_on"]))
    age = activity_age(r)
    if age is not None:
        bits.append("%dd" % age)
    if r.get("new"):
        bits.insert(0, "NEW")
    elif r.get("moved"):
        bits.insert(0, "moved")
    if r.get("track") in ("close", "loose"):
        bits.insert(0, "track:%s" % r["track"])
    star = "* " if r.get("track") == "close" else ""
    s = "- %s[%s](%s) %s" % (star, tag, r["url"], r["title"])
    if bits:
        s += "  \n  <sub>%s</sub>" % " · ".join(bits)
    if r.get("note"):
        s += "  \n  > %s" % r["note"]
    if r.get("agent_task"):
        s += "  \n  > agent: %s" % r["agent_task"]
    return s


def urgency(r):
    d = r.get("deadline") or (r.get("milestone_due") or "")[:10]
    return (0 if r.get("track") == "close" else 1,
            d or "9999-99-99", activity_age(r) or 0)


def render(items, changes, cfg, spent, unread=()):
    vis = [r for r in items.values() if not r["snoozed"]]
    snoozed = [r for r in items.values() if r["snoozed"]]
    out = ["# Work dashboard", "",
           "_%s · %d items · %d rate-limit points_" %
           (NOW.strftime("%Y-%m-%d %H:%M UTC"), len(items), spent), ""]

    # Deadlines first: anything with a date attached, soonest first.
    dated = sorted([r for r in vis if r.get("deadline") or r.get("milestone_due")], key=urgency)
    if dated:
        out += ["## Deadlines", ""]
        for r in dated[:15]:
            d = r.get("deadline") or r["milestone_due"][:10]
            over = " **OVERDUE**" if d < str(TODAY) else ""
            out.append("- `%s`%s [%s#%s](%s) %s" %
                       (d, over, r["repo"].split("/")[-1], r["number"], r["url"], r["title"]))
        out.append("")

    if unread:
        # The inbox replacement. Items you are already carrying come first: an
        # unread comment on your own PR matters more than one on a thread you
        # have never touched.
        by_url = {r["url"]: r for r in items.values()}
        def prio(e):
            r = by_url.get(e["url"])
            return (0 if (r and not r.get("backlog")) else 1, e["updated"])
        ranked = sorted(unread, key=prio)
        ranked.sort(key=lambda e: (prio(e)[0], ), reverse=False)
        out += ["## Unread (%d)" % len(unread),
                "_`wl.py show <ref>` to read a thread, `wl.py read <ref>` when done, "
                "`wl.py read all` to zero the inbox._", ""]
        for e in ranked[:40]:
            r = by_url.get(e["url"])
            bits = ["%d comments" % e["comments"] if e["comments"] else "no comments"]
            if r and not r.get("backlog"):
                bits.append("**%s**" % r["bucket"])
            if e["state"] != "open":
                bits.append(e["state"])
            age = days_since(e["updated"])
            bits.append("%dd" % age if age else "today")
            out.append("- [%s#%s](%s) %s  \n  <sub>%s</sub>" %
                       (e["repo"].split("/")[-1], e["number"], e["url"],
                        e["title"], " · ".join(bits)))
        if len(unread) > 40:
            out.append("- _...and %d more_" % (len(unread) - 40))
        out.append("")

    for key, title, blurb in SECTIONS:
        rs = sorted([r for r in vis if r["bucket"] == key and not r["backlog"]],
                    key=urgency)
        if not rs:
            continue
        out += ["## %s (%d)" % (title, len(rs))]
        if blurb:
            out.append("_%s_" % blurb)
        out.append("")
        out += [line(r) for r in rs]
        out.append("")

    stale = sorted([r for r in vis if r["bucket"] == "stale"],
                   key=lambda r: activity_age(r) or 0)
    if stale:
        out += ["## Stale — decide (%d)" % len(stale),
                "_Yours, gone quiet, and you have not claimed them in `state.toml`. "
                "Add a `note`, `deadline` or `agent_task` to pull one back into an "
                "active lane; otherwise close it._", "",
                "<details><summary>expand</summary>", ""]
        for r in stale:
            out.append("- [%s#%s](%s) %s <sub>%dd</sub>" %
                       (r["repo"].split("/")[-1], r["number"], r["url"], r["title"],
                        activity_age(r) or 0))
        out += ["", "</details>", ""]

    fire = [r for r in vis if r["bucket"] == "firehose"]
    if fire or any(r["bucket"] == "mentioned" for r in vis):
        # Deliberately a count, not a list. The background pile is reached only
        # through `wl.py next`; printing a thousand lines here would be exactly
        # the firehose-in-your-feed this is meant to avoid.
        out += ["## Background pile", "",
                "%d open PRs in %s, %d threads you were mentioned in or commented "
                "on, plus %d of your own gone quiet. None of it surfaces here. "
                "Pull a batch to triage with `wl.py next`." %
                (len(fire), cfg["firehose"]["repo"],
                 sum(1 for r in vis if r["bucket"] == "mentioned"),
                 sum(1 for r in vis if r["bucket"] == "stale")), ""]

    if snoozed:
        out += ["## Snoozed (%d)" % len(snoozed), "",
                "<details><summary>expand</summary>", ""]
        for r in sorted(snoozed, key=lambda r: r["url"]):
            out.append("- [%s#%s](%s) %s <sub>%s</sub>" %
                       (r["repo"].split("/")[-1], r["number"], r["url"],
                        r["title"], r.get("snooze_why") or ""))
        out += ["", "</details>", ""]

    real = [c for c in changes if not c[1].get("backlog")]
    if real:
        out += ["## Changed since last refresh (%d)" % len(real), ""]
        for url, r, what in real[:40]:
            out.append("- [%s#%s](%s) — %s" %
                       (r.get("repo", "?").split("/")[-1], r.get("number", "?"), url, what))
        out.append("")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    try:
        main()
    except FetchError as e:
        raise SystemExit(str(e))
