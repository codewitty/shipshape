---
name: front-door
description: Start a coding task here when the user hasn't named a workflow. Classifies the request (feature, bug, performance, refactor, investigation, review, plan to stress-test, docs) and runs the matching workflow, after writing its steps as a checklist where every dropped step says "skip: <reason>". Use on "front door", "start on", "take this", "work on", "fix", "build", "look into", or any task given without a skill name. Not when the user names a skill; run that one.
---

# Front door

Each workflow assumes you already picked it. Picking wrong is the expensive mistake: a
bug fixed without a repro, a feature built without a plan, a "quick" change that never
ran on the app. This skill makes the pick explicit, then gets out of the way.

Read `.claude/workflow-profile.md` first if the repo has one. Its **Workflows** table names
the project's skill for each class; its other sections tell the later steps how this repo
tests, verifies and deploys. Without it, use the defaults below and suggest
`/shipshape:init-profile` once at the end.

## 1. Classify

Read the request, then look at the code, data or files it names before deciding. When
that shows the request is already done, rests on something the code contradicts, or names
a file that isn't there, stop and say so with the file:line, then ask what the user saw.
Don't build work to fit a wrong premise.

Pick one class. The profile's Workflows table overrides the default skill for any row.

| Class | Signs | Default workflow |
|---|---|---|
| Feature | New behavior: a screen, route, setting, integration | Write a short plan (goal, in scope, out of scope, steps), get the user's sign-off, build, prove it on the running app, run `shipshape:cleanup-review`, and leave the change uncommitted for the user to look at |
| Bug | Something is wrong: an error, a wrong number, a user report | Reproduce it, write a failing test, find the cause, fix |
| Performance | Slow, timing out, costly | Measure in production first, then reproduce locally against that number |
| Refactor | Same behavior, better shape | Small (one module, tests already pin it): pin what they miss, then change. Otherwise plan it like a feature, with the split in the plan |
| Investigation | "Why did", "check prod", a number that looks off | Read logs and data until the cause is known. No code yet |
| Review | A branch or PR that already exists | Review and fix, no PR yet: `shipshape:review-lanes`. Should end as a PR ("review it and open a PR"): `shipshape:review-to-pr`. An open PR's threads: `shipshape:pr-review-loop` |
| Plan to stress-test | A design or plan, no code yet, including a branch that only changes plan documents | Question the user one decision at a time, each with your recommended answer |
| Docs or skills only | Text, no code, scripts or migrations | Edit, then `shipshape:review-to-pr` under its doc-only rules |

An investigation that ends in a code change becomes a bug. A bug whose fix needs new
behavior becomes a feature.

When the request fits two classes and they'd lead to different work, ask one question
with your recommended reading. Don't ask when the classes share a workflow. When it fits
none ("make the dashboard better"), ask for the one outcome they want first, offering the
likeliest from what you read. A change that drops or renames a column or table always
gets a question first: old code still running during a deploy reads the old name, so it
usually takes two releases, and the user may want only the code-side rename.

## 2. Size it

One verifiable unit per PR: one change you can prove on its own, or for a refactor, one
change that tests prove equivalent. When the task holds more than one, say how you'll
split it before starting, and build the units as stacked branches; `shipshape:review-to-pr`
handles stacks. For the second unit onward, create its worktree off the parent branch
from the main checkout's root, so it doesn't nest inside another worktree.

A review that turns up a problem outside the diff gets its own branch, not a bigger one.
Ask the user before widening.

## 3. Write the checklist

Copy the chosen workflow's phases into the task list, or into your first reply as a
checklist when there is no task tool. Steps inside a phase follow that workflow's own
rules; the skip reasons below apply at either level.

The Review and Investigation classes end with their own workflow. A review round that
changes behavior is proven again on the running app. Every class that produces a new
change ends with the standard tail:

1. Verify: prove the change on the running app, as the profile's **Verify** section says.
2. `shipshape:review-to-pr`: its Phase 1 is `shipshape:review-lanes` (focused reviewers, fixes, a
   re-check), then the close-out, the PR and the review-bot loop.
3. Stop. Merging and releasing are the user's call.

A feature workflow that ends with the change uncommitted (the default does) runs step 1,
then waits: step 2 follows only when the user asks for the PR. A project's own feature
skill may commit, or skip the cleanup review; `shipshape:review-lanes` adjusts to either.

Every step either runs or carries `skip: <reason>`. Reasons that hold:

- Doc-only change: no drive and no suites (the profile's Verify section defines it).
- No UI touched: no screenshot.
- No migration: no migration step.
- The user said to skip it, in this conversation.

Reasons that don't hold for a code change: "small", "obvious", "the tests pass", "it's
urgent". The drive and the review are what those changes skip, and they are where their
bugs get caught.

## 4. Hand off

Run the chosen workflow and follow it as written. The front door doesn't repeat its steps
and doesn't override them; when the two disagree, the workflow wins.

Before deleting a route, a job or a setting as part of any workflow, check production
still doesn't use it, as the profile's **Prod usage** section says: a query over a long
window (90 days is a good default) for its path, plus a control query for a path you know
is used, so zero hits means unused and not unlogged. Without that section, ask the user.
