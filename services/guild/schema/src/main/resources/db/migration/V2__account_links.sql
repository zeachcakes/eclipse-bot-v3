-- Game observations do not depend on a Discord link. These intervals describe
-- actual links; attribution episodes separately preserve metric continuity.
CREATE TABLE guild.player_verification (
    verification_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    status text NOT NULL CHECK (status IN ('verified', 'rejected', 'error')),
    checked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_request_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    source_fetch_key bigint REFERENCES guild.fact_api_fetch_attempt,
    UNIQUE (verification_key, user_key, player_key, status)
);
CREATE INDEX player_verification_member_account
    ON guild.player_verification (user_key, player_key, checked_at DESC);
COMMENT ON TABLE guild.player_verification IS
    'Trusted backend verification outcome only. Never retain the supplied or echoed API token.';

-- A successful verification proves control of the account at one moment. It
-- may start a link or a transfer request only for a limited time afterwards.
ALTER TABLE guild.guild_settings
    ADD COLUMN verification_max_age_seconds integer NOT NULL DEFAULT 900
        CHECK (verification_max_age_seconds > 0);

CREATE TABLE guild.metric_attribution_episode (
    attribution_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    first_link_at timestamptz NOT NULL,
    closed_at timestamptz,
    include_prelink_history boolean NOT NULL DEFAULT false,
    UNIQUE (attribution_key, user_key, player_key),
    CHECK (closed_at IS NULL OR closed_at > first_link_at),
    EXCLUDE USING gist (
        player_key WITH =, tstzrange(first_link_at, closed_at, '[)') WITH &&
    )
);
CREATE UNIQUE INDEX metric_attribution_one_open_episode
ON guild.metric_attribution_episode (player_key) WHERE closed_at IS NULL;
CREATE UNIQUE INDEX metric_attribution_first_link_backfill
ON guild.metric_attribution_episode (player_key) WHERE include_prelink_history;
COMMENT ON TABLE guild.metric_attribution_episode IS
    'Continuity boundary, not a claim of ownership during unlinked gaps. First-ever link permits '
    'historical backfill; same-member relinks reuse an episode; a different member starts fresh. '
    'Explicit evidence and assessment versions still govern event-level attribution.';

CREATE TABLE guild.account_link (
    link_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    verification_key bigint NOT NULL UNIQUE,
    verification_status text GENERATED ALWAYS AS ('verified'::text) STORED,
    attribution_key bigint NOT NULL,
    linked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    unlinked_at timestamptz,
    is_primary boolean NOT NULL DEFAULT false,
    transfer_boundary_read_key bigint,
    UNIQUE (link_key, user_key, player_key),
    FOREIGN KEY (verification_key, user_key, player_key, verification_status)
        REFERENCES guild.player_verification (verification_key, user_key, player_key, status),
    FOREIGN KEY (attribution_key, user_key, player_key)
        REFERENCES guild.metric_attribution_episode (attribution_key, user_key, player_key),
    CHECK (unlinked_at IS NULL OR unlinked_at > linked_at),
    EXCLUDE USING gist (
        player_key WITH =, tstzrange(linked_at, unlinked_at, '[)') WITH &&
    )
);
CREATE UNIQUE INDEX account_link_one_current_owner
ON guild.account_link (player_key) WHERE unlinked_at IS NULL;
CREATE UNIQUE INDEX account_link_one_current_primary
ON guild.account_link (user_key) WHERE unlinked_at IS NULL AND is_primary;
CREATE INDEX account_link_member_history
ON guild.account_link (user_key, linked_at DESC);

CREATE TABLE guild.account_transfer_request (
    transfer_request_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    from_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    to_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    source_link_key bigint NOT NULL,
    verification_key bigint NOT NULL,
    verification_status text GENERATED ALWAYS AS ('verified'::text) STORED,
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'awaiting_points', 'rejected', 'consumed',
            'cancelled', 'expired')),
    decided_by bigint REFERENCES guild.dim_discord_user,
    decided_at timestamptz,
    consumed_at timestamptz,
    cancelled_at timestamptz,
    expired_at timestamptz,
    FOREIGN KEY (source_link_key, from_user_key, player_key)
        REFERENCES guild.account_link (link_key, user_key, player_key),
    FOREIGN KEY (verification_key, to_user_key, player_key, verification_status)
        REFERENCES guild.player_verification (verification_key, user_key, player_key, status),
    UNIQUE (transfer_request_key, to_user_key, player_key),
    CHECK (from_user_key <> to_user_key),
    CHECK (
        (status = 'pending' AND decided_by IS NULL AND decided_at IS NULL
            AND consumed_at IS NULL AND cancelled_at IS NULL)
        OR (status IN ('approved', 'awaiting_points', 'rejected') AND decided_by IS NOT NULL
            AND decided_at IS NOT NULL AND decided_at >= requested_at
            AND consumed_at IS NULL AND cancelled_at IS NULL)
        OR (status = 'consumed' AND decided_by IS NOT NULL AND decided_at IS NOT NULL
            AND consumed_at IS NOT NULL AND decided_at >= requested_at
            AND consumed_at >= decided_at AND cancelled_at IS NULL)
        OR (status = 'cancelled' AND cancelled_at IS NOT NULL AND consumed_at IS NULL
            AND (decided_by IS NULL) = (decided_at IS NULL))
        OR (status = 'expired' AND consumed_at IS NULL AND cancelled_at IS NULL
            AND (decided_by IS NULL) = (decided_at IS NULL))
    ),
    CHECK ((status = 'expired') = (expired_at IS NOT NULL)),
    CHECK (expired_at IS NULL OR expired_at >= requested_at)
);
COMMENT ON COLUMN guild.account_transfer_request.cancelled_at IS
    'Set when the source link ended before this request was consumed. A cancelled request '
    'keeps any earlier decision as history and can never be decided or consumed.';
COMMENT ON COLUMN guild.account_transfer_request.expired_at IS
    'The moment the request passed its configured limit without a decision, or its approval '
    'passed its limit without being used. An expired request keeps any earlier decision as '
    'history and can never be decided or consumed; the recipient must request the transfer again.';
-- The scheduler looks for open requests.
CREATE INDEX account_transfer_open ON guild.account_transfer_request (requested_at)
    WHERE status IN ('pending', 'approved', 'awaiting_points');

-- An open request ends on a clock. A request that staff did not decide lapses
-- after the pending limit, and an approval the recipient did not use lapses
-- after the approval limit. Both limits are guild settings.
ALTER TABLE guild.guild_settings
    ADD COLUMN transfer_pending_max_age_seconds integer NOT NULL DEFAULT 172800
        CHECK (transfer_pending_max_age_seconds > 0),
    ADD COLUMN transfer_approval_max_age_seconds integer NOT NULL DEFAULT 86400
        CHECK (transfer_approval_max_age_seconds > 0);

ALTER TABLE guild.account_link ADD COLUMN transfer_request_key bigint;
ALTER TABLE guild.account_link ADD CONSTRAINT account_link_transfer_request
FOREIGN KEY (transfer_request_key, user_key, player_key)
REFERENCES guild.account_transfer_request (transfer_request_key, to_user_key, player_key);
CREATE UNIQUE INDEX account_link_transfer_used_once
ON guild.account_link (transfer_request_key) WHERE transfer_request_key IS NOT NULL;
CREATE UNIQUE INDEX account_transfer_one_pending_recipient
ON guild.account_transfer_request (source_link_key, to_user_key) WHERE status = 'pending';

-- account_link.is_primary holds the current primary only. Every change of a
-- member's primary is kept here, so the primary at any time is the new link of
-- the member's latest change before it (LINK-017).
CREATE TABLE guild.fact_primary_account_change (
    primary_change_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    previous_link_key bigint,
    previous_player_key bigint,
    new_link_key bigint,
    new_player_key bigint,
    cause text NOT NULL CHECK (cause IN (
        'first_link', 'choice', 'unlink_replacement', 'link_ended', 'primary_transferred'
    )),
    actor_user_key bigint REFERENCES guild.dim_discord_user,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (previous_link_key, user_key, previous_player_key)
        REFERENCES guild.account_link (link_key, user_key, player_key),
    FOREIGN KEY (new_link_key, user_key, new_player_key)
        REFERENCES guild.account_link (link_key, user_key, player_key),
    CHECK ((previous_link_key IS NULL) = (previous_player_key IS NULL)),
    CHECK ((new_link_key IS NULL) = (new_player_key IS NULL)),
    CHECK (previous_link_key <> new_link_key),
    CHECK (cause <> 'first_link' OR previous_link_key IS NULL),
    -- A member left without a primary by a transfer (DEC-02) later chooses one
    -- with no previous primary.
    CHECK (previous_link_key IS NOT NULL OR cause IN ('first_link', 'choice')),
    CHECK ((cause IN ('link_ended', 'primary_transferred')) = (new_link_key IS NULL))
);
CREATE INDEX primary_account_change_member
ON guild.fact_primary_account_change (user_key, changed_at DESC);
COMMENT ON TABLE guild.fact_primary_account_change IS
    'One change of a member''s primary account. first_link: the member had no current link. '
    'choice: another current link was chosen, also while linking. unlink_replacement: the '
    'primary was unlinked and its replacement named. link_ended: the member''s last current '
    'link ended, so they have no primary. primary_transferred: an approved transfer took the '
    'primary while other links remain, so the member has no primary until a choice, whose '
    'previous link is then empty (DEC-02). actor_user_key is who made the change; it is null '
    'when a worker completed it.';

CREATE VIEW guild.current_account_link AS
SELECT link_key, user_key, player_key, is_primary
FROM guild.account_link WHERE unlinked_at IS NULL;
