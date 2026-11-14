-- Run with psql as the database administrator AFTER Flyway preparation.
-- Seeds the one Discord server of this database, its settings row and the first
-- developer, whom the guild service cannot create itself. Values come from
-- environment bindings, never tracked SQL. Repeating the script changes nothing.
\set ON_ERROR_STOP on
\getenv discord_guild_id DISCORD_GUILD_ID
\getenv developer_user_id GUILD_FIRST_DEVELOPER_ID

-- psql ignores an exit status after \quit, so a failed check raises an error,
-- which ON_ERROR_STOP turns into exit status 3.
\if :{?discord_guild_id}
\else
    DO $$ BEGIN RAISE EXCEPTION 'Missing DISCORD_GUILD_ID'; END $$;
\endif
\if :{?developer_user_id}
\else
    DO $$ BEGIN RAISE EXCEPTION 'Missing GUILD_FIRST_DEVELOPER_ID'; END $$;
\endif
SELECT :'discord_guild_id' ~ '^[1-9][0-9]{0,19}$'
    AND :'developer_user_id' ~ '^[1-9][0-9]{0,19}$' AS valid_settings
\gset
\if :valid_settings
\else
    DO $$ BEGIN RAISE EXCEPTION 'DISCORD_GUILD_ID and GUILD_FIRST_DEVELOPER_ID must be Discord IDs'; END $$;
\endif

SELECT NOT EXISTS (
    SELECT FROM guild.dim_guild WHERE discord_guild_id <> :'discord_guild_id'::numeric
) AS same_server
\gset
\if :same_server
\else
    DO $$ BEGIN RAISE EXCEPTION 'This database already serves another Discord server'; END $$;
\endif
-- Only the owner developer adds others, through the guild service (ADR 0012,
-- DEC-08). The seed creates the first developer and makes them the owner, or
-- recovers an empty allowlist.
SELECT NOT EXISTS (
    SELECT FROM guild.developer_allowlist a JOIN guild.dim_discord_user u USING (user_key)
    WHERE u.discord_user_id <> :'developer_user_id'::numeric
) AS no_other_developer
\gset
\if :no_other_developer
\else
    DO $$ BEGIN RAISE EXCEPTION 'Developers already exist; add more through the guild service'; END $$;
\endif

BEGIN;

INSERT INTO guild.dim_guild (discord_guild_id) VALUES (:'discord_guild_id')
ON CONFLICT (discord_guild_id) DO NOTHING;

-- Configuration changes made here are recorded as operator changes, as the
-- guild service records its own.
WITH settings AS (
    INSERT INTO guild.guild_settings (guild_key)
    SELECT guild_key FROM guild.dim_guild
    ON CONFLICT (guild_key) DO NOTHING
    RETURNING *
)
INSERT INTO guild.fact_configuration_change (source, entity_type, entity_identity, new_value, reason)
SELECT 'operator', 'guild_settings', jsonb_build_object('guild_key', guild_key), to_jsonb(settings),
    'Operator seed of the guild settings'
FROM settings;

INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (:'developer_user_id')
ON CONFLICT (discord_user_id) DO NOTHING;

WITH developer AS (
    INSERT INTO guild.developer_allowlist (user_key)
    SELECT user_key FROM guild.dim_discord_user WHERE discord_user_id = :'developer_user_id'::numeric
    ON CONFLICT (user_key) DO NOTHING
    RETURNING *
)
INSERT INTO guild.fact_configuration_change (source, entity_type, entity_identity, new_value, reason)
SELECT 'operator', 'developer_allowlist', jsonb_build_object('user_key', user_key), to_jsonb(developer),
    'Operator seed of the first developer'
FROM developer;

-- The first developer becomes the owner developer when no owner is set. Like
-- every operator change, it records its own history row (DEC-09).
WITH before AS (
    SELECT * FROM guild.guild_settings WHERE owner_developer_user_key IS NULL
), owner AS (
    UPDATE guild.guild_settings s
    SET owner_developer_user_key = u.user_key, updated_at = clock_timestamp()
    FROM guild.dim_discord_user u
    WHERE u.discord_user_id = :'developer_user_id'::numeric
        AND s.guild_key IN (SELECT guild_key FROM before)
    RETURNING s.*
)
INSERT INTO guild.fact_configuration_change
    (source, entity_type, entity_identity, previous_value, new_value, reason)
SELECT 'operator', 'guild_settings', jsonb_build_object('guild_key', o.guild_key), to_jsonb(b),
    to_jsonb(o), 'Operator seed of the owner developer'
FROM owner o JOIN before b USING (guild_key);

COMMIT;

SELECT (SELECT discord_guild_id FROM guild.dim_guild) AS discord_guild_id,
    (SELECT count(*) FROM guild.developer_allowlist) AS developers,
    (SELECT u.discord_user_id FROM guild.guild_settings s
        JOIN guild.dim_discord_user u ON u.user_key = s.owner_developer_user_key) AS owner_developer_id;
