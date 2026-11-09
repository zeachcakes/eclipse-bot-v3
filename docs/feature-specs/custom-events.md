# Custom events

## Status and scope

Status: agreed target behavior for future implementation. This specification
replaces the broad custom-event deferral in the
[working plan](../design/star-schema-working-plan.md) for the limited scope below.
It does not claim that a custom-event workflow is implemented.

Collect per-account signups across tracked clans and let staff assemble one
combined event roster. Retain available associated in-game war results. Members
provide signups; staff uses the list and can make manual selections. Manual roster
selection is available to configured Co-leader/Admin staff; developer allowlisting
alone does not grant that action. A tournament
engine, multiple rounds, and automatic in-game actions are outside this scope.

## Requirements

| ID | Agreed requirement |
| --- | --- |
| CUSTOM-001 | Record signups per Clash account, preserving the distinction between multiple accounts linked to the same Discord member. |
| CUSTOM-002 | Combine participating accounts across tracked clans into a custom event's signup pool. Do not require a separate event solely because accounts come from different tracked clans. |
| CUSTOM-003 | Staff uses the signup list to assemble the event roster, with optional manual selection. No automatic balancing or optimizer formula is agreed. |
| CUSTOM-004 | The current event has one roster. Multiple rounds, brackets, or multi-war tournament planning are deferred. |
| CUSTOM-005 | Associate and retain all available in-game war results indefinitely, with source provenance. Keep the selected roster distinct from the roster and results actually observed in game. |
| CUSTOM-006 | Record signup/selection changes and their actors so the final roster and its history remain explainable. |
| CUSTOM-007 | The bot coordinates and reports the event. It does not promise to create a friendly war, move accounts, apply a lineup in game, or execute attacks through the public API. |

## Evidence and logical data grains

These records describe information to retain, not final physical tables.

| Record | Grain and purpose |
| --- | --- |
| Custom event | One independently identified event and its lifecycle/context. |
| Account signup | One account's participation record for that event, with change history. |
| Roster selection | One selected account in a version of the event's single roster, including staff decisions and provenance. |
| Event/game association | One supported association between the event and observed in-game war evidence. |
| War/roster/attack evidence | The available game observations and deduplicated attacks associated with that war; participant identity is independent of later Discord links or clan moves. |

[API evidence](api-evidence.md) does not establish a dedicated friendly/custom-war
result endpoint or a reliable friendly-war discriminator. The accepted retention
rule applies to data that can actually be obtained. Do not fabricate a result,
assume the regular current-war endpoint always exposes a custom event, or label
unknown results as a loss or an unused attack.

## Visibility and audit

Use the shared [configuration and access](configuration-and-access.md) and
[account-link privacy](account-linking-and-attribution.md) boundaries. Signup and
roster output must not expose private link history or developer-only settings
history. Retain who changed a signup or roster, which account was affected, and
the before/after selection. No external role/channel audience or new public
sharing setting is implied merely by calling an event custom.

Game evidence must retain observation/source context and any collection gap.
Delivery state follows [notifications and delivery](notifications-and-delivery.md);
a successful Discord post does not prove an in-game selection was applied.

## Acceptance scenarios

1. One Discord member signs up two accounts, one from each of two tracked clans.
    The event retains two account entries in one combined pool, rather than one
    aggregated member entry or two clan-specific events.
2. Staff reviews the signup list and selects a roster manually. The selected
    account list and staff decision are retained without inventing an automatic
    team-balancing score.
3. Updating a selection revises the event's single roster. It does not silently
    create another round or a tournament bracket.
4. Available game evidence is associated with the event. Later unlinking a
    participant or moving its account to another clan does not delete the event's
    historical roster and results.
5. The API cannot provide the associated custom-war result. The record remains
    unavailable/unknown; the bot does not manufacture a score or claim that a
    dedicated result API was verified.

## Dependencies

- [Account linking and attribution](account-linking-and-attribution.md): stable
  account/member identities without rewriting source game history.
- [Configuration and access](configuration-and-access.md): shared settings and
  staff authorization boundaries.
- [API evidence](api-evidence.md): actual war-data coverage and correlation limits.
- [Regular wars](regular-wars.md): reusable war-observation concepts, without
  assuming identical endpoint coverage for friendly events.
- [Notifications and delivery](notifications-and-delivery.md): roster outputs and
  visible delivery outcomes.

## Suggested future issue workstreams

- Event identity, combined account signup pool, and selection history:
  CUSTOM-001–003 and CUSTOM-006.
- Single-roster commands and output: CUSTOM-003–004 and CUSTOM-007.
- Source validation, event/war association, and indefinite result retention:
  CUSTOM-005 and CUSTOM-007.

These are proposed workstreams; no issue or implementation is created here.

## Explicitly open or deferred

- Multi-round events, brackets, and tournament management are deferred.
- Event capacity, scoring, automated balancing, and custom role/reminder
  automation have no agreed rules in the current scope.
- Friendly/custom-war API accessibility and event/result correlation need
  evidence. Available-result retention is agreed; universal result coverage is
  not established.
