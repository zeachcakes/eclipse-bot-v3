-- Preserve the command actor across every row changed by an atomic operation.
-- In particular, a transfer closes the previous owner's link, but its actor is
-- the requesting recipient, not the old owner inferred from that historical row.
-- Original implementations remain private; typed entry points preserve defaults.
DO $$
DECLARE
    command record;
    implementation record;
    matching_functions integer;
    implementation_name text;
    call_arguments text;
    wrapper_body text;
    declaration text;
    invocation text;
    completion text;
BEGIN
    FOR command IN SELECT * FROM (VALUES
        ('issue_warning', 'p_actor'),
        ('revoke_warning', 'p_actor'),
        ('link_player_account', 'p_user_key'),
        ('unlink_player_account', 'p_user_key'),
        ('set_primary_account', 'p_user_key'),
        ('request_account_transfer', 'p_to_user_key'),
        ('decide_account_transfer', 'p_actor_user_key')
    ) AS commands(function_name, actor_argument) LOOP
        SELECT count(*) INTO matching_functions FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'guild' AND p.proname = command.function_name;
        IF matching_functions <> 1 THEN
            RAISE EXCEPTION 'Expected exactly one command implementation for %', command.function_name;
        END IF;
        SELECT p.oid, p.proargnames, p.pronargs,
            pg_catalog.pg_get_function_arguments(p.oid) AS argument_declaration,
            pg_catalog.pg_get_function_result(p.oid) AS result_type
        INTO STRICT implementation FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'guild' AND p.proname = command.function_name;
        IF implementation.result_type NOT IN ('bigint', 'void')
            OR NOT command.actor_argument = ANY (implementation.proargnames) THEN
            RAISE EXCEPTION 'Unexpected command signature for %', command.function_name;
        END IF;
        SELECT string_agg(format('%I', name), ', ' ORDER BY position)
        INTO call_arguments
        FROM unnest(implementation.proargnames) WITH ORDINALITY AS args(name, position)
        WHERE position <= implementation.pronargs;
        implementation_name := '_command_' || command.function_name;
        EXECUTE format('ALTER FUNCTION %s RENAME TO %I',
            implementation.oid::regprocedure, implementation_name);
        IF implementation.result_type = 'bigint' THEN
            declaration := 'result bigint;';
            invocation := format('result := guild.%I(%s);', implementation_name, call_arguments);
            completion := 'RETURN result;';
        ELSE
            declaration := '';
            invocation := format('PERFORM guild.%I(%s);', implementation_name, call_arguments);
            completion := 'RETURN;';
        END IF;
        wrapper_body := format($body$
DECLARE
    previous_actor text := current_setting('guild.actor_user_key', true);
    previous_source text := current_setting('guild.change_source', true);
    %s
BEGIN
    PERFORM set_config('guild.actor_user_key', %I::text, true);
    PERFORM set_config('guild.change_source', 'command', true);
    %s
    PERFORM set_config('guild.actor_user_key', coalesce(previous_actor, ''), true);
    PERFORM set_config('guild.change_source', coalesce(previous_source, ''), true);
    %s
END;
$body$, declaration, command.actor_argument, invocation, completion);
        EXECUTE format('CREATE FUNCTION guild.%I(%s) RETURNS %s '
            || 'LANGUAGE plpgsql SECURITY DEFINER '
            || 'SET search_path = pg_catalog, guild, pg_temp AS %L',
            command.function_name, implementation.argument_declaration,
            implementation.result_type, wrapper_body);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, guild_runtime',
            implementation.oid::regprocedure);
        EXECUTE format('REVOKE ALL ON FUNCTION guild.%I(%s) FROM PUBLIC',
            command.function_name, pg_catalog.pg_get_function_identity_arguments(implementation.oid));
        EXECUTE format('GRANT EXECUTE ON FUNCTION guild.%I(%s) TO guild_runtime',
            command.function_name, pg_catalog.pg_get_function_identity_arguments(implementation.oid));
    END LOOP;
END;
$$;
