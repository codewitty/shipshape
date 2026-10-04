# Workflow profile

The `shipshape` skills read this file, `.claude/workflow-profile.md` in your repo, for
everything that differs between projects. Fill in what applies and delete what doesn't.
A missing section means the skills use their generic default, which is noted under each
heading. Run `/shipshape:init-profile` to have Claude draft this from your repo.

## Tests

How to run every suite, and how to read a pass count from its output. The skills record
real counts in the PR, so say how to get one.

<!-- Example:
- Backend: `cd backend && pytest tests/unit -q | tail -1` prints `N passed`.
- Frontend: `cd frontend && npm run test:unit`; typecheck with `npx tsc --noEmit`.
-->

Default: look for the commands in `package.json`, `Makefile`, `pyproject.toml`, CI config
and the README.

## Verify

How to prove a change works on the running app, not just in tests: how to start it, how
to drive a feature as a real user would, and where the evidence (rows, responses,
screenshots) comes from. Name the skill or script if you have one.

Also say what counts as **doc-only** here (no code, scripts or migrations is the usual
rule). A doc-only change skips the drive and the suites.

Default: run the app, exercise the changed route or screen with real requests, and paste
the request and its output. When that isn't possible, say so in the PR under "Not
verified".

## Workflows

Which skill handles each class of task, if your repo or your personal skills have one.
The front door routes to these and falls back to its built-in steps for any class left
out.

<!-- Example; these are your own skills, the names are illustrative:
| Class | Skill |
|---|---|
| Feature | `plan-and-build` |
| Bug, performance | `diagnosing-bugs` |
| Investigation | `runbook` |
| Plan to stress-test | `grill-me` |
-->

## Scoping

For the security lane: how users, roles and tenants work. Which check proves a user may
call a route, how the tenant or account is chosen for a request, and which fields must
never come from the request body. Leave it out for a single-tenant app with no roles.

<!-- Example:
Multi-tenant; the subdomain picks the workspace. Roles OWNER > ADMIN > MEMBER > VIEWER.
Routes guard with `require_permission("...")`; `require_user` only proves sign-in.
Every query on tenant data filters by `workspace_id`. Never take `workspace_id` from the
request body.
-->

## Never flag

Patterns the cleanup reviewer must keep even when they look redundant: required audit
calls, tenant filters, locks around money, migration downgrades, and the like. One line
each, with the reason.

## Callers

Where callers of your code live, so the contract lane searches all of them: web
frontend, mobile app, e2e tests, scripts, infrastructure config. Name any client that
updates on its own schedule (an installed mobile app keeps calling old routes until users
update).

Default: search the whole repo.

## Deploy

How code reaches production and in what order: separate frontend and backend deploys,
migrations before or after code, queued jobs that outlive a deploy. The contract lane
checks a change against this.

## Data

Where database constraints live (a migrations directory, a schema file), so a reviewer
can check that any value the change writes will be accepted.

## Prod usage

How to check whether production still calls a route, job or setting before deleting it:
the log query, its location, and a control query for something known to be used.

## GitHub

The `gh` account with repo access, any PR conventions (title style, attribution line),
and the review bot. The PR loop defaults to Codex; for another bot give the values for
`PRLOOP_REVIEW_TRIGGER` (the comment that summons it), `PRLOOP_REVIEW_BOT` (its login),
`PRLOOP_REVIEWED_RE` (how it names the commit it read) and `PRLOOP_BOT_CLEAN_RE` (how it
says it found nothing). With no bot, say `PRLOOP_REVIEW_TRIGGER=none`; the loop then ends
on a human's sign-off.

Review logs (`review_pass_*.md`) are committed on the branch, so they reach the default
branch on merge. Say here if you'd rather keep them out, and add them to `.gitignore`.
