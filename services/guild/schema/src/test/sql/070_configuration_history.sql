BEGIN;

-- V5: the configuration change history. The service writes one row per change
-- in the same transaction; the runtime role cannot rewrite a row.
DO $$
DECLARE
    actor_id bigint; change bigint;
BEGIN
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (970000000000000011) RETURNING user_key INTO actor_id;
    BEGIN
        INSERT INTO guild.fact_configuration_change (source, entity_type, entity_identity, new_value, reason)
        VALUES ('command', 'role_binding', '{"binding_key": 1}', '{"role_key": 1}', 'Bind the member role');
        RAISE EXCEPTION 'A command change was recorded without its actor';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_configuration_change (actor_user_key, source, entity_type, entity_identity, reason)
        VALUES (actor_id, 'command', 'role_binding', '{"binding_key": 1}', 'Bind the member role');
        RAISE EXCEPTION 'A change was recorded without the values before or after';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_configuration_change (actor_user_key, source, entity_type, entity_identity,
            new_value, reason)
        VALUES (actor_id, 'command', 'role_binding', '[1]', '{"role_key": 1}', 'Bind the member role');
        RAISE EXCEPTION 'A change identity that is not a JSON object was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_configuration_change (actor_user_key, source, entity_type, entity_identity,
            new_value, reason)
        VALUES (actor_id, 'command', 'role_binding', '{"binding_key": 1}', '{"role_key": 1}', ' ');
        RAISE EXCEPTION 'configuration accepted a blank reason';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_configuration_change (source, entity_type, entity_identity, new_value, reason)
        VALUES ('migration', 'guild_settings', '{"guild_key": 1}', '{"new_joinee_days": 7}', 'Seed');
        RAISE EXCEPTION 'An unknown change source was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_configuration_change (actor_user_key, source, entity_type, entity_identity,
        previous_value, new_value, reason)
    VALUES (actor_id, 'command', 'role_binding', '{"binding_key": 1}', '{"role_key": 1}', '{"role_key": 2}',
        'Replace the member role')
    RETURNING configuration_change_key INTO change;
    INSERT INTO guild.fact_configuration_change (source, entity_type, entity_identity, new_value, reason)
    VALUES ('operator', 'developer_allowlist', '{"user_key": 1}', '{"user_key": 1}', 'Operator seed');
    IF (SELECT transaction_id FROM guild.fact_configuration_change WHERE configuration_change_key = change)
        <> txid_current() THEN
        RAISE EXCEPTION 'A change did not record its transaction';
    END IF;
    BEGIN
        UPDATE guild.fact_configuration_change SET reason = 'Rewritten' WHERE configuration_change_key = change;
        RAISE EXCEPTION 'configuration change history was mutable';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.fact_configuration_change WHERE configuration_change_key = change;
        RAISE EXCEPTION 'configuration change history was mutable';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RAISE NOTICE 'Configuration change history constraints passed';
END;
$$;

ROLLBACK;
