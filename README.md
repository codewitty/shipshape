# shipshape

A Claude Code plugin for getting a change from "please fix this" to a reviewed pull
request without the agent skipping the parts that catch bugs.

It does three things:

- **Routes the task.** `front-door` reads the request and the code it names, picks a
  workflow (feature, bug, performance, refactor, investigation, review, plan, docs), and
  writes its steps as a checklist. A step it drops has to say why, and "it's small" isn't
  a reason.
- **Reviews in parallel.** `review-lanes` runs three fresh reviewers at once, one each for
  correctness, security and access control, and the change's contract with its callers,
  plus a cleanup reviewer. A re-check then proves the fixes by running code, including
  reverting a fix to show its test fails.
- **Works the PR to sign-off.** `review-to-pr` runs that review, proves the change on the
  running app, opens the PR, and hands it to `pr-review-loop`, which answers every review
  thread, pushes back with evidence where the reviewer is wrong, and waits for the next
  pass until the reviewer signs off.

Nothing in it merges or releases. Those stay with you.

## Install

```
/plugin marketplace add codewitty/shipshape
/plugin install shipshape@shipshape
```

Requires the `gh` CLI (authenticated) and `jq` for the PR loop. Update later with
`/plugin` → Installed → shipshape → Update now.

## Use

Describe a task without naming a skill ("fix the double charge on refunds") and the front
door picks it up from its description. Or name one:

| Skill | What it does |
|---|---|
| `/shipshape:front-door <task>` | Classify, size, checklist, then run the matching workflow |
| `/shipshape:review-lanes` | Parallel focused review of the current branch, fixes, re-check |
| `/shipshape:review-to-pr` | `review-lanes`, close-out, PR, then the review-bot loop |
| `/shipshape:pr-review-loop` | Work an open PR's review threads until sign-off |
| `/shipshape:cleanup-review` | One fresh reviewer for what to delete or simplify |
| `/shipshape:init-profile` | Draft this repo's workflow profile |

Every code change ends the same way: prove it on the running app, `review-to-pr`, stop. A
feature stops before `review-to-pr` and waits for you to ask for the PR.

The PR loop asks Codex (`@codex review`) for a review each round by default. Point it at
another bot, or at none, in your workflow profile. The internal review writes a log,
`review_pass_<branch>.md`, and commits it on the branch.

## Make it fit your repo

The skills are generic. What differs between projects goes in one file,
`.claude/workflow-profile.md`, which `/shipshape:init-profile` drafts from your repo:

- test commands and how to read their counts
- how to prove a change on the running app, and what counts as doc-only
- which of your own skills handle features, bugs and investigations
- your auth and tenant model, for the security reviewer
- patterns the cleanup reviewer must never remove (required audit calls, for example)
- where callers live, including clients that update on their own schedule
- deploy order, where database constraints live, how to check prod usage
- your `gh` account, review bot and PR conventions

Without a profile everything still runs on defaults; the template in
`plugins/shipshape/templates/workflow-profile.md` says what each default is.

## Why it's built this way

The workflow came out of running agents on a production codebase and watching where bugs
got through:

- **Verification before review.** A change that was never run on the app gets reviewed on
  faith. The front door won't let an agent skip the drive for a code change.
- **Fresh reviewers with one job each.** The agent that wrote a change defends its own
  code, and one reviewer looking for everything finds the loud problems and misses the
  quiet ones. The reviewers never see the author's reasoning.
- **Prove fixes by breaking them.** A test that passes on the fix proves little; the
  re-check reverts the fix in a throwaway worktree and shows the test fails.
- **Small, verifiable PRs.** One change you can prove on its own per PR. Small code fixes
  reviewed this way passed the review bot on its first pass.

## License

MIT
