# Clan War Leagues

## Status and scope

Status: agreed target behavior for future implementation. This specification
extends the CWL discussion in the [working plan](../design/star-schema-working-plan.md).
It does not claim that CWL collection, planning, exports, or Discord commands
are implemented by the existing guild schema.

Plan one clan's seven CWL War Days at a time, using account-specific signups,
confirmed game evidence, and staff decisions. Support multiple participating
tracked clans. This feature proposes lineups; it does not register a clan,
move accounts, select an in-game roster, or execute attacks through the API.

Actors are members submitting account signups, leadership choosing participating
clans, configured Co-leader/Admin staff managing exceptions and selections,
and automatic collection/planning/export workers. Developer allowlisting alone
does not confer the Co-leader/Admin actions described here.

## Requirements

| ID | Agreed requirement |
| --- | --- |
| CWL-001 | Notify leadership one week before CWL starts so they can select eligible tracked clans before account signups open. Keep each participating clan's signup and plan distinct. Staff cannot withdraw a participating clan while any active signup targets it; they move or withdraw those signups first, so no signup loses its target silently (DEC-12, 2026-11-14). |
| CWL-002 | Record signups per Clash account and target clan. The target may differ from the account's current clan. Availability selects War Days 1 through 7, rather than calendar dates; selected availability is a strict planning constraint. |
| CWL-003 | Close normal signups at 00:00 GMT on the first day of the month. Immediately generate a provisional seven-day plan, before in-game registration is available. |
| CWL-004 | Co-leader/Admin staff may add late signups and edit availability after the deadline. Members cannot edit their own availability after close for now; that restriction can be reviewed later. |
| CWL-005 | Support 15-player and 30-player daily lineups. Select the provisional plan using TH and availability before current-season performance exists. |
| CWL-006 | The primary planning objective is to maximize the number of individual accounts reaching eight stars. Give accounts below eight priority; do not aggregate alts into a Discord-member score. |
| CWL-007 | Use only that account's current-season CWL performance for performance-based selection. Regular-war results, prior CWL seasons, and another linked account's results do not become its current-season performance. |
| CWL-008 | When accounts that already reached eight fill remaining slots, rank those completed accounts by total stars and then average destruction. No optimizer weights or additional rating formula are agreed here. |
| CWL-009 | Display daily lineups and retain the seven-day planning context. Keep provisional signup-based plans distinct from confirmed registration eligibility and actual in-game participation. |
| CWL-010 | Freeze automatic lineup changes 60 minutes before that battle starts, with a configurable per-clan cutoff. Use the actual battle start timestamp when known, not an assumed daily cadence. This is an automatic-change cutoff, not a prohibition on authorized staff manual replacements. |
| CWL-011 | Staff manual replacements are pinned, including authorized manual changes after the automatic cutoff. Regenerate future unfrozen lineups around those selections; automatic regeneration must not silently overwrite a pin or change a frozen lineup. |
| CWL-012 | A recorded zero- or one-star hit, or an unused attack confirmed after the war ends, mandates a one-war bench at the earliest still-changeable, available, otherwise eligible war. Unknown or incomplete evidence is not a missed attack. |
| CWL-013 | An unavailable day does not consume the bench. After serving one otherwise eligible available war, the account automatically regains eligibility; it is not guaranteed a lineup slot. An unserved bench expires at season end. A war counts as served only when confirmed registration shows the account in the clan's registered pool for that war and the war's complete final roster excludes it (DEC-15, 2026-11-14). Unknown registration can reserve a provisional bench day but never serves it. |
| CWL-014 | Co-leader/Admin staff can explicitly override a bench. Record the override separately from a pin so a manual selection does not silently imply a different penalty policy. |
| CWL-015 | Automatic responses to late results affect the earliest suitable unfrozen future war. Do not automatically rewrite a frozen lineup, rewrite past participation, or carry an unserved penalty into another season. |
| CWL-016 | Export signups and planned lineups as CSV and automatically synchronize Google Sheets when signups or lineups change. Preserve the distinction between database records, exported copies, and the actual in-game roster. Each export keeps the exact signup or plan revisions it lists and the Sheet it targeted; a Sheet never shows an older export after a newer one. A clan's configured CWL signups channel shows its current signup list as one Discord message, edited when signups change (owner decision, 2026-11-14). |
| CWL-017 | Preserve signups, edits, plan versions, staff selections, freezes, performance evidence, bench decisions/service/overrides, and export outcomes so a historical lineup remains explainable. |

These constraints can make a complete lineup infeasible. Show missing slots or
unverified eligibility rather than claiming a complete valid plan. In particular,
strict availability must not be silently ignored and a bench must not be silently
waived to make a result look feasible. Staff can use the authorized actions above
to resolve the underlying conflict.

The CWL group is read every 900 seconds and each round war every 120 seconds by
default, both configurable per clan (DEC-04, 2026-11-14).

## Evidence and logical data grains

These are logical records, not final physical table names or a migration design.

| Record | Grain and purpose |
| --- | --- |
| Planning cycle and participating clan | One bot planning cycle and one leadership-selected clan participation decision; preserve selection history. |
| Account signup | One account's signup for a target clan/cycle, with selected War Days and versioned member/staff edits. |
| League-group observation | One fetched group observation, its raw source season string, member pools, ordered rounds, and source provenance. |
| Registered player | One account in a clan's registered league pool at an observation. This is not current clan membership or a daily lineup. |
| Round and war reference | One source round ordinal and returned war tag, associated with the local cycle/group context. |
| Daily roster observation | One account on one side of a particular war at an observation, retaining source TH and map position. |
| Attack evidence | One deduplicated attack in an identified CWL war, with attacker/defender, stars, destruction, order, and available timing evidence. |
| Plan version and assignment | One clan/cycle plan revision and its account assignments for each War Day, including pins and provenance. |
| Freeze and bench decision | One lineup cutoff transition or penalty incident, with the war where the bench is served, explicit override, or season-end expiry. |
| Export/sync attempt | One attempt to deliver specific signup/plan revisions to CSV or the configured Sheet, with outcome and destination reference. |

The [API evidence record](api-evidence.md) distinguishes the uploaded examples
from live contract validation. The supplied actual group has source season
`2026-11-02`, no explicit group ID, eight registered pools, and seven round
entries. Preserve the source season text separately from the bot's calendar
cycle; do not constrain the API field to `YYYY-MM`.

The actual daily sample has 30 players per side. Its corresponding registered
pools contain 45 and 39 players. Registered TH is `townHallLevel`; daily-war TH
is `townhallLevel`. Daily source map positions have gaps and reach 34, so they
are not the planner's 1-to-30 slot numbers. Source registration and war
observations must remain distinct from current clan membership evidence.

The daily body supplies no season or war tag: retain the requested war tag and
its group/round context. It also omits `attacksPerMember`. Its battle window is
longer than 24 hours, and neither attack order nor attack duration supplies an
occurrence timestamp. A finished roster does not prove that a preparation roster
was immutable before the game locked it. Do not count `bestOpponentAttack`
summaries as additional attacks.

## Visibility and audit

Expose signup, roster, and export outputs through the configured operational
surfaces. Staff-only edits, pins, and bench overrides require the named
capabilities. Apply [configuration and access](configuration-and-access.md)
and [account-link privacy](account-linking-and-attribution.md); exporting a
roster must not expose private link history or developer-only configuration
history. Discord and Google Sheets destination permissions still govern who
can access delivered copies.

Audit the human actor and affected account separately, especially for staff
edits. Retain decision time, source evidence, affected plan version, and
before/after selections. Record whether a delivery succeeded, failed, or is
uncertain. A published Sheet is not proof that staff applied the lineup in game.
Do not store API credentials in observations or audit details.

## Acceptance scenarios

1. At signup close on the first of the month, the selected clan has accounts
    available for different War Days. A provisional seven-day plan is produced
    immediately, even though the official registered roster is not yet known.
    Its eligibility state remains provisional.
2. An account currently in tracked Clan A signs up for selected Clan B. Its
    current clan alone does not reject the signup. Once registration is known,
    the plan distinguishes membership in B's registered pool from the earlier
    signup and from current clan membership.
3. A member tries to edit availability after close and is refused. An authorized
    Co-leader makes the same edit; the change is audited and future unfrozen
    planning reflects it.
4. Two alts belong to one Discord member. One has eight current-season stars and
    the other has two. They remain separate planning candidates; their stars are
    not combined into ten.
5. A one-star result is received after War Day 3 has frozen. The account is
    unavailable on War Day 4 but otherwise eligible and available on Day 5.
    The bench applies to Day 5, not Days 3 or 4. It becomes eligible again after
    that served bench, subject to normal selection.
6. A result arrives too late for any remaining suitable war. The incident is
    retained, and the unserved bench expires with the season.
7. A manual replacement pins an account in a future unfrozen lineup. Regeneration
    preserves that selection. An explicit staff bench override, when needed,
    has its own actor and reason rather than being inferred from the pin.
8. An ongoing or incompletely fetched war shows no attack for an account. No
    missed-attack penalty is created solely from that absence. A complete ended
    war showing its actual participation and unused attack can establish one.
9. Strict availability and eligible replacements leave only 14 candidates for a
    15-player lineup. The output identifies the shortage; it does not silently
    add an unavailable or benched account.
10. A Sheet synchronization fails. The authoritative plan and its version remain
    intact, the failure is recorded, and the bot does not report a successful
    external publication or in-game lineup change.
11. The automatic cutoff passes. An automatic replan cannot change that lineup;
    an authorized staff manual replacement can, with its actor and pinned
    selection retained. This does not imply the game still permits the change.
12. A bench day is reserved while registration is unknown, and that day's final
    roster excludes the account. The incident stays open until a war with
    confirmed registration serves it, or it expires at season end.
13. Staff try to withdraw Clan B while 12 active signups target it. The command
    is refused; after staff move or withdraw those signups, the withdrawal
    succeeds.

## Dependencies

- [Configuration and access](configuration-and-access.md): participating-clan
  settings, staff capabilities, per-clan freeze configuration, and private audits.
- [Account linking and attribution](account-linking-and-attribution.md): stable
  account identity and authorized account references, independently of raw game
  performance.
- [Membership and role automation](membership-and-role-automation.md): current
  clan observations, which must not be confused with CWL registration.
- [API evidence](api-evidence.md): group/war contracts, source identities,
  collection coverage, and timing limitations.
- [Notifications and delivery](notifications-and-delivery.md): leadership prompts,
  roster displays, and delivery outcomes.
- [Leaderboards](leaderboards.md): metric semantics and account-level ranking.

## Suggested future issue workstreams

- Signup lifecycle, participating-clan selection, and staff edits: CWL-001–004.
- Registered-roster and round/war ingestion with current-season evidence:
  CWL-007, CWL-009, CWL-012, and CWL-017.
- Constraint-aware provisional planning and completed-account ranking:
  CWL-005–009, without presenting unapproved weights as requirements.
- Freeze, manual selection, and penalty lifecycle: CWL-010–015 and CWL-017.
- Signup and daily roster output, CSV export, and Google Sheets synchronization:
  CWL-016.

These are proposed issue boundaries; no issue is created by this specification.

## Explicitly open or deferred

- The exact optimizer formulation and numeric rating/weights are not selected.
  The objective and constraints above are accepted; no guaranteed star outcome
  follows from a plan.
- How multiple unserved poor-performance incidents stack or coalesce is not
  specified. Do not invent a multi-war penalty.
- Member self-service availability edits after close remain disabled for now;
  revisiting that policy is deferred.
- Detailed Sheets authentication, retry mechanics, and command/UI design are
  implementation work. Live API accessibility and source completeness still
  require validation; the uploaded payloads are evidence of observed contracts.
