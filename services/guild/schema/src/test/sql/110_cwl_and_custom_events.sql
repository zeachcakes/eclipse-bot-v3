BEGIN;
SET LOCAL plpgsql.check_asserts=on;
DO $$
DECLARE
    g bigint; member_id bigint; staff bigint; stranger bigint; developer bigint; role_id bigint;
    ca bigint; cb bigint; pc bigint; p1 bigint; p2 bigint; defender bigint; extra bigint;
    cycle_id bigint; future_cycle bigint; part bigint; future_part bigint; group_id bigint;
    signup_id bigint; plan_id bigint; manual_plan bigint; incident bigint; missing bigint;
    w1 bigint; w2 bigint; w3 bigint; w4 bigint; custom_war bigint; attack_id bigint;
    event_id bigint; roster_id bigint; ver bigint; episode bigint; result bigint; n integer; membership_poll bigint;
    operation uuid; ts timestamptz:=statement_timestamp();
BEGIN
    INSERT INTO guild.dim_guild(discord_guild_id) VALUES(811000) RETURNING guild_key INTO g;
    INSERT INTO guild.dim_discord_user(discord_user_id) VALUES(811001) RETURNING user_key INTO member_id;
    INSERT INTO guild.dim_discord_user(discord_user_id) VALUES(811002) RETURNING user_key INTO staff;
    INSERT INTO guild.dim_discord_user(discord_user_id) VALUES(811003) RETURNING user_key INTO stranger;
    INSERT INTO guild.dim_discord_user(discord_user_id) VALUES(811004) RETURNING user_key INTO developer;
    INSERT INTO guild.developer_allowlist (user_key) VALUES(developer);
    INSERT INTO guild.fact_discord_membership_event (user_key,event_kind,occurred_at)
        SELECT u,'join',ts-interval '20 days' FROM unnest(ARRAY[member_id,staff,stranger,developer]) u;
    INSERT INTO guild.dim_discord_role (discord_role_id,role_name) VALUES(811005,'Co-leader') RETURNING role_key INTO role_id;
    INSERT INTO guild.server_role_binding VALUES('co_leader',role_id);
    INSERT INTO guild.fact_role_change (user_key,role_key,change_kind,changed_at,actor_user_key,provenance_kind)
        VALUES(staff,role_id,'add',ts-interval '19 days',staff,'manual');
    INSERT INTO guild.dim_clan(clan_tag) VALUES('#P0Y') RETURNING clan_key INTO ca;
    INSERT INTO guild.dim_clan(clan_tag) VALUES('#Q0L') RETURNING clan_key INTO cb;
    INSERT INTO guild.dim_clan(clan_tag) VALUES('#R0J') RETURNING clan_key INTO pc;
    INSERT INTO guild.clan_collection_settings (clan_key) VALUES(ca),(cb),(pc);
    ASSERT (SELECT count(*)=3 FROM guild.cwl_clan_settings),
        'Tracked clans share collection and CWL settings without a second configuration row';
    INSERT INTO guild.dim_player_account(player_tag) VALUES('#P0Y2') RETURNING player_key INTO p1;
    INSERT INTO guild.dim_player_account(player_tag) VALUES('#P0Y9') RETURNING player_key INTO p2;
    INSERT INTO guild.dim_player_account(player_tag) VALUES('#Q0L2') RETURNING player_key INTO defender;
    INSERT INTO guild.clan_membership_poll (clan_key,source_correlation_id,observed_at,outcome)
        VALUES(ca,'cwl-current-clan-a',ts-interval '10 days','complete') RETURNING poll_key INTO membership_poll;
    INSERT INTO guild.fact_clan_member_observation(poll_key,player_key) VALUES(membership_poll,p1);
    INSERT INTO guild.observed_clan_membership_period (player_key,clan_key,observed_since,confirmed_through,
        boundary_policy,coverage_status,first_poll_key,last_poll_key)
        VALUES(p1,ca,ts-interval '10 days',ts-interval '10 days','first-complete-observation','adequate',membership_poll,membership_poll);
    -- Own linked identity is sufficient; signup deliberately does not require
    -- current membership in the target clan or any synthetic game mutation.
    INSERT INTO guild.player_verification (user_key,player_key,status)
        VALUES(member_id,p1,'verified') RETURNING verification_key INTO ver;
    INSERT INTO guild.metric_attribution_episode (user_key,player_key,first_link_at,include_prelink_history)
        VALUES(member_id,p1,ts-interval '10 days',true) RETURNING attribution_key INTO episode;
    INSERT INTO guild.account_link (user_key,player_key,verification_key,attribution_key,linked_at,is_primary)
        VALUES(member_id,p1,ver,episode,ts-interval '10 days',true);
    future_cycle:=guild.cwl_create_cycle(developer,gen_random_uuid(),
        (date_trunc('month',ts)+interval '1 month')::date);
    future_part:=guild.cwl_select_clan(staff,gen_random_uuid(),future_cycle,cb,15);
    operation:=gen_random_uuid();
    signup_id:=guild.cwl_signup(member_id,operation,future_part,p1,ARRAY[1,3,5,6,7],18,false);
    ASSERT signup_id=guild.cwl_signup(member_id,operation,future_part,p1,ARRAY[1,3,5,6,7],18,false),'Signup command retries must not duplicate revisions';
    ASSERT EXISTS(SELECT FROM guild.current_observed_clan_member WHERE player_key=p1 AND clan_key=ca),'Current Clan A membership is retained while signing up to target Clan B';
    ASSERT (SELECT count(*)=1 FROM guild.fact_cwl_signup_revision WHERE operation_id=operation),'One stable operation produces one signup revision';
    ASSERT (SELECT count(*)=1 FROM guild.cwl_export_revision WHERE signup_revision_key=signup_id),'Signup edits automatically queue an export revision';
    BEGIN
        PERFORM guild.cwl_signup(member_id,operation,future_part,p1,ARRAY[1,3,5,6,7],17,false);
        RAISE EXCEPTION 'Operation identity accepted changed arguments';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        PERFORM guild.cwl_signup(stranger,gen_random_uuid(),future_part,p1,ARRAY[1,3,5,6,7],18,false);
        RAISE EXCEPTION 'Unlinked stranger signed up another account';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    BEGIN
        PERFORM guild.cwl_signup(member_id,gen_random_uuid(),future_part,p1,ARRAY[0,8],18,false);
        RAISE EXCEPTION 'Invalid War Days were accepted';
    EXCEPTION WHEN check_violation THEN NULL; END;
    ASSERT (SELECT arguments=jsonb_build_object('participation_key',future_part,'player_key',p1,
            'war_days',jsonb_build_array(1,3,5,6,7),'town_hall_level',18,'withdrawn',false)
        FROM guild.activity_command_operation WHERE operation_id=operation),
        'A command stores exactly its typed arguments';
    -- Past deadline fixture: staff can make late changes, members cannot.
    INSERT INTO guild.cwl_cycle (calendar_month)
        VALUES((date_trunc('month',ts)-interval '1 month')::date) RETURNING cycle_key INTO cycle_id;
    INSERT INTO guild.cwl_participating_clan (cycle_key,clan_key,lineup_size,selected_by)
        VALUES(cycle_id,ca,15,staff) RETURNING participation_key INTO part;
    INSERT INTO guild.cwl_clan_day SELECT part,d,NULL FROM generate_series(1,7) d;
    BEGIN
        PERFORM guild.cwl_signup(member_id,gen_random_uuid(),part,p1,ARRAY[1,3,5,6,7],18,false);
        RAISE EXCEPTION 'Member availability edit accepted after deadline';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    PERFORM guild.cwl_signup(staff,gen_random_uuid(),part,p1,ARRAY[1,3,5,6,7],18,false);
    PERFORM guild.cwl_signup(staff,gen_random_uuid(),part,p2,ARRAY[1,2,3,4,5,6,7],18,false);
    PERFORM guild.cwl_close_signups(cycle_id);
    SELECT plan_key INTO plan_id FROM guild.cwl_plan_revision WHERE participation_key=part;
    ASSERT (SELECT count(*)=7 FROM guild.cwl_plan_day WHERE plan_key=plan_id),'Closing signups immediately creates seven provisional War Days';
    ASSERT (SELECT count(*)=7 FROM guild.cwl_plan_day d
        LEFT JOIN guild.cwl_plan_assignment a USING(plan_key,war_day)
        WHERE d.plan_key=plan_id AND a.player_key IS NULL),
        'A new empty plan still exposes every day';
    ASSERT (SELECT phase='initial_th_availability' FROM guild.cwl_plan_revision WHERE plan_key=plan_id),'Initial plan has explicit provisional TH/availability provenance';
    ASSERT guild.cwl_registration_status(part,p1)='unknown','Absent API registration remains unknown';
    ASSERT (SELECT current_season_stars=0 FROM guild.fact_cwl_plan_input WHERE plan_key=plan_id AND player_key=p1),'Initial snapshot has no fabricated stars';
    BEGIN
        INSERT INTO guild.cwl_plan_assignment VALUES(plan_id,8,1,p1);
        RAISE EXCEPTION 'Derived plan days allowed an eighth day';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        INSERT INTO guild.cwl_plan_assignment VALUES(plan_id,2,1,p1);
        RAISE EXCEPTION 'Assignment ignored strict selected availability';
    EXCEPTION WHEN check_violation THEN NULL; END;
    INSERT INTO guild.cwl_plan_assignment VALUES(plan_id,1,1,p1);
    BEGIN
        PERFORM guild.cwl_publish_plan(plan_id,true);
        RAISE EXCEPTION 'An incomplete seven-day roster was reported complete';
    EXCEPTION WHEN check_violation THEN NULL; END;
    PERFORM guild.cwl_publish_plan(plan_id,false);
    ASSERT (SELECT quality='incomplete' FROM guild.cwl_plan_revision WHERE plan_key=plan_id),'Shortage stays explicit';
    ASSERT EXISTS(SELECT FROM guild.cwl_export_revision WHERE plan_key=plan_id),'Published lineups queue Sheets/CSV revision';
    -- Actual source group season is opaque and registration differs from daily
    -- participation; plan slots are never constrained by source map positions.
    INSERT INTO guild.fact_cwl_group_observation(cycle_key,source_season,source_state,observed_at,source_correlation_id,is_complete)
        VALUES(cycle_id,'2026-11-02','inWar',ts,'cwl-test-group',true) RETURNING group_observation_key INTO group_id;
    INSERT INTO guild.fact_cwl_registered_clan VALUES(group_id,ca),(group_id,cb);
    INSERT INTO guild.fact_cwl_registered_player VALUES(group_id,ca,p1,18,'Main'),(group_id,ca,p2,18,'Alt'),(group_id,cb,defender,18,'Opponent');
    ASSERT guild.cwl_registration_status(part,p1)='registered','Registration reconciles to actual clan pool';
    ASSERT guild.cwl_registration_status(part,defender)='not_registered','Another clan pool does not confer eligibility';
    INSERT INTO guild.dim_war(clan_a_key,clan_b_key,preparation_started_at,started_at,ends_at,team_size,attacks_per_member,identity_source,war_kind,source_war_tag,attack_allowance_source)
        VALUES(least(ca,cb),greatest(ca,cb),ts-interval '4 days',ts-interval '3 days',ts-interval '2 days',15,1,'cwl_war_tag','cwl','#CWLTEST1','game_format') RETURNING war_key INTO w1;
    INSERT INTO guild.dim_war(clan_a_key,clan_b_key,preparation_started_at,started_at,ends_at,team_size,attacks_per_member,identity_source,war_kind,source_war_tag,attack_allowance_source)
        VALUES(least(ca,cb),greatest(ca,cb),ts-interval '2 days',ts-interval '1 day',ts+interval '20 minutes',15,1,'cwl_war_tag','cwl','#CWLTEST3','game_format') RETURNING war_key INTO w2;
    INSERT INTO guild.dim_war(clan_a_key,clan_b_key,preparation_started_at,started_at,ends_at,team_size,attacks_per_member,identity_source,war_kind,source_war_tag,attack_allowance_source)
        VALUES(least(ca,cb),greatest(ca,cb),ts+interval '1 day',ts+interval '2 days',ts+interval '3 days',15,1,'cwl_war_tag','cwl','#CWLTEST5','game_format') RETURNING war_key INTO w3;
    INSERT INTO guild.cwl_round_war_reference VALUES(group_id,1,'#CWLTEST1',w1),(group_id,3,'#CWLTEST3',w2),(group_id,5,'#CWLTEST5',w3),(group_id,7,'#0',NULL);
    UPDATE guild.cwl_clan_day SET war_key=w1 WHERE participation_key=part AND war_day=1;
    UPDATE guild.cwl_clan_day SET war_key=w2 WHERE participation_key=part AND war_day=3;
    UPDATE guild.cwl_clan_day SET war_key=w3 WHERE participation_key=part AND war_day=5;
    INSERT INTO guild.war_participant VALUES(w1,ca,p1),(w1,cb,defender),(w2,ca,p1),(w2,ca,p2),(w2,cb,defender);
    INSERT INTO guild.fact_war_roster_observation(war_key,clan_key,player_key,observed_at,source_correlation_id,player_name,town_hall_level,map_position)
        VALUES(w1,ca,p1,ts-interval '2 days','cwl-ended-roster','Main',18,34);
    INSERT INTO guild.fact_war_attack(war_key,attacker_key,defender_key,attack_order,stars,destruction_percentage,duration_seconds,first_observed_at,last_observed_at,source_correlation_id)
        VALUES(w1,p1,defender,1,1,50,180,ts-interval '2 days',ts-interval '2 days','cwl-poor-attack') RETURNING attack_key INTO attack_id;
    INSERT INTO guild.fact_cwl_bench_incident(participation_key,player_key,war_key,attack_key,incident_kind,source_observed_at)
        VALUES(part,p1,w1,attack_id,'poor_attack',ts-interval '2 days') RETURNING incident_key INTO incident;
    BEGIN
        INSERT INTO guild.fact_cwl_bench_incident(participation_key,player_key,war_key,attack_key,incident_kind,source_observed_at)
            VALUES(part,p1,w1,attack_id,'poor_attack',ts);
        RAISE EXCEPTION 'Repeated source attack duplicated penalty';
    EXCEPTION WHEN unique_violation THEN NULL; END;
    ASSERT guild.cwl_next_bench_day(incident)=5,'Frozen Day3 and unavailable Day4 must not consume a bench';
    ASSERT guild.cwl_assign_bench(incident)=5,'Next eligible available day is stored separately from completed service';
    ASSERT NOT EXISTS(SELECT FROM guild.fact_cwl_bench_resolution WHERE incident_key=incident),'Assignment is not proof a war was served';
    PERFORM guild.cwl_signup(staff,gen_random_uuid(),part,p1,ARRAY[1,3,6,7],18,false);
    ASSERT guild.cwl_assign_bench(incident)=6,'New staff unavailability must not consume the previously assigned Day5';
    PERFORM guild.cwl_signup(staff,gen_random_uuid(),part,p1,ARRAY[1,3,5,6,7],18,false);
    ASSERT guild.cwl_assign_bench(incident)=5,'Restored earlier availability replans the earliest still-changeable bench';
    plan_id:=guild.cwl_begin_plan(part,'current-season-test','current_season_performance');
    ASSERT (SELECT current_season_stars=1 AND current_season_attacks=1 FROM guild.fact_cwl_plan_input WHERE plan_key=plan_id AND player_key=p1),'Current-cycle CWL evidence enters input snapshot';
    BEGIN
        INSERT INTO guild.cwl_plan_assignment VALUES(plan_id,5,1,p1);
        RAISE EXCEPTION 'Benched account selected on assigned skipped day';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        INSERT INTO guild.cwl_plan_assignment VALUES(plan_id,3,1,p2);
        RAISE EXCEPTION 'Automatic assignment changed frozen lineup';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        PERFORM guild.cwl_record_bench_service(incident,5::smallint);
        RAISE EXCEPTION 'Future war falsely proved completed bench service';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        PERFORM guild.cwl_override_bench(developer,gen_random_uuid(),incident,'No staff role');
        RAISE EXCEPTION 'Developer allowlist alone overrode a staff-only bench';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    BEGIN
        PERFORM guild.cwl_pin(staff,gen_random_uuid(),part,5,1,p1,'Pin alone');
        RAISE EXCEPTION 'Manual pin implicitly waived penalty';
    EXCEPTION WHEN check_violation THEN NULL; END;
    PERFORM guild.cwl_override_bench(staff,gen_random_uuid(),incident,'Explicit staff override');
    PERFORM guild.cwl_pin(staff,gen_random_uuid(),part,5,1,p1,'Manual selection');
    BEGIN
        INSERT INTO guild.cwl_plan_assignment VALUES(plan_id,5,1,p2);
        RAISE EXCEPTION 'Automatic regeneration overwrote pin';
    EXCEPTION WHEN check_violation THEN NULL; END;
    -- Freeze only blocks automatic changes. A current staff actor can create
    -- a manual revision and pin a replacement after the configured cutoff.
    manual_plan:=guild.cwl_manual_plan(staff,gen_random_uuid(),part,NULL);
    PERFORM guild.cwl_set_assignment(staff,gen_random_uuid(),manual_plan,3,1,p2);
    -- Partial/ongoing evidence cannot establish a missed attack.
    BEGIN
        INSERT INTO guild.fact_cwl_bench_incident(participation_key,player_key,war_key,incident_kind,source_observed_at)
            VALUES(part,p2,w2,'missed_attack',ts);
        RAISE EXCEPTION 'Missing attack in ongoing/incomplete roster created a penalty';
    EXCEPTION WHEN check_violation THEN NULL; END;
    -- Complete ended roster plus reconciled zero attack count is sufficient.
    INSERT INTO guild.fact_war_clan_observation(war_key,clan_key,observed_at,source_correlation_id,state,stars,attacks,destruction_percentage)
        VALUES(w2,ca,ts,'complete-ended-cwl','warEnded',0,0,0);
    FOR n IN 1..13 LOOP
        INSERT INTO guild.dim_player_account(player_tag) VALUES('#P'||repeat('Y',n)) RETURNING player_key INTO extra;
        INSERT INTO guild.war_participant VALUES(w2,ca,extra);
        INSERT INTO guild.fact_war_roster_observation(war_key,clan_key,player_key,observed_at,source_correlation_id,player_name,town_hall_level,map_position)
            VALUES(w2,ca,extra,ts,'complete-ended-cwl','Other',18,n);
    END LOOP;
    INSERT INTO guild.fact_war_roster_observation(war_key,clan_key,player_key,observed_at,source_correlation_id,player_name,town_hall_level,map_position)
        VALUES(w2,ca,p1,ts,'complete-ended-cwl','Main',18,33),(w2,ca,p2,ts,'complete-ended-cwl','Alt',18,34);
    INSERT INTO guild.fact_cwl_bench_incident(participation_key,player_key,war_key,incident_kind,source_observed_at)
        VALUES(part,p2,w2,'missed_attack',ts) RETURNING incident_key INTO missing;
    -- Unrelated regular-war evidence never enters current-season CWL inputs.
    INSERT INTO guild.dim_war(clan_a_key,clan_b_key,preparation_started_at,started_at,ends_at,team_size,attacks_per_member,identity_source)
        VALUES(least(ca,cb),greatest(ca,cb),ts-interval '10 days',ts-interval '9 days',ts-interval '8 days',15,2,'clan_pair_preparation') RETURNING war_key INTO w4;
    INSERT INTO guild.war_participant VALUES(w4,ca,p1),(w4,cb,defender);
    INSERT INTO guild.fact_war_attack(war_key,attacker_key,defender_key,attack_order,stars,destruction_percentage,first_observed_at,last_observed_at,source_correlation_id)
        VALUES(w4,p1,defender,1,3,100,ts-interval '8 days',ts-interval '8 days','regular-not-cwl');
    ASSERT (SELECT stars=1 FROM guild.cwl_current_performance(part,p1)),'Regular-war stars must not enter the CWL performance scope';
    -- Export failure records outcome without pretending a Sheet was updated.
    SELECT export_revision_key INTO result FROM guild.cwl_export_revision ORDER BY export_revision_key LIMIT 1;
    INSERT INTO guild.fact_cwl_export_attempt(export_revision_key,export_format,attempt_number,outcome,error_code)
        VALUES(result,'google_sheets',1,'failed','permission_denied');
    ASSERT (SELECT sheets_state='failed' FROM guild.cwl_export_revision WHERE export_revision_key=result),'Failed Sheet attempt projects failure rather than claiming success';
    -- One custom event combines accounts without importing CWL's seven-day model.
    event_id:=guild.custom_event_create(staff,gen_random_uuid(),'Combined clans');
    PERFORM guild.custom_event_signup(member_id,gen_random_uuid(),event_id,p1,false);
    PERFORM guild.custom_event_signup(staff,gen_random_uuid(),event_id,p2,false);
    roster_id:=guild.custom_event_roster(staff,gen_random_uuid(),event_id,ARRAY[p1,p2],'One combined roster');
    ASSERT (SELECT count(*)=2 FROM guild.custom_roster_account WHERE roster_key=roster_id),'Custom roster retains account identities, not one Discord aggregate';
    BEGIN
        PERFORM guild.custom_event_roster(member_id,gen_random_uuid(),event_id,ARRAY[p1],'Unauthorized');
        RAISE EXCEPTION 'Ordinary member manually selected a custom roster';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    INSERT INTO guild.dim_war(clan_a_key,clan_b_key,preparation_started_at,started_at,ends_at,team_size,attacks_per_member,identity_source,war_kind)
        VALUES(least(ca,pc),greatest(ca,pc),ts-interval '5 days',ts-interval '4 days',ts-interval '3 days',15,2,'manual_validated','custom') RETURNING war_key INTO custom_war;
    BEGIN
        PERFORM guild.custom_event_result(staff,gen_random_uuid(),event_id,w4,'Wrong war kind');
        RAISE EXCEPTION 'A regular war was attached to a custom event';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        UPDATE guild.custom_event SET war_key=custom_war WHERE event_key=event_id;
        RAISE EXCEPTION 'A game-war association omitted its actor, operation and reason';
    EXCEPTION WHEN check_violation THEN NULL; END;
    operation:=gen_random_uuid();
    PERFORM guild.custom_event_result(staff,operation,event_id,custom_war,'Observed friendly result');
    ASSERT event_id=guild.custom_event_result(staff,operation,event_id,custom_war,'Observed friendly result'),
        'A retried custom-result command returns its original association';
    ASSERT EXISTS(SELECT FROM guild.custom_event_war WHERE event_key=event_id AND war_key=custom_war),'Available custom result association persists separately from signup roster';
    ASSERT (SELECT war_key=custom_war AND association_operation_id=operation
        FROM guild.custom_event WHERE event_key=event_id),
        'The custom event stores its single typed game-war association';
    BEGIN
        UPDATE guild.custom_event SET association_reason='Rewrite' WHERE event_key=event_id;
        RAISE EXCEPTION 'Inline association history was rewritten';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        UPDATE guild.custom_event SET war_key=NULL,associated_by=NULL,
            association_operation_id=NULL,association_reason=NULL WHERE event_key=event_id;
        RAISE EXCEPTION 'Inline association history was erased';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        DELETE FROM guild.custom_event WHERE event_key=event_id;
        RAISE EXCEPTION 'Deleting its event erased a retained association';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        PERFORM guild.custom_event_result(staff,gen_random_uuid(),event_id,custom_war,'Observed friendly result');
        RAISE EXCEPTION 'A new command silently replaced the write-once association';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        PERFORM guild.cwl_end_cycle(cycle_id,ts);
        RAISE EXCEPTION 'Season expired while its known war is still in the future';
    EXCEPTION WHEN check_violation THEN NULL; END;
    -- Assign a real Day4 bench, then simulate time passage in these isolated
    -- source fixtures. No production clock/configuration is changed.
    INSERT INTO guild.dim_war(clan_a_key,clan_b_key,preparation_started_at,started_at,ends_at,team_size,attacks_per_member,identity_source,war_kind,source_war_tag,attack_allowance_source)
        VALUES(least(ca,cb),greatest(ca,cb),ts+interval '12 hours',ts+interval '1 day',ts+interval '2 days',15,1,'cwl_war_tag','cwl','#CWLTEST4','game_format') RETURNING war_key INTO w4;
    INSERT INTO guild.cwl_round_war_reference VALUES(group_id,4,'#CWLTEST4',w4);
    UPDATE guild.cwl_clan_day SET war_key=w4 WHERE participation_key=part AND war_day=4;
    ASSERT guild.cwl_assign_bench(missing)=4,'Available otherwise eligible Day4 is assigned for the new missed attack';
    UPDATE guild.dim_war SET preparation_started_at=preparation_started_at-interval '4 days',
        started_at=started_at-interval '4 days',ends_at=ends_at-interval '4 days' WHERE war_key=ANY(ARRAY[w1,w2,w3,w4]);
    INSERT INTO guild.war_participant(war_key,clan_key,player_key)
        SELECT w4,ca,player_key FROM guild.war_participant WHERE war_key=w2 AND clan_key=ca AND player_key<>p2;
    INSERT INTO guild.dim_player_account(player_tag) VALUES('#P'||repeat('Y',20)) RETURNING player_key INTO extra;
    INSERT INTO guild.war_participant VALUES(w4,ca,extra),(w4,cb,defender);
    INSERT INTO guild.fact_war_roster_observation(war_key,clan_key,player_key,observed_at,source_correlation_id,player_name,town_hall_level,map_position)
        SELECT w4,ca,player_key,ts,'served-bench-actual-roster','Available member',18,row_number() OVER(ORDER BY player_key)::smallint
        FROM guild.war_participant WHERE war_key=w4 AND clan_key=ca;
    INSERT INTO guild.fact_war_clan_observation(war_key,clan_key,observed_at,source_correlation_id,state,stars,attacks,destruction_percentage)
        VALUES(w4,ca,ts,'served-bench-ended','warEnded',0,0,0);
    PERFORM guild.cwl_record_bench_service(missing,4::smallint);
    ASSERT EXISTS(SELECT FROM guild.fact_cwl_bench_resolution WHERE incident_key=missing AND resolution='served'),'Complete ended actual roster proves one-war bench service';
    plan_id:=guild.cwl_begin_plan(part,'post-bench-eligibility','current_season_performance');
    INSERT INTO guild.cwl_plan_assignment VALUES(plan_id,6,1,p2);
    INSERT INTO guild.fact_cwl_bench_incident(participation_key,player_key,war_key,incident_kind,source_observed_at)
        VALUES(part,p1,w4,'missed_attack',ts) RETURNING incident_key INTO missing;
    PERFORM guild.cwl_end_cycle(cycle_id,ts);
    ASSERT EXISTS(SELECT FROM guild.fact_cwl_bench_resolution WHERE incident_key=missing AND resolution='season_expiry'),'Unserved penalty expires at season end';
    ASSERT nullif(current_setting('guild.actor_user_key',true),'') IS NULL,'Human command actor must not leak into later collector operations';
    ASSERT NOT has_table_privilege('guild_runtime','guild.cwl_manual_pin','INSERT'),'Runtime cannot bypass staff pin command';
    ASSERT NOT has_function_privilege('public','guild.cwl_pin(bigint,uuid,bigint,integer,integer,bigint,text)','EXECUTE'),'PUBLIC has no activity command authority';
    ASSERT to_regprocedure('guild.activity_command(bigint,uuid,text,jsonb)') IS NULL,'The untyped activity command transport is gone';
    INSERT INTO guild.fact_discord_membership_event (user_key,event_kind,occurred_at) VALUES(staff,'departure',ts);
    BEGIN
        PERFORM guild.custom_event_roster(staff,gen_random_uuid(),event_id,ARRAY[p1],'Former staff');
        RAISE EXCEPTION 'Departed staff retained manual selection authority';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    RAISE NOTICE 'CWL/custom assertions passed: self/staff signup, retry identity, strict availability, seven-day drafts, source rosters, freezes, pins, bench evidence/expiry, exports, custom single roster';
END;
$$;
SET LOCAL ROLE guild_runtime;
DO $$
DECLARE g bigint; actor bigint; e bigint;
BEGIN
    SELECT guild_key INTO g FROM guild.dim_guild;
    SELECT user_key INTO actor FROM guild.dim_discord_user WHERE discord_user_id=811001;
    SELECT event_key INTO e FROM guild.custom_event WHERE event_name='Combined clans';
    PERFORM guild.custom_event_signup(actor,gen_random_uuid(),e,
        (SELECT player_key FROM guild.dim_player_account WHERE player_tag='#P0Y2'),false);
    BEGIN
        INSERT INTO guild.cwl_manual_pin(participation_key,war_day,slot_number,player_key,actor_user_key,reason,operation_id)
            VALUES(-1,1,1,-1,actor,'Raw bypass',gen_random_uuid());
        RAISE EXCEPTION 'Runtime directly inserted a staff pin';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END;
$$;
RESET ROLE;
ROLLBACK;
