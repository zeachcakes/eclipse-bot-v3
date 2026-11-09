# Raid Weekends

## Status and scope

Status: agreed target behavior for account-level reporting. Existing guild
schema support for raid totals does not establish a live collection or Discord
reporting workflow.

Announce a Raid Weekend's start and report capital gold looted per Clash account,
refreshing every eight hours. Detailed attacks, districts, and raid optimization
remain deferred. Actors are raid participants, clan-member-role audiences,
authorized configuration operators, and automatic collection/report workers.

## Requirements

| ID | Agreed requirement |
| --- | --- |
| RAID-001 | Announce Raid Weekend start with separate clan-member-role pings for each tracked clan. Preserve each clan's role identity rather than substituting one combined role. |
| RAID-002 | Publish capital gold looted per Clash account. Do not combine alts into one Discord-member total. |
| RAID-003 | Refresh the account report every eight hours. Preserve the observation time and collection outcome so an old report is not represented as freshly verified. |
| RAID-004 | Initially use the same shared activity channel as Clan Games, while retaining an independently configurable Raid Weekend channel binding. |
| RAID-005 | Use raid-member `capitalResourcesLooted` as the measure. The player-profile `clanCapitalContributions` donation counter is a different measure. |
| RAID-006 | Treat repeated observations as snapshots of a running total. Select the relevant latest account/weekend observation; do not sum successive snapshots or merge linked accounts. |
| RAID-007 | Retain source identity and history independently of later account links or clan departures. A failed or missing fetch must not become zero gold. |
| RAID-008 | Record announcement/report delivery outcomes independently of the collection outcome. An attempted Discord update is not confirmed delivery. |

## Evidence and logical data grains

These grains are conceptual and do not define final physical tables.

| Record | Grain and purpose |
| --- | --- |
| Clan raid weekend | One identified clan's raid weekend, with available start/end/state evidence. |
| Account total observation | One account in that clan/weekend at one observation, including capital resources looted and source provenance. |
| Report revision | One selected report snapshot for a clan/weekend and its constituent account observations. |
| Announcement/report delivery | One logical start announcement or report output and each external attempt/outcome. |

The supplied [API evidence](api-evidence.md) includes
`/clans/{clanTag}/capitalraidseasons` and member-level
`capitalResourcesLooted`. Its example also contains attack/defense logs,
districts, and attacks. Those available fields do not expand this feature's
current scope into detailed attack/district retention or analysis.

## Visibility and audit

Reports use the configured activity destination and clan-member role pings.
Apply [shared access](configuration-and-access.md) and
[delivery](notifications-and-delivery.md) rules; a shared channel does not expose
private account-link history or developer-only configuration audits.

Record which clan/weekend and source observations a report represents, when it
was refreshed, and whether collection and Discord delivery succeeded. Retain
configuration actors separately from automatic workers. Do not archive API
credentials or verification tokens. The bot does not perform raid attacks or
spend resources in game.

## Acceptance scenarios

1. A weekend starts for two tracked clans. The announcement workflow uses each
    clan's configured member role; one clan's role is not silently substituted
    for both audiences.
2. A member's first account has 1,000 gold and their alt has 2,000. The report
    contains two account rows, not one 3,000-gold Discord-member row.
3. An account is observed with 1,000 and then 1,500 gold in the same weekend.
    The latest report uses 1,500, not a summed total of 2,500.
4. The profile donation counter increases while raid-member loot remains
    unchanged. Raid reporting continues to use raid loot rather than donations.
5. After eight hours, collection succeeds but editing the Discord report fails.
    The fresh evidence and failed delivery remain distinguishable; the bot does
    not report a successful message update.
6. Collection fails at the next refresh. The prior known total remains
    identifiable by its observation time; failure does not replace it with zero
    or imply current coverage.
7. Raid and Clan Games initially share a channel. Changing the raid binding does
    not require changing the Clan Games binding or erase either report's history.

## Dependencies

- [Configuration and access](configuration-and-access.md): destination and role
  bindings plus configuration authorization/audit.
- [Membership and role automation](membership-and-role-automation.md): the clan
  member roles used as announcement audiences.
- [Account linking and attribution](account-linking-and-attribution.md): stable
  account identity without aggregation of alts in this report.
- [Clan Games](clan-games.md): the initially shared activity destination, with
  independently retained bindings.
- [API evidence](api-evidence.md): raid-member totals and source limitations.
- [Notifications and delivery](notifications-and-delivery.md): start announcements,
  report updates, retries, and uncertainty.

## Suggested future issue workstreams

- Weekend identity and per-account total ingestion: RAID-002–003, RAID-005–007.
- Clan-role start announcements and independently configurable destinations:
  RAID-001, RAID-004.
- Eight-hour report refresh and delivery outcome tracking: RAID-003, RAID-006,
  RAID-008.

These are suggested workstreams; no external issue is created here.

## Explicitly open or deferred

- Detailed attack, district, opponent, and defense retention/analysis is deferred.
- Raid optimization and aggregation into Discord-member totals are not requested
  behavior in this scope.
- Command layout, report formatting, and retry mechanics remain implementation
  design. Live endpoint coverage must be validated separately from the uploaded
  reference examples.
