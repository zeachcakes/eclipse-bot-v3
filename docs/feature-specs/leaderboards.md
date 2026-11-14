# Leaderboards

Status: agreed target requirements; not fully implemented. This specification
extends the [working plan](../design/star-schema-working-plan.md) with agreed
membership visibility and monthly-calendar rules. Metric-specific score
definitions and evidence requirements still need design; these are logical
requirements rather than a final physical schema.

## Scope and actors

Provide separate CoC leaderboards for each tracked clan and monthly/all-time
chat leaderboards for the Discord server. CoC ranks use individual Clash
accounts, including alts separately, rather than combined Discord-member scores.
Chat ranks use Discord members.

The bot collects source observations and renders boards. Authorized
configuration operators manage the leaderboard calendar. Members appear only
when they meet the agreed current-membership rules. Command audiences and
presentation details remain to be specified.

## Requirements

| ID | Requirement |
| --- | --- |
| LB-001 | CoC leaderboards are separate per clan and rank individual player accounts. Do not combine a member's primary and alt accounts into one entry or introduce a combined-clan board. |
| LB-002 | Only accounts currently in the relevant clan appear on that clan's boards. Retain departed accounts' raw history; a later return restores current eligibility without recreating or deleting source history. Discord linking does not replace clan-membership eligibility. |
| LB-003 | Current-clan eligibility and metric provenance are separate. The all-time war-stars board uses each eligible account's lifetime profile war-star counter, including stars earned outside that clan. |
| LB-004 | Support the agreed CoC period categories: current event/season, monthly, and all-time. Each metric needs a supported score definition and evidence for a particular period before that board can be treated as reliable. Donations have a per-clan, per-account board for each CoC season, from the last season counter seen in that clan; there is no monthly or all-time donations board (owner decision, 2026-11-14). |
| LB-005 | Chat has monthly and all-time boards. Their current views include only current Discord members; departure hides the member until they rejoin. Preserve their XP, rank, and earning history throughout. |
| LB-006 | All-time chat score is cumulative credited XP. Monthly chat score comes from credited XP assigned to that reporting period, using the stable awards defined in the XP specification. Monthly boundaries do not reset the member's cumulative rank. |
| LB-007 | Monthly leaderboards default to GMT and have a configurable reporting timezone. Keep the active period's calendar policy fixed. A timezone change takes effect for the next period only; do not recalculate historical periods under the new timezone. |
| LB-008 | The leaderboard timezone is not a universal bot timezone. Warning resets and the explicitly GMT CWL deadlines remain GMT regardless of leaderboard configuration. |
| LB-009 | Do not sum repeated observations of cumulative counters as separate earned contributions. Monthly/event scores need metric-specific baselines, deltas, or source events. A current lifetime snapshot alone cannot reconstruct an arbitrary earlier month's result. |
| LB-010 | Preserve evidence quality and distinguish an unavailable or unsupported score from a measured zero. Missing baselines, counter resets, and coverage gaps require explicit metric-specific handling before publishing a definitive score. |
| LB-011 | Leaderboard output must respect source-data visibility. Publicly usable Clan Games points do not authorize publishing private pass/fail assessments; ordinary boards must not expose private warning, account-link, or configuration-audit history. |

## Logical data, audit, and visibility needs

The feature needs identities and evidence for:

- The server, clan when applicable, ranked account/member, metric, and selected
  period. The rank subject must remain stable through name changes and linking.
- The reporting period's timezone, boundaries, and calendar-policy version. Keep
  past boundaries and policy available after later configuration changes.
- Source observations, their timestamps, and any supported opening/closing
  baseline or contributing event set used to calculate a score.
- The score calculation's metric policy, provenance, and known data-quality
  limitations. Repeated snapshots must remain distinguishable from increments.
- Current clan/Discord membership evidence used for eligibility independently
  from historical scoring evidence.
- Published views and their as-of context where needed to explain what a member
  saw, without treating a rendered rank as the only source of truth.

Retaining raw history does not require keeping departed accounts or members on a
current board. Conversely, removing a displayed entry must not delete its
underlying metrics. Member-attribution rules must not silently merge accounts
in an account-ranked CoC board.

Calendar changes are configuration changes and follow the audit and access rules
in [configuration and access](configuration-and-access.md). A score view must
not become a route around the private-data boundaries of its source features.
The permissions for invoking and publishing ordinary leaderboard views remain
an open command-design detail.

## Acceptance scenarios

| Scenario | Expected result |
| --- | --- |
| One Discord member has two accounts in a clan | Each account can have its own CoC entry; primary/alt status does not combine their scores. |
| An account moves from clan A to clan B | It no longer appears on A's current boards and becomes eligible for B's boards. Its earlier raw history remains. Score provenance follows the chosen metric. |
| An account is still in the clan but is not linked to Discord | Clan-membership eligibility remains an account-level decision; a Discord link is not substituted for it. |
| A current clan member has 1,500 lifetime war stars, including 1,200 earned elsewhere | Its all-time war-stars score is the relevant lifetime counter of 1,500. |
| Consecutive profile snapshots show 100 and 110 lifetime war stars | They are observations of the same counter, not contributions totaling 210. A supported period delta requires its own baseline policy. |
| Only today's lifetime counter is available for an earlier month's requested board | Do not label the lifetime counter as that month's earned stars or invent a zero. Report the evidence limitation under the metric's eventual presentation policy. |
| A Discord member leaves with stored XP and later rejoins | Hide them from current monthly/all-time chat views while absent. Restore eligibility after rejoin with their XP and rank preserved. |
| A monthly leaderboard timezone is changed during an active period | Keep the active period's boundaries and calendar policy. Apply the new policy to the next period; leave historical periods unchanged. |
| The configured leaderboard timezone differs from GMT | Leaderboard periods use their configured policy; warning reset and CWL deadline behavior remain explicitly GMT. |
| A Clan Games board displays account points | Do not add private member pass/fail assessments to that output. |

## Dependencies

- [Configuration and access](configuration-and-access.md): reporting timezone,
  effective-period policy, audit visibility, and command authorization.
- [Membership and role automation](membership-and-role-automation.md): current
  clan and Discord membership used to filter entries.
- [Chat XP and ranks](chat-xp-and-ranks.md): stable awards, cumulative totals, and
  earning pauses without deleting existing scores.
- [API evidence](api-evidence.md): profile counters, source timestamps, coverage,
  and missing-data limits.
- [Regular wars](regular-wars.md), [Clan Games](clan-games.md), and
  [Raid Weekends](raid-weekends.md): metric-specific source facts and privacy
  rules. [CWL](clan-war-leagues.md) supplies agreed planning objectives and inputs;
  its exact rating formula and leaderboard presentation remain open.
- [Notifications and delivery](notifications-and-delivery.md): publication and
  refresh outcomes where boards are posted to Discord channels.

## Suggested future issue workstreams

- Define the metric catalogue, score provenance, and supported period combinations.
- Implement current-clan account eligibility and current-member chat visibility.
- Implement lifetime war-star selection without summing cumulative snapshots.
- Define monthly baseline, counter-reset, gap, and quality rules per metric.
- Implement versioned monthly calendars with changes effective next period.
- Add monthly/all-time chat views from stable XP awards.
- Design board commands, publication, and privacy-preserving output.

These are future planning units, not created GitHub issues or completed features.

## Open and deferred decisions

- Exact score definitions for each monthly/event metric, including attribution to
  a clan where the underlying metric requires it.
- Opening/closing baseline selection, acceptable coverage/freshness, counter
  reset handling, and how incomplete scores are displayed.
- The precise timezone cutover when old and new monthly calendars would produce
  different adjacent boundaries. The implementation must preserve the agreed
  active/historical-period rule rather than silently recalculating those periods.
- Tie-breaking, page size, refresh cadence, command audiences, and publication
  destinations.
- Chat-board visibility after loss of XP-eligibility roles. Earning pauses and
  XP/rank retention are agreed; display eligibility in this case remains open.
- Whether and how users browse retained historical boards, including their
  membership-as-of presentation. Current board eligibility is already agreed.
- The exact CWL rating formula and leaderboard presentation; its planning scope,
  objectives, and inputs are already agreed.
- Custom-event leaderboard score definitions and presentation.
