#!/usr/bin/env python3
"""Generate GitHub Mermaid ER diagrams from a migrated guild catalog.

Inspect schema metadata only, never application rows or credentials. The Docker
connection uses the container's PostgreSQL authentication configuration. An
exported metadata JSON file can be rendered later without a database connection.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

CATALOG_SQL = r"""
WITH entities AS (
    SELECT c.oid, c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'guild' AND c.relkind IN ('r', 'p')
        AND c.relname <> 'flyway_schema_history'
), entity_metadata AS (
    SELECT e.relname, jsonb_build_object(
        'name', e.relname,
        'columns', (SELECT jsonb_agg(jsonb_build_object(
            'name', a.attname, 'sql_type', format_type(a.atttypid, a.atttypmod),
            'is_nullable', NOT a.attnotnull, 'is_generated', a.attgenerated <> '',
            'is_identity', a.attidentity <> '',
            'generated_expression', CASE WHEN a.attgenerated <> ''
                THEN pg_get_expr(d.adbin, d.adrelid) ELSE NULL END
        ) ORDER BY a.attnum)
            FROM pg_attribute a LEFT JOIN pg_attrdef d
                ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = e.oid AND a.attnum > 0 AND NOT a.attisdropped),
        'primary_key', coalesce((SELECT jsonb_agg(a.attname ORDER BY k.ordinality)
            FROM pg_constraint c CROSS JOIN LATERAL
                unnest(c.conkey) WITH ORDINALITY AS k(attnum, ordinality)
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
            WHERE c.conrelid = e.oid AND c.contype = 'p'), '[]'::jsonb),
        'unique_keys', coalesce((SELECT jsonb_agg(jsonb_build_object(
            'name', ic.relname, 'is_partial', i.indpred IS NOT NULL,
            'predicate', pg_get_expr(i.indpred, i.indrelid),
            'columns', (SELECT jsonb_agg(a.attname ORDER BY k.ordinality)
                FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ordinality)
                JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                WHERE k.ordinality <= i.indnkeyatts AND k.attnum > 0)
        ) ORDER BY ic.relname)
            FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = e.oid AND i.indisunique AND i.indisvalid AND NOT i.indisprimary
                AND i.indexprs IS NULL), '[]'::jsonb),
        'foreign_keys', coalesce((SELECT jsonb_agg(jsonb_build_object(
            'name', c.conname,
            'columns', (SELECT jsonb_agg(a.attname ORDER BY k.ordinality)
                FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ordinality)
                JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum),
            'referenced_schema', pn.nspname, 'referenced_table', pc.relname,
            'referenced_columns', (SELECT jsonb_agg(a.attname ORDER BY k.ordinality)
                FROM unnest(c.confkey) WITH ORDINALITY AS k(attnum, ordinality)
                JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.attnum),
            'match_type', c.confmatchtype,
            'is_deferrable', c.condeferrable
        ) ORDER BY c.conname)
            FROM pg_constraint c JOIN pg_class pc ON pc.oid = c.confrelid
            JOIN pg_namespace pn ON pn.oid = pc.relnamespace
            WHERE c.conrelid = e.oid AND c.contype = 'f'), '[]'::jsonb)
    ) AS metadata FROM entities e
)
SELECT jsonb_build_object('schema', 'guild',
    'postgres_version', current_setting('server_version'),
    'tables', coalesce(jsonb_agg(metadata ORDER BY relname), '[]'::jsonb))
FROM entity_metadata;
"""


@dataclass(frozen=True)
class Domain:
    title: str
    description: str
    tables: tuple[str, ...]


DOMAINS = (
    Domain(
        "Shared identities",
        "Stable Discord and game identities are shared across activity stars.",
        (
            "dim_guild",
            "dim_discord_user",
            "dim_player_account",
            "dim_clan",
            "dim_discord_role",
            "dim_discord_channel",
            "dim_achievement",
        ),
    ),
    Domain(
        "Configuration and audit",
        "Current configuration and immutable audit evidence have separate authority rules.",
        (
            "guild_settings",
            "role_binding",
            "channel_binding",
            "developer_allowlist",
            "clan_collection_settings",
            "war_reminder_setting",
            "fact_configuration_change",
            "fact_api_fetch_attempt",
        ),
    ),
    Domain(
        "Account links and attribution",
        "Actual links, verification, approved transfers, and metric continuity are distinct.",
        (
            "player_verification",
            "metric_attribution_episode",
            "account_link",
            "account_transfer_request",
            "fact_primary_account_change",
        ),
    ),
    Domain(
        "Clan membership evidence",
        "Observed membership and collection coverage do not imply exact in-game movement times.",
        (
            "clan_membership_poll",
            "fact_clan_member_observation",
            "fact_clan_membership_change",
            "observed_clan_membership_period",
            "dim_coc_season",
        ),
    ),
    Domain(
        "Shared war evidence",
        "Regular, CWL, and obtainable custom-war evidence share the war and attack grains.",
        (
            "dim_war",
            "war_poll",
            "war_participant",
            "fact_war_observation",
            "fact_war_roster_observation",
            "fact_war_clan_observation",
            "fact_war_attack",
        ),
    ),
    Domain(
        "Player profiles and raids",
        "Counters are nonadditive observations; raid gold remains per account and weekend.",
        (
            "fact_player_counter_observation",
            "fact_player_achievement_observation",
            "dim_raid_weekend",
            "raid_poll",
            "fact_raid_weekend_observation",
            "fact_raid_member_observation",
        ),
    ),
    Domain(
        "Clan Games collection",
        "Configured events, boundary reads, affiliation inference, and counter evidence are retained.",
        (
            "dim_clan_games_event",
            "clan_games_read_request",
            "clan_games_counter_read",
            "clan_games_participation_evidence",
            "fact_clan_games_progress",
        ),
    ),
    Domain(
        "Clan Games assessments",
        "Versioned account evidence and member-attribution slices support combined rounded targets.",
        (
            "fact_clan_games_account_assessment",
            "fact_clan_games_member_assessment",
            "clan_games_member_account_input",
        ),
    ),
    Domain(
        "Discord presence and roles",
        "Confirmed roles and accepted joins are distinct from desired changes or past authority.",
        (
            "fact_discord_membership_event",
            "discord_member_state",
            "fact_role_change",
            "discord_member_role",
            "fact_discord_accepted_join",
        ),
    ),
    Domain(
        "Chat XP and ranks",
        "One durable message decision includes any XP award; eligibility and rank history retain their own grains.",
        (
            "chat_xp_policy",
            "chat_xp_eligibility_role",
            "chat_rank_tier",
            "chat_rank_role_binding",
            "fact_chat_xp_decision",
            "chat_member_rank_state",
            "fact_chat_rank_change",
        ),
    ),
    Domain(
        "Warnings and moderation",
        "Warnings, kick decisions, confirmed outcomes, and same-month leadership notices are distinct.",
        (
            "warning",
            "warning_revocation",
            "moderation_action",
            "fact_moderation_action_transition",
            "fact_moderation_action_attempt",
            "fact_moderation_attempt_resolution",
            "fact_manual_moderation_action",
            "fact_moderation_notice",
        ),
    ),
    Domain(
        "CWL registration and signups",
        "Signups, strict availability, observed registered pools, and round references are independent.",
        (
            "activity_command_operation",
            "cwl_cycle",
            "fact_cwl_cycle_schedule_revision",
            "cwl_participating_clan",
            "fact_cwl_participation_revision",
            "cwl_clan_day",
            "cwl_group_poll",
            "fact_cwl_group_observation",
            "fact_cwl_registered_clan",
            "fact_cwl_registered_player",
            "cwl_round_war_reference",
            "cwl_signup",
            "fact_cwl_signup_revision",
        ),
    ),
    Domain(
        "CWL plans benches and exports",
        "Versioned plans retain inputs, pins, automatic cutoffs, bench service, overrides, and exports.",
        (
            "cwl_plan_revision",
            "fact_cwl_plan_input",
            "cwl_plan_assignment",
            "fact_cwl_manual_pin_revision",
            "fact_cwl_day_freeze",
            "cwl_replan_request",
            "fact_cwl_bench_incident",
            "fact_cwl_bench_resolution",
            "fact_cwl_bench_assignment_revision",
            "cwl_export_revision",
            "cwl_export_signup_input",
            "cwl_sheet_destination",
            "fact_cwl_export_attempt",
        ),
    ),
    Domain(
        "Custom events",
        "A custom event has one versioned roster and retains available associated war evidence.",
        (
            "custom_event",
            "custom_event_signup",
            "fact_custom_event_signup_revision",
            "custom_roster_revision",
            "custom_roster_account",
        ),
    ),
    Domain(
        "Notification intents and Kafka",
        "Durable intents, outbox publication, consumer receipts, and catch-up inputs have stable identities.",
        (
            "notification_report",
            "notification_operation",
            "notification_mention_role",
            "notification_mention_user",
            "fact_notification_publication_attempt",
            "notification_kafka_receipt",
            "notification_catchup_input",
            "fact_notification_disposition",
            "notification_cwl_context",
            "notification_cwl_signups_context",
            "notification_moderation_context",
            "notification_raid_start_context",
            "notification_raid_report_context",
            "notification_clan_games_report_context",
            "notification_clan_games_report_assessment",
            "notification_clan_games_report_progress",
        ),
    ),
    Domain(
        "Notification dispatch",
        "One dispatch attempt retains authorization, consumed send permit, and write-once outcome; missing results never permit another ping.",
        ("fact_notification_dispatch_attempt",),
    ),
    Domain(
        "Desired role delivery",
        "Source requirements produce versioned desired roles; stale queued work must not restore old state.",
        (
            "notification_role_target",
            "notification_role_source_requirement",
            "notification_managed_role",
            "notification_role_generation",
            "notification_role_generation_requirement",
        ),
    ),
    Domain(
        "Leaderboard calendars",
        "Immutable period boundaries retain timezone-policy history and expose transition months.",
        (
            "leaderboard_calendar_policy",
            "dim_leaderboard_monthly_period",
            "leaderboard_metric_definition",
        ),
    ),
)

BUSINESS_COLUMNS = (
    "purpose",
    "event_kind",
    "change_kind",
    "war_kind",
    "state",
    "status",
    "outcome",
    "result",
    "evidence_status",
    "checkpoint_kind",
    "measurement_method",
    "policy_key",
    "timezone_name",
    "calendar_month",
    "is_transition",
    "starts_at",
    "started_at",
    "ends_at",
    "observed_at",
    "first_observed_at",
    "occurred_at",
    "message_sent_at",
    "earned_at",
    "requested_at",
    "created_at",
    "source_season",
    "source_season_text",
    "war_day",
    "day_number",
    "lineup_size",
    "team_size",
    "attacks_per_member",
    "map_position",
    "town_hall_level",
    "stars",
    "destruction_percentage",
    "points",
    "required_points",
    "eligible_points",
    "xp",
    "xp_total",
    "value",
    "target",
    "capital_resources_looted",
    "source_war_tag",
    "cutoff_minutes",
    "is_present",
    "is_primary",
    "is_enabled",
    "enabled",
    "reason",
)


def mermaid_type(sql_type: str) -> str:
    """Keep SQL type names legible while avoiding Mermaid punctuation syntax."""
    value = re.sub(r"\([^)]*\)", "", sql_type).strip().lower()
    value = {
        "timestamp with time zone": "timestamptz",
        "timestamp without time zone": "timestamp",
        "time with time zone": "timetz",
        "time without time zone": "time",
        "character varying": "varchar",
        "double precision": "float8",
    }.get(value, value)
    value = value.rsplit(".", 1)[-1].replace("[]", "_array")
    return re.sub(r"[^a-z0-9_]", "_", value).strip("_") or "value"


def effectively_not_null(column: dict) -> bool:
    if not column["is_nullable"]:
        return True
    expression = (column.get("generated_expression") or "").strip()
    # Catalog nullability does not infer a generated non-NULL literal. Recognize
    # only simple constants, not arbitrary expressions that might return NULL.
    return bool(
        column.get("is_generated")
        and re.fullmatch(
            r"(?:'(?:[^']|'')*'|[-+]?\d+(?:\.\d+)?|true|false)(?:::[a-zA-Z_ .]+)?",
            expression,
        )
    )


def unique_column_sets(table: dict) -> list[set[str]]:
    keys = [set(table["primary_key"])] if table["primary_key"] else []
    return keys + [
        set(key["columns"])
        for key in table["unique_keys"]
        if not key["is_partial"] and key["columns"]
    ]


def selected_columns(table: dict, anchor_columns: set[str] | None = None) -> list[dict]:
    if anchor_columns is not None:
        wanted = set(table["primary_key"]) | anchor_columns
    else:
        wanted = set(table["primary_key"])
        for key in table["unique_keys"]:
            wanted.update(key["columns"] or [])
        for foreign_key in table["foreign_keys"]:
            wanted.update(foreign_key["columns"])
        by_name = {column["name"]: column for column in table["columns"]}
        extras = [
            name for name in BUSINESS_COLUMNS if name in by_name and name not in wanted
        ][:5]
        # Unknown future business fields still deserve useful context. Avoid
        # large payload/blob columns, then fill remaining slots by SQL order.
        for column in table["columns"]:
            if len(extras) == 5:
                break
            if (
                column["name"] not in wanted
                and column["name"] not in extras
                and mermaid_type(column["sql_type"])
                not in {"json", "jsonb", "bytea", "xml"}
            ):
                extras.append(column["name"])
        wanted.update(extras)
    return [column for column in table["columns"] if column["name"] in wanted]


def entity_lines(table: dict, anchor_columns: set[str] | None = None) -> list[str]:
    name = table["name"]
    primary = set(table["primary_key"])
    foreign = {name for key in table["foreign_keys"] for name in key["columns"]}
    single_unique = {
        next(iter(key)) for key in unique_column_sets(table) if len(key) == 1
    }
    lines = [f"    {name} {{"]
    for column in selected_columns(table, anchor_columns):
        keys = [
            label
            for label, selected in (
                ("PK", column["name"] in primary),
                ("FK", column["name"] in foreign),
                (
                    "UK",
                    column["name"] in single_unique and column["name"] not in primary,
                ),
            )
            if selected
        ]
        attributes = " " + ", ".join(keys) if keys else ""
        notes = []
        if not effectively_not_null(column):
            notes.append("nullable")
        if column.get("is_generated"):
            notes.append("generated")
        if column.get("is_identity"):
            notes.append("identity")
        comment = ' "' + "; ".join(notes) + '"' if notes else ""
        lines.append(
            f"        {mermaid_type(column['sql_type'])} {column['name']}{attributes}{comment}"
        )
    return lines + ["    }", ""]


def relationship_line(child: dict, foreign_key: dict) -> str:
    columns = {column["name"]: column for column in child["columns"]}
    nullable = [
        not effectively_not_null(columns[name]) for name in foreign_key["columns"]
    ]
    optional = all(nullable) if foreign_key["match_type"] == "f" else any(nullable)
    parent_cardinality = "|o" if optional else "||"
    unique_child = any(
        key <= set(foreign_key["columns"]) for key in unique_column_sets(child)
    )
    child_cardinality = "o|" if unique_child else "o{"
    identifying = set(foreign_key["columns"]) <= set(child["primary_key"])
    connector = "--" if identifying else ".."
    return (
        f"    {foreign_key['referenced_table']} {parent_cardinality}{connector}{child_cardinality} "
        f'{child["name"]} : "{foreign_key["name"]}"'
    )


def slug(title: str) -> str:
    return title.lower().replace(" ", "-")


def render(metadata: dict) -> tuple[str, dict]:
    if metadata.get("schema") != "guild" or not metadata.get("tables"):
        raise ValueError("Expected metadata for a nonempty migrated guild schema")
    tables = {table["name"]: table for table in metadata["tables"]}
    if len(tables) != len(metadata["tables"]):
        raise ValueError("Duplicate table names in schema metadata")
    for table in tables.values():
        for name in [table["name"], *(column["name"] for column in table["columns"])]:
            if not re.fullmatch(r"[a-zA-Z_][a-zA-Z_0-9]*", name):
                raise ValueError(f"Unsupported Mermaid identifier: {name}")
        for foreign_key in table["foreign_keys"]:
            if (
                foreign_key["referenced_schema"] != "guild"
                or foreign_key["referenced_table"] not in tables
            ):
                raise ValueError(
                    "A foreign key references a table outside the inspected guild catalog"
                )

    classified = Counter(
        name for domain in DOMAINS for name in domain.tables if name in tables
    )
    duplicates = [name for name, count in classified.items() if count > 1]
    if duplicates:
        raise ValueError(f"Tables classified into multiple domains: {duplicates}")
    unclassified = sorted(set(tables) - set(classified))
    domains = [domain for domain in DOMAINS if set(domain.tables) & set(tables)]
    if unclassified:
        domains.append(
            Domain(
                "Additional schema records",
                "New records are retained here until their domain classification is added to the generator.",
                tuple(unclassified),
            )
        )

    foreign_keys = [
        (table, foreign_key)
        for table in tables.values()
        for foreign_key in table["foreign_keys"]
    ]
    lines = [
        "# Guild entity-relationship diagrams",
        "",
        "GitHub renders these Mermaid diagrams directly. They are generated from",
        "the migrated PostgreSQL catalog, not inferred from SQL text or application rows.",
        "",
        f"This page covers **{len(tables)} persisted tables and {len(foreign_keys)} foreign keys**",
        "in the `guild` schema. Every table is owned by one domain below; shared parents",
        "reappear as key-only anchors. Flyway history and views are outside the",
        "physical ER diagrams.",
        "",
        "The diagrams describe persistence and constraints, not a running Kafka, CoC,",
        "Discord, or Sheets integration. SQL remains authoritative for all columns,",
        "permissions, checks, and temporal exclusions; the guild service enforces the",
        "business rules.",
        "",
        "- [Feature requirements](../feature-specs/README.md)",
        "- [Current star-schema design](guild-star-schema.md)",
        "- [SQL migrations](../../services/guild/schema/src/main/resources/db/migration)",
        "- [Schema setup and behavior](../../services/guild/schema/README.md)",
        "- [Generator](../../tools/postgres/generate-guild-erd.py)",
        "",
        "## Reading the diagrams",
        "",
        "- PK means primary key; FK means foreign key; UK marks a single-column unconditional unique key.",
        "- Composite unique/index columns are retained without claiming each column is individually unique.",
        "- Each relationship is one declared FK. Its label is the PostgreSQL constraint name.",
        "- Parent optionality follows FK nullability and MATCH semantics; generated non-null literals count as required.",
        "- Child cardinality is zero-or-one when an unconditional unique key proves it, otherwise zero-or-many.",
        "- Solid lines identify FKs contained in the child primary key; other relationships are dashed.",
        "- Partial unique indexes, CHECK constraints, and temporal exclusions impose additional constraints.",
        "- Selected business columns supplement all PK/FK and ordinary unique/index columns.",
        "",
        "## Domains",
        "",
        "| Diagram | Domain-owned tables |",
        "| --- | ---: |",
    ]
    for domain in domains:
        count = sum(name in tables for name in domain.tables)
        lines.append(f"| [{domain.title}](#{slug(domain.title)}) | {count} |")
    for domain in domains:
        owned = [name for name in domain.tables if name in tables]
        anchors: dict[str, set[str]] = {}
        relationships = []
        for name in owned:
            for foreign_key in tables[name]["foreign_keys"]:
                parent = foreign_key["referenced_table"]
                if parent not in owned:
                    anchors.setdefault(parent, set()).update(
                        foreign_key["referenced_columns"]
                    )
                relationships.append(relationship_line(tables[name], foreign_key))
        lines.extend(
            [
                "",
                f"## {domain.title}",
                "",
                domain.description,
                "",
                "```mermaid",
                "erDiagram",
                "    direction LR",
                "",
            ]
        )
        for name in owned:
            lines.extend(entity_lines(tables[name]))
        for name in sorted(anchors):
            lines.extend(entity_lines(tables[name], anchors[name]))
        lines.extend(sorted(relationships))
        lines.append("```")

    lines.extend(
        [
            "",
            "## Full foreign-key reference",
            "",
            "<details>",
            f"<summary>All {len(foreign_keys)} declared foreign keys and their column mappings</summary>",
            "",
            "| Child table | Constraint | Child columns | Parent table | Referenced columns | Match |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
    )
    for table, key in sorted(
        foreign_keys, key=lambda item: (item[0]["name"], item[1]["name"])
    ):
        child_columns = ", ".join(key["columns"])
        parent_columns = ", ".join(key["referenced_columns"])
        match = {"s": "SIMPLE", "f": "FULL", "p": "PARTIAL"}[key["match_type"]]
        lines.append(
            f"| `{table['name']}` | `{key['name']}` | `{child_columns}` | "
            f"`{key['referenced_table']}` | `{parent_columns}` | {match} |"
        )
    lines.extend(["", "</details>", "", "## Unique-index reference", "", "<details>"])
    unique_keys = [
        (table, key) for table in tables.values() for key in table["unique_keys"]
    ]
    lines.extend(
        [
            f"<summary>All {len(unique_keys)} ordinary unique indexes, including composite and partial keys</summary>",
            "",
            "Primary-key columns are marked in the entities above. A partial index proves",
            "uniqueness only for rows satisfying its predicate and does not impose a",
            "global one-to-one relationship in the diagrams.",
            "",
            "| Table | Index | Columns | Scope |",
            "| --- | --- | --- | --- |",
        ]
    )
    for table, key in sorted(
        unique_keys, key=lambda item: (item[0]["name"], item[1]["name"])
    ):
        scope = "Unconditional"
        if key["is_partial"]:
            predicate = (key["predicate"] or "").replace("|", "\\|").replace("\n", " ")
            scope = f"Partial: `{predicate}`"
        columns = ", ".join(key["columns"] or [])
        lines.append(f"| `{table['name']}` | `{key['name']}` | `{columns}` | {scope} |")
    lines.extend(
        [
            "",
            "</details>",
            "",
            "## Regenerating",
            "",
            "Run the generator after migrating a disposable database. Only schema metadata is read:",
            "",
            "```sh",
            "python3 tools/postgres/generate-guild-erd.py \\",
            "  --container <validation-container> --database <migrated-database> \\",
            "  --user <migration-user> --output docs/design/guild-er-diagram.md",
            "```",
            "",
            "Use `--metadata-output` to retain the inspected catalog as JSON outside the repository;",
            "`--input-json` regenerates the diagrams from that metadata without connecting to PostgreSQL.",
            "",
        ]
    )
    return "\n".join(lines), {
        "tables": len(tables),
        "foreign_keys": len(foreign_keys),
        "domains": len(domains),
        "unclassified_tables": unclassified,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--container", help="Docker container running migrated PostgreSQL"
    )
    parser.add_argument("--database", help="Migrated database name")
    parser.add_argument(
        "--user", help="PostgreSQL user; no credentials are printed or accepted"
    )
    parser.add_argument(
        "--input-json",
        type=Path,
        help="Read exported catalog metadata instead of PostgreSQL",
    )
    parser.add_argument(
        "--metadata-output", type=Path, help="Optional schema-metadata JSON destination"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "docs/design/guild-er-diagram.md",
    )
    args = parser.parse_args()
    try:
        if args.input_json:
            metadata = json.loads(args.input_json.read_text(encoding="utf-8"))
        else:
            if not all((args.container, args.database, args.user)):
                parser.error(
                    "--container, --database, and --user are required without --input-json"
                )
            command = [
                "docker",
                "exec",
                "-i",
                args.container,
                "psql",
                "-X",
                "-qAt",
                "--no-password",
                "--set",
                "ON_ERROR_STOP=1",
                "--username",
                args.user,
                "--dbname",
                args.database,
            ]
            completed = subprocess.run(
                command, input=CATALOG_SQL, text=True, capture_output=True, check=True
            )
            metadata = json.loads(completed.stdout)
        document, summary = render(metadata)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(document, encoding="utf-8")
        if args.metadata_output:
            args.metadata_output.parent.mkdir(parents=True, exist_ok=True)
            args.metadata_output.write_text(
                json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
        print(json.dumps({**summary, "output": str(args.output)}, sort_keys=True))
        return 0
    except subprocess.CalledProcessError as error:
        print(
            f"Catalog inspection failed: {error.stderr.strip()[:500]}", file=sys.stderr
        )
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Cannot generate guild ER diagrams: {error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
