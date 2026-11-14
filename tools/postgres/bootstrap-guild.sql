-- Run with psql as the database administrator BEFORE Flyway preparation.
-- Values come from environment bindings, never tracked SQL or -v passwords.
\set ON_ERROR_STOP on
\getenv migration_user GUILD_DB_USER
\getenv migration_password GUILD_DB_PASSWORD
\getenv application_user GUILD_APP_DB_USER
\getenv application_password GUILD_APP_DB_PASSWORD

-- psql ignores an exit status after \quit, so a failed check raises an error,
-- which ON_ERROR_STOP turns into exit status 3.

SELECT length(:'migration_user') > 0
    AND length(:'migration_password') > 0
    AND length(:'application_user') > 0
    AND length(:'application_password') > 0
    AND :'migration_user' <> :'application_user'
    AND :'migration_user' <> 'guild_runtime'
    AND :'application_user' <> 'guild_runtime' AS valid_settings
\gset
\if :valid_settings
\else
    DO $$ BEGIN
        RAISE EXCEPTION 'Missing guild role settings, or migration/application roles are not distinct';
    END $$;
\endif

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;

SELECT 'CREATE ROLE guild_runtime NOLOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'guild_runtime')
\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'migration_user', :'migration_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'migration_user')
\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'application_user', :'application_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'application_user')
\gexec

-- Existing users/passwords are preserved. Refuse privileged pre-existing roles.
SELECT NOT EXISTS (
    SELECT FROM pg_roles
    WHERE rolname IN (:'migration_user', :'application_user', 'guild_runtime')
        AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
) AS safe_roles
\gset
\if :safe_roles
\else
    DO $$ BEGIN RAISE EXCEPTION 'Guild roles must not be privileged PostgreSQL roles'; END $$;
\endif

CREATE SCHEMA IF NOT EXISTS guild AUTHORIZATION :"migration_user";
SELECT n.nspowner = r.oid AS correct_owner
FROM pg_namespace n CROSS JOIN pg_roles r
WHERE n.nspname = 'guild' AND r.rolname = :'migration_user'
\gset
\if :correct_owner
\else
    DO $$ BEGIN
        RAISE EXCEPTION 'Existing guild schema has a different owner; no ownership was changed';
    END $$;
\endif

REVOKE ALL ON SCHEMA guild FROM PUBLIC;
GRANT USAGE ON SCHEMA guild TO guild_runtime;

-- PostgreSQL grants EXECUTE on new functions to PUBLIC by default. That default
-- is global to the creating role: a schema-level default can add to it but
-- cannot remove it, so both are revoked. The guild migrations create no
-- functions (ADR 0012); should one appear, it starts private. This is role
-- configuration, so it lives here rather than in a schema migration.
ALTER DEFAULT PRIVILEGES FOR ROLE :"migration_user" REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE :"migration_user" IN SCHEMA guild
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
GRANT guild_runtime TO :"application_user";
