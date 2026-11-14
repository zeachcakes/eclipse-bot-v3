# Guild star-schema design

Revised 13 November 2026 from the
[feature requirements](../feature-specs/README.md) and supplied CoC response
samples. The migrations define the persistence model and the invariants that
declarative constraints can state. The guild service implements the business
rules, workflows and permission checks in Java
([ADR 0012](../decisions/0012-guild-star-schema.md)), together with the CoC
collectors, the optimizer, the Google Sheets client and the Kafka and Discord
delivery.

The [catalog-derived ER diagrams](guild-er-diagram.md) describe physical tables
and every declared foreign key. The
[schema guide](../../services/guild/schema/README.md) describes preparation,
runtime access, database checks, and the rules the guild service enforces. The
[rule catalog](guild-service-rules.md) lists each of those rules in detail. The
[working plan](star-schema-working-plan.md) lists the schema gaps, the open
decisions and the order of the service work.

## Model boundaries

Each environment owns one Discord server and can track several CoC clans. Dev
and prod have separate databases, using the same schema and migrations. The
guild service owns its schema, migration role, and least-privilege runtime role.
Discord IDs retain their unsigned 64-bit range; names never replace identity.

The analytical design uses conformed dimensions and activity-specific facts.
Temporal bridges, versioned configuration, current projections, workflow state,
and delivery queues support those stars. Operational state is not an analytical
measure, and a delivered message is not an account's source activity.

PostgreSQL enforces keys, uniqueness, row checks, exclusion constraints, and
append-only privileges on facts. Rules that span rows, workflows, and
permission checks belong to the guild service, so the schema holds no functions
or triggers.

## One Discord server per database

`dim_guild` holds exactly one row, so the server is implied everywhere else.
Only `dim_guild` and `guild_settings` carry `guild_key`. Other tables and views
do not repeat it, and no composite key has to prove that two rows belong to the
same server. A second community gets its own database. The project owner chose
this over a multi-server schema, because the multi-server columns would never
be exercised and would only add keys.

## Physical consolidation

The initial design's 115 persisted tables are consolidated to 97. The season
calendar, the manual moderation history, the primary-account history, the
revisions of custom-event signups and CWL pins (in place of the in-place pin
table), the CWL freeze records, the typed context of raid and Clan Games
reports, the mention targets of notifications, the war polls and the revisions of CWL
participating clans make 109. The review gaps added 11 more: kick decision
transitions and attempt resolutions, notification dispositions, typed
moderation, raid-start, CWL-signup and Clan Games progress context, raid polls
and weekend observations, and CWL Sheets destinations with their signup inputs,
which make 120. Shared
configuration, one-to-one workflow state, and duplicated analytical records
share storage where they have the same identity. Views retain useful query
interfaces without a second write or another copy of the same fact.

| Consolidation | Persisted tables removed |
| --- | ---: |
| Server, clan, and TH role bindings share constrained `role_binding` | 2 |
| Clan Games schedule/cadence and next-calendar selection share `guild_settings` | 3 |
| CWL settings share `clan_collection_settings` | 1 |
| Configuration change history is the only change ledger; activity rows are not copied | 1 |
| Credited XP and warning history derive from their source records | 2 |
| Frozen expected Clan Games episodes and attached evidence share input rows | 1 |
| Seven CWL plan days derive from each plan; the single custom-war association lives on its event | 2 |
| Outbox state, first-consumption evidence, and dispatch state/results share their owning records | 5 |
| Unused optional date dimension is removed; timestamp and reporting-period semantics remain explicit | 1 |

Role scopes retain typed foreign keys, purpose checks, and uniqueness. Each
configuration command in the guild service writes only the columns it owns, so
one feature's change preserves the other features' settings. No command
deletes the shared guild settings row, and calendar pointers change only
through the calendar workflow. Raw source observations, attribution episodes,
assessment versions, signup revisions, actual rosters, and moderation attempts
retain their distinct grains.

## Shared identities and fact grains

| Domain | Persisted grain and interpretation |
| --- | --- |
| Discord identity | Stable guild, user, role, and channel identities independent of presence and names |
| CoC identity | Stable player and clan identities shared by source observations and activities |
| Account links | Actual ownership intervals, verified proofs, primary changes, transfer requests, and separate metric-attribution episodes |
| Membership | Complete roster polls, member state stored on change (role and donation counters), observed changes, supported presence intervals, and the season calendar that bounds donation totals |
| Wars | One shared war dimension, one row per war poll as coverage proof, side/player participation, roster and clan observations and complete responses stored on change, and deduplicated attacks |
| Profile counters | One player/profile observation or one player/achievement observation, with source and ingestion provenance |
| Clan Games | Configured event, checkpoint request, source counter read, inferred affiliation, progress, owner-specific assessment slice, and versioned member assessment |
| Raid Weekends | One clan/weekend, every raid poll as coverage, and weekend state and account loot stored on change |
| Discord presence | Individual join/departure occurrences and confirmed role changes, with usable current projections |
| Chat XP | One durable message decision containing any random award; cumulative rank state and rank-change facts |
| Moderation | Warning, revocation, kick decision and its transitions, pre-send attempt authorization with its result and later resolution, manual action from the audit log, accepted join, and leadership-notice intent |
| CWL | Planning cycle, participating clan with its revisions, signup revisions that carry the target clan, observed registered pools, ordered war references, plan/input revisions, assignments, pin revisions, freezes, and bench evidence |
| Custom events | One combined event signup pool with signup revisions, versions of one roster, and an optional write-once association to retained war evidence |
| Leaderboards | Versioned calendar policy, immutable reporting periods, supported metric definitions, and source-specific projections |
| Delivery | Typed logical operations with explicit mention targets, transactional outbox, publication/consumption evidence, dispatch authorizations, outcomes, report identities with typed context, and desired-role generations |

Exact source time is retained when supplied. Observation and ingestion time are
separate. Attack order and duration do not become invented attack timestamps.
Cumulative counters and repeated totals must not be summed across snapshots.

## Ownership and Clan Games

Source activity belongs to a Clash account. Actual Discord links and metric
attribution use different temporal structures: first-ever links can backfill
supported history, and a same-owner relink can continue across an unlinked gap.
An intervening owner creates a new attribution episode instead of reopening an
earlier owner's period.

Clan Games uses the `Games Champion` cumulative achievement, identified by its
name and village rather than array position. The achievement milestone is not
the event cap. A configured event supplies dates and cap; source observations
supply supported deltas. There is no manual-score path.

The regular active-event interval defaults to 900 seconds. Baseline, T−24-hour,
final, and transfer reads are separate request rows. The regular read is one
pending request for each player, held to one by a partial unique index: the
scheduler keeps it due one interval after that player's latest read, and moves
it when the interval setting changes. It does not create a row for every
interval of the event. A request's `due_at` is the checkpoint it supplies, and
`collect_from` opens the window in which the collector takes it. The baseline
window opens at the end of the previous event, because the counter does not
move between events, and the T−24h window a configurable tolerance (default 30
minutes, DEC-03) before its checkpoint, so both reads can finish in time. Final,
transfer and regular reads open at their `due_at`. Failed reads remain retryable; current reads cannot
reconstruct arbitrary missing historical counters.

Participating-clan inference requires consistent supported membership from
event start through the first observed increase, including compatibility with
the profile's observed clan. Positive points require supported affiliation.
A measured zero delta from valid boundary reads proves zero contribution even
without positive-increase affiliation evidence; missing reads never imply zero.

A transfer request is bound to its source link; when that link ends, the
remaining open requests are cancelled and keep any earlier decision as history.
An open request also expires on a clock: two days without a staff decision, or
one day after an approval that the recipient did not use. Both limits are
guild settings. During an active event an approved transfer waits for a
successful boundary read. The approval limit does not run while that read is
pending, and it restarts when the read arrives, so a slow read does not
expire a valid transfer. Source observations remain intact while each owner receives an explicit
point/target slice. A successful read is observation evidence, not a game-clock
ledger. Unknown freshness or historical boundaries preserve `insufficient_data`.

Targets prorate 10% of the configured cap by supported presence, unioned across
tracked clans and clipped to the checkpoint and attribution episode. Earned
points are not time-prorated. Member assessments freeze their expected episode
set so omitted alts cannot waive a target and later first-link backfill cannot
silently rewrite a published version. Sum unrounded targets, then round the
member's combined requirement up to a multiple of ten.

Each frozen episode has one input row. A nullable account-assessment reference
means expected evidence is missing; it never implies zero points. The
assessment worker attaches evidence once and accepts an exact retry. Changing
the cohort or replacing attached evidence requires a new member-assessment
version.

## Discord XP, ranks, and moderation

XP uses an unpredictable uniform integer from 15 through 25 and at most five
credited messages per rolling 60 seconds across channels. The implementation
uses processing time after a per-member lock for this limit; original message
time remains available for monthly scoring. Both credited and rejected message
decisions are durable, so retries cannot reroll or later credit a rejection.
The award view selects credited decisions. Rank evidence references those
credited records directly, with no second award insertion.

Configured eligibility roles use OR semantics and require current Discord
presence. Losing eligibility or leaving preserves earned XP and rank. The ten
approved rank thresholds are seeded, with configured role bindings and a desired
highest-rank projection. Departed users disappear from current-member boards.

Warnings retain their original GMT month and reason. The initial fifth-warning
kick decision is distinct from execution and confirmation. Confirmed kick and
same-month rejoin evidence produces leadership notices; subsequent warnings
produce notices without another automatic kick. Stable command UUIDs deduplicate
warning and revocation transport retries. Each decision, cancellation and
rearming is an append-only transition with its warning, origin and time. A
worker claims a kick for a bounded time: the claim inserts an immutable
authorization that names the targeted Discord join, and the worker marks it
started in a committed transaction before it calls Discord. A late result is
kept for its own authorization, but only the token of the latest claim may
change the current decision, so a worker whose claim was taken over cannot
spend an attempt or release the newer claim. A failed or uncertain kick is
tried again, three attempts in all and five minutes apart by default; both
limits are guild settings. A kick counts as confirmed only from a 2xx Discord
response or from the bot's own audit log entry. A member's absence never
confirms it, because the member may have left or been removed by hand. A
revoked warning cancels a kick that still owes an attempt when fewer than five
active warnings remain in the month, and a new fifth active warning arms it
again.
Kicks, bans, unbans and timeouts that a person makes in Discord are kept from
the audit log, without the entries that the bot itself executed. A manual kick
or an unban followed by a same-month rejoin produces its own leadership
notice and leaves the warning rules unchanged. One reader returns the bot's
confirmed kicks and the manual actions, under the rule of warning history.
Warning history is a view over retained issuance and revocation records.

Desired clan and TH roles union all linked accounts. Desired-role contributions
are kept separately by source, then unioned into an immutable generation with
explicit managed-role scope. Withdrawing one source cannot remove another's
requirement or authorize removing unrelated manual roles. Confirmed role facts
can reference the operation and generation that explain their managed change.
An unchanged role set reuses its generation only while the operation of that
generation can still apply it. Work that was superseded because the member
was absent, or delivered before the member's latest join, is replaced by a new
generation when the same role set is submitted again.

## CWL and custom-event planning

The bot's calendar cycle is separate from the API's opaque source season string
(observed as `2026-11-02`). The group sample supplies no universal group ID;
round ordinals and returned war tags retain their source context. Individual
war bodies do not repeat that context.

Signups, registered league pools, bot plans, and actual daily participation are
distinct. A signup may target another clan; actual eligibility uses that clan's
registered pool. The target clan is part of each signup revision, so staff can
move a signup to another participating clan of the cycle. A participating
clan's selection, lineup size and withdrawal are revisions too, so leadership
can correct a selection while signups are open. Group rosters can contain 45 accounts while a daily lineup has
30. Source map positions can exceed lineup size and are not planner slots.

Closing signups creates a provisional seven-day artifact. Initial selection
inputs are TH and strict War Day 1–7 availability. Plan revisions preserve the
objective of maximizing accounts reaching eight stars, current-season CWL
performance inputs, pins, and algorithm provenance. The guild service validates
constraints and completeness; the optimizer chooses assignments.

Automatic freezes use each war's actual start and the clan's configurable
cutoff, initially 60 minutes. Do not derive future starts from a fixed 24-hour
cadence. The first freeze of a War Day is recorded with the cutoff it used;
a later cutoff change cannot unfreeze the day or change its war. Manual staff changes and explicit bench overrides are separately
recorded. Late evidence applies to an eligible unfrozen future war.

Poor/missed-attack incidents are deduplicated. A bench assignment reserves the
next available eligible day; actual service needs completed-war evidence. An
unavailable day does not consume it. Automatic eligibility returns after service,
and unserved incidents expire at season end. Multiple incidents do not silently
invent an unapproved stacking rule. Export revisions retain signup/plan versions,
their destination and a per-clan sequence; one leased, fenced writer per clan
and export kind keeps an older Sheet write from landing after a newer one, and
CSV/Sheets delivery outcomes stay independent.

Custom events use per-account signups across tracked clans, one versioned roster,
optional staff selection, and available war-result associations. They do not
introduce a tournament engine. Raid reporting remains account loot totals;
detailed district/attack retention is deferred.

## Reporting calendars

Monthly leaderboards default to GMT. A timezone change creates a policy revision
for the next period; active and historical boundaries are immutable. Periods
have explicit instant bounds, a monotonic month label, and a predecessor.

For a timezone transition, the next labeled month starts exactly at its
predecessor's end and ends at the next corresponding local month boundary.
`is_transition` exposes its shortened/extended duration. This avoids gaps,
overlaps, or a hidden recalculation of already reported periods. Named timezone
rules handle daylight saving. Warning months and CWL signup deadlines stay GMT.

Only supported source-specific metrics are reported. Current lifetime counters
cannot reconstruct an arbitrary earlier month's contribution. The metric
catalog marks unresolved formulas rather than manufacturing scores.

## Kafka and Discord delivery

Java commits durable operation intent and its PostgreSQL outbox state together
on one operation record; the outbox view exposes the relay contract.
The relay publishes to Kafka; a Java consumer handles durable deduplication and
requests Discord work from Node through gRPC. Node has neither database access
nor a direct Kafka consumer.

An operation stores the roles and members it mentions when it is queued, so
delivery cannot widen a ping, and a Raid Weekend announcement names its clan.

Publication, consumption, dispatch authorization, actual send, and confirmed
outcome are distinct. Pings receive one automatic dispatch authorization and
one consumable send permit. A lost receipt or expired authorization remains
uncertain and cannot authorize another automatic ping. This deliberately allows
missed reminders. Every Java/gRPC/Discord-client layer must honor that contract;
PostgreSQL cannot disable an HTTP library's hidden retry.

A single dispatch-attempt record retains immutable authorization, send-permit
consumption, and its write-once terminal result. Kafka receipts preserve every coordinate and identify the
first receipt per operation/consumer group under a unique constraint. Delivery
analytics is a view over those authorized results.

Recovery coalesces only never-attempted missed checkpoints into a catch-up with
actual remaining time. Each separate outage may queue its own catch-up, with at
most one unfinished catch-up per war and clan (DEC-14). Previously attempted
pings cannot be relabeled as catch-up work. Role reconciliation uses fenced current generations.

A report (Clan Games report, raid report, CWL roster, CWL signup list) is one Discord message
that is edited in place; the project owner chose this over replacing the
message or posting a new one for each revision. The report record keeps the
one message identity and a revision counter. Each revision of the content is
one operation with its own logical key:

- Only the latest revision is sent. Queuing a revision supersedes the older
  ones that are waiting, failed or uncertain. One that is in flight finishes
  first and is superseded at its next claim, so older content never overwrites
  newer content.
- One revision of a report is in flight at a time. A newer revision waits for
  the dispatch lease of the older one.
- The claim decides the action. It is `report_create` while the report has no
  message and `report_edit` afterwards, whatever was expected when the
  revision was queued.
- Recording a delivered revision also records the message identity. An edit
  must return the known message; a different one is rejected.
- When Discord answers an edit with Unknown Message, the worker records the
  message as missing. The report forgets it, and the next claim of the same
  revision creates a new message.
- Report work does not borrow the ping rule. A failed, uncertain or expired
  attempt can be claimed again. An edit is safe to repeat. A create whose
  result was lost can post a second message; a worker that finds the first
  one can adopt it as the report's message.
- A CWL roster report is shared by all plans of one clan and War Day. Its
  plans are queued under one lock for that clan and day, and a plan that is
  older than one already queued is not queued, so revision order follows plan
  order.

Each revision keeps typed context, so no reader parses a logical key: a CWL
roster its plan and War Day, a CWL signup list the export whose frozen
signups it shows, a raid report its weekend and the latest successful poll it
shows, and a Clan Games report its event and the member assessment versions
or progress rows it publishes.

An edit does not notify members; they see the change when they open the
channel.

## Authorization, audit, and implementation boundary

Configuration belongs in PostgreSQL; bootstrap credentials remain secure runtime
inputs. Configured Admins and developers manage general settings. Only the
owner developer manages the developer allowlist; developers read configuration
change history. Private link history, leadership assessments, and moderation history
each have their own permission check in the guild service. No general reader
spans them.

The runtime role is the guild service's credential, not an end-user SQL role.
Human commands require authenticated actor IDs and current role evidence, which
the service checks. The role reads the tables the service needs, inserts facts
without updating or deleting them, and changes configuration, workflow and
projection rows only in the tables and columns granted for that. Its privileges
limit what a defect in the service can change; they do not replace the
permission checks.

Audit means activity history here: war attacks, Clan Games points, donations,
clan joins and leaves, warnings, kicks and chat XP. The fact tables are that
history, each row names its own actor where one exists, and no second copy of
a fact row is kept. An immutable ledger keeps change history for the
configuration tables only, with actor, reason, identity, and the values before
and after, for developers. The guild service writes it in the same transaction
as the change. Source facts, assessment versions, role history, and
configuration changes survive departures and later configuration changes.
Verification tokens and credentials do not belong in stored evidence or
transport payloads.

The migration series is unreleased. Validate it from an empty bootstrapped
database. After deployment, migrations remain immutable; do not repair
checksums or clean a retained schema.

The guild service implements the CoC collectors, the business rules, the
optimizer, Sheets authentication and synchronization, Kafka publishing and
consumption, and the gRPC calls to the Discord service, with their external
retry behavior. Explicitly open onboarding, rating, and reporting policies
remain listed in the feature specifications.
