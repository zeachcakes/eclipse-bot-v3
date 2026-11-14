# Warnings and moderation

Status: agreed target requirements; not fully implemented. This specification
extends the [working plan](../design/star-schema-working-plan.md) with the agreed
kick/rejoin behavior. It describes logical decisions and evidence without
prescribing a final physical schema or a complete external-action lifecycle.

## Scope and actors

Configured Leadership, Co-leader, and Admin roles can issue and revoke warnings.
Members can read their own warning history. The bot records moderation
decisions, attempts Discord actions, and publishes the required notices.

An allowlisted developer does not gain moderation authority solely from that
allowlist entry. Current configured Discord roles determine command authority;
a historical role record does not grant permission. See
[configuration and access](configuration-and-access.md).

## Requirements

| ID | Requirement |
| --- | --- |
| MOD-001 | Only members with a current configured Leadership, Co-leader, or Admin role can issue or revoke warnings. Both actions require a reason and an identifiable actor and subject. |
| MOD-002 | Preserve each issued warning and any revocation as distinct historical evidence. A revoked warning does not count as valid. Revocation must not erase its issuance, reason, actor, or audit history. |
| MOD-003 | Count valid warnings in their original issuance month using GMT calendar months. The active monthly count resets at 00:00 GMT on the first, while the underlying history remains. A revocation in another month must not subtract from that other month's count. |
| MOD-004 | The fifth valid warning in a GMT month triggers the initial kick. Repeated delivery of a command must not duplicate its warning, and concurrent processing must not duplicate the initial kick decision for the triggering threshold occurrence. |
| MOD-005 | Distinguish a logical kick decision, an execution attempt, and its observed result. A requested, failed, or uncertain kick must not be recorded as a confirmed Discord kick. Recovery behavior for failed or uncertain kicks remains open. |
| MOD-006 | After a confirmed kick and subsequent rejoin within the same GMT month, notify the configured leadership channel. If further warnings are issued after that rejoin during the same GMT month, notify leadership only; do not automatically kick the member again for those warnings. |
| MOD-007 | Publish moderation decisions in the configured moderation-log channel. Its visibility is controlled by Discord's leadership category/channel permissions; storing its channel ID does not require reproducing that channel ACL in the database. |
| MOD-008 | Members can read their own warning history, including issuance and revocation reasons. Access to other members' moderation data must follow the configured moderation permissions, rather than becoming public through a history command. |
| MOD-009 | Retain warning, revocation, decision, attempt, result, and audit history indefinitely. A monthly reset or Discord departure must not delete that evidence. |
| MOD-010 | Warning months always use GMT. A change to the configurable leaderboard timezone does not change warning counts, reset boundaries, or already recorded warning months. |

The configured leadership notification destination and moderation-log destination
must be identifiable in configuration. This specification does not require them
to be the same channel.

## Logical data, audit, and visibility needs

The design needs to preserve:

- Stable server, subject, warning, and command identities, plus the issuing actor,
  reason, occurrence time, and original GMT month.
- Revocation identity, the referenced warning, the revoking actor, reason, and
  occurrence time. Repeated delivery must not subtract the same warning twice.
- Evidence supporting the valid-warning count and initial threshold decision.
  Keep the decision separate from attempts to carry it out.
- Attempt and observed result information sufficient to distinguish confirmed
  completion from failure or uncertainty, without inventing a recovery policy.
- Confirmed kick and later join evidence sufficient to identify the agreed
  same-month notification-only case.
- Logical notices, their configured destinations, and delivery attempts/results.

Moderation commands and history views must enforce their subject and actor
permissions. Members' own-history access does not imply access to everyone else's
history. Discord controls readership of the moderation-log channel. General
moderation logging must not expose developer-only configuration audits or
Co-leader/Admin-only account-link history.

Configuration audit visibility follows
[configuration and access](configuration-and-access.md). Leadership and moderation
notices use [notifications and delivery](notifications-and-delivery.md); that
specification does not supply a general moderation-action executor.

## Acceptance scenarios

| Scenario | Expected result |
| --- | --- |
| Current Leadership, Co-leader, or Admin member issues a warning with a reason | Record the warning and the actor, then apply the agreed counting rule. |
| A member without those roles, including a developer whose only authority is allowlist membership, issues or revokes a warning | Reject the moderation command without changing warning state. |
| An authorized moderator omits the issue or revocation reason | Reject the command. |
| Member reads their own history | Show their warning and revocation history, including reasons; do not expose another subject's private history. |
| Member has four valid warnings and receives a fifth within the same GMT month | Record the fifth warning and the initial kick decision; execution has its own attempt and result. |
| The triggering command is retried or concurrent processing reaches the same threshold | Do not duplicate the warning or the initial kick decision for that event. |
| The issuer loses their moderation role before an identical retry of a committed warning command | Return the stored warning; the retry applies nothing new, so it needs no new permission check (DEC-10, 2026-11-14). A new command or a retry with different arguments is still checked or rejected. |
| The kick result is uncertain | Preserve uncertainty; do not claim that the member was kicked or apply confirmed-kick/rejoin behavior without evidence. Recovery policy is deferred. |
| A confirmed kicked member rejoins within the same GMT month as the kick | Send a notice to the configured leadership channel. |
| That member receives another warning after rejoining during the same GMT month | Record it and notify leadership; do not automatically kick them again for that warning. |
| The clock reaches the first day of a new month at 00:00 GMT | The new month's active count starts at zero; prior warnings, actions, and audit history remain. |
| A prior-month warning is revoked this month | Mark that warning revoked in its original month's history; do not decrement this month's warnings. |
| A revocation is delivered twice | Apply it once; the referenced warning is excluded once from the relevant count. |
| Leaderboard timezone changes away from GMT | Warning months and reset times remain GMT. |
| A moderation decision is published | Use the configured moderation-log channel, whose Discord permissions determine who can read it. |

## Dependencies

- [Configuration and access](configuration-and-access.md): configured moderation
  roles, channel IDs, authorization, and configuration-audit boundaries.
- [Membership and role automation](membership-and-role-automation.md): current
  Discord roles and reliable departure/rejoin evidence.
- [Notifications and delivery](notifications-and-delivery.md): shared operation
  identity/outcome concepts and leadership/moderation notices. Kick execution
  remains a moderation workstream with its own unresolved recovery contract.

## Suggested future issue workstreams

- Implement authorized issue/revoke commands with required reasons and own-history
  views.
- Implement GMT monthly counting and idempotent threshold decisions under
  concurrent commands.
- Connect initial kick decisions to explicit Discord attempts and observed
  outcomes.
- Detect a confirmed kicked member's rejoin and implement the same-month
  notification-only behavior for later warnings.
- Publish moderation logs and leadership notices using configured channels.
- Preserve and review indefinite warning/action audit history with the correct
  visibility boundaries.

These are suggested planning units; no GitHub issues or runtime behavior are
created by this document.

## Open and deferred decisions

- Retry, recovery, and operator workflows after a failed or uncertain kick. This
  specification does not define a rollback, a count reset, or a replacement
  threshold decision for those outcomes.
- Further threshold behavior when a warning is revoked after a threshold decision
  or after a completed kick. No additional automatic action or reversal is
  implied beyond the explicitly agreed post-kick/rejoin notification-only rule.
- Exact moderation/history command presentation and notification contents.
- Whether leadership notifications share the moderation-log channel or use a
  separate configured channel.
