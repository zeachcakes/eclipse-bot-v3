# Clan Games activity tracking

Status: agreed target requirements. Collection, commands, assessments, and delivery must
be implemented and validated together; a schema foundation alone does not complete this
feature. Follow-up decisions here supersede the earlier
[working plan](../design/star-schema-working-plan.md) where its rules remain open.

## Scope

Collect account-level Clan Games activity and evaluate one combined activity requirement
per Discord member across the tracked clans. Provide member-visible points and clan
totals, plus leadership-only pass/fail assessments.

The requirement is an activity metric. Staff exemptions and manually entered scores are
not part of the feature. Manual event creation means entering event dates and a cap,
not overriding earned points.

## Requirements

- **CG-001 — Event configuration.** Store the event's start, end, and per-account points
  cap in PostgreSQL. Automatically create events from configured schedule settings, with
  authorized manual event creation as fallback. Do not assume an API calendar exists.
- **CG-002 — Relevant participation.** Count only points relevant to tracked clans.
  Clan Games participation stays locked to its starting participating clan; the current
  player-profile clan does not itself establish that event affiliation.
- **CG-003 — Accepted affiliation inference.** When an account is observed consistently
  in the same tracked clan from event start through its first observed points increase,
  the bot may infer that participating clan. Mark this as inferred evidence. Ambiguous
  affiliation produces insufficient_data rather than an invented clan assignment.
- **CG-004 — Regular refresh.** During an active event, refresh player-profile and
  Clan Games evidence every 15 minutes. The interval is configurable in PostgreSQL and
  is separate from membership polling.
- **CG-005 — Boundary reads.** Event baselines, the T−24h checkpoint, the final checkpoint,
  and transfer-boundary reads are separate scheduled needs. They must not simply wait
  for the next regular 15-minute poll. The T−24h read may be collected up to 1,800
  seconds before its checkpoint, a configurable default (DEC-03, 2026-11-14); progress
  in that stretch counts at the final checkpoint.
- **CG-006 — Points source.** Use supported observations of the Games Champion cumulative
  achievement counter to derive eligible event progress. Keep its achievement milestone
  target separate from the configured event cap.
- **CG-007 — Automatic recovery.** Retry failed API reads. Do not provide a manual-score
  entry path. Preserve the distinction between a transient error and a historical value
  that cannot be reconstructed by another current read.
- **CG-008 — Base requirement.** Each eligible account owes 10% of the event's account
  cap for a full event: 400 points when the cap is 4,000.
- **CG-009 — Presence proration.** Prorate each account's requirement by its supported
  time in any tracked clan during the event. Union its presence across tracked clans,
  so clan hopping inside the tracked family does not count time twice.
- **CG-010 — Member aggregation.** Combine the eligible points and unrounded account
  requirements for one Discord member across all tracked clans. Do not assess each of
  that member's clans independently.
- **CG-011 — Rounding.** After summing the member's unrounded requirements, round the
  combined target upward to the next multiple of 10. Do not round each account first.
- **CG-012 — Checkpoints.** Evaluate 24 hours before the event ends and again after it
  ends. At T−24h, use only presence time already spent; do not project the final day.
- **CG-013 — Attribution.** Apply first-ever-link backfill and same-profile continuity,
  including an unlinked gap with no intervening different owner. A different-owner
  transfer starts fresh and splits earned points and the requirement at its effective
  boundary. A self-unlinked account keeps counting toward its former owner's target and
  points until a different owner links it (DEC-01, 2026-11-14).
- **CG-014 — Transfer gate.** A mid-event transfer waits for a successful points refresh
  before becoming effective. Record approval and waiting separately from the effective
  ownership change. Do not time-prorate earned points to fill a missing boundary.
- **CG-015 — Evidence outcomes.** Produce pass/fail only when the needed evidence is
  adequate. Otherwise record insufficient_data. Missing observations are not zero
  points and are not an automatic failure.
- **CG-016 — No exemptions.** Leadership cannot exempt a member from the points
  requirement for a particular event.
- **CG-017 — Own-account refresh.** Any member may request an API refresh only for their
  currently linked accounts. No broader staff refresh override has been agreed.
- **CG-018 — Public data.** Members can view account points and clan totals through bot
  commands and automatic posts in a shared, configurable activity channel for all clans.
  That channel initially also carries Raid Weekend activity.
- **CG-019 — Private assessments.** Explicit member pass/fail results are visible to the
  configured Leadership audience. Final tracking results are published to the
  configured clan-logs channel under its existing leadership-only category.
- **CG-020 — Retention and audit.** Retain source evidence and assessment history
  indefinitely. Record rule inputs, evidence, calculation versions, inference status,
  retries, and later supported recalculations without silently replacing old results.
  Each revision of a public points report records, for every account it shows, the
  exact points observation it published (DEC-16, 2026-11-14), so an old revision can
  be rendered again without newer progress.

## Calculation rules

For account i at checkpoint t:

~~~text
account_target_i(t) =
    0.10 × event_account_cap
        × eligible_observed_presence_seconds_i(t)
        ÷ full_event_duration_seconds

member_unrounded_target(t) = sum(account_target_i(t) attributed to this member)
member_target(t) = 10 × ceil(member_unrounded_target(t) ÷ 10)
~~~

Clip presence to the event, checkpoint, and applicable member-attribution boundaries.
Union overlapping tracked-clan intervals per account before calculating its duration.
At T−24h, the checkpoint is the elapsed-time cutoff, not the future event end.

Sum eligible earned points independently. Do not apply the target's time-proration
formula to points. Point deltas spanning a transfer require supported boundary evidence,
not a proportional allocation.

## Logical data and evidence needs

Retain the configured event identity, dates and cap; cumulative account counter
observations; observation and ingestion times; source freshness information where it
exists; membership evidence and gaps; inferred participating clan and its basis; link
and attribution boundaries; and versioned account inputs and combined member results.

Keep the first event baseline, normal polls, T−24h, final, and transfer reads
distinguishable. Record which observations support a delta, rather than treating the
latest cumulative total as the event score.

A measured zero difference from valid baseline and ending reads establishes
zero contribution even without the positive increase needed for clan inference.
Missing reads or unsupported boundaries do not establish zero. This distinction
allows evidence-backed inactivity assessment without inventing affiliation.

A successful current API response does not prove the exact time at which points changed.
The available profile supplies neither an event-specific point ledger nor an explicit
participating-clan field. Inference is accepted only under CG-003; it is not an API claim.

A retry can recover current progress when a valid earlier baseline exists. A later
final read may support the final counter before another event contributes. A retry
cannot necessarily reconstruct an already missed baseline, T−24h value, or past transfer
boundary. Such gaps retain insufficient_data unless supported evidence resolves them.

## Visibility and audit

| Output or action | Required access |
| --- | --- |
| Account points and clan totals | Members |
| Current-event progress command | Members, excluding private assessments |
| Manual API refresh | Requester's own linked accounts |
| Explicit pass/fail assessments | Configured Leadership audience |
| Final clan-logs publication | Existing leadership-category channel visibility |
| Schedule/cap configuration and manual event creation | Authorized configuration actors |
| Configuration audit history | Developers only |

Use Discord channel/category permissions for channel visibility. Do not publish private
pass/fail labels through the shared public activity channel, leaderboards, or a general
audit response. Configuration-audit access remains distinct from event-report access.

## Acceptance scenarios

1. Three accounts are eligible for a full event with a 4,000-point cap. Their owner's
    unrounded combined requirement is 1,200. Points can combine across those accounts
    and across tracked clans.
2. Two account requirements are 13.2 points each. The combined requirement is 26.4,
    rounded once to 30, not separately to 20 plus 20.
3. An account spends half the configured event in tracked clans. Its unrounded
    requirement is half the base target. Time in two tracked clans is counted once.
4. In a configured six-day event, an account present for the first five days is
    assessed at T−24h using five-sixths of the full-event requirement, then included
    in the member-level rounding. The final day is not projected.
5. Observations remain in the same tracked clan from event start through the first
    observed increase. The bot records inferred participation and the supporting
    observations. Ambiguous movement before that increase yields insufficient_data.
6. A captured baseline counter is 200,000 and a supported later counter is 200,600.
    The evidence supports a 600-point difference, subject to event, clan, and owner
    attribution. Neither 200,600 nor the achievement milestone is the event score.
7. The baseline was never captured and the API later returns a cumulative total.
    The bot stores the observation and retries as appropriate, but does not invent
    a baseline or accept a manually entered score.
8. A routine API call fails after a valid baseline. A later successful read can
    recover supported accumulated progress without counting the failed call as zero.
9. Staff approve a mid-event ownership transfer while the point read is failing.
    The transfer waits. When it becomes effective after a successful read, retain
    the boundary evidence and split attribution without moving earlier results.
10. A member refreshes their linked account and another member attempts the same
    account. The own-account request is allowed; the other request is rejected.
11. Members can see points in the shared activity channel, but explicit pass/fail
    results are available only through the authorized leadership output.

## Dependencies

- [Account linking and attribution](account-linking-and-attribution.md): historical
  backfill, gap continuity, approval, and effective transfer boundaries.
- [Membership and role automation](membership-and-role-automation.md): observed
  presence, movements, missing intervals, and the separate membership cadence.
- [Configuration and access](configuration-and-access.md): PostgreSQL settings,
  event configuration, role bindings, and audit permissions.
- [API evidence](api-evidence.md): achievement fields, absent event affiliation,
  source freshness, and collection limitations.
- [Notifications and delivery](notifications-and-delivery.md): checkpoint reports,
  recurring message updates, retry state, and delivery outcomes.
- [Raid Weekends](raid-weekends.md): initially shared public activity channel.
- [Leaderboards](leaderboards.md): account-level ranking views, distinct from the
  member-level activity assessment.

## Suggested future issue workstreams

These are planning workstreams, not created GitHub issues:

- Configured event lifecycle and duplicate-safe automatic/manual event creation.
- Active-event profile collector, checkpoint reads, API retries, and evidence gaps.
- Participating-clan inference and membership/ownership attribution evidence.
- Unrounded account targets, combined rounding, versioned member assessments.
- Own-account refresh commands and public/private reporting.

## Open and deferred points

- Retry/backoff limits, recovery after a missed checkpoint window (the T−24h early
  window is decided under CG-005), and acceptable source freshness.
- Handling counter regressions or corrections without inventing negative points.
- Evidence for accounts first observed after event start or whose participating clan
  cannot satisfy the accepted inference rule.
- Presentation and operational recovery for insufficient_data, including late evidence
  and already published assessment revisions.
- The precise relation between an API observation and the recorded effective transfer
  timestamp when the source supplies no counter-update time.

These are evidence and operational details. The 15-minute configurable cadence,
separate boundary reads, transfer wait, no-manual-score rule, attribution policies,
elapsed-time T−24h target, and member-level rounding are already decided.
