# Configuration, permissions, and audit

Status: agreed requirements for subsequent schema and feature work. These are
target behaviors, not a claim that the current services implement them all.

## Scope and actors

Each deployment serves one Discord server and multiple tracked CoC clans. Dev
uses a separate Discord test server with the production template; its actual
IDs differ. Dev and prod use separate databases with the same schema and
migrations.

Application authority comes from configured Discord roles or allowlisted
developer user IDs. Discord's built-in Administrator permission does not replace
the configured Admin-role rule.

## Requirements

- **CFG-001:** Store bot-managed settings in PostgreSQL and manage them through
  authorized commands. This includes tracked clans, role/channel bindings,
  schedules, polling intervals, rank configuration, and leaderboard timezones.
  This supersedes application-setting bindings in `.env`.
- **CFG-002:** Supply bootstrap connectivity and service credentials through
  secure runtime configuration. Do not commit credentials or include their values
  in ordinary configuration-change records.
- **CFG-003:** Configured Admin-role members and allowlisted developers can
  manage general configuration. Feature-specific authority still applies.
- **CFG-004:** Only existing allowlisted developers can add or remove developer
  Discord IDs. General configuration permission does not grant this action. This
  replaces the earlier provisional restriction with an accepted rule.
- **CFG-005:** Only allowlisted developers can read configuration audit history.
  An Admin-role membership alone must not reveal that history or permit granting
  oneself developer status.
- **CFG-006:** Audit human and automated changes with actor/system origin,
  action, affected identity, time, applicable reason, and sanitized evidence.
  Retain the audit history indefinitely.
- **CFG-007:** Use stable Discord IDs for role/channel bindings and retain cached
  display names. A rename must not break a binding; a deletion must not erase its
  historical identity.
- **CFG-008:** Keep clan-specific settings independently configurable, including
  regular-war reminder schedules and CWL lineup cutoff offsets.
- **CFG-009:** Preserve distinct capabilities for Leadership, Co-leader, Admin,
  developer, clan membership, TH, XP eligibility, and XP ranks. Developer status
  alone does not grant moderation or CWL roster-management authority.
- **CFG-010:** Use current authorization evidence, not historical held roles.
  Departing and rejoining must not restore stale staff permissions.
- **CFG-011:** Preserve the separate visibility of developer-only configuration
  audits, leadership-only assessments, and private link history. A general audit
  viewer or log channel must not bypass those boundaries.

## Capability boundaries

| Action | Required application authority |
| --- | --- |
| General configuration | Configured Admin role or developer allowlist |
| Developer allowlist management | Existing developer allowlist entry |
| Configuration audit access | Developer allowlist entry |
| Account-transfer approval and link-history access | Co-leader or Admin |
| CWL late sign-ups, availability changes, manual lineups, and bench overrides | Co-leader or Admin |
| Warning issue/revoke | Leadership, Co-leader, or Admin |
| Own-account API refresh | Requester's currently linked account |
| Own warning history | Warning subject |

Discord channel/category ACLs govern the configured leadership log channels.
Store channel IDs; do not duplicate their ACLs as a second application-maintained
role list.

## Data and audit requirements

Configuration needs current values, historical revisions, stable role/channel
references, per-clan settings, and a developer user-ID allowlist. Correlate
commands, resulting changes, and outbound work without storing secret values in
before/after evidence.

Initial developer seeding and privileged recovery belong to trusted operator
bootstrap procedures. They must not introduce an Admin-accessible shortcut.

## Acceptance scenarios

- An Admin changes an activity channel but cannot view the configuration audit
  or add a developer ID.
- An existing developer maintains the allowlist and the change is audited.
- Renaming a bound role preserves its behavior and historical display identity.
- Changing one clan's reminder offsets preserves the other clans' schedules.
- A rejoining member supplies current role evidence before a staff action is
  authorized.
- Credentials and verification tokens are absent from configuration logs,
  Kafka messages, errors, and stored request/response archives.

## Dependencies and suggested workstreams

All feature specifications depend on these boundaries. See
[notifications](notifications-and-delivery.md) for delivery contracts and
[account linking](account-linking-and-attribution.md) for verification evidence.

Future workstreams include configuration commands/bindings, authorization,
audited revisions, and operator bootstrap/recovery. They are not created issues.
