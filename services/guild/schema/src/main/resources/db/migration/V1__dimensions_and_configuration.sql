-- The guild schema and its migration/runtime roles are provisioned outside
-- Flyway, following ADR 0007. Never store credentials in these migrations.

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
    'Exactly one Discord server per database/environment; dev and prod use separate databases.';

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
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    discord_role_id guild.discord_snowflake NOT NULL UNIQUE,
    role_name text NOT NULL CHECK (btrim(role_name) <> ''),
    last_synced_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at timestamptz,
    UNIQUE (guild_key, role_key)
);
CREATE TABLE guild.dim_discord_channel (
    channel_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    discord_channel_id guild.discord_snowflake NOT NULL UNIQUE,
    channel_name text NOT NULL CHECK (btrim(channel_name) <> ''),
    last_synced_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at timestamptz,
    UNIQUE (guild_key, channel_key)
);
CREATE TABLE guild.dim_date (
    date_key date PRIMARY KEY,
    year_number integer GENERATED ALWAYS AS (extract(year FROM date_key)::integer) STORED,
    month_number integer GENERATED ALWAYS AS (extract(month FROM date_key)::integer) STORED,
    day_number integer GENERATED ALWAYS AS (extract(day FROM date_key)::integer) STORED,
    iso_weekday integer GENERATED ALWAYS AS (extract(isodow FROM date_key)::integer) STORED
);
COMMENT ON TABLE guild.dim_date IS
    'Optional calendar grouping. Exact source and observation timestamps remain on facts.';

CREATE TABLE guild.guild_settings (
    guild_key bigint PRIMARY KEY REFERENCES guild.dim_guild,
    new_joinee_days integer NOT NULL DEFAULT 7 CHECK (new_joinee_days > 0),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE guild.server_role_binding (
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    purpose text NOT NULL CHECK (purpose IN (
        'applicant', 'member', 'new_joinee', 'admin', 'co_leader', 'leadership'
    )),
    role_key bigint NOT NULL,
    PRIMARY KEY (guild_key, purpose),
    FOREIGN KEY (guild_key, role_key) REFERENCES guild.dim_discord_role (guild_key, role_key)
);
CREATE TABLE guild.clan_role_binding (
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    clan_key bigint NOT NULL REFERENCES guild.dim_clan,
    purpose text NOT NULL CHECK (purpose IN ('member', 'war')),
    role_key bigint NOT NULL,
    PRIMARY KEY (guild_key, clan_key, purpose),
    FOREIGN KEY (guild_key, role_key) REFERENCES guild.dim_discord_role (guild_key, role_key)
);
CREATE TABLE guild.town_hall_role_binding (
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    town_hall_level smallint NOT NULL CHECK (town_hall_level > 0),
    role_key bigint NOT NULL,
    PRIMARY KEY (guild_key, town_hall_level),
    FOREIGN KEY (guild_key, role_key) REFERENCES guild.dim_discord_role (guild_key, role_key)
);
CREATE TABLE guild.channel_binding (
    binding_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    purpose text NOT NULL CHECK (purpose IN (
        'welcome', 'clan_games', 'raid_weekend', 'clan_logs', 'moderation_logs', 'war'
    )),
    clan_key bigint REFERENCES guild.dim_clan,
    channel_key bigint NOT NULL,
    UNIQUE NULLS NOT DISTINCT (guild_key, purpose, clan_key),
    FOREIGN KEY (guild_key, channel_key)
        REFERENCES guild.dim_discord_channel (guild_key, channel_key),
    CHECK ((purpose = 'war') = (clan_key IS NOT NULL))
);
COMMENT ON TABLE guild.channel_binding IS
    'Purpose bindings may share a channel. Discord category/channel ACLs govern channel visibility.';

CREATE TABLE guild.developer_allowlist (
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    added_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    added_by bigint REFERENCES guild.dim_discord_user,
    PRIMARY KEY (guild_key, user_key)
);
COMMENT ON TABLE guild.developer_allowlist IS
    'Privileged allowlist. Initial rows are seeded by the migration operator, not public commands.';

CREATE FUNCTION guild.is_developer(p_guild_key bigint, p_user_key bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
    SELECT EXISTS (
        SELECT FROM guild.developer_allowlist
        WHERE guild_key = p_guild_key AND user_key = p_user_key
    );
$$;
-- PL/pgSQL resolves the confirmed-role projection when invoked after V4.
CREATE FUNCTION guild.has_bound_role(
    p_guild_key bigint, p_user_key bigint, p_purposes text[]
) RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
BEGIN
    RETURN EXISTS (
        SELECT FROM guild.server_role_binding b
        JOIN guild.discord_member_role r
            ON r.guild_key = b.guild_key AND r.role_key = b.role_key
        JOIN guild.dim_discord_role d ON d.role_key = r.role_key
        WHERE r.guild_key = p_guild_key AND r.user_key = p_user_key
            AND b.purpose = ANY (p_purposes) AND d.deleted_at IS NULL
            AND (r.expires_at IS NULL OR r.expires_at > statement_timestamp())
            AND NOT EXISTS (
                SELECT FROM guild.discord_member_state s
                WHERE s.guild_key = p_guild_key AND s.user_key = p_user_key
                AND NOT s.is_present
            )
    );
END;
$$;
CREATE FUNCTION guild.can_configure(p_guild_key bigint, p_user_key bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
    SELECT guild.is_developer(p_guild_key, p_user_key)
        OR guild.has_bound_role(p_guild_key, p_user_key, ARRAY['admin']);
$$;
CREATE FUNCTION guild.can_moderate(p_guild_key bigint, p_user_key bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
    SELECT guild.has_bound_role(
        p_guild_key, p_user_key, ARRAY['leadership', 'co_leader', 'admin']
    );
$$;
CREATE FUNCTION guild.can_manage_links(p_guild_key bigint, p_user_key bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
    SELECT guild.has_bound_role(
        p_guild_key, p_user_key, ARRAY['co_leader', 'admin']
    );
$$;

CREATE TABLE guild.fact_configuration_change (
    configuration_change_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    actor_user_key bigint REFERENCES guild.dim_discord_user,
    source text NOT NULL CHECK (source IN ('command', 'operator')),
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    entity_type text NOT NULL CHECK (btrim(entity_type) <> ''),
    entity_identity jsonb NOT NULL CHECK (jsonb_typeof(entity_identity) = 'object'),
    previous_value jsonb,
    new_value jsonb,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    CHECK (previous_value IS NOT NULL OR new_value IS NOT NULL),
    CHECK (source <> 'command' OR actor_user_key IS NOT NULL)
);
CREATE INDEX configuration_change_guild_time
ON guild.fact_configuration_change (guild_key, changed_at DESC);

CREATE TABLE guild.fact_api_fetch_attempt (
    fetch_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    source_correlation_id text NOT NULL UNIQUE CHECK (btrim(source_correlation_id) <> ''),
    player_key bigint REFERENCES guild.dim_player_account,
    clan_key bigint REFERENCES guild.dim_clan,
    requested_by bigint REFERENCES guild.dim_discord_user,
    endpoint_kind text NOT NULL CHECK (endpoint_kind IN (
        'clan_members', 'player_profile', 'current_war', 'war_log', 'raid_seasons', 'verify_player'
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

CREATE TABLE guild.fact_notification_delivery_attempt (
    delivery_attempt_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    channel_key bigint NOT NULL,
    logical_delivery_key text NOT NULL CHECK (btrim(logical_delivery_key) <> ''),
    attempt_number integer NOT NULL CHECK (attempt_number > 0),
    notification_kind text NOT NULL CHECK (notification_kind IN (
        'welcome', 'war_reminder', 'clan_games_report', 'raid_start', 'raid_report', 'moderation'
    )),
    attempted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    outcome text NOT NULL CHECK (outcome IN ('succeeded', 'failed', 'uncertain')),
    discord_message_id guild.discord_snowflake,
    error_code text,
    FOREIGN KEY (guild_key, channel_key)
        REFERENCES guild.dim_discord_channel (guild_key, channel_key),
    UNIQUE (logical_delivery_key, attempt_number)
);
