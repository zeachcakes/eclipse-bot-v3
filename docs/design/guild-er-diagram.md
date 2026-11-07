# Guild entity-relationship diagrams

GitHub renders these Mermaid diagrams directly. They reflect all nine current
SQL migrations and were checked against the migrated PostgreSQL 18 catalog.

This page covers **56 persisted tables and 127 foreign keys** in the
`guild` schema. Tables appear once as domain-owned entities; shared parents
reappear as key-only anchors in other diagrams. Flyway history, views, routines,
and triggers are excluded from the physical ER diagrams.

The diagrams show every primary/foreign key and selected business columns.
Composite unique columns are also retained to make fact grains visible.
SQL remains authoritative for all columns, checks, permissions, temporal
exclusions, and conditional uniqueness.

- [SQL migrations](../../services/guild/schema/src/main/resources/db/migration)
- [Schema setup and behavior](../../services/guild/schema/README.md)
- [Requirements and star-schema plan](star-schema-working-plan.md)

## Reading the diagrams

- PK means primary key; FK means foreign key; UK marks a single-column unique constraint.
- A bar pair means exactly one; a circle/bar means zero or one; a circle/crow foot means zero or more.
- Solid lines identify relationships whose FK columns are contained in the child primary key; other lines are dashed.
- Each line represents one declared FK, labeled by its role or a source key. Composite relationships are marked; the reference below lists every component.
- An optional composite MATCH SIMPLE FK is unenforced when any component is null.
- Generated constant verification-status columns are treated as non-null for relationship cardinality.
- Temporal and trigger rules can impose additional conditions beyond the FK notation. In particular, historical account links remain many-to-one even though only one may be active.

## Domains

| Diagram | Domain-owned tables |
| --- | ---: |
| [Shared dimensions](#shared-dimensions) | 7 |
| [Configuration and role mappings](#configuration-and-role-mappings) | 9 |
| [Account links and attribution](#account-links-and-attribution) | 4 |
| [Clan membership evidence](#clan-membership-evidence) | 4 |
| [Regular wars](#regular-wars) | 6 |
| [Player profiles and raids](#player-profiles-and-raids) | 5 |
| [Clan Games](#clan-games) | 5 |
| [Discord presence, roles, and chat XP](#discord-presence-roles-and-chat-xp) | 7 |
| [Warnings and moderation](#warnings-and-moderation) | 5 |
| [Audit, collection, and delivery](#audit-collection-and-delivery) | 4 |

## Shared dimensions

Stable Discord and CoC identities are shared by the activity stars. The date dimension is an optional calendar lookup; no current table declares a foreign key to it.

```mermaid
erDiagram
    direction LR

    dim_guild {
        bigint guild_key PK
        discord_snowflake discord_guild_id UK
        text guild_name "nullable"
        boolean singleton UK
    }

    dim_discord_user {
        bigint user_key PK
        discord_snowflake discord_user_id UK
        text display_name "nullable"
    }

    dim_player_account {
        bigint player_key PK
        text player_tag UK
        text player_name "nullable"
    }

    dim_clan {
        bigint clan_key PK
        text clan_tag UK
        text clan_name "nullable"
    }

    dim_discord_role {
        bigint role_key PK
        bigint guild_key FK
        discord_snowflake discord_role_id UK
        text role_name
        timestamptz deleted_at "nullable"
    }

    dim_discord_channel {
        bigint channel_key PK
        bigint guild_key FK
        discord_snowflake discord_channel_id UK
        text channel_name
        timestamptz deleted_at "nullable"
    }

    dim_date {
        date date_key PK
        integer year_number "generated"
        integer month_number "generated"
        integer day_number "generated"
        integer iso_weekday "generated"
    }

    dim_guild ||..o{ dim_discord_channel : "guild_key"
    dim_guild ||..o{ dim_discord_role : "guild_key"
```

## Configuration and role mappings

Configuration bindings give Discord IDs a purpose. Role names are display labels. Channel visibility is controlled by Discord; these bindings do not duplicate category ACLs.

```mermaid
erDiagram
    direction LR

    guild_settings {
        bigint guild_key PK, FK
        integer new_joinee_days
        timestamptz updated_at
        text chat_xp_policy_key FK
    }

    server_role_binding {
        bigint guild_key PK, FK
        text purpose PK
        bigint role_key FK
    }

    clan_role_binding {
        bigint guild_key PK, FK
        bigint clan_key PK, FK
        text purpose PK
        bigint role_key FK
    }

    town_hall_role_binding {
        bigint guild_key PK, FK
        smallint town_hall_level PK
        bigint role_key FK
    }

    channel_binding {
        bigint binding_key PK
        bigint guild_key FK
        text purpose
        bigint clan_key FK "nullable"
        bigint channel_key FK
    }

    developer_allowlist {
        bigint guild_key PK, FK
        bigint user_key PK, FK
        timestamptz added_at
        bigint added_by FK "nullable"
    }

    clan_collection_settings {
        bigint guild_key PK, FK
        bigint clan_key PK, FK
        boolean enabled
        integer membership_poll_seconds
        integer raid_report_seconds
    }

    war_reminder_setting {
        bigint guild_key PK, FK
        bigint clan_key PK, FK
        integer seconds_before_end PK
    }

    clan_games_schedule {
        bigint guild_key PK, FK
        boolean enabled
        smallint start_day
        time start_time_utc
        integer event_seconds
    }

    chat_xp_policy {
        text policy_key PK
    }

    dim_clan {
        bigint clan_key PK
    }

    dim_discord_channel {
        bigint channel_key PK
    }

    dim_discord_role {
        bigint role_key PK
    }

    dim_discord_user {
        bigint user_key PK
    }

    dim_guild {
        bigint guild_key PK
    }

    dim_clan |o..o{ channel_binding : "clan_key"
    dim_discord_channel ||..o{ channel_binding : "channel_key (composite)"
    dim_guild ||..o{ channel_binding : "guild_key"
    dim_clan ||--o{ clan_collection_settings : "clan_key"
    dim_guild ||--o{ clan_collection_settings : "guild_key"
    dim_guild ||--o| clan_games_schedule : "guild_key"
    dim_clan ||--o{ clan_role_binding : "clan_key"
    dim_guild ||--o{ clan_role_binding : "guild_key"
    dim_discord_role ||..o{ clan_role_binding : "role_key (composite)"
    dim_discord_user |o..o{ developer_allowlist : "added_by"
    dim_guild ||--o{ developer_allowlist : "guild_key"
    dim_discord_user ||--o{ developer_allowlist : "user_key"
    chat_xp_policy ||..o{ guild_settings : "chat_xp_policy_key"
    dim_guild ||--o| guild_settings : "guild_key"
    dim_guild ||--o{ server_role_binding : "guild_key"
    dim_discord_role ||..o{ server_role_binding : "role_key (composite)"
    dim_guild ||--o{ town_hall_role_binding : "guild_key"
    dim_discord_role ||..o{ town_hall_role_binding : "role_key (composite)"
    clan_collection_settings ||--o{ war_reminder_setting : "clan_key (composite)"
```

## Account links and attribution

Account links describe actual historical ownership intervals. Attribution episodes separately support first-link backfill, same-member continuity, and fresh attribution after transfers. One current owner and one primary are additional temporal/partial-index constraints, not one-to-one cardinalities for the entire history. Verification tokens are not stored.

```mermaid
erDiagram
    direction LR

    player_verification {
        bigint verification_key PK
        bigint guild_key FK
        bigint user_key FK
        bigint player_key FK
        text status
        timestamptz checked_at
        uuid source_request_id UK
        bigint source_fetch_key FK "nullable"
    }

    metric_attribution_episode {
        bigint attribution_key PK
        bigint guild_key FK
        bigint user_key FK
        bigint player_key FK
        timestamptz first_link_at
        timestamptz closed_at "nullable"
        boolean include_prelink_history
    }

    account_link {
        bigint link_key PK
        bigint guild_key FK
        bigint user_key FK
        bigint player_key FK
        bigint verification_key FK, UK
        text verification_status FK "generated"
        bigint attribution_key FK
        timestamptz linked_at
        timestamptz unlinked_at "nullable"
        boolean is_primary
        bigint transfer_request_key FK "nullable"
    }

    account_transfer_request {
        bigint transfer_request_key PK
        bigint guild_key FK
        bigint player_key FK
        bigint from_user_key FK
        bigint to_user_key FK
        bigint source_link_key FK
        bigint verification_key FK
        text verification_status FK "generated"
        timestamptz requested_at
        text status
        bigint decided_by FK "nullable"
        timestamptz decided_at "nullable"
        timestamptz consumed_at "nullable"
    }

    dim_discord_user {
        bigint user_key PK
    }

    dim_guild {
        bigint guild_key PK
    }

    dim_player_account {
        bigint player_key PK
    }

    fact_api_fetch_attempt {
        bigint fetch_key PK
    }

    metric_attribution_episode ||..o{ account_link : "attribution_key (composite)"
    dim_guild ||..o{ account_link : "guild_key"
    dim_player_account ||..o{ account_link : "player_key"
    account_transfer_request |o..o| account_link : "transfer_request_key (composite)"
    dim_discord_user ||..o{ account_link : "user_key"
    player_verification ||..o| account_link : "verification_key (composite)"
    dim_discord_user |o..o{ account_transfer_request : "decided_by"
    dim_discord_user ||..o{ account_transfer_request : "from_user_key"
    dim_guild ||..o{ account_transfer_request : "guild_key"
    dim_player_account ||..o{ account_transfer_request : "player_key"
    account_link ||..o{ account_transfer_request : "source_link_key (composite)"
    dim_discord_user ||..o{ account_transfer_request : "to_user_key"
    player_verification ||..o{ account_transfer_request : "verification_key (composite)"
    dim_guild ||..o{ metric_attribution_episode : "guild_key"
    dim_player_account ||..o{ metric_attribution_episode : "player_key"
    dim_discord_user ||..o{ metric_attribution_episode : "user_key"
    dim_guild ||..o{ player_verification : "guild_key"
    dim_player_account ||..o{ player_verification : "player_key"
    fact_api_fetch_attempt |o..o{ player_verification : "source_fetch_key"
    dim_discord_user ||..o{ player_verification : "user_key"
```

## Clan membership evidence

Only complete polls can support membership changes. Closing an observed period also requires a matching successful departure fact through a trigger; there is no additional physical foreign key for that proof. Observed time is not an exact in-game join/leave timestamp.

```mermaid
erDiagram
    direction LR

    clan_membership_poll {
        bigint poll_key PK
        bigint guild_key FK
        bigint clan_key FK
        text source_correlation_id UK
        timestamptz observed_at
        text outcome
    }

    fact_clan_member_observation {
        bigint poll_key PK, FK
        bigint player_key PK, FK
        text in_game_role "nullable"
    }

    fact_clan_membership_change {
        bigint membership_change_key PK
        bigint poll_key FK
        bigint guild_key FK
        bigint clan_key FK
        bigint player_key FK
        text change_kind
        timestamptz previous_success_at "nullable"
        timestamptz observed_at
    }

    observed_clan_membership_period {
        bigint membership_period_key PK
        bigint guild_key FK
        bigint player_key FK
        bigint clan_key FK
        timestamptz observed_since
        timestamptz observed_until "nullable"
        timestamptz confirmed_through
        text coverage_status
        bigint first_poll_key FK
        bigint last_poll_key FK
    }

    clan_collection_settings {
        bigint guild_key PK
        bigint clan_key PK
    }

    dim_player_account {
        bigint player_key PK
    }

    clan_collection_settings ||..o{ clan_membership_poll : "clan_key (composite)"
    dim_player_account ||--o{ fact_clan_member_observation : "player_key"
    clan_membership_poll ||--o{ fact_clan_member_observation : "poll_key"
    dim_player_account ||..o{ fact_clan_membership_change : "player_key"
    clan_membership_poll ||..o{ fact_clan_membership_change : "poll_key (composite)"
    clan_membership_poll ||..o{ observed_clan_membership_period : "first_poll_key (composite)"
    clan_membership_poll ||..o{ observed_clan_membership_period : "last_poll_key (composite)"
    clan_collection_settings ||..o{ observed_clan_membership_period : "clan_key (composite)"
    dim_player_account ||..o{ observed_clan_membership_period : "player_key"
```

## Regular wars

Clan A/B and attacker/defender are role-playing references to the same dimensions. Roster observations retain historical TH levels. Attack duration is not an occurrence timestamp; attacks are deduplicated by war and attack order.

```mermaid
erDiagram
    direction LR

    dim_war {
        bigint war_key PK
        bigint clan_a_key FK
        bigint clan_b_key FK
        timestamptz preparation_started_at
        timestamptz started_at
        timestamptz ends_at
        smallint team_size
        smallint attacks_per_member
    }

    fact_war_observation {
        bigint war_key PK, FK
        timestamptz observed_at PK
    }

    war_participant {
        bigint war_key PK, FK
        bigint clan_key FK
        bigint player_key PK, FK
    }

    fact_war_roster_observation {
        bigint war_key PK, FK
        bigint clan_key FK
        bigint player_key PK, FK
        timestamptz observed_at PK
        smallint town_hall_level
        smallint map_position
        smallint opponent_attacks "nullable"
    }

    fact_war_clan_observation {
        bigint war_key PK, FK
        bigint clan_key PK, FK
        timestamptz observed_at PK
        text state
        integer stars
        integer attacks
        numeric destruction_percentage
    }

    fact_war_attack {
        bigint attack_key PK
        bigint war_key FK
        bigint attacker_key FK
        bigint defender_key FK
        integer attack_order
        smallint stars
        numeric destruction_percentage
        integer duration_seconds "nullable"
        timestamptz occurred_at "nullable"
    }

    dim_clan {
        bigint clan_key PK
    }

    dim_player_account {
        bigint player_key PK
    }

    dim_clan ||..o{ dim_war : "clan_a_key"
    dim_clan ||..o{ dim_war : "clan_b_key"
    dim_player_account ||..o{ fact_war_attack : "attacker"
    dim_player_account ||..o{ fact_war_attack : "defender"
    war_participant ||..o{ fact_war_attack : "attacker (composite)"
    war_participant ||..o{ fact_war_attack : "defender (composite)"
    dim_war ||..o{ fact_war_attack : "war_key"
    dim_clan ||--o{ fact_war_clan_observation : "clan_key"
    dim_war ||--o{ fact_war_clan_observation : "war_key"
    dim_war ||--o{ fact_war_observation : "war_key"
    war_participant ||..o{ fact_war_roster_observation : "war_key (composite)"
    dim_clan ||..o{ war_participant : "clan_key"
    dim_player_account ||--o{ war_participant : "player_key"
    dim_war ||--o{ war_participant : "war_key"
```

## Player profiles and raids

Profile counters, cumulative achievements, and running raid totals are snapshots and must not be summed across observations. Raid loot comes from capitalResourcesLooted, independently of profile capital-gold donations.

```mermaid
erDiagram
    direction LR

    fact_player_counter_observation {
        bigint player_key PK, FK
        timestamptz observed_at PK
        smallint town_hall_level "nullable"
        bigint war_stars "nullable"
        integer trophies "nullable"
        bigint clan_capital_contributions "nullable"
    }

    dim_achievement {
        bigint achievement_key PK
        text source_name
        text village
    }

    fact_player_achievement_observation {
        bigint player_key PK, FK
        bigint achievement_key PK, FK
        timestamptz observed_at PK
        bigint value
        bigint target "nullable"
        smallint stars "nullable"
    }

    dim_raid_weekend {
        bigint raid_weekend_key PK
        bigint clan_key FK
        timestamptz starts_at
        timestamptz ends_at
    }

    fact_raid_member_observation {
        bigint raid_weekend_key PK, FK
        bigint player_key PK, FK
        timestamptz observed_at PK
        bigint capital_resources_looted
    }

    dim_clan {
        bigint clan_key PK
    }

    dim_player_account {
        bigint player_key PK
    }

    dim_clan ||..o{ dim_raid_weekend : "clan_key"
    dim_achievement ||--o{ fact_player_achievement_observation : "achievement_key"
    dim_player_account ||--o{ fact_player_achievement_observation : "player_key"
    dim_player_account ||--o{ fact_player_counter_observation : "player_key"
    dim_player_account ||--o{ fact_raid_member_observation : "player_key"
    dim_raid_weekend ||--o{ fact_raid_member_observation : "raid_weekend_key"
```

## Clan Games

Account progress, account assessments, and combined Discord-member assessments have distinct grains. Inputs explicitly identify attribution episodes and evidence. Missing coverage produces insufficient_data. The public progress view omits pass/fail; leadership-only result readers are functions/views and are not physical tables in this diagram.

```mermaid
erDiagram
    direction LR

    dim_clan_games_event {
        bigint event_key PK
        bigint guild_key FK
        timestamptz starts_at
        timestamptz ends_at
        integer account_points_cap
        text schedule_source
    }

    fact_clan_games_progress {
        bigint progress_key PK
        bigint event_key FK
        bigint player_key FK
        timestamptz observed_at
        text measurement_method
        text evidence_status
        integer points "nullable"
        bigint baseline_achievement_key FK "nullable"
        timestamptz baseline_observed_at FK "nullable"
        bigint ending_achievement_key FK "nullable"
        timestamptz ending_observed_at FK "nullable"
    }

    fact_clan_games_account_assessment {
        bigint account_assessment_key PK
        bigint event_key FK
        bigint player_key FK
        text checkpoint_kind
        integer calculation_version
        bigint progress_key FK "nullable"
        numeric observed_seconds
        numeric eligible_points "nullable"
        numeric required_points
        text result "generated"
    }

    fact_clan_games_member_assessment {
        bigint member_assessment_key PK
        bigint event_key FK
        bigint user_key FK
        text checkpoint_kind
        integer calculation_version
        timestamptz calculated_at
        text attribution_status
    }

    clan_games_member_account_input {
        bigint member_assessment_key PK, FK
        bigint account_assessment_key FK
        bigint event_key FK
        text checkpoint_kind FK
        bigint player_key PK, FK
        bigint attribution_key FK "nullable"
        bigint guild_key FK
        bigint user_key FK
    }

    dim_discord_user {
        bigint user_key PK
    }

    dim_guild {
        bigint guild_key PK
    }

    dim_player_account {
        bigint player_key PK
    }

    fact_player_achievement_observation {
        bigint player_key PK
        bigint achievement_key PK
        timestamptz observed_at PK
    }

    metric_attribution_episode {
        bigint attribution_key PK
    }

    fact_clan_games_account_assessment ||..o{ clan_games_member_account_input : "account_assessment_key (composite)"
    metric_attribution_episode |o..o{ clan_games_member_account_input : "attribution_key (composite)"
    fact_clan_games_member_assessment ||..o{ clan_games_member_account_input : "member_assessment_key (composite)"
    dim_clan_games_event ||..o{ clan_games_member_account_input : "event_key (composite)"
    dim_guild ||..o{ dim_clan_games_event : "guild_key"
    fact_clan_games_progress |o..o{ fact_clan_games_account_assessment : "progress_key (composite)"
    dim_clan_games_event ||..o{ fact_clan_games_account_assessment : "event_key"
    dim_player_account ||..o{ fact_clan_games_account_assessment : "player_key"
    dim_clan_games_event ||..o{ fact_clan_games_member_assessment : "event_key"
    dim_discord_user ||..o{ fact_clan_games_member_assessment : "user_key"
    dim_clan_games_event ||..o{ fact_clan_games_progress : "event_key"
    fact_player_achievement_observation |o..o{ fact_clan_games_progress : "baseline evidence (composite)"
    fact_player_achievement_observation |o..o{ fact_clan_games_progress : "ending evidence (composite)"
    dim_player_account ||..o{ fact_clan_games_progress : "player_key"
```

## Discord presence, roles, and chat XP

Membership and role facts are immutable observations; current-state projections are maintained by triggers. Departures invalidate role authority without deleting identity, links, or XP. XP is one credited message, with a provisional cross-channel five-message cap per fixed UTC minute.

```mermaid
erDiagram
    direction LR

    fact_discord_membership_event {
        bigint membership_event_key PK
        uuid operation_id UK
        bigint guild_key FK
        bigint user_key FK
        text event_kind
        timestamptz occurred_at
        timestamptz new_joinee_expires_at "generated"
    }

    discord_member_state {
        bigint guild_key PK, FK
        bigint user_key PK, FK
        boolean is_present
        bigint last_membership_event_key FK
        timestamptz last_event_at
    }

    fact_role_change {
        bigint role_event_key PK
        uuid operation_id UK
        bigint guild_key FK
        bigint user_key FK
        bigint role_key FK
        text change_kind
        timestamptz changed_at
        bigint actor_user_key FK "nullable"
        text provenance_kind
        bigint origin_join_event_key FK "nullable"
        timestamptz expires_at "nullable"
    }

    discord_member_role {
        bigint guild_key PK, FK
        bigint user_key PK, FK
        bigint role_key PK, FK
        timestamptz assigned_at
        bigint last_role_event_key FK
        timestamptz expires_at "nullable"
    }

    chat_xp_policy {
        text policy_key PK
        integer xp_per_message
        integer credited_messages_per_minute
        text window_kind
        boolean is_provisional
    }

    fact_chat_xp_award {
        bigint xp_award_key PK
        bigint guild_key FK
        bigint user_key FK
        bigint channel_key FK
        discord_snowflake discord_message_id UK
        timestamptz message_sent_at
        text policy_key FK
        integer xp
    }

    chat_xp_minute_usage {
        bigint guild_key PK, FK
        bigint user_key PK, FK
        timestamp minute_utc PK
        integer credited_messages
    }

    dim_discord_channel {
        bigint channel_key PK
    }

    dim_discord_role {
        bigint role_key PK
    }

    dim_discord_user {
        bigint user_key PK
    }

    dim_guild {
        bigint guild_key PK
    }

    dim_guild ||--o{ chat_xp_minute_usage : "guild_key"
    dim_discord_user ||--o{ chat_xp_minute_usage : "user_key"
    dim_guild ||--o{ discord_member_role : "guild_key"
    dim_discord_role ||--o{ discord_member_role : "role_key (composite)"
    fact_role_change ||..o{ discord_member_role : "last_role_event_key"
    dim_discord_user ||--o{ discord_member_role : "user_key"
    dim_guild ||--o{ discord_member_state : "guild_key"
    fact_discord_membership_event ||..o{ discord_member_state : "last_membership_event_key"
    dim_discord_user ||--o{ discord_member_state : "user_key"
    dim_discord_channel ||..o{ fact_chat_xp_award : "channel_key (composite)"
    dim_guild ||..o{ fact_chat_xp_award : "guild_key"
    chat_xp_policy ||..o{ fact_chat_xp_award : "policy_key"
    dim_discord_user ||..o{ fact_chat_xp_award : "user_key"
    dim_guild ||..o{ fact_discord_membership_event : "guild_key"
    dim_discord_user ||..o{ fact_discord_membership_event : "user_key"
    dim_discord_user |o..o{ fact_role_change : "actor_user_key"
    dim_guild ||..o{ fact_role_change : "guild_key"
    dim_discord_role ||..o{ fact_role_change : "role_key (composite)"
    fact_discord_membership_event |o..o{ fact_role_change : "origin_join_event_key"
    dim_discord_user ||..o{ fact_role_change : "user_key"
```

## Warnings and moderation

A warning can have at most one revocation. Five valid warnings in a GMT calendar month create a durable kick decision; execution attempts and confirmed outcomes remain separate. Revocation does not erase the original warning or its audit history.

```mermaid
erDiagram
    direction LR

    warning {
        bigint warning_key PK
        bigint guild_key FK
        bigint subject_user_key FK
        bigint issued_by_user_key FK
        timestamptz issued_at
        date issue_month_gmt "generated"
        text reason
    }

    warning_revocation {
        bigint warning_key PK, FK
        bigint revoked_by_user_key FK
        timestamptz revoked_at
        text reason
    }

    fact_warning_event {
        bigint warning_event_key PK
        bigint warning_key FK
        bigint guild_key FK
        bigint subject_user_key FK
        bigint actor_user_key FK
        text event_kind
        timestamptz occurred_at
        text reason
    }

    moderation_action {
        bigint moderation_action_key PK
        bigint guild_key FK
        bigint subject_user_key FK
        text action_kind
        date warning_month_gmt
        bigint trigger_warning_key FK
        text status
        timestamptz next_attempt_at
    }

    fact_moderation_action_attempt {
        bigint moderation_attempt_key PK
        bigint moderation_action_key FK
        integer attempt_number
        timestamptz attempted_at
        text outcome
        integer http_status "nullable"
    }

    dim_discord_user {
        bigint user_key PK
    }

    dim_guild {
        bigint guild_key PK
    }

    moderation_action ||..o{ fact_moderation_action_attempt : "moderation_action_key"
    dim_discord_user ||..o{ fact_warning_event : "actor_user_key"
    dim_guild ||..o{ fact_warning_event : "guild_key"
    warning ||..o{ fact_warning_event : "warning_key (composite)"
    dim_discord_user ||..o{ fact_warning_event : "subject_user_key"
    dim_guild ||..o{ moderation_action : "guild_key"
    warning ||..o{ moderation_action : "trigger_warning_key (composite)"
    dim_discord_user ||..o{ moderation_action : "subject_user_key"
    dim_guild ||..o{ warning : "guild_key"
    dim_discord_user ||..o{ warning : "issued_by_user_key"
    dim_discord_user ||..o{ warning : "subject_user_key"
    dim_discord_user ||..o{ warning_revocation : "revoked_by_user_key"
    warning ||--o| warning_revocation : "warning_key"
```

## Audit, collection, and delivery

These facts retain configuration decisions, stored changes, sanitized API attempts, and notification delivery outcomes. Correlation strings are not foreign keys. Only player_verification.source_fetch_key declares a relationship to an API-fetch attempt. No credentials or verification payloads are included.

```mermaid
erDiagram
    direction LR

    fact_configuration_change {
        bigint configuration_change_key PK
        bigint guild_key FK
        bigint actor_user_key FK "nullable"
        timestamptz changed_at
        text entity_type
        text reason
        bigint transaction_id
    }

    fact_change_audit {
        bigint change_audit_key PK
        bigint guild_key FK "nullable"
        bigint actor_user_key FK "nullable"
        timestamptz changed_at
        bigint transaction_id
        text entity_type
        text operation
    }

    fact_api_fetch_attempt {
        bigint fetch_key PK
        bigint guild_key FK
        text source_correlation_id UK
        bigint player_key FK "nullable"
        bigint clan_key FK "nullable"
        bigint requested_by FK "nullable"
        text endpoint_kind
        timestamptz started_at
        smallint http_status "nullable"
        text outcome
    }

    fact_notification_delivery_attempt {
        bigint delivery_attempt_key PK
        bigint guild_key FK
        bigint channel_key FK
        text logical_delivery_key
        integer attempt_number
        text notification_kind
        timestamptz attempted_at
        text outcome
    }

    dim_clan {
        bigint clan_key PK
    }

    dim_discord_channel {
        bigint channel_key PK
    }

    dim_discord_user {
        bigint user_key PK
    }

    dim_guild {
        bigint guild_key PK
    }

    dim_player_account {
        bigint player_key PK
    }

    dim_clan |o..o{ fact_api_fetch_attempt : "clan_key"
    dim_guild ||..o{ fact_api_fetch_attempt : "guild_key"
    dim_player_account |o..o{ fact_api_fetch_attempt : "player_key"
    dim_discord_user |o..o{ fact_api_fetch_attempt : "requested_by"
    dim_discord_user |o..o{ fact_change_audit : "actor_user_key"
    dim_guild |o..o{ fact_change_audit : "guild_key"
    dim_discord_user |o..o{ fact_configuration_change : "actor_user_key"
    dim_guild ||..o{ fact_configuration_change : "guild_key"
    dim_discord_channel ||..o{ fact_notification_delivery_attempt : "channel_key (composite)"
    dim_guild ||..o{ fact_notification_delivery_attempt : "guild_key"
```

## Complete foreign-key reference

<details>
<summary>All 127 declared foreign keys, including composite columns</summary>

These are the actual catalog constraints. Parent-side optionality accounts for
nullable columns; child-side uniqueness includes unconditional unique-key
subsets and the non-null transfer-request uniqueness rule. A unique current
owner index does not limit the cardinality of an entire historical link table.

| Referencing table | Foreign-key columns | Referenced table | Referenced columns |
| --- | --- | --- | --- |
| `account_link` | `attribution_key, guild_key, user_key, player_key` | `metric_attribution_episode` | `attribution_key, guild_key, user_key, player_key` |
| `account_link` | `guild_key` | `dim_guild` | `guild_key` |
| `account_link` | `player_key` | `dim_player_account` | `player_key` |
| `account_link` | `transfer_request_key, guild_key, user_key, player_key` | `account_transfer_request` | `transfer_request_key, guild_key, to_user_key, player_key` |
| `account_link` | `user_key` | `dim_discord_user` | `user_key` |
| `account_link` | `verification_key, guild_key, user_key, player_key, verification_status` | `player_verification` | `verification_key, guild_key, user_key, player_key, status` |
| `account_transfer_request` | `decided_by` | `dim_discord_user` | `user_key` |
| `account_transfer_request` | `from_user_key` | `dim_discord_user` | `user_key` |
| `account_transfer_request` | `guild_key` | `dim_guild` | `guild_key` |
| `account_transfer_request` | `player_key` | `dim_player_account` | `player_key` |
| `account_transfer_request` | `source_link_key, guild_key, from_user_key, player_key` | `account_link` | `link_key, guild_key, user_key, player_key` |
| `account_transfer_request` | `to_user_key` | `dim_discord_user` | `user_key` |
| `account_transfer_request` | `verification_key, guild_key, to_user_key, player_key, verification_status` | `player_verification` | `verification_key, guild_key, user_key, player_key, status` |
| `channel_binding` | `clan_key` | `dim_clan` | `clan_key` |
| `channel_binding` | `guild_key, channel_key` | `dim_discord_channel` | `guild_key, channel_key` |
| `channel_binding` | `guild_key` | `dim_guild` | `guild_key` |
| `chat_xp_minute_usage` | `guild_key` | `dim_guild` | `guild_key` |
| `chat_xp_minute_usage` | `user_key` | `dim_discord_user` | `user_key` |
| `clan_collection_settings` | `clan_key` | `dim_clan` | `clan_key` |
| `clan_collection_settings` | `guild_key` | `dim_guild` | `guild_key` |
| `clan_games_member_account_input` | `account_assessment_key, event_key, player_key, checkpoint_kind` | `fact_clan_games_account_assessment` | `account_assessment_key, event_key, player_key, checkpoint_kind` |
| `clan_games_member_account_input` | `attribution_key, guild_key, user_key, player_key` | `metric_attribution_episode` | `attribution_key, guild_key, user_key, player_key` |
| `clan_games_member_account_input` | `member_assessment_key, event_key, checkpoint_kind, user_key` | `fact_clan_games_member_assessment` | `member_assessment_key, event_key, checkpoint_kind, user_key` |
| `clan_games_member_account_input` | `event_key, guild_key` | `dim_clan_games_event` | `event_key, guild_key` |
| `clan_games_schedule` | `guild_key` | `dim_guild` | `guild_key` |
| `clan_membership_poll` | `guild_key, clan_key` | `clan_collection_settings` | `guild_key, clan_key` |
| `clan_role_binding` | `clan_key` | `dim_clan` | `clan_key` |
| `clan_role_binding` | `guild_key` | `dim_guild` | `guild_key` |
| `clan_role_binding` | `guild_key, role_key` | `dim_discord_role` | `guild_key, role_key` |
| `developer_allowlist` | `added_by` | `dim_discord_user` | `user_key` |
| `developer_allowlist` | `guild_key` | `dim_guild` | `guild_key` |
| `developer_allowlist` | `user_key` | `dim_discord_user` | `user_key` |
| `dim_clan_games_event` | `guild_key` | `dim_guild` | `guild_key` |
| `dim_discord_channel` | `guild_key` | `dim_guild` | `guild_key` |
| `dim_discord_role` | `guild_key` | `dim_guild` | `guild_key` |
| `dim_raid_weekend` | `clan_key` | `dim_clan` | `clan_key` |
| `dim_war` | `clan_a_key` | `dim_clan` | `clan_key` |
| `dim_war` | `clan_b_key` | `dim_clan` | `clan_key` |
| `discord_member_role` | `guild_key` | `dim_guild` | `guild_key` |
| `discord_member_role` | `guild_key, role_key` | `dim_discord_role` | `guild_key, role_key` |
| `discord_member_role` | `last_role_event_key` | `fact_role_change` | `role_event_key` |
| `discord_member_role` | `user_key` | `dim_discord_user` | `user_key` |
| `discord_member_state` | `guild_key` | `dim_guild` | `guild_key` |
| `discord_member_state` | `last_membership_event_key` | `fact_discord_membership_event` | `membership_event_key` |
| `discord_member_state` | `user_key` | `dim_discord_user` | `user_key` |
| `fact_api_fetch_attempt` | `clan_key` | `dim_clan` | `clan_key` |
| `fact_api_fetch_attempt` | `guild_key` | `dim_guild` | `guild_key` |
| `fact_api_fetch_attempt` | `player_key` | `dim_player_account` | `player_key` |
| `fact_api_fetch_attempt` | `requested_by` | `dim_discord_user` | `user_key` |
| `fact_change_audit` | `actor_user_key` | `dim_discord_user` | `user_key` |
| `fact_change_audit` | `guild_key` | `dim_guild` | `guild_key` |
| `fact_chat_xp_award` | `guild_key, channel_key` | `dim_discord_channel` | `guild_key, channel_key` |
| `fact_chat_xp_award` | `guild_key` | `dim_guild` | `guild_key` |
| `fact_chat_xp_award` | `policy_key` | `chat_xp_policy` | `policy_key` |
| `fact_chat_xp_award` | `user_key` | `dim_discord_user` | `user_key` |
| `fact_clan_games_account_assessment` | `progress_key, event_key, player_key` | `fact_clan_games_progress` | `progress_key, event_key, player_key` |
| `fact_clan_games_account_assessment` | `event_key` | `dim_clan_games_event` | `event_key` |
| `fact_clan_games_account_assessment` | `player_key` | `dim_player_account` | `player_key` |
| `fact_clan_games_member_assessment` | `event_key` | `dim_clan_games_event` | `event_key` |
| `fact_clan_games_member_assessment` | `user_key` | `dim_discord_user` | `user_key` |
| `fact_clan_games_progress` | `event_key` | `dim_clan_games_event` | `event_key` |
| `fact_clan_games_progress` | `player_key, baseline_achievement_key, baseline_observed_at` | `fact_player_achievement_observation` | `player_key, achievement_key, observed_at` |
| `fact_clan_games_progress` | `player_key, ending_achievement_key, ending_observed_at` | `fact_player_achievement_observation` | `player_key, achievement_key, observed_at` |
| `fact_clan_games_progress` | `player_key` | `dim_player_account` | `player_key` |
| `fact_clan_member_observation` | `player_key` | `dim_player_account` | `player_key` |
| `fact_clan_member_observation` | `poll_key` | `clan_membership_poll` | `poll_key` |
| `fact_clan_membership_change` | `player_key` | `dim_player_account` | `player_key` |
| `fact_clan_membership_change` | `poll_key, guild_key, clan_key` | `clan_membership_poll` | `poll_key, guild_key, clan_key` |
| `fact_configuration_change` | `actor_user_key` | `dim_discord_user` | `user_key` |
| `fact_configuration_change` | `guild_key` | `dim_guild` | `guild_key` |
| `fact_discord_membership_event` | `guild_key` | `dim_guild` | `guild_key` |
| `fact_discord_membership_event` | `user_key` | `dim_discord_user` | `user_key` |
| `fact_moderation_action_attempt` | `moderation_action_key` | `moderation_action` | `moderation_action_key` |
| `fact_notification_delivery_attempt` | `guild_key, channel_key` | `dim_discord_channel` | `guild_key, channel_key` |
| `fact_notification_delivery_attempt` | `guild_key` | `dim_guild` | `guild_key` |
| `fact_player_achievement_observation` | `achievement_key` | `dim_achievement` | `achievement_key` |
| `fact_player_achievement_observation` | `player_key` | `dim_player_account` | `player_key` |
| `fact_player_counter_observation` | `player_key` | `dim_player_account` | `player_key` |
| `fact_raid_member_observation` | `player_key` | `dim_player_account` | `player_key` |
| `fact_raid_member_observation` | `raid_weekend_key` | `dim_raid_weekend` | `raid_weekend_key` |
| `fact_role_change` | `actor_user_key` | `dim_discord_user` | `user_key` |
| `fact_role_change` | `guild_key` | `dim_guild` | `guild_key` |
| `fact_role_change` | `guild_key, role_key` | `dim_discord_role` | `guild_key, role_key` |
| `fact_role_change` | `origin_join_event_key` | `fact_discord_membership_event` | `membership_event_key` |
| `fact_role_change` | `user_key` | `dim_discord_user` | `user_key` |
| `fact_war_attack` | `attacker_key` | `dim_player_account` | `player_key` |
| `fact_war_attack` | `defender_key` | `dim_player_account` | `player_key` |
| `fact_war_attack` | `war_key, attacker_key` | `war_participant` | `war_key, player_key` |
| `fact_war_attack` | `war_key, defender_key` | `war_participant` | `war_key, player_key` |
| `fact_war_attack` | `war_key` | `dim_war` | `war_key` |
| `fact_war_clan_observation` | `clan_key` | `dim_clan` | `clan_key` |
| `fact_war_clan_observation` | `war_key` | `dim_war` | `war_key` |
| `fact_war_observation` | `war_key` | `dim_war` | `war_key` |
| `fact_war_roster_observation` | `war_key, clan_key, player_key` | `war_participant` | `war_key, clan_key, player_key` |
| `fact_warning_event` | `actor_user_key` | `dim_discord_user` | `user_key` |
| `fact_warning_event` | `guild_key` | `dim_guild` | `guild_key` |
| `fact_warning_event` | `guild_key, subject_user_key, warning_key` | `warning` | `guild_key, subject_user_key, warning_key` |
| `fact_warning_event` | `subject_user_key` | `dim_discord_user` | `user_key` |
| `guild_settings` | `chat_xp_policy_key` | `chat_xp_policy` | `policy_key` |
| `guild_settings` | `guild_key` | `dim_guild` | `guild_key` |
| `metric_attribution_episode` | `guild_key` | `dim_guild` | `guild_key` |
| `metric_attribution_episode` | `player_key` | `dim_player_account` | `player_key` |
| `metric_attribution_episode` | `user_key` | `dim_discord_user` | `user_key` |
| `moderation_action` | `guild_key` | `dim_guild` | `guild_key` |
| `moderation_action` | `guild_key, subject_user_key, trigger_warning_key` | `warning` | `guild_key, subject_user_key, warning_key` |
| `moderation_action` | `subject_user_key` | `dim_discord_user` | `user_key` |
| `observed_clan_membership_period` | `first_poll_key, guild_key, clan_key` | `clan_membership_poll` | `poll_key, guild_key, clan_key` |
| `observed_clan_membership_period` | `last_poll_key, guild_key, clan_key` | `clan_membership_poll` | `poll_key, guild_key, clan_key` |
| `observed_clan_membership_period` | `guild_key, clan_key` | `clan_collection_settings` | `guild_key, clan_key` |
| `observed_clan_membership_period` | `player_key` | `dim_player_account` | `player_key` |
| `player_verification` | `guild_key` | `dim_guild` | `guild_key` |
| `player_verification` | `player_key` | `dim_player_account` | `player_key` |
| `player_verification` | `source_fetch_key` | `fact_api_fetch_attempt` | `fetch_key` |
| `player_verification` | `user_key` | `dim_discord_user` | `user_key` |
| `server_role_binding` | `guild_key` | `dim_guild` | `guild_key` |
| `server_role_binding` | `guild_key, role_key` | `dim_discord_role` | `guild_key, role_key` |
| `town_hall_role_binding` | `guild_key` | `dim_guild` | `guild_key` |
| `town_hall_role_binding` | `guild_key, role_key` | `dim_discord_role` | `guild_key, role_key` |
| `war_participant` | `clan_key` | `dim_clan` | `clan_key` |
| `war_participant` | `player_key` | `dim_player_account` | `player_key` |
| `war_participant` | `war_key` | `dim_war` | `war_key` |
| `war_reminder_setting` | `guild_key, clan_key` | `clan_collection_settings` | `guild_key, clan_key` |
| `warning` | `guild_key` | `dim_guild` | `guild_key` |
| `warning` | `issued_by_user_key` | `dim_discord_user` | `user_key` |
| `warning` | `subject_user_key` | `dim_discord_user` | `user_key` |
| `warning_revocation` | `revoked_by_user_key` | `dim_discord_user` | `user_key` |
| `warning_revocation` | `warning_key` | `warning` | `warning_key` |

</details>

## Maintenance

When migrations change tables or constraints, update the affected domain
diagram and the complete FK reference together. Validate against a disposable
database prepared through the normal Flyway workflow. Do not reset real data
or alter migration checksums to regenerate documentation.
