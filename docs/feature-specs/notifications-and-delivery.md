# Notifications and delivery

Status: agreed target behavior with the contract details below still open.
This specification describes intended behavior, not a completed delivery runtime
or a final database design. The first release will use Kafka; this supersedes
the earlier Kafka deferral in the [working plan](../design/star-schema-working-plan.md).

## Scope

Deliver activity reminders and announcements, publish or update reports, and
carry role-reconciliation work across the Java and Discord service boundary.
Feature-specific scheduling, recipients, and visibility remain defined by their
respective specifications. This feature does not implement CWL optimization,
game-data collection, or a general-purpose moderation executor.

## Requirements

- **NOTIFY-001:** Kafka is the selected broker for the first release. The flow
  is Java business work and a transactional PostgreSQL outbox, then Kafka, then
  a Java delivery worker, then gRPC, then discord.js, then Discord.
- **NOTIFY-002:** Java owns persistence, scheduling, Kafka integration, and
  durable delivery state. Node.js owns Discord presentation and external Discord
  calls. Node.js has no database access and does not consume Kafka directly.
- **NOTIFY-003:** A domain change that requires a notification and its durable
  delivery intent must commit together. A process restart must not erase
  scheduled work or create a second logical notification for the same decision.
- **NOTIFY-004:** Persist a stable logical operation ID before dispatch. Keep
  publication, consumption, dispatch, and external outcomes distinguishable.
  Kafka replay, relay retry, or worker restart must reuse that identity.
- **NOTIFY-005:** Each ping permits at most one automatic send attempt. Claim
  that attempt durably before dispatch; concurrent workers and replays must not
  obtain another attempt for the same ping.
- **NOTIFY-006:** Once a ping's send attempt has been dispatched, no layer may
  automatically resend it. This includes the Java worker, gRPC behavior, the
  Node handler, and Discord client or HTTP retry behavior. An application-level
  retry setting alone is insufficient if another layer can repeat the send.
- **NOTIFY-007:** A confirmed successful Discord API response and its available
  message ID support a delivered outcome. Kafka acknowledgment, RPC acceptance,
  or beginning a send does not establish Discord delivery. Record explicit
  failures and uncertain outcomes separately; neither permits an automatic
  resend of that ping.
- **NOTIFY-008:** A missed reminder is an accepted consequence of the
  one-attempt policy. Do not claim exactly-once delivery or guaranteed receipt.
  A crash after reserving an attempt can prevent delivery; a crash after Discord
  accepts a send can leave its result uncertain.
- **NOTIFY-009:** Retry of an outbox publication or a failed data read is
  distinct from retry of a ping send. Such work can retry under its own contract
  while deduplication prevents another send of an attempted ping.
- **NOTIFY-010:** On recovery, never-attempted reminder checkpoints missed
  during downtime are coalesced into one catch-up ping for each active war.
  Show the actual remaining time, not the original checkpoint label.
- **NOTIFY-011:** Previously attempted, failed, or uncertain pings must not be
  relabeled as never-attempted catch-up work. Expired reminders for ended wars
  must not produce an old ping. Repeated recovery processing must not recreate
  the same catch-up operation. Each separate outage may produce its own catch-up
  for the never-attempted checkpoints it missed (DEC-14, 2026-11-14): one
  pending catch-up per war and clan at a time, and each missed checkpoint feeds
  at most one catch-up.
- **NOTIFY-012:** Role reconciliation evaluates the latest desired state before
  acting. A stale queued change must not restore a role that newer evidence no
  longer requires. The one-attempt ping rule does not prohibit safe, repeated
  role-state reconciliation or repeated data reads; their retry and confirmation
  semantics must be explicit.
- **NOTIFY-013:** Recurring reports need a stable logical report identity and
  the confirmed Discord message ID when available. Creating a report, editing
  a known report, and emitting a ping are distinct operations. Exact report
  creation/edit retry behavior remains to be designed.
- **NOTIFY-014:** Use database-configured channel and role bindings and preserve
  the feature's allowed audience. Intended mention targets must be explicit;
  a delivery mechanism must not introduce broader pings or expose private data.
- **NOTIFY-015:** Scheduled notifications use ordinary bot message APIs, not
  saved interaction tokens. Commands that need backend work still follow the
  Discord service's interaction-acknowledgment requirements.
- **NOTIFY-016:** Retain evidence of decisions, suppression, attempt claims,
  results, and uncertainty with correlation to the originating feature. Logs,
  Kafka records, failure handling, and audit readers must preserve existing
  visibility boundaries and must never retain player verification tokens.

## Logical workflow and evidence

1. A feature identifies a logical notification from its stored state and
    configured schedule. Persist its identity, reason, intended destination,
    audience, due time, validity boundary, and the source decision or evidence.
    Commit the corresponding outbox entry in the same transaction.
2. The Java relay publishes to Kafka. Broker acknowledgment concerns publication
    only. Repeated publication can be safe because the logical ID does not change.
3. The Java consumer loads the durable operation, checks whether it is still
    applicable, and resolves duplicates, superseded work, and expiry before
    authorizing external action. It persists the disposition of a consumed event
    before treating that work as complete.
4. For a ping, obtain the sole durable send authorization before the external
    dispatch. The Java/Node contract must maintain this guard across concurrent
    calls, replays, and process restarts. An in-memory Node cache cannot be the
    only protection. The precise acknowledgment/authorization handshake is open.
5. Node executes the authorized Discord operation and reports its confirmed,
    failed, or uncertain outcome to Java. Java retains receipts and available
    message IDs. Loss of an acknowledgment must not lead to another automatic
    send of the same ping.
6. On recovery, reconcile the durable state rather than assuming that a missing
    receipt means no send occurred. Derive catch-up work only from never-attempted
    missed checkpoints, and check that the war is still active before dispatch.

The logical model needs operation and source identities, Kafka publication
evidence, attempt authorization, timestamps, schedule/expiry information,
destination bindings, outcome evidence, and message IDs. These are control and
audit needs, not a prescribed set of tables or Kafka topic names. Existing
attempt facts alone do not establish that a durable runtime queue is implemented.

## Permissions and audit

Configuration follows [configuration and access](configuration-and-access.md).
Delivery does not grant new configuration, replay, or moderation privileges.
Java must preserve the authorization and audience established by the originating
feature; Node must not turn an arbitrary inbound payload into an unrestricted
Discord action.

Private Clan Games results remain restricted to Leadership. Account-link
history and configuration audit retain their own distinct access rules. A Kafka
diagnostic, dead-letter record, or aggregate delivery log is not a bypass around
those restrictions. Store sanitized failure information rather than credentials,
verification request/response bodies, or uncontrolled payload dumps.

Audit records must distinguish a human decision from system publication,
attempt authorization, an external result, and an administrative intervention.
Do not describe a queued role change or a requested message as confirmed.

## Acceptance scenarios

| Scenario | Expected result |
| --- | --- |
| A transaction rolls back before committing a notification decision | Neither a committed delivery intent nor a corresponding send is produced. |
| The relay publishes successfully and crashes before recording publication | Replay retains the same operation ID and cannot produce a second ping attempt. |
| Two consumers process the same ping concurrently | At most one obtains authorization to dispatch its send attempt. |
| The worker reserves the attempt and crashes before a send can be confirmed | The operation remains recorded; recovery does not automatically try the ping again. A missed ping is accepted. |
| Discord accepts a ping, but the Node/gRPC acknowledgment is lost | Record uncertainty where no confirmed receipt is available; no layer automatically resends it. |
| A ping send receives an explicit error or a rate-limit response | Record the outcome; hidden client retries must not turn it into another automatic send attempt. Pre-send throttling and data-read retries are separate. |
| The bot recovers with three hours remaining after missing both eight- and four-hour reminders without attempting either | One catch-up ping describes three hours remaining and accounts for both missed checkpoints. |
| An eight-hour ping was attempted with an uncertain result before downtime | Recovery does not resend it under a catch-up identity. Other never-attempted checkpoints are considered separately. |
| The bot returns after a war has ended | Expired reminder work is suppressed; no old war ping is sent. |
| A queued clan-role addition is superseded before processing | Reconciliation uses the newest desired state rather than applying the stale addition. |
| A recurring report already has a confirmed message ID | Its next update identifies that report; its edit/retry contract is not confused with a new ping send. |

## Dependencies

- [Configuration and access](configuration-and-access.md) supplies channel/role
  bindings, authorized configuration commands, and privacy boundaries.
- [Regular wars](regular-wars.md) supplies reminder checkpoints, roster state,
  current unused attacks, and war end times.
- [Clan Games](clan-games.md) and [Raid Weekends](raid-weekends.md) supply report
  schedules, content, and separate public/Leadership audiences.
- [Membership and role automation](membership-and-role-automation.md) supplies
  current desired roles; [account linking](account-linking-and-attribution.md)
  supplies current ownership and primary/alt relationships.
- [API evidence](api-evidence.md) supplies source coverage and the distinction
  between failed collection and valid event state.
- [ADR 0009](../decisions/0009-discord-interaction-service.md) supplies the
  Java/Node boundary and gRPC decision. Kafka is now a first-release requirement.

## Suggested future issue workstreams

The requested parent issue is **Kafka-backed notifications and Discord
delivery**. The following are proposed sub-issue workstreams, not published
issues or assigned issue IDs:

1. **Contracts and identities:** Define event/protobuf contracts, operation and
    attempt IDs, ordering, outcomes, audience, expiry, and the one-send guard.
2. **Kafka infrastructure:** Provide development/test infrastructure, topic
    provisioning, environment separation, access controls, and health checks.
3. **Transactional outbox and relay:** Persist intents with domain decisions,
    publish durably, and preserve identity across relay restarts. Depends on 1–2.
4. **Java consumer lifecycle:** Deduplicate events, persist dispositions, handle
    expiry and uncertainty, and prevent repeated ping attempts. Depends on 1–3.
5. **Node/gRPC delivery:** Implement authorized Discord sends and result
    acknowledgment with no hidden ping resend. Depends on 1; integrate with 4.
6. **Schedulers, reports, and roles:** Produce scheduled and catch-up work,
    preserve report identities, and reconcile the latest role requirements.
    Depends on 3–5 and the relevant feature specifications.
7. **Observability and crash coverage:** Verify all send/ack failure windows,
    replay suppression, privacy, audits, and actionable failure visibility across
    3–6. No successful-delivery claim may depend on a zero-failure happy path only.

Each workstream needs its own acceptance checks. Publishing an issue hierarchy,
choosing precise contracts, and implementing the runtime are separate work.

## Open and deferred decisions

- Exact topic/envelope versions, protobuf methods, partition keys, acknowledgments,
  retention, and the cross-process single-send authorization protocol.
- Report creation/edit retry rules and message replacement if a report is deleted.
- Manual resend/replay permissions and behavior; no manual override is authorized
  by the automatic retry policy itself.
- Which unattempted work can safely retry after transport failure before any
  send authorization, with evidence sufficient to preserve the one-attempt rule.
- Retry/confirmation rules for non-ping operations, including role reconciliation;
  the safety of an operation must be established rather than assumed.
- Production Kafka topology and deployment details. Kafka is selected; these
  operational details remain open.
