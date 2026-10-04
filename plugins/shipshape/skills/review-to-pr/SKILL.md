---
name: review-to-pr
description: Take a finished branch all the way to a reviewed pull request in one unattended run. First the internal review (review-lanes: three parallel focused reviewers plus a cleanup reviewer, fixes, a re-check), then the close-out (fresh test counts, fresh proof on the running app, closing log entry, push, PR opened with a body drawn from the log), then the GitHub review loop with the review bot and any human reviewers until they sign off. Use whenever a branch is done and needs hardening before merge, or the user says "review it and open a PR", "harden and open a PR", "get it through review", "ship this branch". Not for reviewing someone else's PR, and not for merging.
---

# Review to PR

Two reviews, one after the other, with a hand-off in the middle. The internal review
(`shipshape:review-lanes`) hardens the branch before anyone outside sees it. The GitHub loop
(`shipshape:pr-review-loop`) works the PR's review threads to sign-off. This skill owns the
order, the hand-off, and what falls between the two: the close-out, the PR body, stacked
branches, and running more than one branch at once.

Read both skills before starting and follow them as written for their phase; this file
only says what changes when they run back to back. Read `.claude/workflow-profile.md` too:
its **Tests**, **Verify** and **GitHub** sections fill in the commands below. Without it,
use the defaults each section of the template names.

Runs unattended. The user starts it and leaves. Don't come back to the terminal to ask
whether to continue between phases; the phases are the plan.

## Phase 1: internal review

Run `shipshape:review-lanes` as its skill describes: base, gate, log, the four reviewers in
parallel, triage, fixes, re-check. Phase 1 ends when the re-check prints
`RE-CHECK CLEAN`, or when no finding was accepted and the re-check is skipped. Nothing
else opens the PR.

Pre-existing findings outside the diff are the one place the run stops being unattended.
A Critical one goes to the user before Phase 2, as `shipshape:review-lanes` step 3 says,
because whether it joins this branch is their call.

## Phase 2: close-out and PR

When Phase 1 ends, in this order. A doc-only branch (as the profile's Verify section
defines it) skips steps 1 and 2 and says so in the closing entry and the PR body.

1. **Fresh numbers.** Re-run every suite on the commit Phase 1 ended on and record the
   real counts. When a count comes from piping a test run through `tail`, set
   `set -o pipefail` first: without it the pipeline returns `tail`'s status and a failing
   suite looks green. Treat any `failed` or `error` in the summary as a failure too. A
   failing suite is handled like a failed proof in step 2.
2. **Fresh proof.** On the same commit, prove the change on the running app as the
   profile's Verify section says, and read the evidence: the rows, the responses, the
   screenshots. A failed check means the review isn't done: fix it, gate, commit, record
   it in the log, and run the re-check on that commit with the failure as its finding.
   Then repeat steps 1 and 2 on the new head. If that was the third re-check, stop, record
   the failure, and report to the user without opening the PR. A failure never goes in
   the PR as a caveat. Stop anything you started for the proof once it's written down.
3. **Closing entry** in the log, on top of `shipshape:review-lanes` step 6: the fresh counts
   and proof, and a "What is deliberately NOT done" section that repeats every pending
   production or money item. Commit the log on the branch.
4. **Stop any wakeup heartbeat** you started (see "Running two branches at once").
5. **Stacked branch?** Decide before creating the PR, since `gh pr create` sets the base
   and draft state. If this branch sits on another unmerged branch, add `--base <that
   branch>` and say so in the first line of the body. If the parent's own review hasn't
   finished, also add `--draft`, and mark it ready (`gh pr ready`) when the parent's does;
   the bot reviews drafts, so starting its loop early costs nothing.
6. **Push and open the PR** with `gh pr create` and the flags from step 5, after checking
   that the active `gh` account has access (`gh auth status`; the profile's GitHub section
   names the right one). Write the body from the log, and lead with *why* (the defect or
   need, and its user-visible consequences) rather than an inventory of files. Then: what
   changed and the design properties that constrain it, migrations and deploy ordering,
   one paragraph of review history (which lanes found what, what two lanes found
   together, what went to its own branch), a `## Verification` section (the command that
   drove each feature and the output or row that proves it, fresh counts, what was not
   verified), and a **Not done, deliberately** section carrying the pending production and
   money items. Follow any PR conventions in the profile.

   Opening a PR is not merging. Don't merge, and don't run destructive remediation
   scripts: those need their own instruction. A reviewer approving code is not approving
   a production data fix, so name any pending production action in the PR body and in
   your message.

## Phase 3: GitHub loop

Every round that changes code rewrites the PR's `## Verification` section with the new
head sha and that round's counts, so no line describes an older head. A round whose fix
changes behavior proves it again on the running app first and updates those lines; a
refactor-only round keeps them and says they weren't re-run. `gh pr edit --body-file`
replaces the whole body, so fetch it first
(`b=$(mktemp) && gh pr view <n> --json body -q .body > "$b"`), change only that section,
pass the full file back, and `rm "$b"`. A temp file outside the repo keeps the worktree
clean for the next commit.

If the profile's GitHub section names a review bot other than Codex, or none, set the
matching `PRLOOP_*` variables (`PRLOOP_REVIEW_TRIGGER`, `PRLOOP_REVIEW_BOT`,
`PRLOOP_REVIEWED_RE`, `PRLOOP_BOT_CLEAN_RE`; `PRLOOP_REVIEW_TRIGGER=none` for no bot) on
every `prloop.sh` call. Then run `shipshape:pr-review-loop` on the new PR exactly as its skill
describes: status, spec,
baseline, request the bot's review, then rounds of triage, fix, gate, one commit, push,
reply in every thread, resolve what you fixed, request the bot again, wait. Things that
matter when the two reviews are chained:

- **The review log's rejected findings are your pushback material.** A bot will
  predictably re-raise decisions the log already settles. Push back with the same
  evidence and a fact the reviewer can check, and leave the thread unresolved so it has
  the last word.
- **A pushback round has no push**, so force the re-request after replying, as
  `shipshape:pr-review-loop` step 10 says.
- **Someone may press "Update branch" on GitHub** while you work. The push is then
  rejected as non-fast-forward. Pull with `--no-rebase` (a merge), never rebase, then push
  and request review for the merged head; the earlier request named a head that never
  carried your fix.
- **Stacked child PR:** after each round on the parent, merge the parent into the child
  (`git merge --no-edit <parent>`), run the child's full gate (the combined head is new
  code), push, and request review. Rewrite the child's `## Verification` with those
  counts. The child's diff must stay "everything since the parent", or the bot reviews the
  parent's changes twice.
- **The bot may be right about a class the internal review missed.** When a bot finding
  names a mechanism ("this event also fires on savepoint release"), confirm it with a
  repro before either fixing or pushing back.
- **Ten rounds without a clean pass** means the remaining disagreement is about the
  design. Say so on the PR, summarize what's open, and wait for the user instead of
  starting another round.

The loop ends on the states `shipshape:pr-review-loop` lists: a clean bot pass on the current
head with nothing actionable, a human approval, a stop word, merge, or close. Report the
round count, what changed, and every thread left open as a pushback. Don't merge; that
needs its own instruction.

## Running two branches at once

Each branch gets its own worktree, its own log and its own reviewers. The same session can
drive both: reviewer agents notify when they finish, so work whichever review or round
lands. Test runs are the bottleneck, so start a gate the moment its fixes are in and do the
other branch's reading while it runs. If your environment can schedule a wakeup, keep
one (20 to 30 minutes) as a fallback in case a notification is missed, and in its prompt name the task and thread ids
the next tick must check, because that prompt is all a cold heartbeat has.

## What to tell the user at the end

They were away. Lead with the PR links and where each review ended. Name the findings
that changed behavior, and say plainly which were caused by your own earlier fixes. Repeat
the pending production items every time; that is the one thing that must not get lost.
