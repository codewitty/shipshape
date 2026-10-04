---
name: review-lanes
description: Review a finished branch with three parallel fresh-context reviewers, each holding one focus (correctness and data, security and access control, the change's contract with its callers), plus a cleanup reviewer, then triage, fix, and close with a re-check. Use as review-to-pr's internal review, on any branch before its PR, or when someone says "review lanes", "parallel review", "review this branch", or "get it reviewed before the PR".
---

# Review lanes

One reviewer reading a whole diff for everything finds the loud problems and misses the
quiet ones, and a serial review loop then spends its second and third passes on the
fallout of the first. Three reviewers with one focus each read the same diff at the same
time, and a re-check confirms the fixes. Where this workflow was developed, small code
fixes reviewed this way took one or two internal rounds and passed the review bot on its
first pass; a serial loop on a comparable change took three passes and five bot rounds.

The lanes also look outside the diff. The security lane in particular has found real
holes in code a branch didn't touch, and each became a fix of its own.

The templates live in `${CLAUDE_PLUGIN_ROOT}/skills/review-lanes/lanes/` and the cleanup
reviewer's in `${CLAUDE_PLUGIN_ROOT}/skills/cleanup-review/reviewer-prompt.md`. Each
reviewer reads the repo's `.claude/workflow-profile.md` itself when it exists.

## 1. Set up

From the change's own worktree:

- **Base.** On a branch off the default branch: `git fetch -q origin && git merge-base
  origin/<default> HEAD`. On a stacked branch, the parent tip the child contains, picked
  as `shipshape:cleanup-review` step 1 describes.
- **Scope.** `git status --short`. Untracked files are in every reviewer's scope, so move
  out any that aren't part of the change. Plans and review logs can stay; the prompts
  exclude them.
- **Commit the change first.** Commit anything uncommitted now, as its own commit; after a
  feature workflow that leaves its work uncommitted, that is the whole feature. The
  re-check reads the fix commit alone, so the change under review can't ride in with it.
- **Gate first.** Run the full test suites now (the profile's **Tests** section) and record
  the counts. A lane that runs a test and sees a failure you already knew about wastes its
  budget. A doc-only change skips the gate, as it skips the suites everywhere else.
- **Log.** Create `review_pass_<slug>.md` at the worktree root, `<slug>` from the branch
  name with each `/` and `-` turned into `_` (`feat/front-door` gives
  `review_pass_feat_front_door.md`); a slash would make it a path. The name matters: every
  reviewer prompt excludes `review_pass_*.md` from its diff.

## 2. Run the four reviewers

Spawn all four in one message so they run in parallel, each a `general-purpose` agent:

| Reviewer | Template | Fill in |
|---|---|---|
| Correctness and data | `lanes/correctness.md` | `{{BASE}}`, `{{WORKTREE}}`, `{{CHANGE}}`, `{{QUESTIONS}}` |
| Security and access | `lanes/security.md` | same |
| Contract and callers | `lanes/contract.md` | same |
| Cleanup | `cleanup-review/reviewer-prompt.md` | `{{BASE}}`, `{{WORKTREE}}`, `{{REQUEST}}` |

Write each filled prompt to a scratch file outside the repo and give the agent one line:
read that file in full and follow it. Check `grep -c '{{'` is 0 first.

Two cases run fewer:

- **Doc-only** (as the profile's Verify section defines it; no code, scripts or migrations
  by default): the contract lane and the cleanup reviewer. Docs make claims about code,
  and those two check them.
- **After a feature workflow that already ran a cleanup review**: the three lanes only.

A branch that changes only plans or design documents (`*_PLAN.md`, `*_DESIGN.md`) isn't for
this skill: every reviewer excludes those files so the author's reasoning can't steer the
code review. Plans get reviewed with the user.

Filling the placeholders:

- **`{{CHANGE}}`** says what the diff does in two to four sentences: the routes, functions
  or behavior it changes. Never why, never what you were unsure about. The lanes need to
  know where to look, not the author's reasoning.
- **`{{QUESTIONS}}`** is optional, a short list of diff-specific checks for that lane:
  "every caller of `X`", "what happens when `account_id` is None", "the e2e specs that call
  this route". They add to the lane's standing checklist and never replace it. Ask about
  mechanisms, not about whether your choice was right. With none, fill it with an empty
  string.
- **`{{REQUEST}}`** for the cleanup reviewer follows `shipshape:cleanup-review`'s rule: the
  user's words verbatim, or a named plan's goal and scope sections.

Each lane reports Critical, Warning and Nitpick findings with file:line and evidence, and
marks findings in pre-existing code separately.

## 3. Triage

When all four are back, write every finding into the log with a disposition before
changing code:

- **Accept** when the evidence holds. Re-run its command if it's cheap.
- **Reject** with the reason: wrong evidence, on the profile's never-flag list, or a change
  of behavior nobody asked for. Rejections are pushback material for the review-bot round
  later.
- **Two lanes, one finding.** When lanes report the same bug independently, say so in the
  log. It is the strongest signal this review produces.
- **Pre-existing, outside the diff.** Confirm it by reading the code. A Critical one goes
  to the user straight away with a proposed fix as its own branch. Don't widen this branch
  without asking; when the user agrees it belongs here, it goes in.
- **Nitpicks** are cheap. Take them unless they'd churn code the branch doesn't own.

A finding that names a mechanism ("this raises a plain ValueError", "the flush never runs
the default") gets a repro before you act on it, in a scratch script or a unit test.

## 4. Fix

Apply accepted fixes, then the gate: targeted tests, the full suites, lint where it
exists. A fix that changes behavior is proven again on the running app, the same way the
feature was. Commit once for the round, with the findings it answers in the body; the
re-check reads that commit.

Your own revert tests ("does this test fail on the old code?") go in a throwaway worktree,
as the lane prompts describe, never in the branch's tree while any reviewer is running. An
author's revert test in a shared tree once showed a parallel reviewer three failures that
weren't real.

## 5. Re-check

Spawn one fresh agent with `lanes/recheck.md`, filling `{{BASE}}`, `{{WORKTREE}}`,
`{{FIX_COMMIT}}` and `{{FINDINGS}}`: each accepted finding in one line, with the fix you
claim. It proves each fix by running code, says fixed or not fixed, and looks for anything
the fix round broke. It ends with the literal `RE-CHECK CLEAN` when everything is fixed and
it found no new Critical or Warning.

- **Clean:** triage its Nitpicks as in step 3. If you reject them all, the review is done.
  Any you take are a fix like the others: gate, commit, and re-check again, inside the
  cap. At the cap, a Nitpick you'd still like to take goes in the PR's not-done section
  instead.
- **Not clean:** fix, gate, commit, and re-check again. After three re-checks without a
  clean line, stop. Write what's still open in the log and tell the user; the disagreement
  is about the design, and another round won't settle it.
- **Skipping it:** only when no finding was accepted, so there is no fix to check. Say so
  in the log and in the PR body. A fix to tests or docs still gets the re-check: the gate
  only shows a corrected test passes, and the re-check's revert step shows it can fail. A
  test-only fix round that skipped it once shipped an assertion that also passed on the
  old code.

## 6. Close the log

The log's last entry: each reviewer's findings by severity, dispositions, which lanes
found the same thing, pre-existing findings and where they went, the fix commits, the
re-check result, and the gate counts. Commit it on the branch. `shipshape:review-to-pr` writes
the PR's review history from it.
