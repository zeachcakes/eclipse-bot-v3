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
