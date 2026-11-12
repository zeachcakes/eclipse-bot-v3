BEGIN;

DO $$
DECLARE
    guild bigint;
    role_id bigint;
    channel_id bigint;
    rejected boolean;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id, guild_name)
    VALUES (18446744073709551615, 'Development test guild') RETURNING guild_key INTO guild;
    IF (SELECT discord_guild_id::text FROM guild.dim_guild WHERE guild_key = guild)
        <> '18446744073709551615' THEN
        RAISE EXCEPTION 'Unsigned 64-bit Discord ID was not preserved';
    END IF;
    rejected := false;
    BEGIN
        INSERT INTO guild.dim_guild (discord_guild_id) VALUES (900000000000000001);
    EXCEPTION WHEN unique_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Multiple guilds accepted in one environment'; END IF;
    -- One Discord server per database, so only the guild and its settings row
    -- carry guild_key. Views over guild_settings may expose it as well.
    IF EXISTS (SELECT FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'guild' AND c.relkind IN ('r', 'p') AND a.attname = 'guild_key'
            AND NOT a.attisdropped AND c.relname NOT IN ('dim_guild', 'guild_settings')) THEN
        RAISE EXCEPTION 'A table other than dim_guild and guild_settings carries guild_key';
    END IF;
    rejected := false;
    BEGIN
        INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (18446744073709551616);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Out-of-range snowflake accepted'; END IF;
    rejected := false;
    BEGIN
        INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (100.5);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Fractional snowflake silently rounded'; END IF;

    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y');
    rejected := false;
    BEGIN
        INSERT INTO guild.dim_player_account (player_tag) VALUES ('#invalid');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Noncanonical player tag accepted'; END IF;
    rejected := false;
    BEGIN
        INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y');
    EXCEPTION WHEN unique_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Duplicate player identity accepted'; END IF;

    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (100000000000000001, 'Eclipse') RETURNING role_key INTO role_id;
    INSERT INTO guild.server_role_binding (purpose, role_key)
    VALUES ('member', role_id);
    UPDATE guild.dim_discord_role SET role_name = 'Renamed Eclipse' WHERE role_key = role_id;
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
    rejected := false;
    BEGIN
        INSERT INTO guild.channel_binding (purpose, channel_key)
        VALUES ('clan_games', channel_id);
    EXCEPTION WHEN unique_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Duplicate server-wide channel purpose accepted'; END IF;
    rejected := false;
    BEGIN
        INSERT INTO guild.channel_binding (purpose, channel_key)
        VALUES ('war', channel_id);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Clan-scoped war channel accepted without a clan'; END IF;

    rejected := false;
    BEGIN
        INSERT INTO guild.role_binding (town_hall_level, purpose, role_key)
        VALUES (16, 'admin', role_id);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'A TH binding accepted a staff capability purpose'; END IF;
    INSERT INTO guild.town_hall_role_binding (town_hall_level, role_key)
    VALUES (16, role_id);
    rejected := false;
    BEGIN
        INSERT INTO guild.server_role_binding (purpose, role_key)
        VALUES ('member', role_id);
    EXCEPTION WHEN unique_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Duplicate server binding bypassed its shared scope'; END IF;
    RAISE NOTICE 'Dimension and configuration constraints passed';
END;
$$;

ROLLBACK;
