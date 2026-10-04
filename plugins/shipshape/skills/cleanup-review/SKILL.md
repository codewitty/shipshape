---
name: cleanup-review
description: Run a fresh-context reviewer over a branch diff for what to delete or simplify, then apply what holds up. Narrating comments, guards nothing reaches, dead code, layers with one caller, escape hatches and unrelated edits, judged against the repo's own rules (auth checks, tenant filters, why-comments and the workflow profile's never-flag list stay). Use as a feature workflow's cleanup pass, on any branch before its review, or whenever someone says "cleanup review", "deslop", "remove the slop", "simplify this diff" or "is this over-engineered".
---

# Cleanup review

The agent that wrote a change is the worst judge of what it can lose: it defends its own
comments and guards the way anyone would. So a reviewer with fresh context reads the diff
and reports, and the author decides. Nothing is deleted on the reviewer's say-so.

## 1. Run the reviewer

Pick the base and fetch it first, because local refs go stale in worktrees:

- On a branch off the default branch: `git fetch -q origin && git merge-base origin/<default> HEAD`.
- On a stacked branch: the parent tip the child actually contains. Fetch, then use
  `git merge-base <parent> HEAD` when the local parent is ahead of `origin/<parent>` (it has
  commits not yet pushed) or was never pushed, and `git merge-base origin/<parent> HEAD`
  otherwise.

Run this from the change's own worktree, where the untracked files are yours. Check
`git status --short`: untracked files are in the reviewer's scope, so move out any there that
aren't part of the change. Plans and review logs can stay; the prompt excludes them. Never
move files in a checkout other sessions share. If you have to run there,
add a line to the prompt naming the untracked paths the reviewer should skip.

Spawn one agent with fresh context and the prompt in `${CLAUDE_PLUGIN_ROOT}/skills/cleanup-review/reviewer-prompt.md`, filling in
`{{BASE}}` (the sha), `{{WORKTREE}}` (the worktree's absolute path) and `{{REQUEST}}` (the
user's request, copied word for word, or "not given"; never your summary of it). When the
request only names a plan ("build `FOO_PLAN.md`"), use the plan's goal and scope sections
(what's in and what's out), copied verbatim: they state the outcomes. Leave out its problem
analysis, risk discussion and decisions, which are the author's reasoning:

    Agent(subagent_type: "general-purpose", description: "Cleanup review",
          prompt: <reviewer-prompt.md with BASE, WORKTREE and REQUEST filled in>)

Pass nothing else: no summary of the change, no plan, no explanation of choices. The
request says what was wanted; the reviewer's value is that it doesn't know why you did what
you did.

## 2. Triage every finding

For each one, decide and write down why:

- **Accept** when the evidence holds. Re-run its command if it's cheap; a finding that says
  "no caller passes None" is worth a ten-second grep, from the worktree.
- **Reject** when the evidence is wrong, the code is on the reviewer's never-flag list after
  all, removing it would change behavior for a reachable input, or the "dead" code has a
  consumer the grep can't see: a child branch in a stack (grep that branch), or the other
  side of a frontend/backend deploy. Say which.

Don't split the difference. A guard is either unreachable and goes, or reachable and stays;
a shorter version of a comment the reviewer called narration is still narration.

Items under the reviewer's **Seen outside scope** are correctness questions. Treat each
like a review Warning: fix it and re-verify, reject it
with a reason, or name it as open in the report.

## 3. Apply and re-prove

Apply accepted fixes to the working tree. Commit them, one concern per commit, only when the
calling workflow commits (`shipshape:review-lanes`, `shipshape:review-to-pr`) or the user asked; under
a feature workflow that leaves its work uncommitted, they stay uncommitted with the rest of
the feature. If a fix turns out
wrong, reverse that edit by hand.

Re-prove under the caller's verification rules: fresh test counts, and the change proven
again on the running app only where a fix changed behavior. Run on its own, run the full
suites (the workflow profile's **Tests** section) and refresh any `## Verification` section
the same way.

Most accepted fixes are meant to keep behavior the same. For those, a test that now fails
means the finding was wrong: undo that fix and record it as rejected. A few change behavior
on purpose: a swallowed-error fix, and any fix for a "Seen outside scope" item. For those, read the failing test before acting. It may pin the old
behavior and need updating, or it may show the fix is wrong. Either way, have a reviewer
look at the result once more after any behavior-changing fix.

## 4. Report

List each finding with its disposition: accepted (with the commit, or the file:line when
uncommitted), or rejected (and the reason), plus how each "Seen outside scope" item was
handled. A pass that found nothing says so and names what it checked.
