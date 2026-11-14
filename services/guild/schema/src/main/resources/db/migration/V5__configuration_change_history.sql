-- Change history is kept for configuration only: a settings change overwrites
-- the old value, so this ledger is the only place that keeps it. Game and
-- Discord activity is recorded by its own fact tables, which are the activity
-- history. No second copy of their rows is kept. The guild service writes a row
-- in the same transaction as the change it records (ADR 0012).
CREATE TABLE guild.fact_configuration_change (
    configuration_change_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_user_key bigint REFERENCES guild.dim_discord_user,
    source text NOT NULL CHECK (source IN ('command', 'operator')),
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    entity_type text NOT NULL,
    entity_identity jsonb NOT NULL CHECK (jsonb_typeof(entity_identity) = 'object'),
    previous_value jsonb,
    new_value jsonb,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    transaction_id bigint NOT NULL DEFAULT txid_current(),
    CHECK (previous_value IS NOT NULL OR new_value IS NOT NULL),
    CHECK (source <> 'command' OR actor_user_key IS NOT NULL)
);
CREATE INDEX configuration_change_time
    ON guild.fact_configuration_change (changed_at DESC);
COMMENT ON TABLE guild.fact_configuration_change IS
    'Developer-only, immutable history of configuration changes with the values before and '
    'after. An insert has no previous_value and a delete has no new_value.';
COMMENT ON COLUMN guild.fact_configuration_change.source IS
    'command is a change that a configuration command of the guild service made, with its '
    'actor. operator is any other change, such as a migration or an operator seed.';
