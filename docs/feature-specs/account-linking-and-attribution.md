# Account linking and metric attribution

Status: agreed target requirements. This is a feature specification, not a claim that all
commands, collection jobs, or workflows are implemented. It includes follow-up decisions
that supersede open points in the earlier
[working plan](../design/star-schema-working-plan.md).

## Scope

Associate Discord identities with Clash of Clans accounts, verify control of an account,
manage primary/alt designations, preserve link history, and determine whose member metrics
an account's activity contributes to. Source game activity remains attached to the Clash
account independently of whether it is linked to Discord.

This feature does not define the Clan Games assessment formula, role delivery, command
wording, or a final physical database model.

## Requirements

- **LINK-001 — Multiple accounts, one current owner.** A Discord member may link multiple
  Clash accounts. A Clash account may be linked to only one Discord identity at a time.
- **LINK-002 — Primary and alts.** A member with linked accounts has at most one primary
  account; the remaining linked accounts are alts. If the member unlinks their primary
  while alts remain, they must choose a replacement. No replacement is chosen
  automatically. When an approved transfer takes a member's primary while alts remain,
  the transfer completes and the member has no primary until they choose one of their
  remaining accounts (DEC-02, 2026-11-14). Nobody else chooses it for them.
- **LINK-003 — Initial eligibility.** A newly linked account must belong to a tracked
  clan. Later departure from every tracked clan does not automatically unlink it.
- **LINK-004 — Verification.** Verify the player using their in-game API token. Store the
  verification result and supporting non-secret metadata, never the supplied token or
  a token echoed by the API. Tokens must not enter logs, audit payloads, queued work, or
  archived request/response bodies.
- **LINK-005 — Transfers.** Linking an account that is currently linked to another
  Discord member requires successful verification and approval from a configured
  Co-leader or Admin. Developer allowlist membership alone grants neither approval nor
  account-link-history access.
- **LINK-006 — Self-unlinking.** A member may unlink their own accounts without staff
  approval, subject to the primary-replacement rule.
- **LINK-007 — Discord departures.** Account links remain when a member leaves the
  Discord server, so returning to the same Discord identity does not erase them.
- **LINK-008 — Source collection.** Collect and retain activity for accounts in tracked
  clans even when those accounts have never linked to Discord or are currently unlinked.
- **LINK-009 — First-ever link.** If an account has no previous Discord-link history,
  its already collected historical statistics count for the first linked member.
  Backfill must use available evidence; it does not manufacture missing observations.
- **LINK-010 — Same-profile continuity.** If an account is unlinked and later relinked to
  the same Discord profile, with no different owner in between, its member metrics
  continue. Activity collected during that unlinked gap also counts.
  While the account stays unlinked, its activity and Clan Games requirement keep
  counting for the former owner until a different Discord identity links it
  (DEC-01, 2026-11-14). That later link starts a fresh period under LINK-011.
- **LINK-011 — Different-profile fresh start.** Linking to a different Discord identity
  starts a fresh member-attribution period. Earlier activity remains attributed to the
  earlier member and is not rewritten or moved to the new member.
- **LINK-012 — Returning after another owner.** A previous owner who relinks after a
  different Discord profile owned the link starts a new attribution period; the older
  period is not reopened.
- **LINK-013 — Effective transfer boundary.** A direct mid-event Clan Games transfer
  splits earned points and the prorated requirement at the link-effective boundary.
  Earned points are not divided in proportion to elapsed time.
- **LINK-014 — Transfer evidence gate.** During Clan Games, an approved transfer waits
  for a successful points refresh before becoming effective. API failure leads to
  retries, not a guessed split or a manually entered score. The current link does not
  change merely because approval has been recorded.
- **LINK-015 — Public current links.** Everyone may view a member's currently linked
  accounts and which account is primary.
- **LINK-016 — Private history.** Only configured Co-leader and Admin roles may view
  account-link history. Public current-link views must not reveal previous owners.
- **LINK-017 — Retention and audit.** Preserve historical links and source activity
  indefinitely. Audit verification outcomes, requests, approvals, rejections, primary
  changes, effective transfers, unlinking, and failures without retaining secrets.

## Logical data and evidence needs

Keep stable Discord and Clash account identities separate from mutable names and server
membership. The evidence must distinguish actual link intervals, primary designations,
verification results, transfer requests and decisions, effective changes, and metric
continuity across multiple link intervals.

Actual link time alone cannot express both first-ever historical backfill and an
unlinked gap that later belongs to the same member. Preserve attribution continuity
explicitly without changing the account identity on the underlying game observations.

A transfer needs its source link, verified recipient, approver, decision time, waiting
state, successful boundary-read evidence, and effective time. A stale approval must not
silently transfer a newly changed source link. Record collection time separately from
any source time that is actually available.

A successful API read supplies an observation; it does not prove the exact game time at
which points changed. Preserve the observed counter, response provenance, and freshness
uncertainty. The accepted transfer gate must not be described as a timestamped attack
or point-event feed.

## Visibility and audit

| Information or action | Required access |
| --- | --- |
| Current links and primary designation | Public |
| Self-unlink and primary replacement | The member who owns those links |
| Approval of an account currently linked to another member | Co-leader or Admin |
| Link history | Co-leader or Admin |
| Configuration and developer allowlist | See configuration and access |

Use current confirmed permissions for commands. A historical role assignment is audit
evidence, not continuing authority. A general audit viewer or bot log must not bypass
the private link-history rule.

## Acceptance scenarios

1. An unlinked account has supported activity collected from time A. Its first-ever
    Discord link occurs at time B. The first member receives supported historical
    statistics from before B, and the original observations remain unchanged.
2. A member unlinks an account, which remains in a tracked clan. Collection continues.
    When the same profile relinks it without another owner intervening, the gap activity
    and earlier member metrics remain continuous.
3. Member A unlinks an account, Member B later links it, and A subsequently returns.
    B and the returning A each start fresh attribution periods. Neither receives the
    other person's historical member results.
4. A member attempts to unlink their primary while another linked account remains.
    The operation requires their replacement choice and does not leave an invalid
    intermediate primary state visible as a completed operation.
4a. Staff approve a transfer of member A's primary while A keeps two alts and has left
    Discord. The transfer completes; A has no primary, both alts stay linked, and
    current-link views show no primary for A until A chooses one.
4b. A member unlinks an alt during Clan Games and nobody links it before the final
    checkpoint. The account's points and prorated requirement still count toward that
    member's assessment.
5. A recipient verifies a currently owned account but has no staff approval. The bot
    does not transfer it. An ordinary member cannot approve that request.
6. Staff approve a transfer during Clan Games, but the required API read fails. The
    request remains waiting for evidence and the effective link is unchanged. A later
    successful read allows the transfer boundary to be recorded without manual scores.
7. A linked account leaves all tracked clans, or its owner leaves Discord. Existing
    links and retained history survive; role reconciliation is handled separately.
8. A member or developer without Co-leader/Admin access can view public current links
    but cannot use account history or aggregate audits to discover earlier owners.

## Dependencies

- [Configuration and access](configuration-and-access.md): stable role bindings,
  developer permissions, and audit visibility.
- [Membership and role automation](membership-and-role-automation.md): tracked-clan
  evidence, onboarding, and roles derived from all linked accounts.
- [Clan Games](clan-games.md): point evidence, transfer checkpoints, attribution, and
  assessment requirements.
- [API evidence](api-evidence.md): supported response fields and observation limits.
- [Chat XP and ranks](chat-xp-and-ranks.md): separate Discord progress preserved on rejoin.
- [Notifications and delivery](notifications-and-delivery.md): eventual command feedback
  and delivery behavior, without treating a requested action as completed.

## Suggested future issue workstreams

These are planning workstreams, not created GitHub issues:

- Verification ingestion and secret-free command handling.
- Link, unlink, primary-selection, and approved-transfer command flows.
- Attribution continuity, historical backfill, and boundary evidence.
- Authorized current-link/history views and audit coverage.
- Retryable transfer checkpoints with ownership revalidation and acceptance fixtures.

## Open and deferred points

- The expiry/cancellation rules and user feedback for stale or waiting transfer requests.
- The permitted age and revalidation policy for verification evidence.
- How API freshness and the successful boundary observation relate to the recorded
  effective time, without claiming unavailable source occurrence timestamps.
- Presentation of statistics while an account remains unlinked. Attribution is decided:
  they count for the former owner until a different owner links the account (DEC-01).
- How a member without a primary (LINK-002, DEC-02) is prompted to choose one.

These points do not reopen first-link backfill, same-owner gap counting, different-owner
fresh starts, or the successful-refresh gate.
