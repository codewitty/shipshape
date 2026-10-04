---
name: pr-review-loop
description: Drive a GitHub pull request through rounds of code review until the reviewer signs off. Reads the unresolved inline review threads, fixes what is right, pushes back with evidence on what is wrong or out of scope, runs the tests and linters, commits and pushes, replies inline in every thread, then waits for the next review pass and repeats. Use this whenever someone wants the review comments on a PR worked to completion: "I left comments on the PR", "address the review feedback", "go through the review", "work #291 to signoff", "resolve the open review threads", "reply to the reviewer", or keeping a PR moving until it is approved. It covers comments from human reviewers and from review bots such as CodeRabbit, Codex, and Sonar, and it covers disagreeing with a reviewer who misread the code, not only agreeing with them. Also use it right after an agent opens a PR and the user says they are about to review it. Reach for it even when the user never says the word "loop". This is for answering review comments on a PR, not for producing a review of someone else's code, opening a PR, or one-off git chores.
---

# PR review loop

You wrote the code. Someone is reviewing it. Work each round of their comments to
completion, push, reply in the threads, wait for the next round, and repeat until
they sign off.

The reviewer's attention is the scarce thing here. Every round should leave them
with less to say and nothing to repeat. That single idea settles most of the
judgment calls below.

## This runs unattended

Treat the loop as a service. Once it is started, it keeps itself running until
the PR reaches a terminal state, and it never stops to ask whoever launched it
for permission to continue. Interrupting them to confirm the obvious defeats the
point: they started this so they could go review something else.

Three rules follow, and they apply everywhere below even where the step does not
repeat them.

**Never return to the terminal to ask whether to keep going.** Not after a round,
not on a long wait, not on an ambiguous signal. Waiting is the normal state of
this loop, not a stall to report.

**Put questions on the PR, never in the terminal.** The reviewer is reading the
PR. A question in your terminal is invisible to them and stops the loop dead. A
question in a thread is visible, keeps its context, and costs nothing while you
carry on with the rest of the round.

**The reviewer already has a brake.** Commenting `stop`, `pause`, `halt`, `hold`,
or `freeze` ends the loop, and closing or merging the PR ends it too. Because
they can stop it whenever they want, you do not need to keep checking whether
they still want it running. Assume yes.

## The helper script

`${CLAUDE_PLUGIN_ROOT}/skills/pr-review-loop/scripts/prloop.sh` wraps the GitHub API calls this loop needs. Use it instead of
writing your own `gh api` invocations, because the GraphQL query and the
actionable-thread rule are both easy to get subtly wrong.

```bash
S=${CLAUDE_PLUGIN_ROOT}/skills/pr-review-loop/scripts/prloop.sh

$S status                 # one JSON object: state, thread counts, sign-off and stop flags
$S threads --human        # actionable threads written by people
$S threads --bots         # actionable threads written by review bots
$S threads                # both, people first
$S threads --all          # every thread, including resolved and already-answered
$S spec                   # PR body, linked issues, and review summary comments
$S reply   --thread PRRT_xxx --body-file /path/to/reply.md
$S resolve --thread PRRT_xxx
$S comment --body-file /path/to/note.md   # PR-level comment, stamped as an agent post
$S ask-signoff            # ask on the PR whether an ambiguous comment meant sign-off
$S request-review         # summon the review bot for the current head (once per head)
$S wait                   # blocks until something happens, then prints one JSON line
```

Every subcommand takes `--repo owner/name` and `--pr N`. Both default to the
current checkout. If `gh` is not on PATH, the script checks the usual Homebrew and
`/usr/local` locations, or you can export `GH=/path/to/gh`.

For anything the script does not cover, read `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-loop/references/github-api.md`.

## Before the first round

1. **Pin down the PR.** Run `$S status`. With no `--pr`, the script resolves the
   PR for the current branch, which is almost always the right one. If several
   are open and the branch does not disambiguate, take the most recently updated
   PR whose head branch you have checked out and say which one you picked in your
   first status line. Do not stall the loop on this.

2. **Look at `pr_author` and `reviewers`.** If the reviewer's login is also
   `pr_author`, this is a solo PR: the human is reviewing their own branch from
   the same GitHub account you are authenticated as. Two things follow, and both
   are already handled below, but you should know they are in play. GitHub will
   not let that account approve the PR, so `review_decision` stays
   `REVIEW_REQUIRED` forever. And comment authorship tells you nothing about who
   said what.

3. **Check out the branch and get the tree clean.** You cannot push fixes from a
   detached head or on top of unrelated local edits. `git status`, then
   `git switch <head_branch>` from the status output.

4. **Load the spec.** Run `$S spec`. The PR body and any linked issue are the
   agreed boundary of this change. Read the repo's `CLAUDE.md`, contributing
   guide, and any style docs too. You need all of this before triage, because
   "is this comment in scope?" is unanswerable without it.

5. **Record the baseline.** Run the test suite once before you touch anything. If
   something is already red on the branch, you need to know now, so you do not
   spend round three chasing a failure the reviewer never mentioned.

6. **Check the bot has seen the current head.** `$S status` reports
   `bot_reviewed_head`. When it is false, run `$S request-review` now rather
   than after the first round: the head may have moved since the bot's last
   pass, and its findings on the current code belong in the first triage, not
   the second.

## One round

### 1. Read what is actionable

```bash
$S status                 # check threads_actionable_human vs threads_actionable_bot
$S threads --human        # start here
```

A thread is actionable when it is unresolved **and** the last comment in it is
not one of your own replies. `$S reply` stamps every reply it posts with an
invisible HTML marker, and that marker is what the rule keys on.

The marker matters more than it looks. The obvious rule, "the last comment is not
from my login", breaks on a solo PR, where the reviewer's comments and your
replies come from the same account. It would file the reviewer's blocking comment
as something you had already handled and skip it in silence. Keying on the marker
works whether the reviewer is you, a colleague, or a bot.

The rest of the rule is worth keeping too, because it means no round counter on
disk to drift out of sync. Posting a reply marks a thread handled; the reviewer
answering your reply makes it actionable again by itself.

Threads with `is_outdated: true` still count. The lines moved because you pushed,
but the reviewer's point stands, and GitHub collapses outdated threads in the web
UI, so an unanswered one is easy for them to lose. On those threads GitHub drops
`line`, so the script falls back to the line the comment was written against and
sets `line_is_original: true`. Treat that number as a pointer into the old diff,
not into the current file, and find the code by reading the `diff_hunk`.

Also read `$S spec` again for this pass's review summary. Reviewers often put the
framing for the whole round in the summary and only the specifics in the threads.

### 2. Clear the human's threads before you touch the bots

Work `$S threads --human` to completion first. Only pick up `$S threads --bots`
once `threads_actionable_human` is zero.

The reason is that a human review pass is one argument. The reviewer read the
change, formed a view, and left comments that hang together. Interleaving
CodeRabbit nits stretches that pass across more rounds and buries the points they
actually care about. Bots also tend to re-raise, in weaker form, something the
human already framed better. Fixing the human's version first often makes the bot
thread moot, and you get to say so in one sentence instead of doing the work
twice.

When you reach a bot thread that covers code you already changed for the human,
re-read it against the current state of the branch before you reply. Reply with
what the fix was and why it covers their point.

### 3. Read the severity the reviewer already assigned

Reviewers grade their own findings, and that grade is better information than
your guess at how much a comment matters. The script parses it two ways.

**Per thread**, `severity` holds a `P0`-`P5` tag or a word label (`Blocker`,
`Critical`, `Major`, `Minor`, `Nit`, `Trivial`), taken from the opening of the
first non-agent comment. `severity_rank` folds both scales onto one axis, so a
CodeRabbit `Major` sorts alongside a human `P2`. `blocking` is true when the
thread says blocking, false when it says non-blocking or nit, null when it says
nothing. `$S threads` returns work in that order already: humans before bots,
blocking first, then by rank.

**Per PR**, some review tools post a tally marker such as
`<!-- ... head=<sha> blocking=2 -->`. `blocking_declared` is that count and
`threads_blocking_open` counts open threads tagged blocking.

Severity changes two things. It sets the order you work in, which is why the
script sorts by it. And it sets the bar for pushing back. Disagreeing with a
`Nit` costs the reviewer nothing. Disagreeing with a blocking `P1` means telling
them their stop-the-line finding is wrong, so bring evidence you actually
checked, quote the code, and never resolve that thread yourself.

**Do not treat a round as finished while blocking work is open.** If
`blocking_declared` is above zero for the current head, or
`threads_actionable_blocking` is above zero, there is more to do no matter how
tidy the thread list looks. This is a stronger guarantee than counting threads,
because it comes from the reviewer's own tally rather than from your reading of
their comments.

Both markers carry the commit they describe. When `blocking_marker_stale` or
`signoff_stale` is true, the marker names a commit that is no longer head:
someone signed off and then more code landed. Treat the tally as unknown and
keep working rather than inheriting a verdict for code that has since changed.

### 4. Triage every thread before you change any code

Sort each thread into one of three buckets and write the list down before you
start editing. Triaging as you go leads to half-applied rounds where you have
pushed three fixes and are still arguing about the fourth.

- **Fix it.** The reviewer is right, or the change is cheap and harmless even if
  you would have done it differently. Taste disagreements on their codebase go
  here. Do not spend the reviewer's patience on naming preferences.
- **Push back.** The comment rests on a misreading of the code, asks for
  something that breaks a stated requirement, or asks for work outside this PR.
- **Ask.** The comment is clear but the right answer needs a decision only they
  can make, such as which of two behaviours the product should have.

### 5. Fix what you agreed to fix

Two rules keep rounds reviewable:

- Change what the comment asked for and stop. A drive-by refactor next to a fix
  forces the reviewer to re-read code they already approved.
- If one comment implies the same problem in five other places the reviewer did
  not mark, fix all six and say so in the reply. Reviewers point at one instance
  and mean the class. Making them file the other five is the single most annoying
  thing an author can do.

### 6. Run the gate

Do not push red code into a review. The reviewer will spend their next pass on CI
noise instead of on the change.

- **Tests.** Find the command the way the repo declares it: `package.json`
  scripts, `Makefile`, `pyproject.toml`, `CLAUDE.md`, CI config. Run the tests
  covering what you touched while iterating, then the full suite once before you
  push.
- **Lint and typecheck.** Same discovery. Run them if they exist.

If a test fails for a reason this round did not cause, and you confirmed the
baseline in setup, say so in the reply rather than quietly fixing unrelated
things.

### 7. Commit once, push

One commit per review pass. The reviewer's next click is "changes since my last
review", and a single commit makes that diff exactly the answer to their round.

Match the repo's commit convention if it has one. Otherwise:

```
address review feedback (round N)

- <path>:<line> switch to the pooled client
- <path>:<line> guard against the empty-batch case
```

Push normally. **Never force-push or rebase the branch** unless the user asks.
Rewriting history scrambles the reviewer's sense of what is new and can strand
their comments.

### 8. Reply to every thread you touched

Every actionable thread gets a reply, including the ones you are pushing back on
and the ones you are asking about. Silence reads as "ignored".

```bash
$S reply --thread PRRT_xxx --body-file /tmp/reply.md
```

Use `--body-file` rather than `--body` so backticks and newlines survive the
shell. Keep replies to a sentence or two. The reviewer is scanning a dozen
threads, not reading an essay.

**When you fixed it,** name the commit and what changed:

> Fixed in `a1b2c3d`. Switched to the pooled client and dropped the per-call
> `connect()`. Same change applied in `worker.ts:88`, which had the same pattern.

**When you are pushing back,** lead with the fact that changes their mind, keep it
short, and end by offering to do it anyway. You are wrong sometimes and the thread
should stay cheap to reopen:

> `parseDate` already normalises to UTC on line 40, so the offset gets applied
> twice if we convert here. Happy to add an explicit assertion if you want the
> invariant documented.

For out-of-scope requests, say where the boundary is rather than just declaring
something out of scope:

> Agreed this is worth doing, but the retry policy is shared with the ingest path
> and #412 scopes this PR to the read side. I can open a follow-up issue.

**When you are asking,** ask in the thread instead of stopping the loop. A blocked
question sitting in your terminal is invisible to the reviewer:

> Two readings here. Should an expired token return 401, or refresh silently and
> retry once? I went with 401 for now since it matches `/session`, easy to flip.

### 9. Resolve what you fixed, leave the arguments open

```bash
$S resolve --thread PRRT_xxx
```

Resolve the threads where you made the change they asked for. That is the signal
that clears their queue.

Leave push-back and question threads unresolved. The reviewer gets the last word
on anything you disagreed about, and resolving it yourself takes that away.

### 10. Ask the review bot for its pass

```bash
$S request-review
```

Every round ends with this, after the push and the replies. The bot reviews the
commit it is pointed at, and nothing points it at a new head by itself: a review
it left on the previous commit says nothing about the code you just pushed, and
without a fresh request the loop would wait forever on a pass that was never
going to come.

The call is idempotent per head. It posts the trigger (`@codex review` by
default) stamped with the head SHA, and it declines when that head has already
been asked for or the bot has already reported on it, so calling it on a round
with no push costs nothing. A round with no push, where you only replied and
pushed back, is the exception: the bot won't look again on its own, so pass
`--force` once after the replies, or `wait` blocks indefinitely. Otherwise pass
`--force` only when the bot visibly missed a request.

With no review bot on the repo, set `PRLOOP_REVIEW_TRIGGER=none`: request-review
then does nothing, and the loop ends on a human's sign-off, approval or stop word.

Do this before the human's turn as well as after it. The bot's pass is cheap
and the human's is not, so the human should always be reading code the bot has
already been over.

### 11. Wait for the next pass

Run the wait in the background so its exit notification wakes you:

```bash
$S wait --repo owner/name --pr N     # via Bash with run_in_background
```

It polls with escalating backoff, 2 minutes then 4, 8, 16, and 30, checking once
before the first sleep so a reviewer who already commented does not sit through an
interval. It has no deadline unless you pass `--max-wait`, so a reviewer who
steps away for a day comes back to a loop that is still watching. Do not add a
deadline just to check in. It exits as soon as any of these is true, printing one JSON line with a
`woke` field:

| `woke` | Meaning |
|---|---|
| `new_comments` | New actionable threads. Start the next round. |
| `signed_off` | The reviewer posted a sign-off phrase. Stop. |
| `approved` | `review_decision` is `APPROVED`. Stop. |
| `merged` / `closed` | Stop. |
| `stop_requested` | The reviewer commented a stop word. Stop. |
| `signoff_unclear` | Something reads as sign-off but did not match. Run `$S ask-signoff`, then wait again. |
| `timeout` | Only if you passed `--max-wait`. Wait again. |

A clean bot pass arrives as `signed_off` with `signoff_source: "bot_clean"`.
Codex posts it as a PR comment, "Codex Review: Didn't find any major issues",
naming the commit it read, and `status` only counts it when that commit is the
current head and no thread is still actionable. A push changes the head, the
next round requests a new pass, and the verdict has to be earned again.

While waiting, do nothing else to the branch. Extra commits arriving between
review passes make the reviewer's "changes since last review" diff lie.

## Ending the loop

The loop ends on a terminal state, and only on one. Everything else is a reason
to keep waiting, not a reason to report back.

**They signed off.** This is the goal, and on a solo PR it is the only way the
loop can end cleanly, because GitHub refuses to let an account approve its own
pull request. `status` reports this three ways, and the distinction matters.

`signed_off: true` means one of two things happened. Either a review tool left a
structured marker, an HTML comment matching `<!-- ... signoff ... -->`, which is
the reliable signal because nothing matches it by accident. Or a comment carried
one of `LGTM`, `approved`, `ship it`, `looks good to me`, `sign off`, `signed
off`, `good to merge` **as the entire line**. The whole-line rule is what keeps
"I would approve if you split the migration" from ending the loop early.

`signoff_stale: true` means a marker exists but names a different commit than the
current head. Someone signed off and then more code landed. Treat it as not
signed off and keep working.

`signoff_possible` is a list of comments that talk like a sign-off without
matching either test, usually because the phrase sits mid-sentence. When that
list is non-empty and there is nothing actionable left, run `$S ask-signoff` and
go back to waiting. It posts one comment on the PR asking the reviewer to
confirm, stamped with a marker keyed to the current head, so `wait` stops
raising `signoff_unclear` for that commit and the question is asked once rather
than on every poll. If new code lands, the marker no longer matches and the
question can be asked again against the new head.

Resolve this on the PR rather than in the terminal. A missed sign-off is the
expensive failure here, since the reviewer thinks they are done while the loop
keeps polling, but the fix is to ask them where they are already looking.

If the user's review tooling has its own sign-off convention, point
`PRLOOP_SIGNOFF_MARKER_RE` at its marker rather than loosening the prose match.
Prose that reads as sign-off mid-sentence is genuinely ambiguous, and widening
the regex to catch it will eventually end a loop on "this is not approved yet".

**The bot's pass came back clean.** `signoff_source: "bot_clean"` means the
review bot read the current head, found nothing, and no thread is left
actionable. On a solo PR this is the sign-off that actually arrives, so the
loop ends on it by default. On a team PR where a human's approval is the real
gate, set `PRLOOP_BOT_SIGNOFF=0` and the clean pass is reported but does not
end the loop.

**A real approval landed.** On a team PR, `review_decision` reaching `APPROVED`
ends it too.

**The PR was merged or closed.**

**They asked you to stop.** `stop`, `pause`, `halt`, `hold`, or `freeze` on its
own line anywhere on the PR.

**The work stopped converging.** Ten rounds, or the same thread reopening a
third time with no new argument on either side, usually means a disagreement
about the design rather than about the code, and more rounds will not settle it.
Say so in the thread: name what you understand the disagreement to be, what you
would need to change your mind, and what you propose. Then keep waiting. Escalate
by writing on the PR, not by halting, because the reviewer is the one who can
break the tie and they are reading the PR.

When the loop does end, report the round count, what you changed, and every
thread still open because you pushed back on it.

## Settings

Change these with the environment variables below, not by editing this file or the
script: a plugin update replaces both. A repo's workflow profile (its GitHub section)
can name the values to use. They are defaults, not laws, and the user's instructions in
the conversation override them.

| Setting | Default | Change it when |
|---|---|---|
| Order of work | Humans first, bots after | A bot catches something urgent enough to jump the queue. |
| Resolve threads you fixed | Yes | The reviewer wants to verify fixes before resolving. |
| Resolve threads you argued | No | Never, really. It takes their last word. |
| Sign-off marker | `<!-- ... signoff ... -->` | `PRLOOP_SIGNOFF_MARKER_RE` |
| Blocking tally marker | `<!-- ... blocking=N ... -->` | `PRLOOP_BLOCKING_MARKER_RE` |
| Severity tag | `P0`-`P5` | `PRLOOP_SEVERITY_RE` |
| Severity labels | Blocker/Critical/Major/Minor/Nit/Trivial | `PRLOOP_LABEL_RE` |
| Sign-off phrases | See above | `PRLOOP_SIGNOFF_RE` |
| Sign-off near-miss net | Wide, report only | `PRLOOP_SIGNOFF_HINT_RE` |
| Stop words | See above | `PRLOOP_STOP_RE` |
| Bot logins | Any `*[bot]`, plus CodeRabbit, Codex, Actions, Sonar, Codecov, Sourcery, DeepSource | `PRLOOP_BOTS` |
| Review trigger | `@codex review`, posted once per head at the end of every round | `PRLOOP_REVIEW_TRIGGER` |
| Review bot | `chatgpt-codex-connector`, the login whose "Reviewed commit" line marks a head as reviewed | `PRLOOP_REVIEW_BOT`, `PRLOOP_REVIEWED_RE` |
| Bot clean pass is sign-off | Yes, when "Didn't find any major issues" names the current head and nothing is actionable | `PRLOOP_BOT_SIGNOFF=0`, `PRLOOP_BOT_CLEAN_RE` |
| Commits per round | One | The repo squashes on merge and prefers granular commits. |
| Backoff | 2 to 30 min | `PRLOOP_DELAYS` |
| Wait deadline | None | Only when you deliberately want the loop to expire. |
| Non-convergence signal | 10 rounds | Long-running PRs with many reviewers. |
| Force-push | Never | The user explicitly asks for a rebase. |

## When things break

- **`gh` not found.** Export `GH=/path/to/gh`. Homebrew installs to
  `/opt/homebrew/bin/gh`, which is not always on PATH.
- **Reply fails with `Resource not accessible`.** The token lacks write access.
  Check `gh auth status` for the `repo` scope.
- **`can_resolve: false`.** The repo restricts who can resolve threads. Reply
  anyway and leave the thread for the reviewer to close.
- **A thread you already answered shows as actionable again.** Either the
  reviewer replied to it, which is correct and means another round, or someone
  posted your reply by hand without the marker. Check the `agent_reply` flag on
  the thread's comments.
- **The push is rejected.** Someone else pushed to the branch. Pull with a merge,
  not a rebase, then push. Rebasing mid-review is worse than an ugly merge commit.
- **A thread refers to code that no longer exists.** Reply saying where it went
  and which commit moved it. Do not resolve it silently.
