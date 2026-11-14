BEGIN;

-- V2: verification outcomes, account links, attribution episodes and transfer
-- requests. The service decides who may link and transfer; these checks cover
-- the keys, the composite foreign keys, the exclusion constraints and the
-- status checks that back those rules.
DO $$
DECLARE
    guild bigint; owner_id bigint; other_id bigint; staff_id bigint;
    main_account bigint; alt_account bigint;
    owner_main_proof bigint; owner_alt_proof bigint; rejected_proof bigint; other_proof bigint;
    other_second_proof bigint;
    owner_main_episode bigint; owner_alt_episode bigint; other_episode bigint;
    main_link bigint; alt_link bigint; request bigint; staff_proof bigint; staff_episode bigint;
    linked timestamptz := clock_timestamp() - interval '10 days';
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (920000000000000001) RETURNING guild_key INTO guild;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.guild_settings (guild_key) VALUES (guild);
    IF (SELECT (verification_max_age_seconds, transfer_pending_max_age_seconds,
            transfer_approval_max_age_seconds) FROM guild.guild_settings)
        IS DISTINCT FROM (900, 172800, 86400) THEN
        RAISE EXCEPTION 'The transfer limits must default to two days pending and one day approved';
    END IF;
    BEGIN
        UPDATE guild.guild_settings SET transfer_pending_max_age_seconds = 0;
        RAISE EXCEPTION 'A transfer limit of zero seconds was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.guild_settings SET verification_max_age_seconds = 0;
        RAISE EXCEPTION 'A verification age limit of zero seconds was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (920000000000000011) RETURNING user_key INTO owner_id;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (920000000000000012) RETURNING user_key INTO other_id;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (920000000000000013) RETURNING user_key INTO staff_id;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#Q0Y') RETURNING player_key INTO main_account;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#Q2Y') RETURNING player_key INTO alt_account;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (owner_id, main_account, 'verified', linked) RETURNING verification_key INTO owner_main_proof;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (owner_id, alt_account, 'verified', linked) RETURNING verification_key INTO owner_alt_proof;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (owner_id, main_account, 'rejected', linked) RETURNING verification_key INTO rejected_proof;
    INSERT INTO guild.player_verification (user_key, player_key, status)
    VALUES (other_id, main_account, 'verified') RETURNING verification_key INTO other_proof;
    INSERT INTO guild.player_verification (user_key, player_key, status)
    VALUES (other_id, main_account, 'verified') RETURNING verification_key INTO other_second_proof;
    BEGIN
        INSERT INTO guild.player_verification (user_key, player_key, status)
        VALUES (owner_id, main_account, 'pending');
        RAISE EXCEPTION 'An unknown verification status was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    INSERT INTO guild.metric_attribution_episode (user_key, player_key, first_link_at, include_prelink_history)
    VALUES (owner_id, main_account, linked, true) RETURNING attribution_key INTO owner_main_episode;
    INSERT INTO guild.metric_attribution_episode (user_key, player_key, first_link_at, include_prelink_history)
    VALUES (owner_id, alt_account, linked, true) RETURNING attribution_key INTO owner_alt_episode;
    BEGIN
        INSERT INTO guild.metric_attribution_episode (user_key, player_key, first_link_at)
        VALUES (other_id, main_account, linked + interval '1 day');
        RAISE EXCEPTION 'Two open attribution episodes were accepted for one account';
    EXCEPTION WHEN unique_violation OR exclusion_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.metric_attribution_episode SET closed_at = first_link_at
        WHERE attribution_key = owner_main_episode;
        RAISE EXCEPTION 'An attribution episode closed when it started';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, linked_at)
        VALUES (owner_id, main_account, rejected_proof, owner_main_episode, linked);
        RAISE EXCEPTION 'Direct SQL attached a rejected verification outcome';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, linked_at)
        VALUES (owner_id, main_account, other_proof, owner_main_episode, linked);
        RAISE EXCEPTION 'A member reused a verification proof belonging to another member';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, linked_at)
        VALUES (owner_id, main_account, owner_main_proof, owner_alt_episode, linked);
        RAISE EXCEPTION 'A link accepted the attribution episode of another account';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, linked_at, is_primary)
    VALUES (owner_id, main_account, owner_main_proof, owner_main_episode, linked, true)
    RETURNING link_key INTO main_link;
    BEGIN
        INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, linked_at, is_primary)
        VALUES (owner_id, alt_account, owner_alt_proof, owner_alt_episode, linked, true);
        RAISE EXCEPTION 'A member was given two current primary accounts';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, linked_at)
    VALUES (owner_id, alt_account, owner_alt_proof, owner_alt_episode, linked)
    RETURNING link_key INTO alt_link;
    BEGIN
        INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, linked_at)
        VALUES (owner_id, main_account, owner_main_proof, owner_main_episode, linked + interval '1 day');
        RAISE EXCEPTION 'One verification backed two links';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.account_link SET unlinked_at = linked_at WHERE link_key = alt_link;
        RAISE EXCEPTION 'A link ended when it started';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    -- Swapping the primary is two updates in one transaction.
    UPDATE guild.account_link SET is_primary = false WHERE link_key = main_link;
    UPDATE guild.account_link SET is_primary = true WHERE link_key = alt_link;
    IF (SELECT player_key FROM guild.current_account_link WHERE user_key = owner_id AND is_primary)
        <> alt_account THEN
        RAISE EXCEPTION 'The public current links did not show the primary';
    END IF;

    -- Primary history.
    INSERT INTO guild.fact_primary_account_change (user_key, new_link_key, new_player_key, cause, actor_user_key,
        changed_at)
    VALUES (owner_id, main_link, main_account, 'first_link', owner_id, linked);
    INSERT INTO guild.fact_primary_account_change (user_key, previous_link_key, previous_player_key, new_link_key,
        new_player_key, cause, actor_user_key)
    VALUES (owner_id, main_link, main_account, alt_link, alt_account, 'choice', owner_id);
    BEGIN
        INSERT INTO guild.fact_primary_account_change (user_key, previous_link_key, previous_player_key,
            new_link_key, new_player_key, cause)
        VALUES (owner_id, main_link, main_account, alt_link, alt_account, 'first_link');
        RAISE EXCEPTION 'A first link was recorded with a previous primary';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    -- DEC-02: a transfer can take the primary while alts remain; the member
    -- then has no primary until they choose one.
    INSERT INTO guild.fact_primary_account_change (user_key, previous_link_key, previous_player_key, cause)
    VALUES (owner_id, alt_link, alt_account, 'primary_transferred');
    INSERT INTO guild.fact_primary_account_change (user_key, new_link_key, new_player_key, cause, actor_user_key)
    VALUES (owner_id, main_link, main_account, 'choice', owner_id);
    BEGIN
        INSERT INTO guild.fact_primary_account_change (user_key, previous_link_key, previous_player_key,
            new_link_key, new_player_key, cause)
        VALUES (owner_id, main_link, main_account, alt_link, alt_account, 'primary_transferred');
        RAISE EXCEPTION 'A transferred primary was recorded with a replacement';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_primary_account_change (user_key, new_link_key, new_player_key, cause)
        VALUES (owner_id, alt_link, alt_account, 'unlink_replacement');
        RAISE EXCEPTION 'An unlink replacement was recorded without the unlinked primary';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_primary_account_change (user_key, previous_link_key, previous_player_key, cause)
        VALUES (owner_id, alt_link, alt_account, 'choice');
        RAISE EXCEPTION 'A choice was recorded without the chosen link';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_primary_account_change (user_key, previous_link_key, previous_player_key,
            new_link_key, new_player_key, cause)
        VALUES (owner_id, main_link, main_account, alt_link, alt_account, 'link_ended');
        RAISE EXCEPTION 'An ended last link was recorded with a new primary';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_primary_account_change (user_key, previous_link_key, previous_player_key,
            new_link_key, new_player_key, cause)
        VALUES (owner_id, alt_link, alt_account, alt_link, alt_account, 'choice');
        RAISE EXCEPTION 'A primary change kept the same link';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_primary_account_change (user_key, new_link_key, cause)
        VALUES (owner_id, main_link, 'first_link');
        RAISE EXCEPTION 'A primary change named a link without its account';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_primary_account_change (user_key, new_link_key, new_player_key, cause)
        VALUES (other_id, main_link, main_account, 'first_link');
        RAISE EXCEPTION 'A primary change named the link of another member';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_primary_account_change (user_key, new_link_key, new_player_key, cause)
        VALUES (owner_id, main_link, alt_account, 'first_link');
        RAISE EXCEPTION 'A primary change named a link with another account';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;

    -- Transfer requests.
    BEGIN
        INSERT INTO guild.account_transfer_request
            (player_key, from_user_key, to_user_key, source_link_key, verification_key)
        VALUES (main_account, owner_id, owner_id, main_link, owner_main_proof);
        RAISE EXCEPTION 'A member requested a transfer to themself';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.account_transfer_request
            (player_key, from_user_key, to_user_key, source_link_key, verification_key)
        VALUES (main_account, other_id, staff_id, main_link, other_proof);
        RAISE EXCEPTION 'A transfer request named a source link of another owner';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.account_transfer_request
            (player_key, from_user_key, to_user_key, source_link_key, verification_key)
        VALUES (main_account, owner_id, staff_id, main_link, other_proof);
        RAISE EXCEPTION 'A transfer request used the verification of another member';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.account_transfer_request
        (player_key, from_user_key, to_user_key, source_link_key, verification_key)
    VALUES (main_account, owner_id, other_id, main_link, other_proof)
    RETURNING transfer_request_key INTO request;
    BEGIN
        INSERT INTO guild.account_transfer_request
            (player_key, from_user_key, to_user_key, source_link_key, verification_key)
        VALUES (main_account, owner_id, other_id, main_link, other_second_proof);
        RAISE EXCEPTION 'A recipient had two pending requests for one source link';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.account_transfer_request SET status = 'approved' WHERE transfer_request_key = request;
        RAISE EXCEPTION 'An approval was recorded without its decision';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.account_transfer_request
        SET status = 'consumed', consumed_at = clock_timestamp() WHERE transfer_request_key = request;
        RAISE EXCEPTION 'An undecided request was consumed';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.account_transfer_request SET status = 'expired' WHERE transfer_request_key = request;
        RAISE EXCEPTION 'A request expired without its expiry time';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.account_transfer_request
        SET status = 'cancelled', cancelled_at = clock_timestamp(), decided_by = staff_id
        WHERE transfer_request_key = request;
        RAISE EXCEPTION 'A cancellation kept half of a decision';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.account_transfer_request
    SET status = 'approved', decided_by = staff_id, decided_at = clock_timestamp()
    WHERE transfer_request_key = request;
    BEGIN
        UPDATE guild.account_transfer_request
        SET status = 'cancelled', cancelled_at = clock_timestamp(), consumed_at = clock_timestamp()
        WHERE transfer_request_key = request;
        RAISE EXCEPTION 'A consumed transfer was cancelled';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    -- The approved transfer completes: the old link ends, the new one starts.
    UPDATE guild.account_link SET unlinked_at = clock_timestamp() - interval '1 minute' WHERE link_key = main_link;
    UPDATE guild.metric_attribution_episode SET closed_at = clock_timestamp() - interval '1 minute'
    WHERE attribution_key = owner_main_episode;
    INSERT INTO guild.metric_attribution_episode (user_key, player_key, first_link_at)
    VALUES (other_id, main_account, clock_timestamp() - interval '1 minute')
    RETURNING attribution_key INTO other_episode;
    BEGIN
        INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, linked_at)
        VALUES (other_id, main_account, other_proof, other_episode, clock_timestamp() - interval '2 minutes');
        RAISE EXCEPTION 'Direct SQL created overlapping link intervals';
    EXCEPTION WHEN exclusion_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.account_link
            (user_key, player_key, verification_key, attribution_key, linked_at, transfer_request_key)
        VALUES (staff_id, main_account, other_proof, other_episode, clock_timestamp() - interval '1 minute', request);
        RAISE EXCEPTION 'A transfer request completed for another recipient';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.account_link
        (user_key, player_key, verification_key, attribution_key, linked_at, transfer_request_key, is_primary)
    VALUES (other_id, main_account, other_proof, other_episode, clock_timestamp() - interval '1 minute', request, true);
    UPDATE guild.account_transfer_request
    SET status = 'consumed', consumed_at = clock_timestamp() WHERE transfer_request_key = request;
    IF (SELECT count(*) FROM guild.current_account_link WHERE player_key = main_account) <> 1 THEN
        RAISE EXCEPTION 'A transferred account must have exactly one current owner';
    END IF;
    -- Two current links always overlap, so the exclusion or the one-current-owner
    -- index rejects the second; the staff episode is closed and does not conflict.
    INSERT INTO guild.player_verification (user_key, player_key, status)
    VALUES (staff_id, alt_account, 'verified') RETURNING verification_key INTO staff_proof;
    INSERT INTO guild.metric_attribution_episode (user_key, player_key, first_link_at, closed_at)
    VALUES (staff_id, alt_account, linked - interval '5 days', linked - interval '4 days')
    RETURNING attribution_key INTO staff_episode;
    BEGIN
        INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, linked_at)
        VALUES (staff_id, alt_account, staff_proof, staff_episode, clock_timestamp());
        RAISE EXCEPTION 'An account accepted a second current owner';
    EXCEPTION WHEN unique_violation OR exclusion_violation THEN NULL;
    END;
    -- With the recipient's link ended, only the used-once index rejects a reuse.
    UPDATE guild.account_link SET unlinked_at = clock_timestamp()
    WHERE player_key = main_account AND unlinked_at IS NULL;
    BEGIN
        INSERT INTO guild.account_link
            (user_key, player_key, verification_key, attribution_key, linked_at, transfer_request_key)
        VALUES (other_id, main_account, other_second_proof, other_episode,
            clock_timestamp() + interval '1 second', request);
        RAISE EXCEPTION 'Transfer approval must be consumed once';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.account_link SET player_key = alt_account WHERE link_key = main_link;
        RAISE EXCEPTION 'The runtime role moved a link to another account';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.account_link WHERE link_key = main_link;
        RAISE EXCEPTION 'The runtime role deleted link history';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    IF EXISTS (SELECT FROM information_schema.columns
        WHERE table_schema = 'guild' AND column_name ILIKE '%token%' AND table_name IN
            ('player_verification', 'account_link', 'account_transfer_request', 'fact_api_fetch_attempt')) THEN
        RAISE EXCEPTION 'Link and verification tables must not have a token column';
    END IF;
    RAISE NOTICE 'Account link constraints passed';
END;
$$;

ROLLBACK;
