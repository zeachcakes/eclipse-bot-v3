BEGIN;

-- V4, first part: Discord membership and role events, their projections, chat
-- XP decisions and ranks. The service decides presence, eligibility, the
-- rolling limit and ranks; these checks cover the facts and their keys.
DO $$
DECLARE
    guild bigint; member_id bigint; other_id bigint; role_id bigint; other_role bigint; channel_id bigint;
    join_event bigint; departure_event bigint; sync_join bigint; sync_departure bigint;
    role_event bigint; credited bigint; rejected bigint;
    award bigint; joined timestamptz := '2026-03-05 12:00+00';
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (950000000000000001) RETURNING guild_key INTO guild;
    -- Reference data seeded by the migrations is not writable by the runtime role.
    IF ARRAY(SELECT (rank_key, rank_name, minimum_cumulative_xp)::text FROM guild.chat_rank_tier ORDER BY rank_key)
        <> ARRAY['(1,Stardust,0)', '(2,Stargazer,4000)', '(3,Orbiter,12000)', '(4,"Lunar Drift",28000)',
            '(5,"Solar Wanderer",60000)', '(6,Penumbra,120000)', '(7,Corona,240000)', '(8,Umbra,400000)',
            '(9,Totality,650000)', '(10,"Eclipse Ascendant",1000000)'] THEN
        RAISE EXCEPTION 'Seeded cumulative rank thresholds differ from the approved schedule';
    END IF;
    IF (SELECT (minimum_xp, maximum_xp, credited_messages_per_window, window_seconds, window_kind, is_provisional)
            FROM guild.chat_xp_policy WHERE policy_key = 'rolling_60s_v1')
        IS DISTINCT FROM (15, 25, 5, 60, 'rolling_processing_time'::text, false)
        OR (SELECT count(*) FROM guild.chat_xp_policy) <> 1 THEN
        RAISE EXCEPTION 'The seeded XP policy differs from the agreed version';
    END IF;
    BEGIN
        INSERT INTO guild.chat_xp_policy VALUES ('rolling_60s_v2', 15, 30, 5, 60, 'rolling_processing_time', false);
        RAISE EXCEPTION 'An XP policy outside the agreed values was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.guild_settings (guild_key) VALUES (guild);
    BEGIN
        UPDATE guild.guild_settings SET chat_xp_policy_key = 'rolling_60s_v1';
        RAISE EXCEPTION 'the XP policy catalog was offered as a setting';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        UPDATE guild.chat_rank_tier SET minimum_cumulative_xp = 1 WHERE rank_key = 2;
        RAISE EXCEPTION 'The runtime role changed a rank threshold';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (950000000000000011) RETURNING user_key INTO member_id;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (950000000000000012) RETURNING user_key INTO other_id;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (950000000000000021, 'Eclipse') RETURNING role_key INTO role_id;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (950000000000000022, 'Orbiter') RETURNING role_key INTO other_role;
    INSERT INTO guild.dim_discord_channel (discord_channel_id, channel_name)
    VALUES (950000000000000031, 'general') RETURNING channel_key INTO channel_id;

    -- Membership events and the New Joinee policy they record.
    BEGIN
        INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
        VALUES (member_id, 'join', joined);
        RAISE EXCEPTION 'A join was recorded without its New Joinee policy';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at, new_joinee_policy_days)
        VALUES (member_id, 'departure', joined, 7);
        RAISE EXCEPTION 'A departure carried a New Joinee policy';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at, new_joinee_policy_days,
            new_joinee_expires_at)
        VALUES (member_id, 'join', joined, 7, joined + interval '30 days');
        RAISE EXCEPTION 'incorrect New Joinee expiry accepted';
    EXCEPTION WHEN generated_always THEN NULL;
    END;
    -- The expiry is computed in UTC: a daylight saving change in the session
    -- time zone does not move it.
    SET LOCAL TIME ZONE 'America/New_York';
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at, new_joinee_policy_days)
    VALUES (member_id, 'join', joined, 7) RETURNING membership_event_key INTO join_event;
    IF (SELECT new_joinee_expires_at - occurred_at FROM guild.fact_discord_membership_event
        WHERE membership_event_key = join_event) <> interval '168 hours' THEN
        RAISE EXCEPTION 'selected join provenance and New Joinee expiry were not retained';
    END IF;
    SET LOCAL TIME ZONE 'UTC';
    BEGIN
        INSERT INTO guild.fact_discord_membership_event (operation_id, user_key, event_kind, occurred_at)
        SELECT operation_id, member_id, 'departure', joined + interval '1 day'
        FROM guild.fact_discord_membership_event WHERE membership_event_key = join_event;
        RAISE EXCEPTION 'A redelivered gateway event was recorded twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (member_id, 'departure', joined + interval '1 day') RETURNING membership_event_key INTO departure_event;
    BEGIN
        UPDATE guild.fact_discord_membership_event SET occurred_at = joined + interval '2 days'
        WHERE membership_event_key = departure_event;
        RAISE EXCEPTION 'A recorded membership event was rewritten';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.fact_discord_membership_event WHERE membership_event_key = departure_event;
        RAISE EXCEPTION 'The runtime role deleted a membership event';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    INSERT INTO guild.discord_member_state (user_key, is_present, last_membership_event_key, last_event_at)
    VALUES (member_id, true, join_event, joined);
    UPDATE guild.discord_member_state SET is_present = false, last_membership_event_key = departure_event,
        last_event_at = joined + interval '1 day' WHERE user_key = member_id;

    -- DEC-18: a join that the sync finds is welcomed only when it is recent.
    IF (SELECT welcome_sync_max_age_seconds FROM guild.guild_settings) <> 86400 THEN
        RAISE EXCEPTION 'The welcome window of a member list join must default to one day';
    END IF;
    BEGIN
        UPDATE guild.guild_settings SET welcome_sync_max_age_seconds = 0;
        RAISE EXCEPTION 'A welcome window of zero seconds was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.guild_settings SET welcome_sync_max_age_seconds = 3600;

    -- Presence found in the gateway member list (CFG-010): a gateway event is
    -- the default source, and a sync records the member's joined_at as a join.
    IF (SELECT event_source FROM guild.fact_discord_membership_event WHERE membership_event_key = join_event)
        <> 'gateway_event' THEN
        RAISE EXCEPTION 'A gateway event did not keep its source';
    END IF;
    BEGIN
        INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, event_source, occurred_at,
            new_joinee_policy_days)
        VALUES (other_id, 'join', 'guess', joined, 7);
        RAISE EXCEPTION 'An unknown membership event source was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, event_source, occurred_at)
        VALUES (other_id, 'join', 'member_list_sync', joined);
        RAISE EXCEPTION 'A join from the member list was recorded without its New Joinee policy';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, event_source, occurred_at,
        new_joinee_policy_days, observed_at)
    VALUES (other_id, 'join', 'member_list_sync', joined - interval '300 days', 7, joined)
    RETURNING membership_event_key INTO sync_join;
    INSERT INTO guild.discord_member_state (user_key, is_present, last_membership_event_key, last_event_at)
    VALUES (other_id, true, sync_join, joined - interval '300 days');
    IF (SELECT new_joinee_expires_at FROM guild.fact_discord_membership_event
        WHERE membership_event_key = sync_join) <> joined - interval '293 days' THEN
        RAISE EXCEPTION 'A member list join did not count New Joinee from the source joined_at';
    END IF;
    -- A departure that the sync found has no source time: its occurred_at is
    -- the sync time, the latest moment at which the member can have left.
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, event_source, occurred_at, observed_at)
    VALUES (other_id, 'departure', 'member_list_sync', joined + interval '2 days', joined + interval '2 days')
    RETURNING membership_event_key INTO sync_departure;
    UPDATE guild.discord_member_state SET is_present = false, last_membership_event_key = sync_departure,
        last_event_at = joined + interval '2 days' WHERE user_key = other_id;
    BEGIN
        UPDATE guild.fact_discord_membership_event SET event_source = 'gateway_event'
        WHERE membership_event_key = sync_departure;
        RAISE EXCEPTION 'A membership event changed its source';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Role events and the held-role projection.
    BEGIN
        INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind, expires_at)
        VALUES (member_id, role_id, 'add', joined, 'onboarding', joined + interval '7 days');
        RAISE EXCEPTION 'A role expiry was recorded without its origin join';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
        VALUES (member_id, role_id, 'add', joined, 'guess');
        RAISE EXCEPTION 'An unknown role provenance was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind,
        origin_join_event_key, expires_at)
    VALUES (member_id, role_id, 'add', joined, 'onboarding', join_event, joined + interval '7 days')
    RETURNING role_event_key INTO role_event;
    BEGIN
        UPDATE guild.fact_role_change SET change_kind = 'remove' WHERE role_event_key = role_event;
        RAISE EXCEPTION 'Projection repair erased source role facts';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    INSERT INTO guild.discord_member_role (user_key, role_key, assigned_at, last_role_event_key, expires_at)
    VALUES (member_id, role_id, joined, role_event, joined + interval '7 days');
    BEGIN
        INSERT INTO guild.discord_member_role (user_key, role_key, assigned_at, last_role_event_key)
        VALUES (member_id, role_id, joined, role_event);
        RAISE EXCEPTION 'A member held one role twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    DELETE FROM guild.discord_member_role WHERE user_key = member_id;

    -- Chat XP decisions and ranks.
    INSERT INTO guild.chat_xp_eligibility_role (role_key) VALUES (role_id);
    BEGIN
        INSERT INTO guild.fact_chat_xp_decision (user_key, channel_key, discord_message_id, message_sent_at,
            decided_at, policy_key, outcome, eligibility_role_key, xp)
        VALUES (member_id, channel_id, 950000000000000101, joined, joined, 'rolling_60s_v1', 'credited', role_id, 26);
        RAISE EXCEPTION 'XP fell outside the approved range';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_chat_xp_decision (user_key, channel_key, discord_message_id, message_sent_at,
            decided_at, policy_key, outcome, xp)
        VALUES (member_id, channel_id, 950000000000000101, joined, joined, 'rolling_60s_v1', 'credited', 20);
        RAISE EXCEPTION 'A credited message had no eligibility role';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_chat_xp_decision (user_key, channel_key, discord_message_id, message_sent_at,
            decided_at, policy_key, outcome, xp)
        VALUES (member_id, channel_id, 950000000000000101, joined, joined, 'rolling_60s_v1', 'rate_limited', 20);
        RAISE EXCEPTION 'A rejected message carried XP';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_chat_xp_decision (user_key, channel_key, discord_message_id, message_sent_at,
        decided_at, policy_key, outcome, eligibility_role_key, xp)
    VALUES (member_id, channel_id, 950000000000000101, joined, joined, 'rolling_60s_v1', 'credited', role_id, 20)
    RETURNING xp_decision_key, xp_award_key INTO credited, award;
    INSERT INTO guild.fact_chat_xp_decision (user_key, channel_key, discord_message_id, message_sent_at,
        decided_at, policy_key, outcome)
    VALUES (member_id, channel_id, 950000000000000102, joined, joined, 'rolling_60s_v1', 'rate_limited')
    RETURNING xp_decision_key INTO rejected;
    IF award IS DISTINCT FROM credited
        OR (SELECT xp_award_key FROM guild.fact_chat_xp_decision WHERE xp_decision_key = rejected) IS NOT NULL
        OR (SELECT count(*) FROM guild.fact_chat_xp_award WHERE user_key = member_id) <> 1 THEN
        RAISE EXCEPTION 'A rejected decision became addressable as a credited award';
    END IF;
    BEGIN
        INSERT INTO guild.fact_chat_xp_decision (user_key, channel_key, discord_message_id, message_sent_at,
            decided_at, policy_key, outcome)
        VALUES (other_id, channel_id, 950000000000000102, joined, joined, 'rolling_60s_v1', 'not_present');
        RAISE EXCEPTION 'A rejected message identity was reused by another member';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_chat_xp_decision SET xp = 25 WHERE xp_decision_key = credited;
        RAISE EXCEPTION 'The award projection allowed XP history rewrites';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.fact_chat_xp_decision WHERE xp_decision_key = rejected;
        RAISE EXCEPTION 'The runtime role deleted an XP decision';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    BEGIN
        INSERT INTO guild.chat_member_rank_state (user_key, cumulative_xp, rank_key, last_award_key, updated_at)
        VALUES (other_id, 20, 1, award, joined);
        RAISE EXCEPTION 'A rank state named the award of another member';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.chat_member_rank_state (user_key, cumulative_xp, rank_key, last_award_key, updated_at)
    VALUES (member_id, 20, 1, award, joined);
    BEGIN
        INSERT INTO guild.fact_chat_rank_change (user_key, previous_rank_key, rank_key, cumulative_xp,
            trigger_award_key, decided_at)
        VALUES (member_id, 2, 1, 20, award, joined);
        RAISE EXCEPTION 'A rank change moved down';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_chat_rank_change (user_key, rank_key, cumulative_xp, trigger_award_key, decided_at)
    VALUES (member_id, 1, 20, award, joined);
    BEGIN
        INSERT INTO guild.fact_chat_rank_change (user_key, previous_rank_key, rank_key, cumulative_xp,
            trigger_award_key, decided_at)
        VALUES (member_id, 1, 2, 20, award, joined);
        RAISE EXCEPTION 'One award changed the rank twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;

    INSERT INTO guild.chat_rank_role_binding (rank_key, role_key) VALUES (3, other_role);
    BEGIN
        INSERT INTO guild.chat_rank_role_binding (rank_key, role_key) VALUES (4, other_role);
        RAISE EXCEPTION 'One role served two ranks';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.chat_rank_role_binding (rank_key, role_key) VALUES (11, role_id);
        RAISE EXCEPTION 'A role was bound to a rank that does not exist';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    UPDATE guild.chat_rank_role_binding SET role_key = role_id WHERE rank_key = 3;
    DELETE FROM guild.chat_rank_role_binding WHERE rank_key = 3;
    DELETE FROM guild.chat_xp_eligibility_role WHERE role_key = role_id;
    RAISE NOTICE 'Discord presence, role and XP constraints passed';
END;
$$;

ROLLBACK;
