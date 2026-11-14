# Star-schema working plan

Start here for a guild schema or service task. This is the authoritative
register of remaining gaps, owner decisions and workstream dependencies.
Detailed behavior belongs in the [rule catalog](guild-service-rules.md);
requirements belong in [feature specifications](../feature-specs/README.md).
`services/guild/schema/FOLLOW-UPS.md` was removed and replaced by this file.
Keep it removed rather than maintaining a second handoff list.

## Current baseline

Baseline on 2026-11-14: [PR 34](https://github.com/zeachcakes/eclipse-bot-v3/pull/34),
`feat/guild-star-schema`, squashed into one commit on `main` after the review
gaps and owner decisions were recorded. Inspect the current branch head
before resuming.

- The shared dimensions, activity facts, temporal bridges and separate
  workflow state are the intended model. The review does not require a
  wholesale redesign.
- The migrations contain 122 tables and 50 views, with no functions, triggers
  or procedural blocks. Java owns business rules, workflows and permission
  checks ([ADR 0012](../decisions/0012-guild-star-schema.md)).
- `services/guild/server` does not exist. No Java consumer implements the
  catalog yet. A documented target is not implemented behavior.
- Baseline CI was green. All 11 SQL suites and the application-login check
  passed in a fresh PostgreSQL 18 container. A separate reproduction confirmed
  GAP-12 despite those passing checks; GAP-12 is now closed and covered by
  `030_coc.sql`. These checks do not prove the future Java workflows correct.
- `guild-sql-reference` tags commit `c407abb`, the former PL/pgSQL
  implementation. Keep the tag as historical provenance, not as authority
  over current requirements or the corrections below.

## Start a session

1. Inspect `git status` and follow [AGENTS.md](../../AGENTS.md). Preserve
    existing work and select one feature or workstream below.
2. Read its feature specification, including acceptance scenarios, then only
    its catalog sections and owning migrations. Use the feature map for routing.
3. Check the gap and decision registers. Every `GAP` below is **OPEN** unless
    listed as closed. A `DEC` in the open table is **OPEN — OWNER INPUT
    REQUIRED**; resolved decisions are recorded with their date and outcome.
    Implement independent work while a decision is unresolved; do not choose
    the dependent product policy or mark it complete.
4. State the requirement IDs, rule IDs, affected records, transaction/lock
    order and tests for the selected task. Distinguish existing storage from
    proposed columns/tables before writing code.
5. Implement and verify the selected slice. Use the completion checklist;
    passing the old SQL tests alone does not complete a feature.
6. Update this register and the owning contract in the same change. Keep IDs
    stable; do not recycle closed IDs. End the session with changed behavior,
    checks, remaining gap IDs and owner decisions.

## Claude handoff: what to inspect next

Choose one bounded packet below. The schema parts of all four packets
landed on 2026-11-14 (see each packet's status); the sections remain as
reading paths for the service work that is still open. The packets are investigation priorities,
not instructions to implement every feature in one session. Status stays in
the gap/decision registers; this section supplies concrete reading paths.

### 1. Membership boundaries — GAP-12

Read the [membership specification](../feature-specs/membership-and-role-automation.md)
and [SR-MEM-03](guild-service-rules.md#sr-mem-03-membership-periods).
Inspect [V3](../../services/guild/schema/src/main/resources/db/migration/V3__coc_facts.sql):
`observed_clan_membership_period`, `current_observed_clan_member`,
`current_clan_member_state` and `current_clan_lifetime_war_stars`. Trace
`desired_clan_member_role` in
[V9](../../services/guild/schema/src/main/resources/db/migration/V9__feature_integration_and_access.sql)
before changing the exclusion constraint.

Deliver a scoped constraint/read-model change and replace the conflicting
expectation in [030_coc.sql](../../services/guild/schema/src/test/sql/030_coc.sql).
Check B's 12:01 join before A's 12:02 departure in both ingestion orders,
same-clan overlap rejection, current role/board eligibility, and supported CG
presence counted once. Consult SR-CG-03 for the union calculation and the
DEC-01 outcome for unlinked accounts.

### 2. Kick evidence and concurrency — GAP-06, GAP-13, GAP-14

Read the [moderation specification](../feature-specs/warnings-and-moderation.md),
SR-CTX-03 and SR-MOD-08–13. Inspect
[V4](../../services/guild/schema/src/main/resources/db/migration/V4__discord_utility_facts.sql):
`moderation_action`, `fact_moderation_action_attempt`,
`fact_discord_accepted_join` and `fact_moderation_event`, plus their V9 grants.
Use [060_moderation.sql](../../services/guild/schema/src/test/sql/060_moderation.sql)
and [110_runtime_grants.sql](../../services/guild/schema/src/test/sql/110_runtime_grants.sql)
for the schema checks.

Deliver the durable authorization/result/transition model and a consistent
lock order before enabling an executor. Explain crash-before-send, lost
response, voluntary/manual departure, late result after takeover and
kick-then-rejoin recovery. Keep unknown outcomes unknown. Warning retries are
answered before the permission check (DEC-10).

Status: the schema part landed. GAP-06 is closed; GAP-13 keeps only its
service protocol and tests, and GAP-14 is a service lock-order contract.
Both wait for `services/guild/server`.

### 3. Delivery context and attempt history — GAP-05, GAP-07, GAP-17

Read the [delivery specification](../feature-specs/notifications-and-delivery.md)
and SR-NTF-01/02/06/09/13. Inspect
[V7](../../services/guild/schema/src/main/resources/db/migration/V7__notification_delivery.sql):
`notification_operation`, `notification_report`,
`fact_notification_dispatch_attempt` and the existing typed context tables.
Start regression coverage in
[090_notification_delivery.sql](../../services/guild/schema/src/test/sql/090_notification_delivery.sql).

Deliver typed moderation/raid-start context, suppression evidence and
immutable per-attempt action/target fields with V9 grants. Prove that edit M
→ 404 → create N preserves both attempts' original context. DEC-14 (one
catch-up per outage) and DEC-16 (public CG progress rows) landed in V7.

Status: the schema part landed and GAP-05, GAP-07 and GAP-17 are closed.
Writing the context, disposition and per-attempt snapshot in the right
transactions is workstream 8 service work.

### 4. CWL frozen inputs, manual changes and exports — GAP-15, GAP-16, GAP-19

Read the [CWL specification](../feature-specs/clan-war-leagues.md) and
SR-CWL-10–17. Inspect
[V6](../../services/guild/schema/src/main/resources/db/migration/V6__cwl_and_custom_events.sql):
`fact_cwl_plan_input`, `cwl_plan_assignment`, `fact_cwl_manual_pin_revision`,
`cwl_export_revision` and `fact_cwl_export_attempt`. Compare storage checks in
[080_cwl_and_custom_events.sql](../../services/guild/schema/src/test/sql/080_cwl_and_custom_events.sql)
with the service regressions still required by the catalog.

Deliver a trace of signup A→B after a day freezes, an authorized manual
replacement after cutoff, and an old Sheets writer resuming after a newer
revision. Exports now freeze their signup inputs and destination and order
Sheets writes per clan and kind (GAP-19, SR-CWL-17).
Follow DEC-12 (refuse withdrawal while signups target the clan) and DEC-15
(confirmed registration serves a bench).

Status (2026-11-14 trace): GAP-15 and GAP-16 need no new tables. A plan
input now must use a signup revision that targets the plan's clan, and
`080_cwl_and_custom_events.sql` shows Day 1 freezing, the move A→B, a
carried-forward automatic plan and a manual revision. Both gaps stay open
for the service workflow. GAP-19 closed on 2026-11-14 with its storage and
Sheets ordering contract (SR-CWL-17).

### Starter prompt for the next Claude session

> Read AGENTS.md and docs/design/star-schema-working-plan.md. The four
> handoff packets have landed their schema parts; pick one open gap or
> workstream, unless I name another scope. Check the current branch and gap
> status, then trace its specification, catalog rules, owning migrations and
> SQL checks. Implement the selected slice with its relevant grants,
> regression checks and design/ER updates. Leave any new owner DEC item open
> and report which service/concurrency acceptance cases remain pending. Do not
> copy conflicting behavior from guild-sql-reference or recreate FOLLOW-UPS.md.

For schema work, also inspect the module's `build.gradle`, V9 grants and the
schema guide's disposable-database procedure. `services/guild/server` does
not exist: schema checks can run now, but runtime/concurrency cases need the
future service and must stay pending. When starting service work, use
`services/catalog/server` as the structural reference, especially
`JdbcConfiguration.java`, alongside ADR 0007/0009 and SR-CTX. Use the
workstream table for that implementation order.

## Documents

| Question | Source of truth |
| --- | --- |
| What must the feature do? | [Feature specifications](../feature-specs/README.md), requirement IDs such as `LINK-014` |
| What does the API actually supply? | [API evidence](../feature-specs/api-evidence.md); distinguish supplied samples from live validation |
| Why this model and service boundary? | [Design](guild-star-schema.md), [ADR 0012](../decisions/0012-guild-star-schema.md) |
| How does a service transaction behave? | [Rule catalog](guild-service-rules.md), stable IDs such as `SR-ACC-09` |
| Which tables, constraints and grants exist now? | Migrations `V1`–`V9`; [ER diagrams](guild-er-diagram.md) |
| How do I prepare, seed and check a database? | [Schema guide](../../services/guild/schema/README.md) |
| Where did an old function or test come from? | [SQL reference map](guild-sql-reference-map.md) |
| What is unfinished or awaiting the owner? | This file only |

Accepted decisions must be recorded in the relevant feature specification and
then reflected in the catalog and design/ADR. Do not copy an obsolete SQL
behavior over a requirement. Where an accepted design decision and a stale
specification disagree, record the discrepancy and propagate the decision
before implementing that behavior; never silently resolve a policy conflict.

Keep behavior in the catalog, rationale in the design/ADR, setup and access
instructions in the schema guide, and progress here. Link instead of copying.

## Working rules

- Work on the dedicated feature branch. Do not add a Claude `Co-Authored-By`
  trailer. Push as a fast-forward; a force-push needs owner approval in that
  session. Follow AGENTS.md for commits, checks and merge strategy.
- The migrations are unreleased and no shared database has applied them.
  Until first deployment, edit `V1`–`V9` in place, without adding `V10`.
  After deployment, applied migrations are immutable.
- Keep migrations declarative and domain-owned. Only `V9` grants access to
  `guild_runtime`. Facts have no delete privilege; update grants name only
  columns legitimately completed later, never identities or measures.
- A schema gap needs the migration, runtime grants, SQL checks, regenerated
  ER diagrams and relevant contract/design updates together. Do not describe
  a proposed table or grant as available before that change lands.
- SQL fixtures test schema constraints, indexes, generated values and grants
  as `guild_runtime`. Service rules need unit tests and, where applicable,
  repository/concurrency tests. Database tests stay outside ordinary builds
  (ADR 0007, ADR 0011).
- Use a throwaway PostgreSQL container following the schema guide. Never run
  checks against the developer's `eclipse-bot-postgres-1` container.
- `prepareSchema` must produce no jOOQ `Ambiguous key name` warning. Name
  colliding paths in `services/guild/schema/build.gradle`.

## Feature map

Storage exists for every feature, but that does not establish feature
readiness. The table lists the relevant open gaps and decisions; service code
is outstanding throughout. Detailed table inventories stay in the schema guide.

| Feature | Owning migrations | Catalog sections | Open dependencies |
| --- | --- | --- | --- |
| Configuration and access (`CFG`) | V1, V3, V5, V8, V9 | SR-AUTH, SR-CFG, SR-LB | none |
| Account links and attribution (`LINK`) | V2, V3 | SR-ACC, SR-CG | Primary-write ordering corrected under GAP-18 |
| Membership, onboarding and roles (`MEM`) | V3, V4, V7, V9 | SR-MEM, SR-DSC, SR-NTF-10 | none |
| Regular wars (`WAR`) | V3, V7 | SR-WAR, SR-NTF-05/11/12 | GAP-10 |
| Clan Games (`CG`) | V2, V3, V7 | SR-CG, SR-NTF-13 | none |
| Raid Weekends (`RAID`) | V3, V7 | SR-NTF-02/13; RAID collector requirements | none |
| Clan War Leagues (`CWL`) | V3, V6, V7 | SR-ACT, SR-CWL, SR-NTF-14–17 | GAP-15, GAP-16 |
| Custom events (`CUSTOM`) | V3, V6 | SR-ACT, SR-CUS | War evidence and the activity command envelope |
| Chat XP and ranks (`XP`) | V4, V8 | SR-XP | none |
| Warnings and moderation (`MOD`) | V4, V7 | SR-MOD, SR-CTX-03 | GAP-13, GAP-14 |
| Leaderboards (`LB`) | V3, V4, V8 | SR-LB, SR-MEM-08, SR-XP-05 | Metric definitions in LB-004/009/010 |
| Notifications and delivery (`NOTIFY`) | V7, V9 | SR-NTF | none |

## Schema gaps

This register includes **schema**, **service-contract** and **documentation**
gaps. Type identifies the work needed; a service-contract gap does not imply a
missing table. All rows in this table are **OPEN**. The referenced rules hold
the detailed transaction and acceptance contracts.

| ID | Priority / type | Requirement and affected rules | Gap and required outcome |
| --- | --- | --- | --- |
| GAP-10 | Low / schema and evidence | WAR-006; SR-WAR-01/04; workstream 11 | Validate war-log fields against a live response. Define retention for wars lacking preparation/start times; V3 currently requires both and has no `war_log` identity source. Never invent timestamps. A retention-scope reduction needs a requirement decision. Owner deferred the war-log retention choice on 2026-11-14 ("keep this for later"); options were war-log summaries in a separate fact (recommended), live wars only, or nullable `dim_war` times. |
| GAP-13 | High / service | MOD-005/006/009; SR-MOD-09–13; workstream 10 | Storage landed (2026-11-14): pre-send authorization with target join and `started_at`, write-once result columns, kick-specific `fact_moderation_attempt_resolution` and `confirmed_moderation_kick`. Remaining: the claim/start/result/recovery protocol in Java/Node, the stale-token fence, audit-log correlation, and tests for crash before send, lost response, voluntary leave, manual removal, late result after takeover and kick/rejoin recovery. |
| GAP-14 | Medium / service contract | MOD-004/006; SR-CTX-03, SR-MOD-01/04/08–13; workstream 10 | Warning issuance takes member then action locks; result processing can take action then member. Use member → warning month → action across moderation paths and prove concurrent warning/revocation/result/rejoin handling cannot deadlock. |
| GAP-15 | Medium / service contract | CWL-004/010/017; SR-CWL-10/11/14; workstream 15 | Current-signup-only inputs omit accounts moved away after a frozen assignment. Snapshot current candidates plus historical inputs needed by frozen carry-forward, retaining their prior signup provenance. Test an A→B signup move after A's day freezes. Storage is sufficient: an input's signup revision must target the plan's clan (2026-11-14), and `080` traces the move. Only the service workflow remains. |
| GAP-16 | Medium / service contract | CWL-010/011; SR-CWL-13/14/15; workstream 15 | A post-cutoff pin cannot both replace a frozen assignment and pass automatic publication's unchanged-day rule. Apply the authorized replacement through an explicit manual revision, publish it and carry it forward in later automatic plans. A pin does not override a bench. Storage is sufficient (manual revision with actor, pin revisions); only the service workflow remains. |

Closed gaps (do not reuse the IDs):

| ID | Closed | Outcome |
| --- | --- | --- |
| GAP-01 | 2026-11-14, schema | Read requests have `collect_from`; the checkpoint tolerance setting opens the T−24h acceptance window. Service enforcement remains SR-CG-04–06. |
| GAP-02 | 2026-11-14, schema | Signup revisions retain their target participation, allowing CWL moves. Service commands/exports remain SR-CWL-03. |
| GAP-03 | 2026-11-14, schema | Participating-clan revisions retain selection, lineup size and withdrawal. Service enforcement remains SR-CWL-02. |
| GAP-04 | 2026-11-14, schema | `clan_collection_settings` has war, profile/TH, CWL group, CWL war and raid cadences with the DEC-04 defaults, `> 0` checks and V9 update grants; `030_coc.sql` checks them. Collectors stay service work (workstreams 5, 11, 13, 15). |
| GAP-05 | 2026-11-14, schema | `notification_moderation_context` names exactly one warning, revocation, kick transition, kick attempt or rejoin notice; `notification_raid_start_context` names the announced weekend. Queuing them with the operation stays service work (SR-NTF-02, workstreams 4, 10, 13). |
| GAP-06 | 2026-11-14, schema | `fact_moderation_action_transition` keeps every decision, cancellation and rearming with trigger or revoked warning, system/staff origin, actor, attempts granted and time; `060_moderation.sql` checks the five → revoke → fifth-again sequence. Java must append the transition with each projection change (SR-MOD-01/08). |
| GAP-07 | 2026-11-14, schema | `fact_notification_disposition` keeps when and why an operation was expired or superseded and which operation replaced it. Writing it with the status change stays service work (SR-NTF-01/12/13, workstream 8). |
| GAP-08 | 2026-11-14, schema | Owner chose a signup-list report: `cwl_signups` report and notification kind, `notification_cwl_signups_context` naming the signup export it shows (V7, V9; SR-NTF-17; `080_cwl_and_custom_events.sql`). Queuing it stays service work (workstreams 8, 15). |
| GAP-09 | 2026-11-14, schema | Owner chose a per-season donations board only: `donations`/`season` with the new `latest_season_counter` method in the V8 catalog (SR-MEM-07, SR-LB-05; `100_leaderboard_calendars.sql`). |
| GAP-11 | 2026-11-14, schema | `raid_poll` keeps every raid collection; weekend state and totals are stored on change and name their poll; `raid_weekend_coverage` gives `observed_through`; raid report contexts name their poll (V3, V7, V9; SR-NTF-13; `030_coc.sql`, `090_notification_delivery.sql`). The collector stays service work (workstream 13). |
| GAP-19 | 2026-11-14, schema and contract | Exports have a per-clan/kind `export_sequence`, a destination snapshot and frozen signup inputs; `cwl_sheet_destination` serializes Sheets writers with a lease and fence; Sheets attempts are authorized before the write and completed once (V6, V9; SR-CWL-17; `080_cwl_and_custom_events.sql`). Worker and stale-writer tests stay in workstream 15. |
| GAP-12 | 2026-11-14, schema | The membership exclusion covers one account in one clan, so a move seen by B at 12:01 before A's 12:02 departure keeps both boundaries in either ingestion order. `current_observed_clan_member` resolves one current clan by the latest `confirmed_through`; the member list, war-stars board and desired clan roles follow it. `030_coc.sql` checks both orders, same-clan overlap and presence counted once. The collector and SR-CG-03 union remain service work (workstreams 5, 12). |
| GAP-17 | 2026-11-14, schema | Each dispatch authorization keeps `dispatch_action`, the edit's `requested_message_id` and, for a create after a missing message, `replaced_dispatch_key`; a succeeded edit must return the requested message. `090_notification_delivery.sql` checks edit M → 404 → create N. |
| GAP-18 | 2026-11-14, documentation | SR-ACC-09 now orders demotion → insert/return new link → append primary history. This fixes the guide's immediate-FK violation; Java still needs its first-link/make-primary test. |
| GAP-20 | 2026-11-14, schema | Presence found in the gateway member list had no record of its own: a state row needs a membership event, and a departure missed during an outage has no source time. `fact_discord_membership_event.event_source` distinguishes `gateway_event` from `member_list_sync`; a sync join carries `joined_at`, and a sync departure's `occurred_at` is documented as an upper bound (V4; SR-DSC-01/07, SR-AUTH-03; `050_discord.sql`). `guild_settings.welcome_sync_max_age_seconds` bounds the welcome of a sync join (DEC-18). The sync itself is workstream 3. |
| GAP-21 | 2026-11-14, schema | A Clan Games event could not be moved or corrected: unique start, no overlap and insert-only. `dim_clan_games_event.voided_at` voids a stored event once, `replaces_event_key` on the new manual event names it, the overlap exclusion covers only events that are not voided, and the correlation ID is unique so the schedule does not create that month again (DEC-19; V3, V9; SR-CG-01/02/07/14; `040_clan_games.sql`, `110_runtime_grants.sql`). The reschedule command is workstream 12. |
| GAP-22 | 2026-11-14, schema | Each league-group fetch stored every registered pool again, kept no row for a failed fetch or the requesting clan, and keyed round references by tag, so the repeated `#0` placeholder collided. `cwl_group_poll` keeps every poll; observations name their `group` poll and are stored on change; round references are keyed by `tag_position` (V6, V9; SR-CWL-04/07/18; `080_cwl_and_custom_events.sql`). The collector is workstream 15. |
| GAP-23 | 2026-11-14, schema | The reserved bench day was updated in place, so the day that an earlier plan kept free was lost. `fact_cwl_bench_assignment_revision` keeps every reservation, move and release; `current_cwl_bench_assignment` shows the latest (V6, V9; SR-CWL-09/16; `080_cwl_and_custom_events.sql`). Writing revisions is workstream 15. |
| GAP-24 | 2026-11-14, schema | A CWL cycle was one per month with a generated signup close, so a moved CWL or a second CWL of a month could not be planned. `cwl_cycle.month_sequence` allows further cycles; `fact_cwl_cycle_schedule_revision` keeps each signup close with actor, reason and operation, and `current_cwl_cycle` shows the latest; a leadership prompt names one schedule revision, and `schedule_changed` records a superseded prompt; a partial unique index allows one open cycle at a time (DEC-20, DEC-21; V6, V7, V9; SR-CWL-01/19, SR-NTF-14/15; `080_cwl_and_custom_events.sql`, `090_notification_delivery.sql`). The commands are workstream 15. |

## Decisions for the project owner

No owner decision is open. Add a new `DEC` row here, marked **OPEN — OWNER
INPUT REQUIRED**, when a product policy needs the owner. Record the answer in
its feature specification and catalog rule, then move the row to the resolved
table with its date and outcome.

| ID | Decision needed | Affected work |
| --- | --- | --- |

### Resolved decisions

The owner answered DEC-01 to DEC-17 on 2026-11-14, decided DEC-19 and
DEC-20 with the schema review of the same day, and answered DEC-18 and
DEC-21 on 2026-11-15. Each outcome is recorded in the named requirement and rule.

| ID | Outcome | Recorded in |
| --- | --- | --- |
| DEC-01 | A self-unlinked account keeps counting toward its former owner's Clan Games target and points until a different owner links it. | LINK-010, CG-013; SR-ACC-11, SR-CG-03 |
| DEC-02 | An approved transfer of an owner's primary completes while alts remain; the owner has no primary until they choose one. Nobody chooses for them. Schema: `primary_transferred` cause, `choice` without a previous link. | LINK-002; SR-ACC-09/13/16; V2, `020_account_links.sql` |
| DEC-03 | The T−24h read window defaults to 1,800 seconds, not 900. | CG-005; SR-CG-04/06; V3, `040_clan_games.sql` |
| DEC-04 | Default cadences: war 120 s, profile/TH 3,600 s, CWL group 900 s, CWL war 120 s, raid 900 s (member list 120 s, CG refresh 900 s and raid report 28,800 s unchanged). Closed GAP-04. | CFG-001, MEM-002, RAID-003, WAR, CWL; SR-CFG-05; V3, V9, `030_coc.sql` |
| DEC-05 | War reminders mention linked members with unused attacks and list unlinked roster accounts by in-game name; no war-role ping. Follow-up: no reminder is sent when no unused attack remains (`no_unused_attacks` disposition, V7). | WAR-005; SR-NTF-07/11; V7 |
| DEC-06 | Staff capabilities require a confirmed present Discord state; unknown presence fails closed. | CFG-010; SR-AUTH-03 |
| DEC-07 | CWL settings require an existing tracked clan. | CFG-012; SR-CFG-06 |
| DEC-08 | Only the owner developer (the main developer, seeded) adds or removes developers; the owner cannot be removed by command. Schema: `guild_settings.owner_developer_user_key`. | CFG-004; SR-AUTH-02, SR-CFG-12; V1, seed, `010_dimensions.sql` |
| DEC-09 | Direct SQL configuration edits are for bootstrap or emergencies only and must insert their `operator` history row in the same transaction. | CFG-013; SR-CFG-13; schema guide |
| DEC-10 | Warning command retries are answered before the permission check, as activity commands are. | MOD acceptance; SR-MOD-03 |
| DEC-11 | Merge V1–V9 with PR 34 now, including the CWL and delivery schema; migrations stay editable in place until first deployment. | This plan, "Before merging PR 34" |
| DEC-12 | Withdrawing a CWL clan is refused while active signups target it (proposed default confirmed). | CWL-001; SR-CWL-02 |
| DEC-13 | Stardust and its rank role start at the first credited message. Owner clarification: XP needs Eclipse (after a verified link) or Friends. | XP-001, XP-007; SR-XP-04 |
| DEC-14 | Each outage may queue its own catch-up; at most one unfinished catch-up per war and clan. Schema: partial unique index on unfinished catch-ups. | NOTIFY-011; SR-NTF-12; V7, `090_notification_delivery.sql` |
| DEC-15 | A bench is served only with confirmed registration; unknown registration only reserves a provisional day. | CWL-013; SR-CWL-09/16 |
| DEC-16 | Each public Clan Games points revision freezes explicit per-account progress rows. Schema: `notification_clan_games_report_progress`. | CG-020; SR-NTF-13; V7, V9, `090_notification_delivery.sql` |
| DEC-17 | The latest accepted join governs New Joinee; retained eligible links onboard at rejoin with New Joinee to rejoin plus 7 days; a first link after join plus 7 days gets no New Joinee. | MEM-012; SR-DSC-06 |
| DEC-18 | A join that the member list sync finds sends the MEM-010 welcome only when the member joined within the welcome window before the sync. The window is a guild setting; the review proposed the default of one day (86,400 seconds) and the owner did not change it. An older join gets no welcome; Applicants and onboarding are not affected. Schema: `guild_settings.welcome_sync_max_age_seconds`. | MEM-010; SR-DSC-07, SR-CFG-02; V4, V9, `050_discord.sql` |
| DEC-19 | The game has moved Clan Games, so an event can be rescheduled. The stored event is voided, not edited or cancelled, and a manual event that names it takes the new dates; the voided event keeps its evidence and collects and assesses nothing more. Schema: `voided_at`, `replaces_event_key`, partial overlap exclusion, unique correlation ID. Closed GAP-21. Proposed by the review and not changed by the owner: a configuration actor reschedules with a reason, and the schedule does not create that month again. | CG-001; SR-CG-14; V3, V9, `040_clan_games.sql` |
| DEC-20 | The game has moved CWL and has run two CWLs in one month. Staff can reschedule the signups of a cycle, and a month can have a further cycle. Schema: `month_sequence`, `fact_cwl_cycle_schedule_revision`, prompt per schedule revision. Closed GAP-24; the details are DEC-21. | CWL-003, CWL-018; SR-CWL-01/19, SR-NTF-15; V6, V7, V9 |
| DEC-21 | Rescheduling CWL: (1) Leadership, Co-leader or Admin reschedule a cycle or create a further cycle; (2) a later close reopens signups that had already closed, until the first War Day of the cycle freezes, and the earlier plans stay as history; (3) the new schedule always prompts leadership again, at once when its due time has passed; (4) cycles never overlap: the first cycle ends before a further one is created. Schema: partial unique index for one open cycle. | CWL-018; SR-CWL-01/18/19, SR-NTF-15; V6, `080_cwl_and_custom_events.sql` |

Follow-up to DEC-05 (2026-11-14): a war reminder or catch-up with no unused
attack left at send time is not sent; it is expired with a `no_unused_attacks`
disposition (WAR-005; SR-NTF-07/11; V7, `090_notification_delivery.sql`).

Other unresolved feature details remain explicit in the specifications,
including leaderboard metric formulas/baselines and the CWL optimizer's
unagreed rating formula. Do not add weights or publish unsupported scores as
an implementation convenience. Kafka topic/envelope, gRPC, retry and Sheets
worker protocols also need engineering contracts; those are implementation
work, not blanket requests for owner approval.

### Accepted decisions awaiting specification updates

These are already selected in ADR 0012/the catalog; do not ask the owner to
select them again. Their source specifications still describe portions as
open. Propagate the accepted behavior when implementing the affected slice:

| Accepted behavior | Specification to reconcile | Rules |
| --- | --- | --- |
| Verification freshness and configurable pending/approved-transfer expiry, including the points-read wait | Account linking: expiry/cancellation open points | SR-ACC-03/06/07/09 |
| Three kick attempts, 300 seconds apart by default; recovery must still satisfy GAP-13's evidence rules | Moderation: failed/uncertain recovery open points | SR-MOD-09/10 |
| Reports edit one message; missing messages are recreated; failed/uncertain creation can leave duplicates and needs explicit reconciliation behavior | Notifications: report retry/replacement open points | SR-NTF-13 |

Do not label a selected retry policy as proof that uncertain execution is a
confirmed outcome. A requirement change needs explicit agreement; a design
note cannot waive indefinite moderation history.

## Service workstreams

Use these IDs for task scope. Dependencies include shared workstreams and
applicable gaps/decisions; they block only the relevant slice. Shared delivery
gaps apply to every feature using that path. A feature's specification remains
authoritative even where no historical SQL rule exists.

| Order | Workstream and requirement coverage | Catalog | Dependencies |
| --- | --- | --- | --- |
| 1 | Service skeleton, blocking jOOQ boundary, clock, locks and independent database-test task; transaction/restart foundations of NOTIFY-003/004 | SR-CTX, SR-TEST | none |
| 2 | Identities, configuration commands and change history; CFG requirements and configuration acceptance scenarios | SR-CFG, SR-AUTH | 1 |
| 3 | Discord presence/held roles, the member list sync and current permission evidence; CFG-003–005/009–011, MEM-016 | SR-DSC-01–05/07, SR-AUTH | 2 |
| 4 | Atomic operation intent, typed source context and mentions; NOTIFY-003/004/014 | SR-NTF-01/02 | 2 |
| 5 | Member-list collector, observed periods, storage-on-change and seasons; MEM-001–005, CFG-006 | SR-MEM | 2 |
| 6 | Verification, links, attribution, primary and transfers; LINK requirements and acceptance scenarios | SR-ACC | 3, 5; test the GAP-18 ordering correction |
| 7 | Desired roles, welcome, onboarding and expiry; MEM-006–016, NOTIFY-012 | SR-DSC-06, SR-NTF-10 | 3, 4, 6 |
| 8 | Kafka infrastructure/contracts, relay, consumer, dispatch, results and reports; NOTIFY-001–016 plus every delivery failure/restart scenario | SR-NTF-03–10/13/17 | 4 |
| 9 | Chat eligibility, awards, rolling limits and ranks; XP requirements/acceptance scenarios | SR-XP | 3, 7 |
| 10 | Warnings, kicks, manual moderation and notices; MOD-001–010 and recovery/concurrency scenarios | SR-MOD | 3, 4, 8; GAP-13, GAP-14 |
| 11 | War collector, attacks, war roles, reminders and catch-up; WAR requirements and NOTIFY-010/011 | SR-WAR, SR-NTF-05/11/12 | 5, 7, 8; GAP-10 |
| 12 | CG events, boundary reads, inference, assessments and reports; CG requirements and LINK-013–016 | SR-CG, SR-NTF-13 | 5, 6, 8 |
| 13 | Raid collection, clan announcements and revisioned reports; RAID requirements/acceptance scenarios | SR-NTF-02/13; API evidence | 5, 8 |
| 14 | Reporting calendars and supported account/member boards; LB-001–011 | SR-LB, SR-XP-05, SR-MEM-08 | 5, 9; metric-specific 11/12/13/15; unresolved metric definitions |
| 15 | CWL cycles, signups, collectors, optimizer, pins, benches and CSV/Sheets/Discord outputs; CWL-001–017 | SR-ACT, SR-CWL, SR-NTF-14–17 | 6, 8, 11; GAP-15, GAP-16 |
| 16 | Custom events and roster/result association; CUSTOM requirements/acceptance scenarios | SR-ACT, SR-CUS | 6, 11; shared activity-command infrastructure with 15 |

The [notification specification](../feature-specs/notifications-and-delivery.md)
breaks workstreams 4 and 8 into infrastructure, contracts, workers and crash
coverage. Treat collectors, optimization, exports and cross-service adapters as
required feature work, even though they were never implemented in SQL.

### Completion checklist

- Map every in-scope requirement and acceptance scenario to implementation and
  validation. List deferred requirements explicitly; partial work uses
  `Part-Of`, not `Closes`.
- Implement the applicable rules and close their gap dependencies. Record
  resolved product decisions in their owning specifications. Do not label a
  workstream complete while its required decision or evidence is missing.
- Port or intentionally replace the applicable checks from the
  [SQL reference map](guild-sql-reference-map.md#checks-of-the-sql-tests),
  recording why obsolete expectations are dropped. Add the new review
  regressions; old SQL behavior is not the acceptance oracle.
- Verify realistic API/adaptor behavior, privacy, transaction rollback,
  idempotency, restart/uncertainty and concurrent workers where relevant.
  Use unit tests for pure rules and disposable-database tests for repositories,
  locks and grants. Never claim an external action succeeded from queued work.
- Run relevant checks from the development/schema guides and repository hooks.
  Update schema/grants/ER documentation together where needed. Report checks
  that could not run and why.
- Update this register and relevant existing PR threads only when the fix
  actually lands and thread handling is part of the task. Do not post a review
  or resolve a thread just because a plan has been written.

## Open review threads of PR 34

At the reviewed baseline, 13 existing threads were open. This is a historical
cross-reference, not another gap register. Verify GitHub state before acting.
"Schema present" means the service still needs to enforce the rule.

| Existing thread | Current routing |
| --- | --- |
| Checkpoint reads have no usable acceptance window | Schema present; SR-CG-04–06; window 1,800 s (DEC-03, resolved) |
| Rejoin notices never reach delivery | GAP-05; SR-MOD-13 |
| A transfer waiting for points cannot resume | SR-ACC-09 |
| An unlinked account still counts toward the old owner's target | Intended: DEC-01 resolved to keep counting |
| A primary with alts cannot transfer without its old owner | DEC-02 resolved: transfer completes, owner left without a primary (V2) |
| CWL cycles need an Admin before the leadership prompt | SR-CWL-01; runtime grants permit scheduler creation |
| CWL selections/signups cannot be corrected | Revision storage present; SR-CWL-02/03; GAP-15/16 cover later workflow conflicts |
| CWL freezes are never recorded | Freeze storage present; SR-CWL-05 |
| Custom events can use only wars already classified custom | `war_kind` update grant present; SR-CUS-01 |
| Backend cannot read its awarded XP | Read grants present; SR-XP-03 |
| Full war responses stored every poll | `war_poll` present; SR-WAR-04 |
| Older membership polls replace newer state | SR-MEM-05 |
| Assignment validation races plan publication | SR-CWL-14 |

## Before merging PR 34

- DEC-11 (2026-11-14): merge V1–V9 as one scope, including the CWL and
  delivery schema. The open gaps are service or later schema work; list them
  in the PR as not ready. Do not describe the complete feature set as ready
  while gaps remain.
- Confirm CI against the latest head; the baseline result above is historical.
- Squash the feature, rebase onto current `main`, then use GitHub's **Rebase
  and merge**, following AGENTS.md. Obtain approval before a force-push in
  that session. Preserve the pushed `guild-sql-reference` tag.

## No action until needed

- Keep single-value checks such as the plan objective and event version until
  another value is agreed.
- Add indexes from measured read paths, not merely to cover every foreign key.
  Parent dimension rows are retained.
- Derive missed war attacks from final participation and attack allowance;
  do not create invented attack rows.
- Measure the history-scanning profile/chat views before replacing them with
  per-account lookups or latest projections (SR-MEM-08, SR-XP-05).
- Clan activity history covers used/missed attacks, CG points, donations and
  joins/leaves; raid loot was not selected for that audit scope.
- SQL formatting tooling is optional maintenance, not a feature blocker.

## History

The original 7 November 2026 requirements draft is available with
`git show fb6ff1a:docs/design/star-schema-working-plan.md`. References in
feature specifications to superseding/extending "the working plan" mean that
draft, not this implementation register. The draft's unofficial API copy has
an incorrect individual-CWL-war example; use the current API evidence record.
