BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    g bigint; u bigint; admin_user bigint; developer_user bigint;
    clan bigint; member_role bigint; admin_role bigint; th16 bigint; th17 bigint;
    channel bigint; first_poll bigint; last_poll bigint; player bigint;
    verification bigint; episode bigint; operation uuid;
    players bigint[] := '{}'; i integer;
    first_at timestamptz := clock_timestamp() - interval '1 hour';
BEGIN
    INSERT INTO guild.dim_guild(discord_guild_id) VALUES(9001400000000000001)
        RETURNING guild_key INTO g;
    INSERT INTO guild.guild_settings(guild_key) VALUES(g);
    INSERT INTO guild.dim_discord_user(discord_user_id) VALUES(9001400000000000011)
        RETURNING user_key INTO u;
    INSERT INTO guild.dim_discord_user(discord_user_id) VALUES(9001400000000000012)
        RETURNING user_key INTO admin_user;
    INSERT INTO guild.dim_discord_user(discord_user_id) VALUES(9001400000000000013)
        RETURNING user_key INTO developer_user;
    INSERT INTO guild.developer_allowlist (user_key) VALUES(developer_user);
    INSERT INTO guild.fact_discord_membership_event (user_key,event_kind,occurred_at)
        VALUES(u,'join',first_at),(admin_user,'join',first_at);
    INSERT INTO guild.dim_discord_role (discord_role_id,role_name)
        VALUES(9001400000000000021,'Configured Admin') RETURNING role_key INTO admin_role;
    INSERT INTO guild.server_role_binding (purpose,role_key) VALUES('admin',admin_role);
    INSERT INTO guild.fact_role_change (user_key,role_key,change_kind,changed_at,provenance_kind)
        VALUES(admin_user,admin_role,'add',first_at+interval '1 minute','manual');
    INSERT INTO guild.dim_discord_role (discord_role_id,role_name)
        VALUES(9001400000000000022,'Clan member') RETURNING role_key INTO member_role;
    INSERT INTO guild.dim_discord_role (discord_role_id,role_name)
        VALUES(9001400000000000023,'TH16') RETURNING role_key INTO th16;
    INSERT INTO guild.dim_discord_role (discord_role_id,role_name)
        VALUES(9001400000000000024,'TH17') RETURNING role_key INTO th17;
    INSERT INTO guild.town_hall_role_binding (town_hall_level,role_key)
        VALUES(16,th16),(17,th17);
    INSERT INTO guild.dim_discord_channel (discord_channel_id,channel_name)
        VALUES(9001400000000000031,'Day one') RETURNING channel_key INTO channel;
    INSERT INTO guild.dim_clan(clan_tag) VALUES('#P0YJ') RETURNING clan_key INTO clan;
    INSERT INTO guild.clan_collection_settings (clan_key) VALUES(clan);
    INSERT INTO guild.clan_role_binding (clan_key,purpose,role_key)
        VALUES(clan,'member',member_role);
    INSERT INTO guild.clan_membership_poll (clan_key,source_correlation_id,observed_at,outcome)
        VALUES(clan,'integration/first',first_at,'complete') RETURNING poll_key INTO first_poll;
    INSERT INTO guild.clan_membership_poll (clan_key,source_correlation_id,observed_at,outcome)
        VALUES(clan,'integration/last',first_at+interval '1 minute','complete')
        RETURNING poll_key INTO last_poll;
    FOR i IN 1..2 LOOP
        INSERT INTO guild.dim_player_account(player_tag)
            VALUES(CASE i WHEN 1 THEN '#P0YJ2' ELSE '#P0YJ9' END) RETURNING player_key INTO player;
        players := array_append(players,player);
        INSERT INTO guild.fact_clan_member_observation(poll_key,player_key)
            VALUES(first_poll,player);
        INSERT INTO guild.observed_clan_membership_period (player_key,clan_key,
            observed_since,confirmed_through,boundary_policy,coverage_status,first_poll_key,last_poll_key)
            VALUES(player,clan,first_at,first_at+interval '1 minute',
                'observed','adequate',first_poll,last_poll);
        verification := guild.record_player_verification(u,player,'verified');
        INSERT INTO guild.metric_attribution_episode (user_key,player_key,
            first_link_at,include_prelink_history)
            VALUES(u,player,clock_timestamp(),true) RETURNING attribution_key INTO episode;
        INSERT INTO guild.account_link (user_key,player_key,verification_key,
            attribution_key,is_primary) VALUES(u,player,verification,episode,i=1);
        INSERT INTO guild.fact_player_counter_observation(player_key,observed_at,
            source_correlation_id,town_hall_level)
            VALUES(player,first_at,'integration/profile/'||i,15+i);
    END LOOP;
    INSERT INTO guild.dim_clan_games_event (starts_at,ends_at,account_points_cap,
        schedule_source,source_correlation_id)
        VALUES(first_at,first_at+interval '6 days',4000,'manual','integration/event');
    ASSERT (SELECT count(*)=1 FROM guild.desired_clan_member_role WHERE user_key=u);
    ASSERT (SELECT count(*)=2 FROM guild.desired_town_hall_role WHERE user_key=u);
    INSERT INTO guild.fact_player_counter_observation(player_key,observed_at,source_correlation_id,war_stars)
        VALUES(players[2],clock_timestamp(),'integration/partial-profile',100);
    ASSERT (SELECT count(*)=2 FROM guild.desired_town_hall_role WHERE user_key=u),
        'A missing field in another profile observation erased a supported TH';
    PERFORM guild.set_notification_desired_roles(u,ARRAY[th16]::bigint[],'integration/th');
    SELECT operation_key INTO STRICT operation FROM guild.notification_operation
        WHERE target_user_key=u AND operation_kind='role_reconcile';
    BEGIN
        INSERT INTO guild.fact_role_change (user_key,role_key,change_kind,changed_at,
            provenance_kind,notification_operation_key)
            VALUES(u,th17,'add',clock_timestamp(),'reconciliation',operation);
        RAISE EXCEPTION 'Unmanaged role was attributed to another role operation';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_role_change (user_key,role_key,change_kind,changed_at,
        provenance_kind,notification_operation_key)
        VALUES(u,th16,'add',clock_timestamp(),'reconciliation',operation);
END;
$$;

SET LOCAL ROLE guild_runtime;
DO $$
DECLARE g bigint; admin_user bigint; developer_user bigint; role_id bigint; clan bigint; channel bigint; event_id bigint;
BEGIN
    SELECT guild_key INTO STRICT g FROM guild.dim_guild;
    SELECT user_key INTO admin_user FROM guild.dim_discord_user WHERE discord_user_id=9001400000000000012;
    SELECT user_key INTO developer_user FROM guild.dim_discord_user WHERE discord_user_id=9001400000000000013;
    SELECT role_key INTO role_id FROM guild.server_role_binding WHERE purpose='admin';
    SELECT clan_key INTO clan FROM guild.dim_clan WHERE clan_tag='#P0YJ';
    SELECT channel_key INTO channel FROM guild.dim_discord_channel;
    PERFORM guild.set_chat_xp_eligibility_role(admin_user,role_id,'Enable eligible chat role');
    PERFORM guild.set_chat_rank_role(admin_user,1,role_id,'Bind initial tier');
    PERFORM guild.set_clan_games_refresh(admin_user,1200,'Configure refresh cadence');
    PERFORM guild.set_transfer_policy(admin_user,259200,43200,'Configure transfer limits');
    PERFORM guild.set_cwl_clan_settings(admin_user,clan,45,NULL,'Configure clan cutoff');
    PERFORM guild.set_channel_binding(admin_user,'cwl_roster',clan,1,channel,
        'Bind day-one roster channel');
    PERFORM guild.set_channel_binding(admin_user,'leadership_notifications',NULL,NULL,channel,
        'Bind leadership prompt channel');
    PERFORM guild.set_war_reminder(admin_user,clan,3600,'Remind one hour before the end');
    PERFORM guild.set_war_reminder(admin_user,clan,3600,'Remind one hour before the end');
    ASSERT (SELECT count(*)=1 FROM guild.war_reminder_setting
        WHERE clan_key=clan AND seconds_before_end=3600), 'A repeated reminder must not duplicate';
    PERFORM guild.delete_war_reminder(admin_user,clan,3600,'Remove the one-hour reminder');
    ASSERT NOT EXISTS (SELECT FROM guild.war_reminder_setting
        WHERE clan_key=clan AND seconds_before_end=3600), 'A deleted reminder must be gone';
    ASSERT (SELECT refresh_seconds=1200 FROM guild.clan_games_collection_policy WHERE guild_key=g);
    ASSERT (SELECT transfer_pending_max_age_seconds=259200 AND transfer_approval_max_age_seconds=43200
        FROM guild.guild_settings WHERE guild_key=g), 'Transfer limits must be configurable guild settings';
    ASSERT (SELECT automatic_freeze_minutes=45 FROM guild.cwl_clan_settings WHERE clan_key=clan);
    ASSERT (SELECT membership_poll_seconds=120 AND raid_report_seconds=28800
        FROM guild.clan_collection_settings WHERE clan_key=clan),
        'Updating CWL settings replaced unrelated clan collection settings';
    PERFORM guild.set_server_role(admin_user,'new_joinee',role_id,'Consolidated server binding');
    PERFORM guild.set_server_role(admin_user,'new_joinee',role_id,'Consolidated server binding replay');
    PERFORM guild.set_clan_role(admin_user,clan,'war',role_id,'Consolidated clan binding');
    PERFORM guild.set_town_hall_role(admin_user,18,role_id,'Consolidated TH binding');
    ASSERT (SELECT count(*)=1 FROM guild.server_role_binding WHERE purpose='new_joinee');
    ASSERT (SELECT count(*)=1 FROM guild.clan_role_binding WHERE clan_key=clan AND purpose='war');
    ASSERT (SELECT count(*)=1 FROM guild.town_hall_role_binding WHERE town_hall_level=18);
    BEGIN
        PERFORM guild.set_clan_role(admin_user,NULL,'admin',role_id,
            'Attempt to configure server capability through clan scope');
        RAISE EXCEPTION 'Null clan scope escaped into a server role binding';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        PERFORM guild.delete_clan_role(admin_user,NULL,'admin','Attempt to delete server binding');
        RAISE EXCEPTION 'Clan-scope deletion removed a server capability';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    PERFORM guild.set_clan_games_schedule(admin_user,false,start_day,start_time_utc,
            event_seconds,account_points_cap,'Disable automatic Clan Games creation')
        FROM guild.clan_games_schedule;
    PERFORM guild.set_new_joinee_days(admin_user,12,'Update independent guild setting');
    ASSERT (SELECT NOT enabled AND account_points_cap=4000 FROM guild.clan_games_schedule WHERE guild_key=g);
    ASSERT (SELECT refresh_seconds=1200 FROM guild.clan_games_collection_policy WHERE guild_key=g),
        'Partial feature configuration overwrote another shared setting';
    ASSERT (SELECT count(*)=1 FROM guild.configuration_audit_for(developer_user)
        WHERE reason='Consolidated server binding' AND entity_type='role_binding'),
        'A shared binding write must produce one classified configuration audit record';
    -- No command deletes the guild settings row or writes the calendar
    -- selection; the generic JSON entry point that could is gone.
    ASSERT to_regprocedure('guild.configure_setting(bigint,text,jsonb,text,boolean)') IS NULL,
        'The untyped configuration transport is gone';
    ASSERT NOT EXISTS (SELECT FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'guild' AND 'jsonb'::regtype = ANY (p.proargtypes)
            AND has_function_privilege('guild_runtime', p.oid, 'EXECUTE')),
        'No runtime entry point takes a JSON argument';
    ASSERT NOT has_table_privilege(current_user,'guild.clan_games_member_account_input','INSERT');
    ASSERT has_function_privilege(current_user,'guild.attach_clan_games_member_input(bigint,bigint)','EXECUTE');
    ASSERT (SELECT count(*)=0 FROM guild.clan_games_assessment_scope(-1,'final'));
    SELECT event_key INTO STRICT event_id FROM guild.dim_clan_games_event
        WHERE source_correlation_id='integration/event';
    ASSERT (SELECT count(*)=2 AND bool_and(required_points>0)
        FROM guild.clan_games_assessment_scope(event_id,'t_minus_24h')),
        'A trusted worker cannot obtain supported owner scopes without raw link-ledger access';
    ASSERT NOT has_table_privilege(current_user,'guild.metric_attribution_episode','SELECT');
    BEGIN
        PERFORM guild.manage_developer(admin_user,admin_user,true,'Attempt self-promotion');
        RAISE EXCEPTION 'Admin granted developer status';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        PERFORM guild.configuration_audit_for(admin_user);
        RAISE EXCEPTION 'Admin viewed developer-only configuration history';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    ASSERT EXISTS(SELECT FROM guild.configuration_audit_for(developer_user)
        WHERE actor_user_key=admin_user AND source='command' AND entity_type='chat_xp_eligibility_role');
    ASSERT NOT has_function_privilege(current_user,'guild.sample_chat_xp()','EXECUTE');
    ASSERT NOT has_function_privilege(current_user,'guild.ensure_clan_games_transfer_read(bigint,timestamp with time zone)','EXECUTE');
    ASSERT NOT has_table_privilege(current_user,'guild.fact_notification_delivery_attempt','INSERT');
    ASSERT NOT has_table_privilege(current_user,'guild.notification_operation','UPDATE');
    ASSERT NOT has_table_privilege(current_user,'guild.leaderboard_calendar_state','UPDATE');
    ASSERT (SELECT count(*)=12 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='guild' AND t.tgname='record_configuration_change' AND NOT t.tgisinternal),
        'Change history must cover the configuration tables and no activity table';
END;
$$;
RESET ROLE;

DO $$
DECLARE g bigint; clan bigint; admin_user bigint; cycle bigint; participation bigint; plan bigint;
BEGIN
    SELECT guild_key INTO STRICT g FROM guild.dim_guild;
    SELECT clan_key INTO clan FROM guild.dim_clan WHERE clan_tag='#P0YJ';
    SELECT user_key INTO admin_user FROM guild.dim_discord_user WHERE discord_user_id=9001400000000000012;
    INSERT INTO guild.cwl_cycle (calendar_month)
        VALUES(date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')::date)
        RETURNING cycle_key INTO cycle;
    INSERT INTO guild.cwl_participating_clan (cycle_key,clan_key,lineup_size,selected_by)
        VALUES(cycle,clan,15,admin_user) RETURNING participation_key INTO participation;
    INSERT INTO guild.cwl_clan_day(participation_key,war_day)
        SELECT participation,day::smallint FROM generate_series(1,7) day;
    PERFORM guild.cwl_close_signups(cycle);
    SELECT plan_key INTO STRICT plan FROM guild.cwl_plan_revision WHERE participation_key=participation;
    PERFORM guild.cwl_publish_plan(plan,false);
END;
$$;
SET LOCAL ROLE guild_runtime;
DO $$
DECLARE cycle bigint; plan bigint; prompt uuid; roster uuid;
    participation bigint; middle_plan bigint; newest_plan bigint; newest_roster uuid;
BEGIN
    SELECT cycle_key INTO STRICT cycle FROM guild.cwl_cycle;
    SELECT plan_key INTO STRICT plan FROM guild.cwl_plan_revision;
    prompt := guild.queue_cwl_leadership_prompt(cycle);
    ASSERT prompt= guild.queue_cwl_leadership_prompt(cycle);
    ASSERT EXISTS(SELECT FROM guild.notification_cwl_context c
        JOIN guild.notification_operation n USING(operation_key)
        WHERE c.operation_key=prompt AND c.cycle_key=cycle
            AND c.plan_key IS NULL AND n.audience='leadership');
    roster := guild.queue_cwl_roster_report(plan,1::smallint);
    ASSERT roster= guild.queue_cwl_roster_report(plan,1::smallint);
    ASSERT EXISTS(SELECT FROM guild.notification_cwl_context c
        JOIN guild.notification_operation n USING(operation_key)
        WHERE c.operation_key=roster AND c.plan_key=plan AND c.war_day=1
            AND n.audience='members' AND n.status='pending'
            AND n.operation_kind='report_create' AND n.report_revision=1);
    BEGIN
        PERFORM guild.queue_cwl_roster_report(plan,8::smallint);
        RAISE EXCEPTION 'Output accepted an invalid CWL day';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    -- Two later plans reach the output worker out of order. The newest plan
    -- stays the latest revision of the day's report; the older plan queues nothing.
    SELECT participation_key INTO STRICT participation FROM guild.cwl_plan_revision
        WHERE plan_key = plan;
    middle_plan := guild.cwl_begin_plan(participation, 'integration');
    PERFORM guild.cwl_publish_plan(middle_plan, false);
    newest_plan := guild.cwl_begin_plan(participation, 'integration');
    PERFORM guild.cwl_publish_plan(newest_plan, false);
    newest_roster := guild.queue_cwl_roster_report(newest_plan, 1::smallint);
    ASSERT guild.queue_cwl_roster_report(middle_plan, 1::smallint) IS NULL
        AND NOT EXISTS (SELECT FROM guild.notification_cwl_context WHERE plan_key = middle_plan),
        'An older plan was queued after a newer plan of the same clan and War Day';
    ASSERT (SELECT status = 'pending' AND report_revision = 2 FROM guild.notification_operation
        WHERE operation_key = newest_roster)
        AND (SELECT status = 'superseded' FROM guild.notification_operation
            WHERE operation_key = roster),
        'The newest plan must stay the latest revision of the roster report';
    ASSERT guild.queue_cwl_roster_report(newest_plan, 1::smallint) = newest_roster
        AND guild.queue_cwl_roster_report(plan, 1::smallint) = roster,
        'A replayed plan must return its own operation';
END;
$$;
RESET ROLE;

DO $$
DECLARE g bigint; u bigint; operation uuid; fence uuid;
BEGIN
    SELECT guild_key INTO STRICT g FROM guild.dim_guild;
    SELECT user_key INTO u FROM guild.dim_discord_user WHERE discord_user_id=9001400000000000011;
    UPDATE guild.account_link SET unlinked_at=clock_timestamp()
        WHERE user_key=u AND NOT is_primary;
    ASSERT (SELECT count(*)=1 FROM guild.desired_clan_member_role WHERE user_key=u),
        'Unlinking one account removed another account requirement';
    ASSERT (SELECT count(*)=1 FROM guild.desired_town_hall_role WHERE user_key=u);
    SELECT operation_key INTO STRICT operation FROM guild.notification_operation
        WHERE target_user_key=u AND operation_kind='role_reconcile';
    PERFORM guild.record_notification_consumption(operation,'integration','notifications',0,140000);
    fence := guild.claim_notification_dispatch(operation,'integration');
    ASSERT fence IS NOT NULL;
    INSERT INTO guild.fact_discord_membership_event (user_key,event_kind,occurred_at)
        VALUES(u,'departure',clock_timestamp());
    ASSERT NOT guild.begin_notification_send(operation,fence),
        'A known Discord departure did not suppress queued role work';
    ASSERT (SELECT status='superseded' FROM guild.notification_operation WHERE operation_key=operation);
    ASSERT NOT EXISTS(SELECT FROM guild.desired_clan_member_role WHERE user_key=u);
    ASSERT NOT EXISTS(SELECT FROM guild.desired_town_hall_role WHERE user_key=u);
    ASSERT (SELECT count(*)=1 FROM guild.current_account_link WHERE user_key=u);
END;
$$;
ROLLBACK;
