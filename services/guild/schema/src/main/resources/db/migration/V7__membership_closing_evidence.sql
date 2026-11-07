-- Existing migrations are immutable. A period can no longer disappear from
-- current membership merely because a worker supplies an arbitrary end time.
-- Use the explicit observed_departure fact as the durable closure proof. Its
-- source poll must be complete at exactly that boundary; failed/incomplete
-- polls cannot produce a departure under the V3 fact trigger.

CREATE INDEX membership_departure_boundary
ON guild.fact_clan_membership_change (guild_key, clan_key, player_key, observed_at)
WHERE change_kind = 'observed_departure';

CREATE FUNCTION guild.membership_has_closing_evidence(
    p_guild_key bigint, p_clan_key bigint, p_player_key bigint, p_observed_until timestamptz
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
    SELECT EXISTS (
        SELECT FROM guild.fact_clan_membership_change c
        JOIN guild.clan_membership_poll p
            ON p.poll_key = c.poll_key AND p.guild_key = c.guild_key AND p.clan_key = c.clan_key
        WHERE c.guild_key = p_guild_key AND c.clan_key = p_clan_key
            AND c.player_key = p_player_key AND c.change_kind = 'observed_departure'
            AND c.observed_at = p_observed_until
            AND p.observed_at = p_observed_until AND p.outcome = 'complete'
    );
$$;
REVOKE ALL ON FUNCTION guild.membership_has_closing_evidence(bigint, bigint, bigint, timestamptz)
FROM PUBLIC, guild_runtime;

CREATE FUNCTION guild.require_membership_closing_evidence() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.guild_key, NEW.player_key, NEW.clan_key, NEW.observed_since, NEW.first_poll_key)
            IS DISTINCT FROM
            (OLD.guild_key, OLD.player_key, OLD.clan_key, OLD.observed_since, OLD.first_poll_key) THEN
            RAISE EXCEPTION 'Membership period identity and first observation cannot be rewritten'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.confirmed_through < OLD.confirmed_through THEN
            RAISE EXCEPTION 'Out-of-order evidence cannot rewind confirmed membership'
                USING ERRCODE = '23514';
        END IF;
        IF OLD.observed_until IS NOT NULL AND NEW.observed_until IS DISTINCT FROM OLD.observed_until THEN
            RAISE EXCEPTION 'Closed membership boundaries cannot be rewritten; record a new membership interval'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.observed_until IS NOT NULL AND NOT guild.membership_has_closing_evidence(
        NEW.guild_key, NEW.clan_key, NEW.player_key, NEW.observed_until
    ) THEN
        RAISE EXCEPTION 'Closing membership requires an observed departure from a complete poll at the exact boundary'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION guild.require_membership_closing_evidence() FROM PUBLIC, guild_runtime;
CREATE TRIGGER membership_period_closing_evidence BEFORE INSERT OR UPDATE
ON guild.observed_clan_membership_period FOR EACH ROW
EXECUTE FUNCTION guild.require_membership_closing_evidence();

-- Validate existing history rather than manufacturing departures from a failed
-- request, an empty staging table, or the last positive membership timestamp.
DO $$
BEGIN
    IF EXISTS (
        SELECT FROM guild.observed_clan_membership_period m
        WHERE m.observed_until IS NOT NULL
            AND NOT guild.membership_has_closing_evidence(
                m.guild_key, m.clan_key, m.player_key, m.observed_until
            )
    ) THEN
        RAISE EXCEPTION 'Existing closed membership periods lack complete-poll departure evidence; reconcile source evidence before applying V7'
            USING ERRCODE = '23514';
    END IF;
END;
$$;
COMMENT ON TABLE guild.observed_clan_membership_period IS
    'Derived observation-based intervals, not exact game join times. Closing requires a matching '
    'observed_departure from a complete poll at observed_until. confirmed_through remains the '
    'last positive coverage boundary and may precede closing evidence; it must not rewind. '
    'An API failure or incomplete response must not close a current period.';
