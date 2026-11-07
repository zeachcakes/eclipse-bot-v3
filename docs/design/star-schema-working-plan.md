# Star-schema working plan

Working draft from the requirements discussion through 7 November 2026. This
records agreed behavior separately from proposed tables and open decisions.
This is the requirements and design record. The first SQL implementation is in
[services/guild/schema](../../services/guild/schema/README.md); proposed
grains and unresolved policies below remain distinguishable from final behavior.

See the [ER diagrams](guild-er-diagram.md) for the implemented tables and
physical foreign-key relationships.

The selected design is a star schema with activity-specific facts and shared
dimensions. CoC activity and Discord utility activity are both in scope.
Temporal bridges, current configuration, and constrained workflow state support
those stars; configuration changes and actions also produce historical facts.
The precise physical schema, indexes, partitioning, and migration tooling remain
to be designed.

## Environment and configuration

- Each running environment serves one Discord server. Initially one CoC clan is
  tracked, but multiple clans must be supported.
- Dev uses a separate Discord test server with the same template as production.
  Their actual server, channel, and role IDs differ.
- Separate dev/prod databases using the same schema and migrations are the
  proposed deployment arrangement; deployment architecture is still open.
- All bot-managed application settings belong in PostgreSQL and are managed
  through admin commands. This supersedes earlier plans to keep clan tags,
  channel IDs, role IDs, or polling settings in .env.
- The configured Admin Discord role and explicitly allowlisted developer Discord
  user IDs can manage configuration. Discord's built-in Administrator permission
  is not the selected application authorization rule.
- Database connection credentials must be supplied externally to bootstrap the
  application. Credential delivery is not part of the dimensional model.
- Configuration changes are audited. Configuration audit records are visible
  only to allowlisted developers, even though Admin-role members can configure
  the bot.
- How the developer allowlist itself is managed remains open. General
  configuration permission must not silently imply developer-audit access.

## Identity, account links, and attribution

| Subject | Agreed behavior |
| --- | --- |
| Discord identity | Retained after the person leaves the server |
| Linked accounts | A member can link multiple CoC accounts |
| Current account link | Each CoC account can be linked to only one Discord identity at a time |
| Primary account | One primary when accounts are linked; the others are alts |
| Unlinking primary | The member chooses a replacement if other links remain |
| Initial eligibility | An account must be in a tracked clan when it is linked |
| Later clan departure | The account's Discord link remains |
| Discord departure | Existing account links remain |
| Verification | Use the player's in-game API token; persist verification status without the token |
| Transfer | Verification plus Co-leader/Admin approval is required when linked to another Discord identity |
| Self-unlink | No staff approval is required |
| Current links and primary | Visible to everyone |
| Link history | Visible only to configured Co-leader and Admin roles |
| Historical member metrics | Remain attributed to the earlier member after a transfer |
| First-ever link | Previously collected account statistics count for the first Discord member |
| Link to a different member | A fresh member-attribution start |
| Same-member relink | Metrics continue if nobody else linked the account in between |
| Collection without a link | Continue collecting activity while the account is in a tracked clan |

Source game facts belong to the player account independently of Discord links.
Changing a link must not overwrite source history or move an earlier member's
historical results to a new member.

Actual link intervals and metric-attribution continuity are different concepts.
First-link backfill and same-member continuity cannot be implemented by joining
every fact only to the Discord link active at the fact's timestamp.
An attribution episode or equivalent explicit policy boundary is proposed
alongside the actual link history.

The user confirmed continued collection during unlinked gaps. Exact treatment
of gap activity in member-facing aggregates, transfer-time Clan Games
requirements, and retroactive changes to already published assessments still
need precise examples before the attribution implementation is final.

Verification tokens must not enter stored request/response bodies, raw payload
archives, audit details, job arguments, or error logs. This also applies to the
token echoed in a verification response.

## Clan membership and role automation

- Membership polling is configurable in the database; the initial interval is
  two minutes. For one clan this is approximately 720 membership requests per
  day, excluding profile, war, raid, and other API requests.
- This interval does not yet define player-profile or achievement polling.
- Keep observed clan joins, departures, and moves. Membership history is public.
- Grant each clan's member role when any linked account belongs to that clan.
  A member can hold multiple clan roles.
- Desired roles are the union of requirements across linked accounts. Removing
  one account must not remove a role still required by another account.
- API failure or incomplete pagination is not evidence that every member left.
  Store observation time, last successful coverage, and gaps.
- Exact join/leave times are not supplied by polling. Proration needs an explicit
  observation-based boundary policy. A second-successful-poll departure check
  was suggested, but is not a confirmed requirement.

Discord onboarding rules:

1. On joining the server, send a welcome message in the configured welcome
    channel and grant the configured Applicants role.
2. On the first successful eligible account link, automatically remove
    Applicants and grant Eclipse, New Joinee, applicable clan roles, and TH roles.
3. New Joinee expires seven days after joining Discord.
4. Grant a role for each distinct TH level across all currently linked accounts,
    including alts. Remove a TH role only when no linked account requires it.

Late first links, which join occurrence governs New Joinee after a rejoin, and
Eclipse/Applicants behavior after all links disappear remain open.

Role configuration uses stable Discord role IDs with cached display names.
Renaming a role must not break a binding; deleted roles remain identifiable in
history. Proposed mapping tables are server_role_binding, clan_role_binding,
and town_hall_role_binding, referencing a shared role dimension.

## CoC activities

### Regular wars

- Rosters are selected in game; there are no bot sign-ups for regular wars.
- Each clan has its own war channel/category and dedicated war role for pings.
- Any linked account on the roster qualifies its Discord member for that role.
- Keep the previous war role until the next roster is available, then reconcile.
- Automatically remind members with unused attacks at eight and four hours
  before war end. Each clan's reminder schedule is independently configurable.
- Retain all available war/roster/attack data for metrics, including opponents,
  TH matchups, stars, destruction, and other available fields.
- Whether automatic reminder messages use individual mentions, role mentions,
  or a combination has not been specified precisely.

### Clan Games

- Base requirement: 10% of the event's per-account points cap, such as 400
  points when the cap is 4,000.
- Calculate a prorated requirement for each account based on time in any
  tracked clan during the event. An account present for half the event owes
  half the base requirement.
- Account time across tracked clans must be unioned, so a move between tracked
  clans does not count time twice.
- Sum eligible account points and prorated requirements into one result per
  Discord member across all tracked clans. Three full-event accounts owe 1,200
  points in a 4,000-cap event.
- Accounts outside the tracked clans do not add an outside-clan requirement.
  Accounts joining midway have a prorated requirement.
- Assess at 24 hours before the end and again after the event ends.
- At the 24-hour checkpoint, count only time already spent in tracked clans;
  do not project the remaining day.
- No staff exemptions from the requirement.
- Record insufficient_data when evidence is inadequate; absence is not zero
  contribution or an automatic failure.
- Any member can request a manual API refresh, but only for accounts currently
  linked to that member. No staff override for other people's accounts has
  been requested.
- A refresh records new evidence and can recalculate supported results. It
  cannot be assumed to recover a missed historical baseline.
- Automatically create events from configurable schedule/cap settings, with
  manual fallback. No API event-calendar endpoint is documented in the supplied
  reference, so API-driven schedule discovery is not a verified capability.
- Members can view points and clan totals through commands and automatic posts
  in one shared, database-configured activity channel.
- Explicit member pass/fail assessments are leadership-only. Final results are
  logged for leadership in the configured clan-logs channel.

The observed-time target for one account at an assessment checkpoint is:

    0.10 * event_account_cap
        * observed_time_in_tracked_clans_so_far
        / full_event_duration

The time interval is bounded by the event and the checkpoint. Member targets
sum the eligible account targets. Attribution intersections, rounding, observation
tolerance, and handling incomplete membership intervals remain to be specified.

The points data source needs live validation. The reference exposes generic
player achievements but does not document per-event Clan Games points. Cumulative
achievement differences are a candidate measurement method, with coverage and
attribution limits; they must not be represented as verified event totals without
adequate evidence.

### Raid Weekends

- Announce the start with separate clan-member role pings for each clan.
- Publish capital gold looted per Clash account, without combining alts into a
  Discord-member total.
- Refresh the report every eight hours.
- Initially use the same shared activity channel as Clan Games, while keeping
  its channel binding configurable.
- Current scope stores account capital-gold totals. Detailed attack and district
  retention is anticipated but its schema is deferred.
- Use capitalResourcesLooted from raid-member data for this report, not the
  player profile's clanCapitalContributions donation counter.

### Deferred activities

CWL is deliberately open: sign-ups with preferred days; CSV and Google Sheets
exports; daily roster displays; week-long roster planning using stars, TH-vs-TH
performance and a member rating; and the stated medal-bonus objective. Scoring,
optimization constraints, permissions, and API integration require a separate
planning pass.

Custom events, including possible 50v50 events, are also open.

## Discord utility activities

### Chat XP and ranks

- All text channels count.
- Provisional rule: 20 XP per message, at most five credited messages per member
  per minute across channels, for a maximum of 100 XP per minute.
- Detailed earning/rank logic is deferred. Fixed-minute versus rolling-window
  enforcement, message eligibility, rank thresholds, and rank-role behavior have
  not been decided.
- Monthly and all-time chat leaderboards are required.
- Leaving and rejoining Discord preserves chat XP and rank.
- Departed-member leaderboard visibility and the reporting-month timezone are
  still open. GMT has been explicitly chosen for warning resets, not yet every
  reporting calendar.

### Warnings and moderation

- Configured Leadership, Co-leader, and Admin roles can issue and revoke warnings.
- A developer allowlist entry alone does not currently grant those moderation
  permissions.
- Members can view their own warning history.
- Issuance and revocation both require a reason.
- The fifth valid warning in a calendar month triggers a kick.
- Count warnings using GMT calendar months; active counts reset at 00:00 GMT on
  the first. Preserve the underlying history.
- Revocation removes the referenced warning from the relevant count and retains
  its issuance, revocation, reasons, and audit history.
- Publish moderation decisions in a database-configured moderation-log channel.
  The server places it under its leadership category; Discord's category/channel
  permissions govern channel visibility. Do not duplicate its channel ACL in
  the application database.
- Kick decision, execution attempt, and result must be distinguishable.
  A requested kick is not proof that Discord performed it.

Count individual issued warnings that have not been revoked, in their original
issuance month. Avoid double subtraction, cross-month revocation errors, and
duplicate kick decisions from concurrent warning commands.

Threshold behavior after a kick/rejoin or a later revocation is not yet specified.

## Leaderboards

| Topic | Agreed behavior |
| --- | --- |
| CoC ranking identity | Clash account, not aggregated Discord member |
| Clan scope | Separate leaderboard for each clan; no combined-clan leaderboard requested |
| CoC periods | Current event/season, monthly, and all-time |
| CoC eligibility | Only accounts currently in that clan appear |
| Departed accounts | Retain their historical data |
| All-time war stars | Account's lifetime war stars, including stars earned outside that clan |
| Chat periods | Monthly and all-time |
| Chat persistence | XP/rank survives leaving and rejoining |

Current-clan eligibility and metric attribution are separate query steps.
For lifetime war stars, select the eligible account's relevant profile counter;
do not restrict that counter to tracked-clan war participation.

Monthly/event score definitions still need to be specified per metric. A
current lifetime snapshot is not enough to reconstruct an arbitrary past month.
Counter resets and missing period baselines must be handled explicitly.

## Proposed dimensional model

Shared dimensions identify Discord users, player accounts, clans, the Discord
server, roles, channels, achievements, and calendar dates. War, Clan Games event,
and Raid Weekend identities provide activity-specific context.

Keep exact timestamps as well as any date keys. Record source event time when
available, observation time, and ingestion time where they differ. A date
dimension does not replace time needed for two-minute polling or minute-based XP.

Stable identity must survive display-name changes and departures. Historical TH
values for war analysis belong to the war roster evidence, not a join to the
player's current TH. Exact historical name/version requirements will determine
where slowly changing dimensions are appropriate.

| Proposed fact | Grain |
| --- | --- |
| fact_war_roster_observation | One player on one clan side of one war at an observation/version |
| fact_war_attack | One attack in one war, deduplicated across repeated fetches |
| fact_player_counter_observation | One player account at one profile observation |
| fact_player_achievement_observation | One player, achievement, and observation |
| fact_clan_membership_change | One observed player/clan membership change |
| fact_raid_member_observation | One player, clan raid weekend, and observation |
| fact_clan_games_progress | One player, Clan Games event, and progress observation |
| fact_clan_games_account_assessment | One account, event, checkpoint, and calculation version |
| fact_clan_games_member_assessment | One Discord user, event, checkpoint, and calculation version |
| fact_discord_membership_event | One Discord join or departure occurrence |
| fact_role_change | One confirmed role addition/removal for one Discord member |
| fact_chat_xp_award | One credited Discord message |
| fact_warning_event | One warning issuance/revocation referencing a persistent warning identity |
| fact_moderation_action_attempt | One attempt to execute a logical moderation action |
| fact_configuration_change | One configuration revision/change with before/after evidence |
| fact_api_fetch_attempt | One sanitized API collection attempt, automatic or manually requested |
| fact_notification_delivery_attempt | One attempt to publish/send a logical notification |

These names and physical table boundaries are proposals. A common audit envelope
can correlate domain facts without independently duplicating the same action in
several unconnected logs.

Repeated snapshots of lifetime war stars, cumulative achievements, or running
raid totals are nonadditive across time. Queries must select a snapshot, compute
a supported delta, or sum independent event facts as appropriate.

Regular wars do not have a verified universal source war ID in this reference.
Use a local key and validate a source identity/deduplication strategy; do not
assume every war has a CWL warTag. Likewise, attack duration is not its occurrence
timestamp. Preserve observation provenance where source event time is missing.

## Supporting relationships and control state

Proposed supporting structures include:

- Actual account-link intervals, verification/approval records, primary-account
  selection, and separate attribution-continuity episodes or derived boundaries.
- Observed player/clan membership intervals with coverage metadata.
- Current server settings, tracked-clan settings, role/channel bindings, TH-role
  mappings, developer allowlist, and versioned earning/assessment policies.
- Per-clan war-reminder offsets, recurring Clan Games schedule/cap settings,
  logical notification identities, and delivery state.
- Usable current projections and durable pending work for commands and workers.

Enforce one active Discord link per player and one primary per member with active
links. A valid primary transition and its audit evidence must commit together.
Current permissions must come from current Discord roles and the current
developer allowlist; a historical role-dimension row must not grant authority.

Role changes and notification decisions need stable operation identities.
Transactional pending work/outbox state is a proposed reliability mechanism.
Kafka and deployment boundaries remain open. No message broker is required by
the Gradle module layout alone, and no broker has been added.

Discord delivery is not generally end-to-end exactly once. Track attempts and
outcomes; retain message IDs for recurring report edits where appropriate, and
reconcile roles against desired state. Do not label an uncertain external result
as confirmed success.

## Visibility boundaries

| Data/action | Access rule |
| --- | --- |
| Current account links and primary | Public |
| Account-link history | Co-leader/Admin roles |
| Observed clan membership history | Public |
| Clan Games points/totals | Members, through commands and shared activity channel |
| Explicit Clan Games pass/fail | Configured Leadership audience |
| Configuration commands | Configured Admin role or developer user allowlist |
| Configuration audit history | Developer user allowlist only |
| Warning issue/revoke | Leadership/Co-leader/Admin roles |
| Own warning history | Warning subject |
| Moderation-log channel visibility | Discord channel/category permissions |
| Manual player API refresh | Requester's own linked accounts only |

An audit viewer or general log channel must not bypass the more restrictive
configuration-history or account-link-history rules.

## Evidence and next design decisions

The initial inspection found only the Gradle scaffold and PostgreSQL decision.
Main subsequently added Flyway/jOOQ schema conventions, the example catalog,
and a database-free Discord interaction service (ADRs 0007–0010). The guild
SQL implementation follows that current service-owned preparation workflow.

The supplied documentation reference was inspected at commit
2b9a93ca87f8e0b267ae837cd4d8a8b0d7a5d5dd:

- https://github.com/MasiaAntoine/clash-of-clan-api-doc-official/tree/2b9a93ca87f8e0b267ae837cd4d8a8b0d7a5d5dd
- The checked commit is dated 8 June 2026. Treat it as an interim copy maintained
  outside Supercell, with API contracts to verify.
- Its individual CWL-war endpoint shows a league-group response, a concrete
  documentation inconsistency.
- The mirror documents generic achievements, but no dedicated Clan Games event
  score/calendar endpoint. This is not proof of absence from the current API.
- Official developer/API hosts were inaccessible from this environment through
  the network proxy. Live contract validation remains pending.

Before final DDL, resolve attribution examples, developer-allowlist management,
leaderboard eligibility/calendars, missing-data tolerances, and selected role
lifecycle edges. Keep the explicitly deferred CWL, custom-event, detailed raid,
XP/rank, and deployment discussions open. Do not block the rest of the core
schema on deciding every deferred feature.
