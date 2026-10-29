-- =====================================================================
-- CricDB — 03_logic.sql : triggers that enforce the laws of the game,
-- and the core views (derived data is never stored: BR-12)
-- Run after 02_ddl.sql and BEFORE loading, so every real ball is checked.
-- =====================================================================
SET search_path = cricdb;

-- ---------------------------------------------------------------------
-- BR-14: a franchise fields only one team name per season.
-- This is the FD (franchise, season) → team_name that the BCNF split of
-- §5.6 could not keep inside one table.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_one_name_per_franchise() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1
               FROM team_season ts
               JOIN team t     ON t.team_id = ts.team_id
               JOIN team mine  ON mine.team_id = NEW.team_id
               WHERE ts.season_id = NEW.season_id
                 AND t.franchise_id = mine.franchise_id
                 AND ts.team_id <> NEW.team_id) THEN
        RAISE EXCEPTION 'BR-14: franchise of team % already plays under another name in %',
            NEW.team_id, NEW.season_id;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER one_name_per_franchise
    BEFORE INSERT OR UPDATE ON team_season
    FOR EACH ROW EXECUTE FUNCTION trg_one_name_per_franchise();

-- ---------------------------------------------------------------------
-- BR-4 + BR-5: a playing-XI entry must be one of the two teams, the player
-- must be in that team's squad for the season, and the side size must
-- respect the rules of that season.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_playing_xi_rules() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    m       match%ROWTYPE;
    n_xi    int;
    n_imp   int;
BEGIN
    SELECT * INTO m FROM match WHERE match_id = NEW.match_id;

    IF NEW.team_id NOT IN (m.team1_id, m.team2_id) THEN
        RAISE EXCEPTION 'BR-4: team % is not playing match %', NEW.team_id, NEW.match_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM squad
                   WHERE player_id = NEW.player_id AND season_id = m.season_id AND team_id = NEW.team_id) THEN
        RAISE EXCEPTION 'BR-4: player % is not in team %''s % squad', NEW.player_id, NEW.team_id, m.season_id;
    END IF;

    SELECT count(*) FILTER (WHERE entry_type = 'XI'),
           count(*) FILTER (WHERE entry_type = 'IMPACT')
      INTO n_xi, n_imp
      FROM playing_xi
     WHERE match_id = NEW.match_id AND team_id = NEW.team_id;

    IF n_xi > 11 THEN
        RAISE EXCEPTION 'BR-5: more than 11 starting players for team % in match %', NEW.team_id, NEW.match_id;
    END IF;
    IF (n_imp > 1 OR (n_imp = 1 AND m.season_id < 2023))
       AND NOT EXISTS (SELECT 1 FROM rule_exception WHERE match_id = NEW.match_id AND rule_code = 'BR-5') THEN
        RAISE EXCEPTION 'BR-5: Impact Player not allowed (season %, count %)', m.season_id, n_imp;
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER playing_xi_rules
    AFTER INSERT OR UPDATE ON playing_xi
    FOR EACH ROW EXECUTE FUNCTION trg_playing_xi_rules();

-- ---------------------------------------------------------------------
-- BR-6: the batter and non-striker are in the batting side's playing XI;
-- the bowler is in the other side's.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_delivery_players() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    bat_team  smallint;
BEGIN
    SELECT batting_team_id INTO bat_team
      FROM innings WHERE match_id = NEW.match_id AND innings_no = NEW.innings_no;

    IF (SELECT count(*) FROM playing_xi
         WHERE match_id = NEW.match_id AND team_id = bat_team
           AND player_id IN (NEW.batter_id, NEW.non_striker_id)) <> 2 THEN
        RAISE EXCEPTION 'BR-6: batters %/% are not both in the batting XI (match %, %.%)',
            NEW.batter_id, NEW.non_striker_id, NEW.match_id, NEW.over_no, NEW.ball_seq;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM playing_xi
                    WHERE match_id = NEW.match_id AND player_id = NEW.bowler_id AND team_id <> bat_team) THEN
        RAISE EXCEPTION 'BR-6: bowler % is not in the fielding XI (match %, %.%)',
            NEW.bowler_id, NEW.match_id, NEW.over_no, NEW.ball_seq;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER delivery_players
    BEFORE INSERT OR UPDATE ON delivery
    FOR EACH ROW EXECUTE FUNCTION trg_delivery_players();

-- ---------------------------------------------------------------------
-- BR-7: an over has at most 6 legal balls, unless the umpires' miscount
-- is on record. Legality depends on delivery_extra rows that arrive after
-- the delivery, so this is a DEFERRED constraint trigger checked at COMMIT.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_legal_balls_per_over() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r        record := COALESCE(NEW, OLD);
    n_legal  int;
    allowed  int;
BEGIN
    SELECT count(*) INTO n_legal
      FROM delivery d
     WHERE d.match_id = r.match_id AND d.innings_no = r.innings_no AND d.over_no = r.over_no
       AND NOT EXISTS (SELECT 1 FROM delivery_extra e JOIN extra_type x USING (extra_type)
                        WHERE (e.match_id, e.innings_no, e.over_no, e.ball_seq)
                            = (d.match_id, d.innings_no, d.over_no, d.ball_seq)
                          AND NOT x.is_legal);

    SELECT COALESCE(MAX(legal_balls), 6) INTO allowed
      FROM over_miscount
     WHERE match_id = r.match_id AND innings_no = r.innings_no AND over_no = r.over_no;

    IF n_legal > allowed THEN
        RAISE EXCEPTION 'BR-7: over % of innings % in match % has % legal balls (allowed %)',
            r.over_no, r.innings_no, r.match_id, n_legal, allowed;
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER legal_balls_per_over
    AFTER INSERT OR UPDATE ON delivery
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_legal_balls_per_over();

CREATE CONSTRAINT TRIGGER legal_balls_per_over_extra
    AFTER INSERT OR UPDATE OR DELETE ON delivery_extra
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_legal_balls_per_over();

-- ---------------------------------------------------------------------
-- BR-8: only a batter at the crease can be dismissed on a ball.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_wicket_at_crease() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM delivery d
                    WHERE (d.match_id, d.innings_no, d.over_no, d.ball_seq)
                        = (NEW.match_id, NEW.innings_no, NEW.over_no, NEW.ball_seq)
                      AND NEW.player_out_id IN (d.batter_id, d.non_striker_id)) THEN
        RAISE EXCEPTION 'BR-8: player % was not at the crease on match % %.%',
            NEW.player_out_id, NEW.match_id, NEW.over_no, NEW.ball_seq;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER wicket_at_crease
    BEFORE INSERT OR UPDATE ON wicket
    FOR EACH ROW EXECUTE FUNCTION trg_wicket_at_crease();

-- =====================================================================
-- Views (BR-12: everything derived is computed, never stored)
-- =====================================================================

-- One row per ball, with everything the analytics need already derived
CREATE VIEW v_ball AS
SELECT d.match_id, d.innings_no, d.over_no, d.ball_seq,
       m.season_id, i.batting_team_id,
       CASE WHEN i.batting_team_id = m.team1_id THEN m.team2_id ELSE m.team1_id END AS bowling_team_id,
       i.is_super_over,
       d.batter_id, d.non_striker_id, d.bowler_id,
       d.runs_batter,
       COALESCE(x.extras, 0)                                   AS runs_extras,
       d.runs_batter + COALESCE(x.extras, 0)                   AS runs_total,
       d.runs_batter + COALESCE(x.bowler_extras, 0)            AS runs_conceded,  -- byes/leg-byes excluded
       COALESCE(x.is_legal, true)                              AS is_legal,       -- counts for the bowler
       NOT COALESCE(x.is_wide, false)                          AS is_ball_faced,  -- no-balls are faced, wides are not
       d.runs_batter = 4 AND NOT d.is_non_boundary             AS is_four,
       d.runs_batter = 6                                       AS is_six,
       CASE WHEN d.over_no <= 6 THEN 'Powerplay'
            WHEN d.over_no <= 15 THEN 'Middle'
            ELSE 'Death' END                                   AS phase
FROM delivery d
JOIN innings i USING (match_id, innings_no)
JOIN match   m USING (match_id)
LEFT JOIN LATERAL (
    SELECT SUM(e.runs)                                   AS extras,
           SUM(e.runs) FILTER (WHERE t.charged_to_bowler) AS bowler_extras,
           bool_and(t.is_legal)                          AS is_legal,
           bool_or(e.extra_type = 'wides')               AS is_wide
    FROM delivery_extra e JOIN extra_type t USING (extra_type)
    WHERE (e.match_id, e.innings_no, e.over_no, e.ball_seq) = (d.match_id, d.innings_no, d.over_no, d.ball_seq)
) x ON true;

-- Innings scoreboard: total / wickets (overs)
CREATE VIEW v_innings_score AS
SELECT b.match_id, b.innings_no, b.batting_team_id, b.bowling_team_id, b.is_super_over,
       SUM(b.runs_total)                         AS runs,
       (SELECT count(*) FROM wicket w JOIN dismissal_kind k USING (kind)
         WHERE w.match_id = b.match_id AND w.innings_no = b.innings_no AND k.counts_as_out) AS wickets,
       count(*) FILTER (WHERE b.is_legal)        AS legal_balls,
       (count(*) FILTER (WHERE b.is_legal) / 6) || '.' || (count(*) FILTER (WHERE b.is_legal) % 6) AS overs
FROM v_ball b
GROUP BY b.match_id, b.innings_no, b.batting_team_id, b.bowling_team_id, b.is_super_over;

-- Batting card: one row per batter per innings (super overs excluded)
CREATE VIEW v_batting_card AS
SELECT b.match_id, b.innings_no, b.season_id, b.batting_team_id AS team_id, b.batter_id AS player_id,
       SUM(b.runs_batter)                          AS runs,
       count(*) FILTER (WHERE b.is_ball_faced)     AS balls,
       count(*) FILTER (WHERE b.is_four)           AS fours,
       count(*) FILTER (WHERE b.is_six)            AS sixes,
       EXISTS (SELECT 1 FROM wicket w JOIN dismissal_kind k USING (kind)
                WHERE w.match_id = b.match_id AND w.innings_no = b.innings_no
                  AND w.player_out_id = b.batter_id AND k.counts_as_out) AS is_out
FROM v_ball b
WHERE NOT b.is_super_over
GROUP BY b.match_id, b.innings_no, b.season_id, b.batting_team_id, b.batter_id;

-- Bowling card: one row per bowler per innings (super overs excluded)
CREATE VIEW v_bowling_card AS
SELECT b.match_id, b.innings_no, b.season_id, b.bowling_team_id AS team_id, b.bowler_id AS player_id,
       count(*) FILTER (WHERE b.is_legal)  AS legal_balls,
       SUM(b.runs_conceded)                AS runs_conceded,
       count(*) FILTER (WHERE b.runs_total = 0 AND b.is_legal) AS dot_balls,
       (SELECT count(*) FROM wicket w JOIN dismissal_kind k USING (kind)
         JOIN delivery d USING (match_id, innings_no, over_no, ball_seq)
         WHERE w.match_id = b.match_id AND w.innings_no = b.innings_no
           AND d.bowler_id = b.bowler_id AND k.credited_to_bowler) AS wickets
FROM v_ball b
WHERE NOT b.is_super_over
GROUP BY b.match_id, b.innings_no, b.season_id, b.bowling_team_id, b.bowler_id;

-- Human-readable match result
CREATE VIEW v_match_result AS
SELECT m.match_id, m.season_id, m.match_date, m.stage, v.venue_name, c.city_name,
       t1.team_name AS team1, t2.team_name AS team2, tw.team_name AS winner,
       CASE m.result_type
            WHEN 'RUNS'    THEN tw.team_name || ' won by ' || m.margin || ' runs'
            WHEN 'WICKETS' THEN tw.team_name || ' won by ' || m.margin || ' wickets'
            WHEN 'TIE'     THEN 'Tied; ' || tw.team_name || ' won the super over'
            ELSE 'No result' END
       || CASE WHEN m.method IS NOT NULL THEN ' (' || m.method || ')' ELSE '' END AS result
FROM match m
JOIN venue v ON v.venue_id = m.venue_id
JOIN city  c ON c.city_id  = v.city_id
JOIN team t1 ON t1.team_id = m.team1_id
JOIN team t2 ON t2.team_id = m.team2_id
LEFT JOIN team tw ON tw.team_id = m.winner_id;

-- Read-only role for the analytics notebook and any demo UI
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cricdb_readonly') THEN
        CREATE ROLE cricdb_readonly LOGIN PASSWORD 'cricdb_readonly';
    END IF;
END $$;
GRANT USAGE ON SCHEMA cricdb TO cricdb_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA cricdb TO cricdb_readonly;
