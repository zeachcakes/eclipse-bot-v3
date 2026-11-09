# CoC API evidence reference

Status: reference for feature planning, not a complete or independently validated
live API contract. Sources are a user-supplied Postman collection and selected player,
individual-war, and league-group response snapshots. Raw uploads, authentication
material, real player/clan identifiers, and personal names are not included.

The official documentation/API hosts previously returned proxy CONNECT 403 errors from
the execution environment. That establishes a local reachability limitation, not that
the documentation is unavailable to everyone or that an endpoint is absent. The fields
below were inspected offline from the supplied files. No embedded collection scripts
were executed, and these samples were not fetched by authenticated calls in this
environment.

## Evidence sources

| Reference | Source | What it establishes |
| --- | --- | --- |
| EVID-001 | Uploaded Postman collection | 32 routes and generated response examples |
| EVID-002 | Player-profile snapshot | Games Champion total, milestone, and profile fields |
| EVID-003 | Individual-war snapshot | Daily roster/attack fields, timing, and positions |
| EVID-004 | CWL league-group snapshot | Season, registered rosters, and round references |

Single snapshots establish observed fields and values, not every allowable enum,
mandatory field, historical retention rule, or freshness guarantee.

## Collection coverage

The offline collection contains these 32 request paths:

~~~text
GET  /warleagues/:leagueId
GET  /warleagues
POST /players/:playerTag/verifytoken
GET  /players/:playerTag
GET  /locations/:locationId/rankings/players-versus
GET  /locations/:locationId/rankings/players-builder-base
GET  /locations/:locationId/rankings/players
GET  /locations/:locationId/rankings/clans-versus
GET  /locations/:locationId/rankings/clans-builder-base
GET  /locations/:locationId/rankings/clans
GET  /locations/:locationId/rankings/capitals
GET  /locations/:locationId
GET  /locations
GET  /leagues/:leagueId/seasons/:seasonId
GET  /leagues/:leagueId/seasons
GET  /leagues/:leagueId
GET  /leagues
GET  /labels/players
GET  /labels/clans
GET  /goldpass/seasons/current
GET  /clanwarleagues/wars/:warTag
GET  /clans/:clanTag/warlog
GET  /clans/:clanTag/members
GET  /clans/:clanTag/currentwar/leaguegroup
GET  /clans/:clanTag/currentwar
GET  /clans/:clanTag/capitalraidseasons
GET  /clans/:clanTag
GET  /clans
GET  /capitalleagues/:leagueId
GET  /capitalleagues
GET  /builderbaseleagues/:leagueId
GET  /builderbaseleagues
~~~

This is the collection's inventory, not a claim that every route is current. It
includes legacy versus-related paths. Some example numeric fields are string
placeholders, and some name fields are empty objects; these are not live wire-type
evidence.

## Clan Games counter

The player-profile source contains this selected achievement excerpt:

~~~json
{
  "name": "Games Champion",
  "stars": 3,
  "value": 237655,
  "target": 100000,
  "info": "Earn 100000 points in Clan Games",
  "completionInfo": "Total Clan Games points: 237655",
  "village": "home"
}
~~~

The accepted interpretation is a cumulative Clan Games achievement total. The 100,000
target is an achievement milestone, not a per-event contribution cap. Keep event caps,
such as 4,000, in the configured event information.

The collection's generic achievement example is at
$.item[1].item[0].item[1].response[0].body after parsing the body string
(collection line 1305). It does not name Games Champion. The actual profile snapshot
provides that specific evidence at $.achievements[31], around lines 336–342.
Array position is not an achievement identity.

Neither source provides an explicit Clan Games event identifier, event-point ledger,
locked participating clan, counter-update timestamp, or historical counter series.
The profile's clan object is not a Clan Games affiliation record. The player's
Clan Games label is also not participation evidence.

The collection has no dedicated Clan Games score or calendar request. The startTime
and endTime fields in /goldpass/seasons/current concern Gold Pass, not Clan Games.
This does not establish universal absence from the current live API.

Supported collection design uses timestamped counter observations and adequately
supported differences. A missed baseline or historical point boundary cannot
necessarily be recovered by another current read. The accepted inference and retry
rules are specified in [Clan Games](clan-games.md); manually entered scores are excluded.

## Clan membership and movement

The collection exposes current-state inputs:

- /players/:playerTag returns a clan object with tag, name, clanLevel, and badgeUrls.
- /clans/:clanTag/members lists members.
- /clans/:clanTag includes memberList.

No collection request or success example provides a clan movement timeline, historical
join/leave events, join/leave timestamps, or a membership-change webhook.
previousClanRank is paired with clanRank as a ranking field; it is not a previous
clan identifier or a movement record.

Build observed movement history by comparing complete membership snapshots. Store
observed boundaries and gaps rather than claiming exact game join/leave times.
A movement entirely between polls can be missed. A war roster or raid participant
list is not a complete membership timeline.

Relevant collection locations are $.item[7].item[0].item[1].item[0] for member lists
(line 9551), $.item[7].item[0].item[4] for a clan (line 11208), and
$.item[7].item[0].item[0].item[0] for the war log (line 9070).

## Individual war evidence

The supplied war snapshot contains this selected, non-identifying excerpt:

~~~json
{
  "state": "warEnded",
  "teamSize": 30,
  "preparationStartTime": "20261102T164714.000Z",
  "startTime": "20261103T164657.000Z",
  "endTime": "20261104T171254.000Z",
  "warStartTime": "20261103T164657.000Z"
}
~~~

The observed start/end difference is 87,957 seconds: 24 hours, 25 minutes,
57 seconds. Do not impose an exact 24-hour duration or replace supplied boundaries
with calculated defaults.

Both sides contain 30 daily participants, but the maximum observed mapPosition is
34. Roster positions must not be assumed to form the contiguous range 1..teamSize.

War members contain tag, name, mapPosition, townhallLevel, opponentAttacks,
bestOpponentAttack, and attacks. Attack records contain attackerTag, defenderTag,
order, stars, destructionPercentage, and duration.

Important distinctions:

- War roster townhallLevel uses a lowercase h. The profile and CWL group use
  townHallLevel. Preserve correct source mapping.
- Attack duration is elapsed attack length, not its occurrence timestamp.
- The source attack records have no attack timestamp.
- The supplied body has no top-level warTag and no attacksPerMember field.
  Retain request context rather than inventing those response fields or silently
  applying a regular-war attack allowance to a CWL war.
- warStartTime duplicates startTime in this snapshot; one example does not prove it
  is always present or always an interchangeable alias.
- Names, current TH levels, and present clan membership cannot replace the roster
  values recorded for an earlier war.

## CWL league-group evidence

The group source contains state, season, clans, and rounds. Its observed season value
is exactly "2026-11-02". Treat that as the source identifier; do not truncate it to
YYYY-MM because another example or assumed contract uses a shorter format.

The source has eight clans and seven rounds, each with four war references in warTags.
Registered clan members contain name, tag, and townHallLevel, not a daily attack log
or daily map positions.

For the clan matching one side of the supplied individual war, the group contains
45 registered members while the daily war has 30 participants. The other side has
39 registered members and 30 daily participants. Registration and daily participation
are different facts; do not use the entire registered roster as the daily lineup.

The collection's individual-CWL-war example is internally inconsistent:
$.item[6].item[0].item[0].item[0] describes
/clanwarleagues/wars/:warTag but its example contains league-group fields such as
clans, rounds, and season. The actual supplied individual-war snapshot is a distinct
shape. Do not generate a final client or model solely from that mismatched example.

Round warTags provide request references for individual wars. Preserve those references
and the response's own context separately, especially when the response omits warTag.
An unavailable round/war value is not itself an observed empty roster.

## Other relevant distinctions

- Verification uses /players/:playerTag/verifytoken. The example response includes
  status and an echoed token. Store the result without retaining either supplied or
  echoed secret material.
- Raid-member capitalResourcesLooted is the relevant earned-gold field for the
  requested Raid Weekend report. Profile clanCapitalContributions concerns
  contributions and is not the same measure.
- Profile warStars is the selected source for the all-time war-star leaderboard.
  Repeated cumulative snapshots must not be summed across time.
- The collection's array examples and earlier generic pagination descriptions
  need validation against actual endpoint responses. Preserve full-page completion
  evidence before inferring departures from a roster.

## Use in feature work

- [Account linking and attribution](account-linking-and-attribution.md): secret-free
  verification and supported transfer boundaries.
- [Clan Games](clan-games.md): cumulative-counter observations, accepted affiliation
  inference, checkpoint retries, and insufficient_data.
- [Membership and role automation](membership-and-role-automation.md): observed
  movement and current-role reconciliation.
- [Regular wars](regular-wars.md): roster/attack history and source-time limitations.
- [Clan War Leagues](clan-war-leagues.md): group registration versus daily lineups.
- [Raid Weekends](raid-weekends.md): earned gold versus contribution counters.
- [Leaderboards](leaderboards.md): account identity, score provenance, and baselines.

Future validation should exercise representative live responses through authorized,
sanitized fixtures and preserve source provenance. It must not copy raw user uploads,
credentials, real identities, or misleading generated examples into tracked fixtures.
