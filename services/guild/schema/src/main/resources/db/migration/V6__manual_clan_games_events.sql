-- Manual fallback uses the same guild/start identity as scheduled creation.
-- A repeat cannot silently replace the evidence behind an existing assessment.
CREATE FUNCTION guild.create_manual_clan_games(
    p_guild_key bigint,
    p_actor_user_key bigint,
    p_starts_at timestamptz,
    p_ends_at timestamptz,
    p_account_points_cap integer,
    p_reason text,
    p_source_correlation_id text DEFAULT gen_random_uuid()::text
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    result_key bigint;
    existing_event guild.dim_clan_games_event%ROWTYPE;
    previous_actor text := current_setting('guild.actor_user_key', true);
    previous_source text := current_setting('guild.change_source', true);
    previous_reason text := current_setting('guild.change_reason', true);
BEGIN
    IF p_actor_user_key IS NULL
        OR NOT guild.can_configure(p_guild_key, p_actor_user_key) THEN
        RAISE EXCEPTION 'Admin role or developer allowlist is required to create an event'
            USING ERRCODE = '42501';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = ''
        OR p_source_correlation_id IS NULL OR btrim(p_source_correlation_id) = '' THEN
        RAISE EXCEPTION 'Manual event creation requires a reason and correlation identifier'
            USING ERRCODE = '23514';
    END IF;
    PERFORM set_config('guild.actor_user_key', p_actor_user_key::text, true);
    PERFORM set_config('guild.change_source', 'command', true);
    PERFORM set_config('guild.change_reason', p_reason, true);

    INSERT INTO guild.dim_clan_games_event
        (guild_key, starts_at, ends_at, account_points_cap, schedule_source, source_correlation_id)
    VALUES (p_guild_key, p_starts_at, p_ends_at, p_account_points_cap,
        'manual', p_source_correlation_id)
    ON CONFLICT (guild_key, starts_at) DO NOTHING
    RETURNING event_key INTO result_key;
    IF result_key IS NULL THEN
        SELECT * INTO STRICT existing_event FROM guild.dim_clan_games_event
        WHERE guild_key = p_guild_key AND starts_at = p_starts_at FOR SHARE;
        IF (existing_event.ends_at, existing_event.account_points_cap)
            IS DISTINCT FROM (p_ends_at, p_account_points_cap) THEN
            RAISE EXCEPTION 'An existing event has different boundaries or a points cap'
                USING ERRCODE = '23514';
        END IF;
        result_key := existing_event.event_key;
    END IF;
    PERFORM set_config('guild.actor_user_key', coalesce(previous_actor, ''), true);
    PERFORM set_config('guild.change_source', coalesce(previous_source, ''), true);
    PERFORM set_config('guild.change_reason', coalesce(previous_reason, ''), true);
    RETURN result_key;
END;
$$;

CREATE TRIGGER manual_clan_games_configuration_audit
AFTER INSERT ON guild.dim_clan_games_event
FOR EACH ROW WHEN (NEW.schedule_source = 'manual')
EXECUTE FUNCTION guild.audit_configuration_change();

REVOKE ALL ON FUNCTION guild.create_manual_clan_games(
    bigint, bigint, timestamptz, timestamptz, integer, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION guild.create_manual_clan_games(
    bigint, bigint, timestamptz, timestamptz, integer, text, text
) TO guild_runtime;
