-- Leaderboard reporting calendars are independent of GMT warning months and
-- CWL signup deadlines. Period boundaries and the policy used to create them
-- are retained rather than recomputed from today's timezone setting.

CREATE TABLE guild.leaderboard_calendar_policy (
    calendar_policy_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    timezone_name text NOT NULL DEFAULT 'Etc/UTC',
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    requested_by_user_key bigint REFERENCES guild.dim_discord_user,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    UNIQUE (calendar_policy_key, timezone_name)
);

-- The one current selection belongs to the guild's configuration row. Policy
-- versions and frozen reporting periods remain separate historical records.
ALTER TABLE guild.guild_settings
    ADD COLUMN leaderboard_next_policy_key bigint,
    ADD COLUMN leaderboard_next_timezone_name text,
    ADD COLUMN leaderboard_policy_selected_at timestamptz,
    ADD CONSTRAINT leaderboard_selection_complete CHECK (
        (leaderboard_next_policy_key IS NULL) = (leaderboard_next_timezone_name IS NULL)
        AND (leaderboard_next_policy_key IS NULL) = (leaderboard_policy_selected_at IS NULL)
    ),
    ADD CONSTRAINT leaderboard_selected_policy FOREIGN KEY
        (leaderboard_next_policy_key, leaderboard_next_timezone_name)
        REFERENCES guild.leaderboard_calendar_policy (calendar_policy_key, timezone_name);

CREATE VIEW guild.leaderboard_calendar_state AS
SELECT guild_key, leaderboard_next_policy_key AS next_policy_key,
    leaderboard_next_timezone_name AS next_timezone_name,
    leaderboard_policy_selected_at AS selected_at
FROM guild.guild_settings
WHERE leaderboard_next_policy_key IS NOT NULL
WITH LOCAL CHECK OPTION;
COMMENT ON VIEW guild.leaderboard_calendar_state IS
    'Latest requested policy for the next uncreated period. Only the timezone workflow of '
    'the guild service changes it; changing this pointer never updates an existing period.';

CREATE TABLE guild.dim_leaderboard_monthly_period (
    period_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    calendar_policy_key bigint NOT NULL,
    timezone_name text NOT NULL,
    sequence_number integer NOT NULL UNIQUE CHECK (sequence_number > 0),
    calendar_month date NOT NULL UNIQUE
        CHECK (calendar_month = date_trunc('month', calendar_month::timestamp)::date),
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    previous_period_key bigint UNIQUE REFERENCES guild.dim_leaderboard_monthly_period,
    is_transition boolean NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (calendar_policy_key, timezone_name)
        REFERENCES guild.leaderboard_calendar_policy (calendar_policy_key, timezone_name),
    CHECK (starts_at < ends_at),
    CHECK ((sequence_number = 1) = (previous_period_key IS NULL)),
    EXCLUDE USING gist (tstzrange(starts_at, ends_at, '[)') WITH &&)
);
COMMENT ON TABLE guild.dim_leaderboard_monthly_period IS
    'Append-only reporting boundaries. A timezone transition starts at the prior '
    'period end and ends at the next month label boundary in the new zone. '
    'is_transition exposes the resulting shortened/extended period; no gap, '
    'double-counting, or historical boundary rewrite is introduced.';

-- Definitions establish which formulas are supported. Unknown monthly metric
-- semantics remain explicit; no cumulative snapshot is silently used as an
-- arbitrary month's earned score. This is a metric catalog, not score storage.
CREATE TABLE guild.leaderboard_metric_definition (
    metric_key text NOT NULL,
    period_kind text NOT NULL CHECK (period_kind IN ('monthly', 'all_time', 'event', 'season')),
    subject_kind text NOT NULL CHECK (subject_kind IN ('discord_member', 'player_account')),
    calculation_method text NOT NULL CHECK (calculation_method IN
        ('award_sum', 'latest_lifetime_counter', 'latest_season_counter', 'event_evidence',
            'requires_definition')),
    definition_status text NOT NULL CHECK (definition_status IN ('supported', 'needs_definition')),
    evidence_requirement text NOT NULL CHECK (btrim(evidence_requirement) <> ''),
    PRIMARY KEY (metric_key, period_kind),
    CHECK ((definition_status = 'needs_definition') = (calculation_method = 'requires_definition'))
);
INSERT INTO guild.leaderboard_metric_definition VALUES
    ('chat_xp', 'monthly', 'discord_member', 'award_sum', 'supported',
        'Credited message awards within retained reporting-period boundaries'),
    ('chat_xp', 'all_time', 'discord_member', 'award_sum', 'supported',
        'All credited awards; current Discord membership controls display'),
    ('war_stars', 'all_time', 'player_account', 'latest_lifetime_counter', 'supported',
        'Latest profile warStars, including other clans; current clan controls display'),
    ('war_stars', 'monthly', 'player_account', 'requires_definition', 'needs_definition',
        'Define supported baselines or source-time attribution; attack duration is not a timestamp'),
    ('clan_games_points', 'event', 'player_account', 'event_evidence', 'supported',
        'Supported event counter deltas and tracked participating-clan attribution'),
    ('clan_games_points', 'monthly', 'player_account', 'requires_definition', 'needs_definition',
        'Define event-to-calendar attribution and baseline coverage before ranking'),
    ('raid_capital_gold', 'event', 'player_account', 'event_evidence', 'supported',
        'Latest per-account raid-weekend capitalResourcesLooted, not summed snapshots'),
    ('raid_capital_gold', 'monthly', 'player_account', 'requires_definition', 'needs_definition',
        'Define attribution of weekends crossing reporting boundaries'),
    ('cwl_stars', 'season', 'player_account', 'event_evidence', 'supported',
        'Deduplicated attacks joined to the registered CWL cycle and actual war context'),
    -- GAP-09 (2026-11-14): donations rank per clan and CoC season only.
    ('donations', 'season', 'player_account', 'latest_season_counter', 'supported',
        'Last member-list donations counter seen in that clan before the CoC season ended '
        '(clan_member_season_donation); the game resets it each season, so it is never summed');

CREATE VIEW guild.chat_xp_current_member_all_time AS
SELECT a.user_key, sum(a.xp)::bigint AS xp_total,
    count(*) AS credited_messages,
    dense_rank() OVER (ORDER BY sum(a.xp) DESC) AS position
FROM guild.fact_chat_xp_award a
JOIN guild.discord_member_state s USING (user_key)
WHERE s.is_present
GROUP BY a.user_key;

CREATE VIEW guild.chat_xp_monthly_leaderboard AS
SELECT p.period_key, p.calendar_month, p.timezone_name,
    p.starts_at, p.ends_at, p.is_transition, a.user_key,
    sum(a.xp)::bigint AS xp_total, count(*) AS credited_messages,
    dense_rank() OVER (PARTITION BY p.period_key ORDER BY sum(a.xp) DESC) AS position
FROM guild.dim_leaderboard_monthly_period p
JOIN guild.fact_chat_xp_award a
    ON a.message_sent_at >= p.starts_at AND a.message_sent_at < p.ends_at
JOIN guild.discord_member_state s ON s.user_key = a.user_key
WHERE s.is_present
GROUP BY p.period_key, a.user_key;

CREATE VIEW guild.current_chat_xp_monthly_leaderboard AS
SELECT * FROM guild.chat_xp_monthly_leaderboard
WHERE starts_at <= statement_timestamp() AND statement_timestamp() < ends_at;

COMMENT ON VIEW guild.chat_xp_monthly_leaderboard IS
    'Current-membership projection of credited XP over immutable reporting periods. '
    'Departure hides retained history until rejoin. Earning-role loss does not erase '
    'awards; any additional role-based board eligibility is a future explicit policy.';
