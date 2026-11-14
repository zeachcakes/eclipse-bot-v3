#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd "$repo_root"

# Tests roll back their fixtures. Never reset a schema or delete a Docker volume.
# Preparation is an explicit separate operation.
# Variables are expanded by the shell inside the PostgreSQL container.
# shellcheck disable=SC2016
psql_script='exec psql -X --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${GUILD_TEST_DATABASE:-$POSTGRES_DB}"'
if [[ -n "${GUILD_TEST_CONTAINER:-}" ]]; then
    psql_command=(docker exec -i -e GUILD_TEST_DATABASE "$GUILD_TEST_CONTAINER" sh -c "$psql_script")
else
    psql_command=(docker compose exec -T -e GUILD_TEST_DATABASE postgres sh -c "$psql_script")
fi

"${psql_command[@]}" <<'SQL'
DO $$
BEGIN
    IF to_regclass('guild.dim_guild') IS NULL THEN
        RAISE EXCEPTION 'Prepare the guild schema before running its SQL tests';
    END IF;
    IF EXISTS (SELECT FROM guild.dim_guild) THEN
        RAISE EXCEPTION 'Use a disposable migrated database with no configured guild data';
    END IF;
END;
$$;
SQL

for sql_file in services/guild/schema/src/test/sql/*.sql; do
    printf 'Running %s\n' "$sql_file"
    "${psql_command[@]}" <"$sql_file"
done

# The fixtures above switch to the shared runtime group. Also connect as the
# application login role itself: it must inherit that group's grants and
# nothing more. Local connections inside the container need no password.
if [[ -z "${GUILD_APP_DB_USER:-}" ]]; then
    printf 'Skipping the application login check: GUILD_APP_DB_USER is not set\n'
    exit 0
fi
# shellcheck disable=SC2016
login_script='exec psql -X --set ON_ERROR_STOP=1 --username "$GUILD_APP_DB_USER" --dbname "${GUILD_TEST_DATABASE:-$POSTGRES_DB}"'
if [[ -n "${GUILD_TEST_CONTAINER:-}" ]]; then
    login_command=(docker exec -i -e GUILD_TEST_DATABASE -e GUILD_APP_DB_USER "$GUILD_TEST_CONTAINER" sh -c "$login_script")
else
    login_command=(docker compose exec -T -e GUILD_TEST_DATABASE -e GUILD_APP_DB_USER postgres sh -c "$login_script")
fi
printf 'Checking the application login role\n'
"${login_command[@]}" <<'SQL'
DO $$
BEGIN
    IF (SELECT rolsuper OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname = current_user)
        OR pg_has_role(current_user, (SELECT nspowner FROM pg_namespace WHERE nspname = 'guild'), 'MEMBER') THEN
        RAISE EXCEPTION 'The application login role is privileged or can act as the schema owner';
    END IF;
    -- The service reads private histories; its permission checks protect them.
    PERFORM count(*) FROM guild.dim_guild;
    PERFORM count(*) FROM guild.warning;
    BEGIN
        UPDATE guild.warning SET reason = reason;
        RAISE EXCEPTION 'The application login role can update a fact';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.fact_war_attack;
        RAISE EXCEPTION 'The application login role can delete a fact';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END;
$$;
SQL
