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

    INSERT INTO guild.dim_discord_role (guild_key, discord_role_id, role_name)
    VALUES (guild, 100000000000000001, 'Eclipse') RETURNING role_key INTO role_id;
    INSERT INTO guild.server_role_binding (guild_key, purpose, role_key)
    VALUES (guild, 'member', role_id);
    UPDATE guild.dim_discord_role SET role_name = 'Renamed Eclipse' WHERE role_key = role_id;
    IF NOT EXISTS (
        SELECT FROM guild.server_role_binding b JOIN guild.dim_discord_role r USING (role_key)
        WHERE b.guild_key = guild AND b.purpose = 'member' AND r.role_name = 'Renamed Eclipse'
    ) THEN
        RAISE EXCEPTION 'Role rename broke its purpose binding';
    END IF;
    -- Identical display names never identify a role.
    INSERT INTO guild.dim_discord_role (guild_key, discord_role_id, role_name)
    VALUES (guild, 100000000000000002, 'Renamed Eclipse');

    INSERT INTO guild.dim_discord_channel (guild_key, discord_channel_id, channel_name)
    VALUES (guild, 100000000000000003, 'activity') RETURNING channel_key INTO channel_id;
    INSERT INTO guild.channel_binding (guild_key, purpose, channel_key)
    VALUES (guild, 'clan_games', channel_id), (guild, 'raid_weekend', channel_id);
    rejected := false;
    BEGIN
        INSERT INTO guild.channel_binding (guild_key, purpose, channel_key)
        VALUES (guild, 'clan_games', channel_id);
    EXCEPTION WHEN unique_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Duplicate server-wide channel purpose accepted'; END IF;
    rejected := false;
    BEGIN
        INSERT INTO guild.channel_binding (guild_key, purpose, channel_key)
        VALUES (guild, 'war', channel_id);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Clan-scoped war channel accepted without a clan'; END IF;

    INSERT INTO guild.dim_date (date_key) VALUES ('2028-02-29');
    IF NOT EXISTS (
        SELECT FROM guild.dim_date WHERE date_key = '2028-02-29'
            AND year_number = 2028 AND month_number = 2 AND day_number = 29
    ) THEN
        RAISE EXCEPTION 'Calendar dimension did not derive leap-day attributes';
    END IF;
    RAISE NOTICE 'Dimension and configuration constraints passed';
END;
$$;

ROLLBACK;
