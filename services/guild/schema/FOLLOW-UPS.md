# Guild schema follow-ups

Hand-over for [PR 34](https://github.com/zeachcakes/eclipse-bot-v3/pull/34),
branch `feat/guild-star-schema`. A new session can start from this file alone,
without the earlier review history or conversations.

Status on 2026-11-12, after the branch was squashed into one commit on
`main` at `44c85ed`, which merged the feature specifications (PR 35). Commit
hashes below name the commits before the squash; the PR 34 timeline still
shows them.

- The first review left 20 threads. All 20 are fixed; item 6 was fixed in
  `98812f7`, item 5 in `47e1fff`, and item 7 in the squashed commit after
  PR 35 merged.
- An automated review on 2026-11-10 added 4 more threads (items 17 to 20).
  All 4 are fixed, pushed and resolved: `7c0ddb7`, `663c20e`, `62d96e8` and
  `e9b2219`.
- Items 12 to 16 came from a discussion with the project owner, not from a
  review. Items 13 and 14 are built in `a3b3d8d`, item 12 in `8d654be`.

Remove an item when it is done and resolve its review thread. Item numbers
stay fixed, so a removed item leaves a gap. Delete this file when the list is
empty.

## Start here

- Read "Rules" and "Decisions already made" below. Do not reopen a decision
  that is recorded there.
- Item 15 is a spec change for its own docs pull request against `main`.
  Items 10, 11 and 16 need no action yet.
- Before merging, work through "Before merge" at the end of this file.

## Rules

- Work on `feat/guild-star-schema`; PR 34 is the place for these changes.
  Follow [AGENTS.md](../../../AGENTS.md) for commits. Do not add a Claude
  `Co-Authored-By` trailer; the project owner asked for none.
- Push only as a fast-forward. Fetch first; a force-push needs the owner's
  approval in that session.
- The migrations are unreleased and no shared database has applied them, so
  edit `V1` to `V9` in place. Do not add a `V10`.
- Every migration lives in `src/main/resources/db/migration/`. Each file owns
  one domain, every function declares its own `SECURITY DEFINER` and
  `search_path`, and `V9` is the only file that grants anything to
  `guild_runtime`.
- SQL test files 020, 030, 040, 100, 105, 120 and 130 run as `guild_runtime`
  and switch to the administrator with `RESET ROLE` only for what that role may
  not do. Keep that pattern in new cases.
- Never run tests against the developer's own `eclipse-bot-postgres-1`
  container. Use a throwaway container as shown below.
- When behaviour changes, update [README.md](README.md), the
  [design](../../../docs/design/guild-star-schema.md) and
  [ADR 0012](../../../docs/decisions/0012-guild-star-schema.md). CI fails when
  [the ER diagram page](../../../docs/design/guild-er-diagram.md) is out of
  date, so commit the regenerated page with any table or index change.

### Verify a change locally

This repeats the CI build job against a throwaway container. Docker Desktop
must be running (`open -a Docker`). No local `psql` is needed. A worktree has
no `.env`, so the settings are passed inline. Run from the repository root:

```sh
image="$(docker inspect eclipse-bot-postgres-1 --format '{{.Image}}')"
docker run -d --rm --name guild-check -p 127.0.0.1:55432:5432 \
  -e POSTGRES_USER=eclipse -e POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
  -e POSTGRES_DB=eclipse_bot "$image"
until docker exec guild-check pg_isready -U eclipse -d eclipse_bot -q; do sleep 1; done

export MISE_NO_ENV=1 \
  CATALOG_DB_URL=jdbc:postgresql://localhost:55432/eclipse_bot \
  CATALOG_DB_USER=catalog_migration CATALOG_DB_PASSWORD=local_only \
  GUILD_DB_URL=jdbc:postgresql://localhost:55432/eclipse_bot \
  GUILD_DB_USER=guild_migration GUILD_DB_PASSWORD=local_only \
  GUILD_APP_DB_USER=guild_application GUILD_APP_DB_PASSWORD=local_only

docker exec -i guild-check psql -X --set ON_ERROR_STOP=1 -U eclipse -d eclipse_bot \
  -c "CREATE ROLE catalog_migration LOGIN PASSWORD 'local_only'" \
  -c "CREATE SCHEMA catalog AUTHORIZATION catalog_migration"
docker exec -i -e GUILD_DB_USER -e GUILD_DB_PASSWORD -e GUILD_APP_DB_USER \
  -e GUILD_APP_DB_PASSWORD guild-check \
  psql -X --set ON_ERROR_STOP=1 -U eclipse -d eclipse_bot < tools/postgres/bootstrap-guild.sql

mise exec -- ./gradlew :services:catalog:schema:prepareSchema --no-configuration-cache
mise exec -- ./gradlew :services:guild:schema:prepareSchema --no-configuration-cache
GUILD_TEST_CONTAINER=guild-check bash tools/postgres/test-guild.sh
mise exec -- python tools/postgres/generate-guild-erd.py \
  --container guild-check --database eclipse_bot --user guild_migration
git diff --exit-code -- docs/design/guild-er-diagram.md
mise exec -- ./gradlew build
mise exec -- ./gradlew -p tools/gradle :convention-plugins:check
mise exec -- pre-commit run --all-files --show-diff-on-failure
docker rm -f guild-check
```

## Decisions already made

The project owner made these choices. They are implemented, tested and
documented on the branch.

| Topic | Decision | Commit |
| --- | --- | --- |
| Verification age | A verification can start a link or a transfer request for 15 minutes (`verification_max_age_seconds`, 900). | `87ef0ba` |
| Transfer expiry | A pending request expires after 2 days (`transfer_pending_max_age_seconds`), an unused approval 1 day after the decision (`transfer_approval_max_age_seconds`). Both are guild settings. The approval limit does not run while a Clan Games boundary read is pending and restarts when it arrives. | `7373063` |
| Report dispatch | A report is one Discord message; every revision edits it. If the message was deleted, the next revision creates a new one. | `82fc75e` |
| Kick retry | A failed or uncertain kick is tried again: 3 attempts (`kick_max_attempts`), 300 seconds apart (`kick_retry_seconds`). The attempt limit is fixed when the kick is decided. | `1ed6c8a` |
| Kick claims | `claim_moderation_action` gives one worker a lease and returns `kick` or `check_member`. After an uncertain attempt or an expired claim, the worker checks the member first and records success if they are gone. | `1ed6c8a` |
| Kick cancellation | A revoked warning cancels a kick that still owes an attempt when fewer than 5 active warnings remain that month. An attempt in flight finishes; its failure cancels instead of retrying. A new fifth warning arms the kick again. | `1ed6c8a` |
| SQL checks | Stay outside the Gradle build, as `mise run guild:test` and a CI step. An ordinary build must not depend on a database (ADR 0007, ADR 0011). | `9022f3f` |
| Meaning of audit | Audit means activity history: war attacks, Clan Games points, donations, clan joins and leaves, warnings, kicks and chat XP. The fact tables are that history; no row is copied into a change ledger. | `3d68404` |
| Single Discord server | One server per database. Only `dim_guild` and `guild_settings` carry `guild_key`; no function takes a guild argument. A second community gets its own database. | `98812f7` |
| Change history | Kept only for the 11 configuration tables and hand-made Clan Games events, in `fact_configuration_change`, read by developers through `configuration_audit_for`. | `3d68404` |
| Kick history scope | Includes what a leader does by hand in Discord: kicks, bans, unbans and timeouts, read from the audit log (`fact_manual_moderation_action`). The collector leaves out entries that the bot itself executed, so the bot's kicks are not counted twice. | `8d654be` |
| Donation source | Donation counters come from the clan member list poll, not from scheduled profile fetches. | `a3b3d8d` |
| Donation season | A fixed season calendar bounds donation totals: a season ends on the last Monday of the month at 05:00 UTC (`dim_coc_season`). The total is the last counter that a poll saw before that time (`clan_member_season_donation`). | `a3b3d8d` |
| Manual moderation readers | Same rule as `warning_history`: moderation roles read any member's entries, a member reads only their own (`moderation_history`). | `8d654be` |
| Manual moderation rejoin notices | A manual kick, and an unban, followed by a rejoin in the same month creates a leadership notice. Bans and timeouts do not. The notices have their own kinds; they do not stop the automatic kick of the fifth warning. | `8d654be` |
| Member list storage | Member rows are stored only on change, per member: a row when the member is new, the role or a donation counter changed, the member left and returned, or a new season began. `record_clan_member_observation` is the only runtime write path. One row per poll in `clan_membership_poll` proves that the poll ran. | `a3b3d8d` |
| Clan audits | War attacks used and missed, Clan Games points, donations, and joins and leaves. Raid loot was not chosen. | none |
| Command API | Every command is a typed function; none takes JSON. 13 activity functions (`cwl_*`, `custom_event_*`) keep the operation-UUID replay check first. Configuration has one `set_`/`delete_` function per entity, with full-row arguments; `guild_settings` is split into feature setters. The XP policy key has no setter. | `47e1fff` |

## Separate pull request

### 15. CFG-006 wording

Spec CFG-006 in `docs/feature-specs/configuration-and-access.md` says "audit
human and automated changes" and was read as a copy of every row change. The
owner defined audit as activity history. The specifications are on `main`
since PR 35 merged; reword it in its own docs pull request, not in PR 34.
Draft:

> **CFG-006:** Keep activity history as facts: war attacks, Clan Games points,
> donations, clan joins and leaves, warnings, kicks and chat XP, each with its
> actor or system origin, time and applicable reason. Keep configuration
> changes with actor, reason and the values before and after. Retain both
> indefinitely.

## No action until needed

These have no review thread.

### 10. Pinned single-value columns

`cwl_plan_revision.objective` and `notification_operation.event_version` are
pinned to one value by a `CHECK`, like `chat_xp_policy`. They are not offered
as settings. Nothing to do until a second value is needed; then widen the
check in the owning migration.

### 11. Foreign keys without an index

Indexes cover the known read paths. About 160 foreign keys still have no index
that leads with their columns. That is acceptable while parent dimension rows
are never deleted. Revisit with a real query plan.

### 16. Missed war attacks

Clan audits need attacks used and missed. Used attacks are rows in
`fact_war_attack`. A missed attack is not a row: it is a `war_participant`
with fewer attacks than `dim_war.attacks_per_member` when the war ends. Add a
view for it with the war feature that reads it.

## Before merge

- **CI.** CI passed for `47e1fff` on 2026-11-12, and the full local sequence
  passed on the squashed tree. Confirm that the run for the current head
  finished green; rerun it if it is still queued.
- **Rebase and merge.** The branch is one squashed commit on `44c85ed`. If
  `main` moves or later fixes land as new commits, squash and rebase again
  just before merging (a force-push, with the owner's approval in that
  session), then merge with GitHub's **Rebase and merge**.
- **Scope.** 99 tables and about 170 functions have no Java consumer yet.
  Consider landing CWL, notification delivery and leaderboards with the code
  that uses them.
- **Readability.** `V6` has many lines over 140 characters and no spacing
  around operators. There is no SQL formatter in pre-commit; sqlfluff would
  fit beside the existing hooks.
