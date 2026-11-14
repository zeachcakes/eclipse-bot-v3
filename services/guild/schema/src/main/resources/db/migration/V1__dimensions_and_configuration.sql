-- The guild schema and its migration/runtime roles are provisioned outside
-- Flyway, following ADR 0007. Never store credentials in these migrations.
-- The migrations hold declarative schema only: tables, constraints, indexes,
-- views and grants. Business rules, workflows and permission checks are Java in
-- the guild service (ADR 0012).

CREATE DOMAIN guild.discord_snowflake AS numeric
    CHECK (VALUE = trunc(VALUE) AND VALUE > 0 AND VALUE <= 18446744073709551615);

CREATE TABLE guild.dim_guild (
    guild_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    discord_guild_id guild.discord_snowflake NOT NULL UNIQUE,
    guild_name text,
    singleton boolean NOT NULL DEFAULT true UNIQUE CHECK (singleton),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
COMMENT ON TABLE guild.dim_guild IS
    'Exactly one Discord server per database/environment; dev and prod use separate databases. '
    'Because there is one server, no other table except guild_settings carries guild_key.';

CREATE TABLE guild.dim_discord_user (
    user_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    discord_user_id guild.discord_snowflake NOT NULL UNIQUE,
    display_name text,
    first_observed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE guild.dim_player_account (
    player_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_tag text NOT NULL UNIQUE CHECK (player_tag ~ '^#[0289PYLQGRJCUV]+$'),
    player_name text,
    first_observed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE guild.dim_clan (
    clan_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    clan_tag text NOT NULL UNIQUE CHECK (clan_tag ~ '^#[0289PYLQGRJCUV]+$'),
    clan_name text,
    first_observed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE guild.dim_discord_role (
    role_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    discord_role_id guild.discord_snowflake NOT NULL UNIQUE,
    role_name text NOT NULL CHECK (btrim(role_name) <> ''),
    last_synced_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at timestamptz
);
CREATE TABLE guild.dim_discord_channel (
    channel_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    discord_channel_id guild.discord_snowflake NOT NULL UNIQUE,
    channel_name text NOT NULL CHECK (btrim(channel_name) <> ''),
    last_synced_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at timestamptz
);
CREATE TABLE guild.guild_settings (
    guild_key bigint PRIMARY KEY REFERENCES guild.dim_guild,
    new_joinee_days integer NOT NULL DEFAULT 7 CHECK (new_joinee_days > 0),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE guild.role_binding (
    binding_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    clan_key bigint REFERENCES guild.dim_clan,
    town_hall_level smallint CHECK (town_hall_level > 0),
    purpose text NOT NULL DEFAULT 'town_hall',
    role_key bigint NOT NULL REFERENCES guild.dim_discord_role,
    UNIQUE NULLS NOT DISTINCT (purpose, clan_key, town_hall_level),
    CHECK (clan_key IS NULL OR town_hall_level IS NULL),
    CHECK (CASE
        WHEN clan_key IS NOT NULL THEN purpose IN ('member', 'war', 'cwl')
        WHEN town_hall_level IS NOT NULL THEN purpose = 'town_hall'
        ELSE purpose IN ('applicant', 'member', 'new_joinee', 'admin', 'co_leader', 'leadership')
    END)
);
COMMENT ON TABLE guild.role_binding IS
    'Typed server, clan, and town-hall role bindings. Scope-specific views share '
    'one constrained source.';
CREATE VIEW guild.server_role_binding AS
SELECT purpose, role_key FROM guild.role_binding
WHERE clan_key IS NULL AND town_hall_level IS NULL WITH CASCADED CHECK OPTION;
CREATE VIEW guild.clan_role_binding AS
SELECT clan_key, purpose, role_key FROM guild.role_binding
WHERE clan_key IS NOT NULL AND town_hall_level IS NULL WITH CASCADED CHECK OPTION;
CREATE VIEW guild.town_hall_role_binding AS
SELECT town_hall_level, role_key FROM guild.role_binding
WHERE town_hall_level IS NOT NULL AND clan_key IS NULL WITH CASCADED CHECK OPTION;
CREATE TABLE guild.channel_binding (
    binding_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    purpose text NOT NULL CHECK (purpose IN (
        'welcome', 'clan_games', 'raid_weekend', 'clan_logs', 'moderation_logs',
        'leadership_notifications', 'war', 'cwl_signups', 'cwl_roster'
    )),
    clan_key bigint REFERENCES guild.dim_clan,
    war_day smallint CHECK (war_day BETWEEN 1 AND 7),
    channel_key bigint NOT NULL REFERENCES guild.dim_discord_channel,
    UNIQUE NULLS NOT DISTINCT (purpose, clan_key, war_day),
    CHECK ((purpose IN ('war', 'cwl_signups', 'cwl_roster')) = (clan_key IS NOT NULL)),
    CHECK ((purpose = 'cwl_roster') = (war_day IS NOT NULL))
);
COMMENT ON TABLE guild.channel_binding IS
    'Purpose bindings may share a channel. Discord category/channel ACLs govern channel visibility.';

CREATE TABLE guild.developer_allowlist (
    user_key bigint PRIMARY KEY REFERENCES guild.dim_discord_user,
    added_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    added_by bigint REFERENCES guild.dim_discord_user
);
COMMENT ON TABLE guild.developer_allowlist IS
    'Privileged allowlist. The first row comes from tools/postgres/seed-guild.sql, not from a command.';
-- The owner developer alone adds and removes developers (DEC-08, CFG-004). The
-- reference keeps the owner's allowlist row from being deleted, and the runtime
-- role has no UPDATE grant on it, so only an operator changes the owner.
ALTER TABLE guild.guild_settings
    ADD COLUMN owner_developer_user_key bigint REFERENCES guild.developer_allowlist;
COMMENT ON COLUMN guild.guild_settings.owner_developer_user_key IS
    'The main developer, seeded by tools/postgres/seed-guild.sql. Only this developer manages '
    'the allowlist; no command removes or changes the owner.';

CREATE TABLE guild.fact_api_fetch_attempt (
    fetch_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_correlation_id text NOT NULL UNIQUE CHECK (btrim(source_correlation_id) <> ''),
    player_key bigint REFERENCES guild.dim_player_account,
    clan_key bigint REFERENCES guild.dim_clan,
    requested_by bigint REFERENCES guild.dim_discord_user,
    endpoint_kind text NOT NULL CHECK (endpoint_kind IN (
        'clan_members', 'player_profile', 'current_war', 'war_log', 'raid_seasons',
        'verify_player', 'cwl_group', 'cwl_war'
    )),
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz,
    http_status smallint CHECK (http_status BETWEEN 100 AND 599),
    outcome text NOT NULL CHECK (outcome IN ('pending', 'succeeded', 'failed', 'insufficient_data')),
    error_code text,
    CHECK (completed_at IS NULL OR completed_at >= started_at),
    CHECK ((outcome = 'pending') = (completed_at IS NULL))
);
COMMENT ON TABLE guild.fact_api_fetch_attempt IS
    'Sanitized request metadata only. No headers, credential values, or verification bodies.';
