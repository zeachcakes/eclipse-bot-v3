# Regular wars

## Status and scope

Status: agreed target behavior. The existing guild schema has war evidence
structures, but this specification does not claim a working live collector,
Discord role reconciliation, or reminder worker.

Observe regular wars selected in game, retain their evidence, reconcile the
configured clan war role, and remind members about unused attacks. There are no
bot signups for regular wars. [CWL](clan-war-leagues.md) and
[custom events](custom-events.md) have separate planning requirements.

Actors are participating accounts and their linked Discord members, authorized
configuration operators, and collection/role/reminder workers. In-game staff
selects the roster; the bot observes that decision.

## Requirements

| ID | Agreed requirement |
| --- | --- |
| WAR-001 | Use the actual in-game regular-war roster; do not introduce a bot signup or roster-selection workflow. |
| WAR-002 | Each tracked clan has its own configured war channel/category and dedicated war role for pings, identified by stable Discord IDs. |
| WAR-003 | A Discord member qualifies for the clan's war role when any currently linked account is on that war's roster. Compute the union across the member's accounts. |
| WAR-004 | Retain the previous war role until the next roster is available, then reconcile against that roster. A failed or incomplete fetch must not be interpreted as an authoritative empty roster. |
| WAR-005 | Automatically remind members with unused attacks eight and four hours before war end. Each clan's reminder schedule is independently configurable. |
| WAR-006 | Preserve all available war, roster, and attack evidence indefinitely for metrics, including opponents, historical TH matchups, stars, destruction, and other supplied fields. |
| WAR-007 | Repeated collection must not turn one attack into several attacks or add successive snapshots of the same war totals. Preserve source and observation provenance. |
| WAR-008 | Role reconciliation and notifications record attempts and outcomes. A planned role change or reminder is not evidence that Discord applied or delivered it. |

The exact composition of reminder mentions remains open: individual mentions,
role mentions, or a combination have not been selected.

## Evidence and logical data grains

These are logical grains, not instructions to add or rename tables.

| Record | Grain and purpose |
| --- | --- |
| War identity/context | One identified regular war and its clan sides, observed timing, size, and state. Preserve how identity was established. |
| War observation | One source observation/version of the war and available complete response fields. |
| Roster observation | One account on one clan side at an observation, with source name, TH, position, and other available roster evidence. |
| Attack | One deduplicated attack within the identified war, with attacker/defender and source order when available. |
| Desired role state | One member's required clan war role, derived across all currently linked roster accounts. |
| Reminder decision/delivery | One logical clan/war/reminder checkpoint and its attempts/outcomes. |

The [API evidence](api-evidence.md) distinguishes regular current-war and war-log
examples from verified live behavior. Do not assume every regular war has a
universal API war tag. A local identity needs defensible source context and a
validated deduplication strategy.

Historical TH analysis must use roster evidence rather than the account's
current TH. Attack duration is not an occurrence timestamp. A missing timestamp
must remain unknown. Defensive summaries such as `bestOpponentAttack` must not
be counted as additional attacks already present in attack evidence.

## Visibility and audit

Use the clan's configured operational surfaces and
[shared access rules](configuration-and-access.md). Configuration changes remain
private to developer audit viewers; sending a war report does not widen that
access. Public current account links and configured-role membership can support
role reconciliation without exposing private account-link history.

Record source coverage, role decisions and attempts, reminder identity, delivery
outcomes, and human configuration actors separately. Do not include API secrets
or verification tokens in payload archives or logs. This feature observes war
participation; it does not change an in-game roster or perform attacks.

## Acceptance scenarios

1. A member has two linked accounts on one roster. The member receives the
    required war role once. Removing one account from eligibility does not remove
    the role while the other still qualifies.
2. The previous war ended and fetching the next roster fails. Existing war-role
    eligibility is preserved until the next roster is available; failure does
    not empty the role set.
3. A complete next roster arrives. Reconciliation adds newly eligible members
    and removes members no longer eligible, subject to the union across accounts.
4. At eight and four hours before the observed war end, the configured reminder
    workflow identifies unused attacks using the available roster/attack evidence.
    Another clan can have independently configured offsets.
5. The collector fetches the same attack three times. Metrics still contain one
    attack, while collection observations can retain their separate provenance.
6. A roster account later upgrades TH or leaves the clan. Its earlier war's TH
    matchup and attack history remain based on that war's evidence.
7. Discord fails to apply a role or deliver a reminder. The outcome is recorded
    as failed/uncertain rather than confirmed success.

## Dependencies

- [Configuration and access](configuration-and-access.md): per-clan destinations,
  war-role bindings, reminder offsets, and configuration audit privacy.
- [Account linking and attribution](account-linking-and-attribution.md): current
  links and retained account identities.
- [Membership and role automation](membership-and-role-automation.md): role
  reconciliation and union semantics across accounts.
- [API evidence](api-evidence.md): regular-war source coverage and identity.
- [Notifications and delivery](notifications-and-delivery.md): logical reminders,
  external attempts, and uncertainty.
- [Leaderboards](leaderboards.md): historical score and current-clan eligibility
  are separate concerns.

## Suggested future issue workstreams

- Regular-war ingestion, identity, and evidence retention: WAR-001, WAR-006–007.
- Next-roster detection and desired war-role reconciliation: WAR-002–004.
- Configurable unused-attack reminder decisions and delivery: WAR-005, WAR-008.

These are suggested workstreams, not created issues or claims of implementation.

## Explicitly open or deferred

- The choice of individual mentions, war-role mentions, or a combination in
  reminders is still open.
- Live API coverage, collection intervals, and source-identity validation remain
  implementation/evidence work. Missing evidence must not become an invented
  unused attack or an authoritative empty roster.
- CWL planning and custom-event signup behavior are specified separately and
  must not be imported into regular wars automatically.
