# For agents

Read `DESIGN.md` before changing anything: its headings are the index, and
"Invariants found by debugging" and "Decisions not to re-litigate" are the
parts that will otherwise be re-learned the hard way. `README.md` is the
manual; `TODO.md` is what is open; `git log` is the history. `Worklog.jl`'s
include list is the index to the code.

## The views set the design

Three lists are what the program is for, and everything else exists so that
each of them is exactly right:

1. **The firehose** (`'` `1`, where the browser opens): what *moved* and is
   unfiled, open or closed. "Moved" means somebody else did something since
   you read it - the wake table - never something you did yourself, and never
   `updated_at`. That is why every key on a row is a time or a sha of an
   event by somebody else, why `s` and `x` are the read stamp with one thing
   added, and why the stamps are GitHub's own event times.
2. **My work** (`'` `2`): the open work, whose tags - `edits`, `ready`,
   `review`, `second` - have to be right without a clock saying so. That is
   why the three lanes are fetched whole every refresh and everything else
   only by url when a clock says it moved.
3. **The backlog** (`'` `3`): the standing open list, read ones too. That is
   why nothing ever leaves the corpus, why backlog rows are read by
   construction, and why `filed` is a separate mark - it is the one thing the
   backlog leaves out.

A view names a filter, one axis per question; it is never a lane, and no
row carries a single word for what it is.

## Two rules that hold everywhere

- **Facts are fetched, wants are derived, judgement is written down** - in
  `data/local.toml`, which is edited key by key and **never rewritten**.
  `config.toml` and `themes/` are never written at all.
- **Time is an argument, `at`, and it is when the operation started.** No
  global clock, no stored age, no offset.

## Working here

Run from the code checkout, not `data/` (its own repository).
`julia --project=cli cli/test/runtests.jl` is the suite; it never writes
`local.toml` (it does clear `data/errors.log`). Commit as `worklog: summary`
with a prose body, via `git commit -F`.
