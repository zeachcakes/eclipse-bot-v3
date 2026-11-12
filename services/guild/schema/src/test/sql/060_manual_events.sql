BEGIN;

DO $$
DECLARE
    guild bigint;
    admin_id bigint;
    role_id bigint;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (9800000000000000001)
    RETURNING guild_key INTO guild;
    INSERT INTO guild.dim_discord_user (discord_user_id)
    VALUES (9800000000000000011), (9800000000000000012), (9800000000000000013);
    SELECT user_key INTO admin_id FROM guild.dim_discord_user
    WHERE discord_user_id = 9800000000000000011;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (9800000000000000021, 'Admin') RETURNING role_key INTO role_id;
    INSERT INTO guild.server_role_binding (purpose, role_key)
    VALUES ('admin', role_id);
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (admin_id, role_id, 'add', clock_timestamp(), 'manual');
    INSERT INTO guild.developer_allowlist (user_key)
    SELECT user_key FROM guild.dim_discord_user
    WHERE discord_user_id = 9800000000000000013;
    INSERT INTO guild.guild_settings (guild_key) VALUES (guild);
END;
$$;

SET LOCAL ROLE guild_runtime;

DO $$
DECLARE
    guild bigint;
    admin_id bigint;
    member_id bigint;
    developer_id bigint;
    manual_event bigint;
    scheduled_event bigint;
    returned_event bigint;
    rejected boolean;
BEGIN
    SELECT guild_key INTO STRICT guild FROM guild.dim_guild;
    SELECT user_key INTO admin_id FROM guild.dim_discord_user
    WHERE discord_user_id = 9800000000000000011;
    SELECT user_key INTO member_id FROM guild.dim_discord_user
    WHERE discord_user_id = 9800000000000000012;
    SELECT user_key INTO developer_id FROM guild.dim_discord_user
    WHERE discord_user_id = 9800000000000000013;

    rejected := false;
    BEGIN
        PERFORM guild.create_manual_clan_games(member_id,
            '2026-11-22 08:00+00', '2026-11-28 08:00+00', 4000, 'Not authorized');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Ordinary member manually created a Clan Games event'; END IF;

    manual_event := guild.create_manual_clan_games(admin_id,
        '2026-11-22 08:00+00', '2026-11-28 08:00+00', 4000, 'Scheduler recovery');
    IF NOT EXISTS (
        SELECT FROM guild.dim_clan_games_event WHERE event_key = manual_event
            AND schedule_source = 'manual' AND account_points_cap = 4000
    ) THEN
        RAISE EXCEPTION 'Manual event metadata was not retained';
    END IF;
    returned_event := guild.create_manual_clan_games(admin_id,
        '2026-11-22 08:00+00', '2026-11-28 08:00+00', 4000, 'Retry');
    IF returned_event <> manual_event THEN RAISE EXCEPTION 'Manual retry duplicated an event'; END IF;
    scheduled_event := guild.create_scheduled_clan_games(2026, 11);
    IF scheduled_event <> manual_event THEN RAISE EXCEPTION 'Schedule recovery duplicated a manual event'; END IF;

    scheduled_event := guild.create_scheduled_clan_games(2026, 12);
    returned_event := guild.create_manual_clan_games(developer_id,
        '2026-12-22 08:00+00', '2026-12-28 08:00+00', 4000, 'Existing schedule retry');
    IF returned_event <> scheduled_event THEN RAISE EXCEPTION 'Manual retry duplicated a scheduled event'; END IF;
    rejected := false;
    BEGIN
        PERFORM guild.create_manual_clan_games(admin_id,
            '2026-11-22 08:00+00', '2026-11-29 08:00+00', 5000, 'Conflicting retry');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Retry silently changed frozen event evidence'; END IF;
    IF NOT EXISTS (
        SELECT FROM guild.configuration_audit_for(developer_id)
        WHERE actor_user_key = admin_id AND entity_type = 'dim_clan_games_event'
            AND reason = 'Scheduler recovery'
    ) THEN
        RAISE EXCEPTION 'Manual creation did not record its actor and configuration decision';
    END IF;
    IF nullif(current_setting('guild.actor_user_key', true), '') IS NOT NULL THEN
        RAISE EXCEPTION 'Manual event command leaked its audit actor into later work';
    END IF;
    RAISE NOTICE 'Manual Clan Games creation, authorization, audit and idempotence passed';
END;
$$;

RESET ROLE;
ROLLBACK;
