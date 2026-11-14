BEGIN;

-- V1: shared dimensions, typed role and channel bindings, and fetch metadata.
-- Fixtures write as guild_runtime; RESET ROLE only for what it may not do.
DO $$
DECLARE
    guild bigint; member_id bigint; role_id bigint; channel_id bigint; clan_id bigint;
    player_id bigint; fetch_id bigint; other_developer bigint;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id, guild_name)
    VALUES (18446744073709551615, 'Development test guild') RETURNING guild_key INTO guild;
    IF (SELECT discord_guild_id::text FROM guild.dim_guild WHERE guild_key = guild)
        <> '18446744073709551615' THEN
        RAISE EXCEPTION 'Unsigned 64-bit Discord ID was not preserved';
    END IF;
    BEGIN
        INSERT INTO guild.dim_guild (discord_guild_id) VALUES (900000000000000001);
        RAISE EXCEPTION 'Multiple guilds accepted in one environment';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- One Discord server per database, so only the guild and its settings row
    -- carry guild_key. Views over guild_settings may expose it as well.
    IF EXISTS (SELECT FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'guild' AND c.relkind IN ('r', 'p') AND a.attname = 'guild_key'
            AND NOT a.attisdropped AND c.relname NOT IN ('dim_guild', 'guild_settings')) THEN
        RAISE EXCEPTION 'A table other than dim_guild and guild_settings carries guild_key';
    END IF;

    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.guild_settings (guild_key) VALUES (guild);
    BEGIN
        INSERT INTO guild.guild_settings (guild_key) VALUES (guild);
        RAISE EXCEPTION 'A second settings row accepted for the guild';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.guild_settings SET new_joinee_days = 0;
        RAISE EXCEPTION 'A New Joinee period of zero days accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (18446744073709551616);
        RAISE EXCEPTION 'Out-of-range snowflake accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (100.5);
        RAISE EXCEPTION 'Fractional snowflake silently rounded';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (0);
        RAISE EXCEPTION 'Zero snowflake accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.dim_discord_user (discord_user_id, display_name)
    VALUES (100000000000000010, 'Member') RETURNING user_key INTO member_id;
    BEGIN
        INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (100000000000000010);
        RAISE EXCEPTION 'Duplicate Discord user identity accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    UPDATE guild.dim_discord_user SET display_name = 'Renamed member' WHERE user_key = member_id;

    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y') RETURNING player_key INTO player_id;
    BEGIN
        INSERT INTO guild.dim_player_account (player_tag) VALUES ('#invalid');
        RAISE EXCEPTION 'Noncanonical player tag accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y');
        RAISE EXCEPTION 'Duplicate player identity accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    UPDATE guild.dim_player_account SET player_name = 'Renamed player' WHERE player_key = player_id;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#2PP') RETURNING clan_key INTO clan_id;
    BEGIN
        INSERT INTO guild.dim_clan (clan_tag) VALUES ('2PP');
        RAISE EXCEPTION 'Clan tag without its # accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.dim_clan SET clan_name = 'Eclipse' WHERE clan_key = clan_id;

    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (100000000000000001, 'Eclipse') RETURNING role_key INTO role_id;
    BEGIN
        INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
        VALUES (100000000000000004, ' ');
        RAISE EXCEPTION 'Blank role name accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.role_binding (purpose, role_key) VALUES ('member', role_id);
    UPDATE guild.dim_discord_role SET role_name = 'Renamed Eclipse', last_synced_at = clock_timestamp()
    WHERE role_key = role_id;
    IF NOT EXISTS (
        SELECT FROM guild.server_role_binding b JOIN guild.dim_discord_role r USING (role_key)
        WHERE b.purpose = 'member' AND r.role_name = 'Renamed Eclipse'
    ) THEN
        RAISE EXCEPTION 'Role rename broke its purpose binding';
    END IF;
    -- Identical display names never identify a role.
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (100000000000000002, 'Renamed Eclipse');

    INSERT INTO guild.dim_discord_channel (discord_channel_id, channel_name)
    VALUES (100000000000000003, 'activity') RETURNING channel_key INTO channel_id;
    INSERT INTO guild.channel_binding (purpose, channel_key)
    VALUES ('clan_games', channel_id), ('raid_weekend', channel_id);
    BEGIN
        INSERT INTO guild.channel_binding (purpose, channel_key) VALUES ('clan_games', channel_id);
        RAISE EXCEPTION 'Duplicate server-wide channel purpose accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.channel_binding (purpose, channel_key) VALUES ('war', channel_id);
        RAISE EXCEPTION 'Clan-scoped war channel accepted without a clan';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.channel_binding (purpose, clan_key, channel_key)
        VALUES ('welcome', clan_id, channel_id);
        RAISE EXCEPTION 'A server-wide channel purpose accepted a clan';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.channel_binding (purpose, clan_key, channel_key)
        VALUES ('cwl_roster', clan_id, channel_id);
        RAISE EXCEPTION 'A CWL roster channel accepted without its War Day';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.channel_binding (purpose, clan_key, war_day, channel_key)
        VALUES ('cwl_roster', clan_id, 8, channel_id);
        RAISE EXCEPTION 'A CWL roster channel accepted War Day 8';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.channel_binding (purpose, clan_key, war_day, channel_key)
    VALUES ('cwl_roster', clan_id, 1, channel_id), ('cwl_roster', clan_id, 2, channel_id);
    UPDATE guild.channel_binding SET channel_key = channel_id WHERE purpose = 'welcome';

    BEGIN
        INSERT INTO guild.role_binding (town_hall_level, purpose, role_key) VALUES (16, 'admin', role_id);
        RAISE EXCEPTION 'A TH binding accepted a staff capability purpose';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.role_binding (purpose, role_key) VALUES ('war', role_id);
        RAISE EXCEPTION 'Null clan scope escaped into a server role binding';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.role_binding (clan_key, town_hall_level, purpose, role_key)
        VALUES (clan_id, 16, 'town_hall', role_id);
        RAISE EXCEPTION 'A binding accepted both a clan and a TH level';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.role_binding (town_hall_level, purpose, role_key) VALUES (16, 'town_hall', role_id);
    INSERT INTO guild.role_binding (clan_key, purpose, role_key) VALUES (clan_id, 'war', role_id);
    BEGIN
        INSERT INTO guild.role_binding (purpose, role_key) VALUES ('member', role_id);
        RAISE EXCEPTION 'Duplicate server binding bypassed its shared scope';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.role_binding (clan_key, purpose, role_key) VALUES (clan_id, 'war', role_id);
        RAISE EXCEPTION 'Duplicate clan binding accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    IF (SELECT count(*) FROM guild.server_role_binding) <> 1
        OR (SELECT count(*) FROM guild.clan_role_binding) <> 1
        OR (SELECT count(*) FROM guild.town_hall_role_binding) <> 1 THEN
        RAISE EXCEPTION 'The scope views did not each show their own bindings';
    END IF;

    INSERT INTO guild.developer_allowlist (user_key) VALUES (member_id);
    BEGIN
        INSERT INTO guild.developer_allowlist (user_key) VALUES (member_id);
        RAISE EXCEPTION 'A developer was listed twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- DEC-08: the operator names the owner developer; the service can neither
    -- change the owner nor delete the owner's allowlist row.
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (100000000000000011)
    RETURNING user_key INTO other_developer;
    RESET ROLE;
    BEGIN
        UPDATE guild.guild_settings SET owner_developer_user_key = other_developer;
        RAISE EXCEPTION 'A user outside the allowlist became the owner developer';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    UPDATE guild.guild_settings SET owner_developer_user_key = member_id;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.developer_allowlist (user_key, added_by) VALUES (other_developer, member_id);
    DELETE FROM guild.developer_allowlist WHERE user_key = other_developer;
    BEGIN
        DELETE FROM guild.developer_allowlist WHERE user_key = member_id;
        RAISE EXCEPTION 'The runtime role removed the owner developer';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.guild_settings SET owner_developer_user_key = NULL;
        RAISE EXCEPTION 'The runtime role changed the owner developer';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    INSERT INTO guild.fact_api_fetch_attempt
        (player_key, requested_by, source_correlation_id, endpoint_kind, outcome)
    VALUES (player_id, member_id, 'test:fetch', 'player_profile', 'pending')
    RETURNING fetch_key INTO fetch_id;
    BEGIN
        INSERT INTO guild.fact_api_fetch_attempt (source_correlation_id, endpoint_kind, outcome)
        VALUES ('test:fetch', 'player_profile', 'pending');
        RAISE EXCEPTION 'A fetch correlation ID was reused';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_api_fetch_attempt (source_correlation_id, endpoint_kind, outcome)
        VALUES (' ', 'player_profile', 'pending');
        RAISE EXCEPTION 'A blank fetch correlation ID was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_api_fetch_attempt (source_correlation_id, endpoint_kind, outcome)
        VALUES ('test:unknown-endpoint', 'player_search', 'pending');
        RAISE EXCEPTION 'An unknown endpoint kind was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_api_fetch_attempt SET outcome = 'succeeded' WHERE fetch_key = fetch_id;
        RAISE EXCEPTION 'A finished fetch was accepted without its completion time';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_api_fetch_attempt
        SET outcome = 'succeeded', completed_at = started_at - interval '1 second'
        WHERE fetch_key = fetch_id;
        RAISE EXCEPTION 'A fetch completed before it started';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_api_fetch_attempt
        SET outcome = 'succeeded', completed_at = started_at, http_status = 600
        WHERE fetch_key = fetch_id;
        RAISE EXCEPTION 'An HTTP status outside 100-599 was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.fact_api_fetch_attempt
    SET outcome = 'succeeded', completed_at = started_at + interval '1 second', http_status = 200
    WHERE fetch_key = fetch_id;
    RAISE NOTICE 'Dimension and configuration constraints passed';
END;
$$;

ROLLBACK;
