BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    guild bigint;
    controller bigint;
    subject bigint;
    expired_user bigint;
    role_id bigint;
    channel_id bigint;
    player_id bigint;
    verification_id bigint;
    attribution_id bigint;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (9000900000000000001)
    RETURNING guild_key INTO guild;
    INSERT INTO guild.guild_settings (guild_key) VALUES (guild);
    INSERT INTO guild.dim_discord_user (discord_user_id)
    VALUES (9000900000000000011) RETURNING user_key INTO controller;
    INSERT INTO guild.dim_discord_user (discord_user_id)
    VALUES (9000900000000000012) RETURNING user_key INTO subject;
    INSERT INTO guild.dim_discord_user (discord_user_id)
    VALUES (9000900000000000013) RETURNING user_key INTO expired_user;
    INSERT INTO guild.dim_discord_role (guild_key, discord_role_id, role_name)
    VALUES (guild, 9000900000000000021, 'Configured Admin') RETURNING role_key INTO role_id;
    INSERT INTO guild.server_role_binding (guild_key, purpose, role_key)
    VALUES (guild, 'admin', role_id);
    INSERT INTO guild.fact_discord_membership_event (guild_key, user_key, event_kind, occurred_at)
    VALUES (guild, controller, 'join', '2026-11-01 00:00:00+00'),
        (guild, subject, 'join', '2026-11-01 00:00:00+00'),
        (guild, expired_user, 'join', '2020-01-01 00:00:00+00');
    INSERT INTO guild.fact_role_change (
        guild_key, user_key, role_key, change_kind, changed_at, provenance_kind
    ) VALUES (guild, controller, role_id, 'add', '2026-11-01 01:00:00+00', 'manual'),
        (guild, subject, role_id, 'add', '2026-11-01 01:00:00+00', 'manual');
    INSERT INTO guild.fact_role_change (
        guild_key, user_key, role_key, change_kind, changed_at, provenance_kind,
        origin_join_event_key, expires_at
    )
    SELECT guild, expired_user, role_id, 'add', '2020-01-01 01:00:00+00', 'manual',
        membership_event_key, new_joinee_expires_at
    FROM guild.fact_discord_membership_event
    WHERE guild_key = guild AND user_key = expired_user AND event_kind = 'join';
    INSERT INTO guild.dim_discord_channel (guild_key, discord_channel_id, channel_name)
    VALUES (guild, 9000900000000000031, 'Chat') RETURNING channel_key INTO channel_id;
    PERFORM guild.credit_chat_xp(guild, subject, channel_id, 9000900000000000041,
        '2026-11-01 02:00:00+00');
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#Y0Q')
    RETURNING player_key INTO player_id;
    verification_id := guild.record_player_verification(guild, subject, player_id, 'verified');
    INSERT INTO guild.metric_attribution_episode (
        guild_key, user_key, player_key, first_link_at, include_prelink_history
    ) VALUES (guild, subject, player_id, clock_timestamp(), true)
    RETURNING attribution_key INTO attribution_id;
    INSERT INTO guild.account_link (
        guild_key, user_key, player_key, verification_key, attribution_key, is_primary
    ) VALUES (guild, subject, player_id, verification_id, attribution_id, true);
END;
$$;

SET LOCAL ROLE guild_runtime;

-- Exercise actual relation shadowing rather than only inspecting proconfig.
-- If a definer uses pg_temp before pg_catalog, its catalog introspection will
-- call this untrusted invoker function through the attacker's temporary views.
CREATE TEMP TABLE security_probe_invocations (effective_user name NOT NULL);
GRANT INSERT, SELECT ON pg_temp.security_probe_invocations TO PUBLIC;
CREATE FUNCTION pg_temp.note_definer_invocation() RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER AS $$
BEGIN
    INSERT INTO pg_temp.security_probe_invocations VALUES (current_user);
    RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION pg_temp.note_definer_invocation() TO PUBLIC;
CREATE TEMP VIEW pg_attribute AS
SELECT a.attrelid, a.attname, a.attnum, a.attisdropped, a.attidentity, a.attgenerated
FROM pg_catalog.pg_attribute AS a WHERE pg_temp.note_definer_invocation();
CREATE TEMP VIEW pg_index AS
SELECT i.indrelid, i.indisprimary, i.indkey
FROM pg_catalog.pg_index AS i WHERE pg_temp.note_definer_invocation();
GRANT SELECT ON pg_temp.pg_attribute, pg_temp.pg_index TO PUBLIC;

DO $$
DECLARE
    guild bigint;
    controller bigint;
    subject bigint;
    expired_user bigint;
    role_id bigint;
    old_join bigint;
BEGIN
    SELECT guild_key INTO STRICT guild FROM guild.dim_guild;
    SELECT user_key INTO controller FROM guild.dim_discord_user
    WHERE discord_user_id = 9000900000000000011;
    SELECT user_key INTO subject FROM guild.dim_discord_user
    WHERE discord_user_id = 9000900000000000012;
    SELECT user_key INTO expired_user FROM guild.dim_discord_user
    WHERE discord_user_id = 9000900000000000013;
    SELECT role_key INTO role_id FROM guild.server_role_binding
    WHERE guild_key = guild AND purpose = 'admin';
    PERFORM guild.configure_setting(guild, controller, 'guild_settings',
        '{"new_joinee_days":8}'::jsonb, 'Temporary-catalog-shadow regression');
    ASSERT (SELECT new_joinee_days = 8 FROM guild.guild_settings WHERE guild_key = guild),
        'Curated runtime configuration grant must survive hardening';
    ASSERT NOT EXISTS (SELECT FROM pg_temp.security_probe_invocations),
        'A definer executed attacker-controlled temporary catalog views';
    ASSERT NOT EXISTS (
        SELECT FROM pg_catalog.pg_proc AS p
        JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'guild' AND p.prosecdef
            AND NOT coalesce(p.proconfig @> ARRAY['search_path=pg_catalog, guild, pg_temp'], false)
    ), 'Every definer must explicitly place pg_temp after trusted namespaces';
    ASSERT NOT EXISTS (
        SELECT FROM pg_catalog.pg_proc AS p
        JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
        CROSS JOIN LATERAL pg_catalog.aclexplode(
            coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
        ) AS a
        WHERE n.nspname = 'guild' AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'
    ), 'PUBLIC must not execute guild functions';

    ASSERT guild.can_moderate(guild, subject) AND guild.can_configure(guild, subject),
        'The initial confirmed Admin role should authorize its member';
    INSERT INTO guild.fact_discord_membership_event (guild_key, user_key, event_kind, occurred_at)
    VALUES (guild, subject, 'departure', '2026-11-02 00:00:00+00');
    ASSERT NOT EXISTS (SELECT FROM guild.discord_member_role
        WHERE guild_key = guild AND user_key = subject), 'Departure must clear confirmed role state';
    INSERT INTO guild.fact_role_change (
        guild_key, user_key, role_key, change_kind, changed_at, provenance_kind
    ) VALUES (guild, subject, role_id, 'add', '2026-11-01 02:00:00+00', 'manual');
    ASSERT NOT EXISTS (SELECT FROM guild.discord_member_role
        WHERE guild_key = guild AND user_key = subject), 'A delayed old event revived departed authority';
    INSERT INTO guild.fact_discord_membership_event (guild_key, user_key, event_kind, occurred_at)
    VALUES (guild, subject, 'join', '2026-11-03 00:00:00+00')
    RETURNING membership_event_key INTO old_join;
    ASSERT NOT guild.can_moderate(guild, subject) AND NOT guild.can_configure(guild, subject),
        'Rejoining without a fresh role confirmation restored staff authority';
    INSERT INTO guild.fact_role_change (
        guild_key, user_key, role_key, change_kind, changed_at, provenance_kind
    ) VALUES (guild, subject, role_id, 'add', '2026-11-02 12:00:00+00', 'manual');
    ASSERT NOT guild.can_moderate(guild, subject),
        'A pre-rejoin role confirmation must remain historical';
    ASSERT (SELECT xp_total = 20 FROM guild.chat_xp_all_time_totals
        WHERE guild_key = guild AND user_key = subject), 'Departure erased chat XP';
    ASSERT (SELECT count(*) = 1 FROM guild.current_account_link
        WHERE guild_key = guild AND user_key = subject), 'Departure erased account links';
    ASSERT (SELECT count(*) = 3 FROM guild.fact_role_change
        WHERE guild_key = guild AND user_key = subject), 'Projection repair erased source role facts';
    INSERT INTO guild.fact_role_change (
        guild_key, user_key, role_key, change_kind, changed_at, provenance_kind
    ) VALUES (guild, subject, role_id, 'add', '2026-11-03 01:00:00+00', 'manual');
    ASSERT guild.can_moderate(guild, subject), 'Fresh role confirmation did not restore valid authority';
    INSERT INTO guild.fact_discord_membership_event (guild_key, user_key, event_kind, occurred_at)
    VALUES (guild, subject, 'departure', '2026-11-02 01:00:00+00');
    ASSERT guild.can_moderate(guild, subject), 'An out-of-order departure erased current authority';
    INSERT INTO guild.fact_role_change (
        guild_key, user_key, role_key, change_kind, changed_at, provenance_kind
    ) VALUES (guild, subject, role_id, 'remove', '2026-11-03 02:00:00+00', 'manual'),
        (guild, subject, role_id, 'add', '2026-11-03 01:30:00+00', 'manual');
    ASSERT NOT guild.can_moderate(guild, subject), 'An old add overrode a newer role removal';

    INSERT INTO guild.fact_discord_membership_event (guild_key, user_key, event_kind, occurred_at)
    VALUES (guild, subject, 'departure', '2026-11-04 00:00:00+00');
    INSERT INTO guild.fact_role_change (
        guild_key, user_key, role_key, change_kind, changed_at, provenance_kind
    ) VALUES (guild, subject, role_id, 'add', '2026-11-05 01:00:00+00', 'manual');
    ASSERT NOT guild.can_moderate(guild, subject),
        'A role event must not authorize a member while observed as departed';
    INSERT INTO guild.fact_discord_membership_event (guild_key, user_key, event_kind, occurred_at)
    VALUES (guild, subject, 'join', '2026-11-05 00:00:00+00');
    ASSERT guild.can_moderate(guild, subject),
        'A fresh source confirmation arriving before its join event was not reconciled';
    INSERT INTO guild.fact_role_change (
        guild_key, user_key, role_key, change_kind, changed_at, provenance_kind, origin_join_event_key
    ) VALUES (guild, subject, role_id, 'remove', '2026-11-05 03:00:00+00', 'manual', old_join);
    ASSERT guild.can_moderate(guild, subject),
        'An earlier join occurrence removed a role confirmed for the current stay';
    ASSERT NOT guild.can_moderate(guild, expired_user)
        AND NOT guild.can_configure(guild, expired_user), 'Expired role evidence authorized staff commands';
END;
$$;
RESET ROLE;

-- Check defaults as the actual migration/schema owner, not the fixture's
-- superuser. The probe is rolled back with the rest of this test.
DO $$
DECLARE
    migration_owner name;
    previous_role name := current_user;
    public_execute boolean;
BEGIN
    SELECT pg_catalog.pg_get_userbyid(nspowner) INTO STRICT migration_owner
    FROM pg_catalog.pg_namespace WHERE nspname = 'guild';
    EXECUTE format('SET LOCAL ROLE %I', migration_owner);
    EXECUTE 'CREATE FUNCTION guild._test_default_execute_probe() RETURNS integer '
        || 'LANGUAGE sql AS ''SELECT 1''';
    SELECT EXISTS (
        SELECT FROM pg_catalog.pg_proc AS p
        JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
        CROSS JOIN LATERAL pg_catalog.aclexplode(
            coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
        ) AS a
        WHERE n.nspname = 'guild' AND p.proname = '_test_default_execute_probe'
            AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'
    ) INTO public_execute;
    EXECUTE format('SET LOCAL ROLE %I', previous_role);
    ASSERT NOT public_execute, 'Future migration-owned functions regained default PUBLIC EXECUTE';
    ASSERT NOT EXISTS (SELECT FROM pg_temp.security_probe_invocations),
        'Catalog shadow views were invoked during a hardened operation';
    RAISE NOTICE 'Definer search-path, default ACL, role-epoch and retention assertions passed';
END;
$$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
