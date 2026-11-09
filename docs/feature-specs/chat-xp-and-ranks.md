# Chat XP and ranks

Status: agreed target requirements; not fully implemented. The initial SQL uses
provisional earning rules. This specification replaces the earlier provisional
rules in the [working plan](../design/star-schema-working-plan.md). It specifies
behavior and logical data needs, not a final physical schema.

## Scope and actors

The feature rewards chat participation by eligible members of the configured
Discord server. It covers earning XP, cumulative ranks, rank-role reconciliation,
and the XP evidence consumed by [leaderboards](leaderboards.md).

Members earn XP and hold rank roles. Authorized configuration operators select
the eligibility roles and bind rank roles to Discord IDs. The bot evaluates
earning decisions and reconciles rank roles. These permissions follow
[configuration and access](configuration-and-access.md).

## Requirements

| ID | Requirement |
| --- | --- |
| XP-001 | All text channels are in scope. A member qualifies to earn when they hold at least one configured XP-eligibility role. Initially two roles are configured; either role or both roles qualify. A linked CoC account is not required. |
| XP-002 | Each credited message earns a uniformly sampled integer from 15 through 25, inclusive, using unpredictable server-side randomness. Store the sampled amount as part of that message's award. |
| XP-003 | A member can earn from at most five messages in a rolling 60-second window across all text channels combined. |
| XP-004 | A message can produce at most one award. If already credited, retrying or redelivering it returns the existing award and amount; it must not reroll XP, add XP again, or consume another earning slot. Concurrent processing must preserve this rule and XP-003. |
| XP-005 | Losing all configured eligibility roles pauses earning. Existing XP and achieved rank remain. Regaining either role restores earning eligibility. |
| XP-006 | Leaving and rejoining Discord preserves the member's XP and achieved rank. Departure changes current membership and leaderboard eligibility without deleting earning history. |
| XP-007 | Rank is determined by cumulative XP using the approved thresholds below. Monthly leaderboard boundaries do not reset cumulative XP or rank. |
| XP-008 | When applying rank roles, assign only the member's highest achieved rank's configured Discord role. Reconciliation removes lower rank roles without removing unrelated roles. Role bindings use stable Discord IDs; names are display labels. |
| XP-009 | XP earning eligibility and leaderboard eligibility are separate. Monthly and all-time chat boards follow the membership and calendar rules in the leaderboard specification. |
| XP-010 | Keep evidence sufficient to explain an award, the resulting total/rank, and each requested or confirmed rank-role change. A requested Discord role change is not evidence that Discord applied it. |

### Approved cumulative thresholds

The threshold is the minimum cumulative XP needed for the rank. Use the highest
threshold the member has reached.

| Rank | Minimum cumulative XP |
| --- | ---: |
| Stardust | 0 |
| Stargazer | 4,000 |
| Orbiter | 12,000 |
| Lunar Drift | 28,000 |
| Solar Wanderer | 60,000 |
| Penumbra | 120,000 |
| Corona | 240,000 |
| Umbra | 400,000 |
| Totality | 650,000 |
| Eclipse Ascendant | 1,000,000 |

## Logical data, audit, and visibility needs

These are information requirements rather than table or column prescriptions:

- Stable server, member, message, and channel identities, with earning timestamps
  sufficient to enforce the shared rolling window.
- The credited message's durable award and its sampled XP. Preserve the policy
  and eligibility evidence needed to explain that decision.
- Award history, cumulative XP, monthly-period attribution, and the resulting
  achieved rank. A stored total must remain explainable from its source awards.
- Configured eligibility-role IDs, ordered rank thresholds, and rank-role IDs.
  Keep their display names separate from identity.
- Membership and role evidence distinguishing an absent member from a present
  member whose earning is paused.
- Rank-role decisions, delivery attempts, and observed outcomes, using the
  [notification and delivery](notifications-and-delivery.md) contract.

Retain award, XP, and rank history indefinitely, including through role loss and
Discord departure. Applying a rank role or displaying a score must not expose
private warnings, account-link history, or configuration audit records.
Configuration changes and their audit visibility follow the configuration
specification; rank and score publication follows the leaderboard specification.

## Acceptance scenarios

| Scenario | Expected result |
| --- | --- |
| Member has the first eligibility role only, the second only, or both | Each case qualifies for earning. Neither role means earning is paused. |
| Eligible member has no linked CoC account | Their chat messages can earn XP under the same rules. |
| A message earns 19 XP and is delivered again | The existing 19 XP award is returned; the total and earning-slot count do not increase again. |
| Five messages earn across several channels and a sixth arrives while all five remain within the rolling window | The sixth message does not earn. Changing channels does not bypass the limit. |
| Five messages earn shortly before a calendar-minute boundary and another arrives shortly after it | Crossing the calendar-minute boundary does not create new earning capacity. |
| The oldest credited message falls outside the rolling 60 seconds | A later eligible message can earn if fewer than five credited messages remain in the window. |
| Two workers process messages competing for the last available slot | At most one additional message earns; the member's limit is preserved. |
| Member loses their last eligibility role while holding 12,000 XP | Earning pauses; 12,000 XP and Orbiter remain. Regaining either role allows earning again. |
| Member reaches 4,000 cumulative XP | Their rank becomes Stargazer and only the Stargazer rank role is desired. At 3,999 XP the rank is Stardust. |
| A monthly leaderboard period ends | Monthly scoring rolls into the next period; cumulative XP and rank remain. |
| Member leaves and later rejoins Discord | Their previous XP and rank remain available, and leaderboard visibility follows current membership. |
| Discord rejects a rank-role update | Keep the role decision distinct from its failed outcome; do not describe the role as confirmed applied. |

The random selection must cover all eleven integers with equal probability and
use an unpredictable server-side source. Tests should verify the sampling
contract without requiring a particular random sequence or rerolling an existing
award.

## Dependencies

- [Configuration and access](configuration-and-access.md): eligibility roles,
  rank-role bindings, authorized configuration, and configuration audits.
- [Membership and role automation](membership-and-role-automation.md): current
  Discord membership, observed roles, and reconciliation of desired roles.
- [Leaderboards](leaderboards.md): monthly/all-time scores and membership filters.
- [Notifications and delivery](notifications-and-delivery.md): durable role-change
  decisions, attempts, and outcomes.

## Suggested future issue workstreams

- Implement idempotent message awards and the concurrent rolling-window limit.
- Add uniform, unpredictable server-side XP sampling and cumulative total/rank
  calculation.
- Configure eligibility roles and approved rank-role bindings.
- Reconcile the highest rank role through role changes and rejoins.
- Expose XP/rank results and leaderboard inputs with explainable source awards.
- Replace the provisional SQL behavior and validate the target rules end to end.

These are planning workstreams, not created GitHub issues or implementation
claims.

## Open and deferred decisions

- Exact command responses, rank announcements, and where they are published.
- The clock used for earning decisions and treatment of delayed or out-of-order
  Discord events, including the exact boundary convention for 60-second windows.
- Any additional message filters or anti-abuse rules. None are added by this
  specification; they need separate agreement.
- Historical XP correction or administrator-adjustment workflows, if required.
- Whether rank thresholds can be edited later and how such a change affects
  already achieved ranks. The table above is the approved initial schedule.
