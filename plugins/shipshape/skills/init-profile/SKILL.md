---
name: init-profile
description: Draft this repo's .claude/workflow-profile.md, the file the ship skills read for project specifics (test commands, how to verify on the running app, auth and tenant model, never-flag rules, where callers live, deploy order, database constraints, prod usage checks, GitHub conventions). Use when someone says "set up the workflow profile", "init profile", or after a ship skill suggests it.
---

# Init profile

The `shipshape` skills are generic. Everything that differs between projects lives in one file,
`.claude/workflow-profile.md`, and this skill drafts it from what the repo already says.

1. **Read the template** at `${CLAUDE_PLUGIN_ROOT}/templates/workflow-profile.md`. Its
   headings are the contract: the other skills look sections up by these names, so keep
   them exactly.
2. **Read the repo.** Agent instructions (`CLAUDE.md`, `AGENTS.md`, `.cursorrules`), the
   README, CI config, `package.json` / `Makefile` / `pyproject.toml`, the migrations
   directory, auth middleware and route guards, deploy config. For each section, take
   only what the repo states or the code shows.
3. **Draft the file.** Write each section from what you found, citing the file it came
   from where that helps a reader check it. Leave out a section you have nothing real for;
   its default applies. Never invent a command, a rule or a log location.
4. **Ask about the gaps.** List the sections you left out or are unsure of, with your best
   guess for each, and ask the user to confirm or correct them in one message. Verify,
   Never flag and Prod usage are the ones code rarely answers on its own.
5. **Write it** to `.claude/workflow-profile.md` once the user has answered, and say which
   sections still use defaults. It belongs in version control, so everyone working in the
   repo gets the same behavior; don't commit it unless the user asks.

If the file already exists, show what you'd change and why, and edit only with the user's
agreement.
