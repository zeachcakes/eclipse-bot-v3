# Membership and role automation

Status: agreed target behavior, with the lifecycle edges below explicitly open.
This specifies intended behavior and evidence needs, not completed live CoC or
Discord integration and not a final physical schema.

## Scope

Track observed membership in the server's configured Clash of Clans clans,
retain public movement history, and derive Discord clan and town hall roles
across linked primary and alt accounts. Include the agreed welcome, Applicants,
Eclipse, and New Joinee onboarding behavior.

One Discord server is served per environment. Initially one clan is tracked;
the model and configuration must support several clans. War-specific roles use
their own roster lifecycle in [regular wars](regular-wars.md).

## Requirements

- **MEM-001:** Tracked clans, polling settings, role mappings, and the welcome
  channel are database-managed application configuration. Use stable clan tags
  and Discord IDs; cached names are display labels, not relationship keys.
- **MEM-002:** The initial clan-membership polling interval is two minutes and
  is configurable. For one clan, this is approximately 720 membership requests
  per day, excluding other API operations. This is not an instantaneous-change
  guarantee or a player-profile/achievement polling schedule.
- **MEM-003:** Only successful, complete roster evidence can establish an
  observed membership departure. Failure, incomplete pagination, or missing
  collection is not evidence that a clan became empty.
- **MEM-004:** Retain observed joins, departures, and moves, together with
  collection time, successful coverage, and relevant gaps. Polling does not
  establish exact in-game join or leave times.
- **MEM-005:** Observed clan-membership history is public. Its public status
  does not make historical Discord-to-account links public.
- **MEM-006:** A Discord member receives a tracked clan's configured member
  role when any of their currently linked accounts belongs to that clan.
  Primary and alt accounts both qualify.
- **MEM-007:** Desired clan roles are the union across all linked accounts.
  A member with accounts in two tracked clans receives both clan roles. Removing
  or moving one account must not remove a role still required by another.
- **MEM-008:** A supported clan departure changes the relevant clan-role
  requirement, not the Discord account link or primary designation. Retain
  account associations when a player temporarily has no tracked clan.
- **MEM-009:** Grant a configured TH role for each distinct town hall level
  across all currently linked accounts, including alts. Remove a TH-role
  requirement only when no current link requires that level. A failed profile
  read is not evidence of a changed town hall level.
- **MEM-010:** On joining Discord, send a welcome in the configured welcome
  channel and grant the configured Applicants role. Record the join occurrence
  independently of retained account links and previous Discord presence.
- **MEM-011:** On the first successful eligible account link, remove Applicants
  and grant Eclipse, New Joinee, applicable clan roles, and applicable TH roles.
  Eligibility and verification follow the account-linking specification.
- **MEM-012:** The initial New Joinee duration is seven days from the applicable
  Discord join, not seven days from linking. The governing join occurrence after
  a rejoin and treatment of a first link after that period remain open.
- **MEM-013:** Reconciliation derives the latest complete desired role state
  and compares it with confirmed Discord state before acting. Replayed or delayed
  work must not blindly apply an old addition/removal or remove a role another
  applicable requirement still needs.
- **MEM-014:** Distinguish a role decision, a requested Discord change, and a
  confirmed assignment/removal. Preserve evidence of actual outcomes, failure,
  and uncertainty. Reconciliation can run again under its own delivery contract;
  it does not inherit a blanket one-attempt limit from notification pings.
- **MEM-015:** Role renames do not break bindings. Preserve stable identities
  in history when a role is renamed or deleted; a missing role is an operational
  condition to report, not a reason to rebind automatically by name.
- **MEM-016:** Preserve Discord identities, account links, and accumulated
  historical data after a Discord departure. Retained historical staff-role
  evidence must not grant current configuration or moderation authority.

## Logical workflow and evidence

### Observed clan membership

1. Load enabled tracked clans and the polling interval from configuration.
2. Fetch each clan's complete roster. Retain the outcome, observation time,
    completeness, and correlation to the API operation.
3. Compare supported roster evidence with the last supported state. Record
    observed changes and coverage rather than claiming an exact game timestamp.
4. Resolve current account links and calculate the union of applicable clan
    roles per Discord member. Keep source account requirements identifiable so
    one account cannot incorrectly cancel another account's role requirement.
5. Submit current desired-state reconciliation through the delivery boundary.
    Record confirmed Discord outcomes separately from the decision.

A move can be observed at different times in two clans' polling cycles. The
collector must preserve those observation boundaries and gaps. A second
successful-poll departure check was suggested during planning but was not
confirmed as a requirement; it must not become an undocumented rule.

### Discord onboarding and town hall roles

Retain each observed Discord join/departure occurrence and source time when
available. Welcome delivery and Applicants assignment are separate external
operations with separate outcomes. A successfully verified eligible first link
provides the trigger for the agreed Eclipse/New Joinee/clan/TH reconciliation.

TH requirements use supported current profile evidence across every current
link. Changing the primary account alone must not discard roles still required
by alts. The New Joinee deadline needs the relevant join occurrence and duration
policy recorded as evidence; unresolved join-selection behavior must stay open.

The logical data needs are current and historical account associations, observed
membership/coverage, current TH evidence, Discord presence, role configuration,
source requirements, desired state, and confirmed Discord outcomes. These are
not a prescribed set of tables or an authorization model based on old facts.

## Permissions and audit

Role/channel/clan configuration follows
[configuration and access](configuration-and-access.md): the configured Admin
role and allowlisted developers manage application settings. Discord's built-in
Administrator permission alone is not the selected application rule.

Membership history is public by player/clan identity. Historical account-link
ownership remains subject to the separate Co-leader/Admin restriction in
[account linking and attribution](account-linking-and-attribution.md).

Audit configuration edits, collection coverage, observed changes, role decisions,
and confirmed changes with their human or system origin. Do not claim a role was
granted solely because work was queued. Do not store verification tokens in role
provenance, delivery payloads, or diagnostics. Current staff authority must use
current confirmed role/presence evidence rather than historical assignments.

This feature grants no new manual role-override capability. Management of
unrelated roles and moderator permissions is outside this automation's scope.

## Acceptance scenarios

| Scenario | Expected result |
| --- | --- |
| One linked account moves from Clan A to Clan B and no other linked account remains in A | Supported observations remove A's requirement and add B's; the account link and primary designation remain. |
| A member has their primary in A and an alt in B | Both clan roles are required. |
| One account leaves A while another linked account stays there | A's member role remains required. |
| A linked account temporarily belongs to no tracked clan | The account association remains; clan-role requirements reflect supported membership evidence. |
| A clan roster request fails or pagination is incomplete | Do not infer mass departures or remove clan roles from that incomplete evidence; retain the coverage gap. |
| Two linked accounts are TH16 and another is TH15 | TH16 and TH15 are both required, with no duplicate TH16 requirement. |
| One TH16 account unlinks while another TH16 account remains | TH16 stays required. |
| A player-profile request fails | Do not treat failure as a new TH value or automatically erase the supported TH requirement. |
| A new Discord member joins | Create join evidence and initiate the configured welcome and Applicants operations, each with its own delivery outcome. |
| The member's first eligible, verified link succeeds | Remove Applicants and require Eclipse, New Joinee, and applicable clan/TH roles, subject to the explicit late-link lifecycle decision below. |
| An ordinary first link occurs two days after the relevant Discord join | The initial New Joinee deadline is join plus seven days, not link plus seven days. |
| A delayed old role-change operation arrives after newer requirements | Reconcile the latest desired state instead of restoring the stale role. |
| A configured role is renamed | Continue identifying it by its Discord ID. |
| A Discord member leaves and later returns | Preserve links and historical data. Historical staff roles alone do not restore current authority; unresolved onboarding/expiry behavior is not guessed. |

## Dependencies

- [Configuration and access](configuration-and-access.md) defines tracked clans,
  role/channel bindings, settings permissions, and configuration-audit visibility.
- [Account linking and attribution](account-linking-and-attribution.md) defines
  verified current links, primary/alt handling, transfers, and retained links.
- [API evidence](api-evidence.md) defines complete collection, provenance, and
  what a missing or failed API response can establish.
- [Notifications and delivery](notifications-and-delivery.md) defines the
  Kafka/Java/gRPC/Node boundary and separate role-reconciliation semantics.
- [Regular wars](regular-wars.md) defines war-roster roles and their retention
  until the next roster; current clan membership does not replace that lifecycle.
- [Chat XP and ranks](chat-xp-and-ranks.md) defines retained XP/rank behavior;
  rank-role earning rules are not introduced by this feature.

## Suggested future issue workstreams

- Complete membership collection and coverage-aware observed-change recording.
- Current-link/TH aggregation and desired-role reconciliation across source
  requirements, including stale-operation suppression.
- Welcome, Applicants, and first-link onboarding through the delivery service.
- Join-based New Joinee expiry after resolving its lifecycle edges.
- Permission, rename/deletion, gap, multi-account, and restart regression coverage.

These are proposed workstreams, not published issues or a completed runtime.

## Open and deferred decisions

- Which Discord join occurrence governs New Joinee after a rejoin.
- What to do when the first eligible account link occurs after New Joinee would
  already have expired.
- How retained links on rejoin interact with first-link onboarding; do not
  silently treat them as a new verification or unlink them.
- Eclipse/Applicants behavior after every account link disappears. No automatic
  removal or fallback policy has been agreed for that case.
- Player-profile/TH polling cadence, freshness tolerances, and precise boundary
  policy for membership observations and collection gaps.
- Whether departure confirmation should require a second successful poll.
- Operational recovery when a configured role/channel is deleted or permission
  to apply a role is missing; do not invent name-based replacement behavior.
- Exact cross-process reconciliation, ordering, and retry contracts. No blanket
  permission for replaying arbitrary Discord side effects follows from desired
  role-state reconciliation.
