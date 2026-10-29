-- =====================================================================
--  CricDB  |  Analytics: SQL statistics, feature views, k-means segments
--
--  A1-A5  descriptive statistics computed INSIDE PostgreSQL
--  v_batter_features / v_bowler_features   one row per player (2022-2026)
--  segment / player_segment                k-means labels, written back by
--                                          analytics/cricdb_kmeans.ipynb
--  S1-S2  questions that need the segments
--
--  The notebook runs each labelled query from this file, so the SQL on
--  the slides and the SQL executed are the same text.
--  Re-runnable: views are dropped and recreated; segment tables are kept.
-- =====================================================================

SET search_path TO cricdb, public;
SET client_min_messages = warning;

-- One definition of the eras, used everywhere
CREATE OR REPLACE FUNCTION era(season smallint) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN season <= 2012 THEN '2008-12'
                WHEN season <= 2017 THEN '2013-17'
                WHEN season <= 2022 THEN '2018-22'
                ELSE '2023-26 (Impact)' END
$$;


-- =====================================================================
-- A1. HAS SCORING INFLATED?
-- First-innings totals per season: mean, SD, median and 90th percentile.
-- Only complete, unreduced matches (no DLS, a result reached).
-- FDS: aggregate + ordered-set aggregates (PERCENTILE_CONT), FILTER-free
-- WHERE on the outer query, a view (v_innings_score) as input.
-- =====================================================================

SELECT m.season_id,
       era(m.season_id)                                              AS era,
       count(*)                                                      AS matches,
       round(avg(s.runs), 1)                                         AS mean_runs,
       round(stddev_samp(s.runs), 1)                                 AS sd_runs,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY s.runs)           AS median_runs,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY s.runs)::numeric, 1) AS p90_runs,
       count(*) FILTER (WHERE s.runs >= 200)                         AS totals_200_plus
FROM v_innings_score s
JOIN match m USING (match_id)
WHERE s.innings_no = 1 AND m.method IS NULL AND m.result_type <> 'NO_RESULT'
GROUP BY m.season_id
ORDER BY m.season_id;


-- =====================================================================
-- A2. DOES WINNING THE TOSS HELP?
-- For each era and toss decision: how often the toss winner chose it, and
-- how often the toss winner went on to win. The notebook runs a χ² test
-- on these counts.
-- =====================================================================

SELECT era(season_id)                                                AS era,
       toss_decision,
       count(*)                                                      AS matches,
       count(*) FILTER (WHERE winner_id = toss_winner_id)            AS toss_winner_won,
       round(100.0 * count(*) FILTER (WHERE winner_id = toss_winner_id) / count(*), 1) AS win_pct
FROM match
WHERE result_type <> 'NO_RESULT'
GROUP BY era(season_id), toss_decision
ORDER BY era, toss_decision;


-- =====================================================================
-- A3. WHERE IN THE INNINGS HAS SCORING CHANGED?
-- Run rate (runs per 6 legal balls) by era × phase, with subtotals per era
-- and a grand total from GROUP BY ROLLUP.
-- =====================================================================

SELECT COALESCE(era(season_id), 'All eras')                          AS era,
       COALESCE(phase, 'All overs')                                  AS phase,
       count(*) FILTER (WHERE is_legal)                              AS legal_balls,
       round(6.0 * SUM(runs_total) / count(*) FILTER (WHERE is_legal), 2) AS run_rate,
       round(100.0 * count(*) FILTER (WHERE is_four OR is_six) / count(*) FILTER (WHERE is_legal), 1) AS boundary_pct
FROM v_ball
WHERE NOT is_super_over
GROUP BY ROLLUP (era(season_id), phase)
ORDER BY era(season_id) NULLS LAST,
         CASE phase WHEN 'Powerplay' THEN 1 WHEN 'Middle' THEN 2 WHEN 'Death' THEN 3 ELSE 4 END;


-- =====================================================================
-- A4. IS THERE A HOME ADVANTAGE?
-- A match counts when exactly one side is playing in its franchise's home
-- city. Home win % per franchise, plus the overall figure (GROUPING SETS).
-- =====================================================================

WITH home_matches AS (
    SELECT m.match_id, m.winner_id,
           CASE WHEN f1.home_city_id = v.city_id THEN m.team1_id ELSE m.team2_id END AS home_team_id
    FROM match m
    JOIN venue v      ON v.venue_id = m.venue_id
    JOIN team t1      ON t1.team_id = m.team1_id
    JOIN team t2      ON t2.team_id = m.team2_id
    JOIN franchise f1 ON f1.franchise_id = t1.franchise_id
    JOIN franchise f2 ON f2.franchise_id = t2.franchise_id
    WHERE m.result_type <> 'NO_RESULT'
      AND (f1.home_city_id = v.city_id) <> (f2.home_city_id = v.city_id)   -- exactly one side at home
)
SELECT COALESCE(f.franchise_code, 'ALL')                             AS franchise,
       count(*)                                                      AS home_matches,
       count(*) FILTER (WHERE h.winner_id = h.home_team_id)          AS home_wins,
       round(100.0 * count(*) FILTER (WHERE h.winner_id = h.home_team_id) / count(*), 1) AS home_win_pct
FROM home_matches h
JOIN team t      ON t.team_id = h.home_team_id
JOIN franchise f ON f.franchise_id = t.franchise_id
GROUP BY GROUPING SETS ((f.franchise_code), ())
HAVING count(*) >= 20
ORDER BY GROUPING(f.franchise_code), home_win_pct DESC;


-- =====================================================================
-- A5. HOW ARE STRIKE RATES DISTRIBUTED (2022-2026)?
-- Histogram of batter strike rates (≥ 300 balls faced) in buckets of 10,
-- built with WIDTH_BUCKET. generate_series + LEFT JOIN keeps empty buckets.
-- =====================================================================

WITH sr AS (
    SELECT batter_id, 100.0 * SUM(runs_batter) / count(*) FILTER (WHERE is_ball_faced) AS strike_rate
    FROM v_ball
    WHERE season_id >= 2022 AND NOT is_super_over
    GROUP BY batter_id
    HAVING count(*) FILTER (WHERE is_ball_faced) >= 300
), binned AS (
    SELECT width_bucket(strike_rate, 110, 240, 13) AS bucket, count(*) AS batters
    FROM sr GROUP BY 1
)
SELECT g.bucket,
       (100 + 10 * g.bucket) || '-' || (110 + 10 * g.bucket)         AS strike_rate_range,
       COALESCE(b.batters, 0)                                        AS batters,
       round(100.0 * COALESCE(b.batters, 0) / SUM(COALESCE(b.batters, 0)) OVER (), 1) AS pct
FROM generate_series(1, 13) AS g(bucket)
LEFT JOIN binned b USING (bucket)
ORDER BY g.bucket;


-- =====================================================================
-- Feature views for k-means (window 2022-2026, super overs excluded)
-- =====================================================================
DROP VIEW IF EXISTS v_segment_profile, v_batter_features, v_bowler_features;

-- When did each batter come in? The over of the first ball on which they
-- were at the crease (as striker or non-striker), per innings.
CREATE VIEW v_batter_features AS
WITH b AS (
    SELECT * FROM v_ball WHERE season_id >= 2022 AND NOT is_super_over
), entry AS (
    SELECT match_id, innings_no, player_id, MIN(over_no + ball_seq / 100.0) AS entry_point
    FROM (SELECT match_id, innings_no, over_no, ball_seq, batter_id AS player_id FROM b
          UNION ALL
          SELECT match_id, innings_no, over_no, ball_seq, non_striker_id FROM b) x
    GROUP BY match_id, innings_no, player_id
), entry_avg AS (
    SELECT player_id, round(avg(entry_point), 2) AS avg_entry_over
    FROM entry GROUP BY player_id
), outs AS (
    SELECT w.player_out_id AS player_id, count(*) AS outs
    FROM wicket w JOIN dismissal_kind k USING (kind)
    JOIN innings i USING (match_id, innings_no) JOIN match m USING (match_id)
    WHERE k.counts_as_out AND m.season_id >= 2022 AND NOT i.is_super_over
    GROUP BY w.player_out_id
)
SELECT b.batter_id                                                   AS player_id,
       count(*) FILTER (WHERE b.is_ball_faced)                       AS balls_faced,
       SUM(b.runs_batter)                                            AS runs,
       COALESCE(o.outs, 0)                                           AS outs,
       round(100.0 * SUM(b.runs_batter) / count(*) FILTER (WHERE b.is_ball_faced), 2)  AS strike_rate,
       round(SUM(b.runs_batter)::numeric / GREATEST(COALESCE(o.outs, 0), 1), 2)       AS average,
       round(100.0 * count(*) FILTER (WHERE b.is_four OR b.is_six) / count(*) FILTER (WHERE b.is_ball_faced), 2) AS boundary_pct,
       round(100.0 * count(*) FILTER (WHERE b.is_ball_faced AND b.runs_batter = 0) / count(*) FILTER (WHERE b.is_ball_faced), 2) AS dot_pct,
       round(100.0 * count(*) FILTER (WHERE b.is_ball_faced AND b.phase = 'Death') / count(*) FILTER (WHERE b.is_ball_faced), 2) AS death_share,
       e.avg_entry_over
FROM b
LEFT JOIN outs o      ON o.player_id = b.batter_id
JOIN entry_avg e      ON e.player_id = b.batter_id
GROUP BY b.batter_id, o.outs, e.avg_entry_over
HAVING count(*) FILTER (WHERE b.is_ball_faced) >= 300;

CREATE VIEW v_bowler_features AS
WITH b AS (
    SELECT * FROM v_ball WHERE season_id >= 2022 AND NOT is_super_over
), wk AS (
    SELECT d.bowler_id, count(*) AS wickets
    FROM wicket w JOIN dismissal_kind k USING (kind)
    JOIN delivery d USING (match_id, innings_no, over_no, ball_seq)
    JOIN innings i USING (match_id, innings_no) JOIN match m USING (match_id)
    WHERE k.credited_to_bowler AND m.season_id >= 2022 AND NOT i.is_super_over
    GROUP BY d.bowler_id
)
SELECT b.bowler_id                                                   AS player_id,
       count(*) FILTER (WHERE b.is_legal)                            AS legal_balls,
       SUM(b.runs_conceded)                                          AS runs_conceded,
       COALESCE(wk.wickets, 0)                                       AS wickets,
       round(6.0 * SUM(b.runs_conceded) / count(*) FILTER (WHERE b.is_legal), 2)          AS economy,
       round(count(*) FILTER (WHERE b.is_legal)::numeric / GREATEST(COALESCE(wk.wickets, 0), 1), 2) AS bowling_sr,
       round(100.0 * count(*) FILTER (WHERE b.is_legal AND b.runs_total = 0) / count(*) FILTER (WHERE b.is_legal), 2) AS dot_pct,
       round(100.0 * count(*) FILTER (WHERE b.is_four OR b.is_six) / count(*) FILTER (WHERE b.is_legal), 2) AS boundary_pct,
       round(100.0 * count(*) FILTER (WHERE b.is_legal AND b.phase = 'Powerplay') / count(*) FILTER (WHERE b.is_legal), 2) AS pp_share,
       round(100.0 * count(*) FILTER (WHERE b.is_legal AND b.phase = 'Death') / count(*) FILTER (WHERE b.is_legal), 2) AS death_share
FROM b
LEFT JOIN wk ON wk.bowler_id = b.bowler_id
GROUP BY b.bowler_id, wk.wickets
HAVING count(*) FILTER (WHERE b.is_legal) >= 360;   -- 60 overs


-- =====================================================================
-- Segment tables (BCNF): the notebook writes k-means results here
-- =====================================================================
CREATE TABLE IF NOT EXISTS segment (
    segment_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role          varchar(4)  NOT NULL CHECK (role IN ('BAT', 'BOWL')),
    segment_name  varchar(40) NOT NULL,
    description   text        NOT NULL,
    UNIQUE (role, segment_name),
    UNIQUE (segment_id, role)                    -- target of the composite FK below
);

CREATE TABLE IF NOT EXISTS player_segment (
    player_id   integer    REFERENCES player ON DELETE CASCADE,
    role        varchar(4) NOT NULL,
    segment_id  smallint   NOT NULL,
    distance    numeric(6, 3) NOT NULL CHECK (distance >= 0),   -- to the centroid, in SD units
    PRIMARY KEY (player_id, role),
    FOREIGN KEY (segment_id, role) REFERENCES segment (segment_id, role) ON DELETE CASCADE
);

CREATE VIEW v_segment_profile AS
SELECT s.role, s.segment_name, count(*) AS players,
       string_agg(p.known_as, ', ' ORDER BY ps.distance) AS most_typical
FROM segment s
JOIN player_segment ps USING (segment_id, role)
JOIN person p ON p.person_id = ps.player_id
GROUP BY s.segment_id, s.role, s.segment_name;

GRANT SELECT ON ALL TABLES IN SCHEMA cricdb TO cricdb_readonly;


-- =====================================================================
-- S1. HOW DOES EACH 2026 SQUAD MIX THE BATTING STYLES?
-- Share of each team's 2026 balls faced, by batting segment. Players who
-- were not clustered (too few balls) fall in "Unclustered".
-- =====================================================================

SELECT t.short_name                                                  AS team,
       COALESCE(s.segment_name, 'Unclustered')                       AS batting_segment,
       count(*) FILTER (WHERE b.is_ball_faced)                       AS balls_faced,
       round(100.0 * count(*) FILTER (WHERE b.is_ball_faced)
             / SUM(count(*) FILTER (WHERE b.is_ball_faced)) OVER (PARTITION BY t.short_name), 1) AS share_pct
FROM v_ball b
JOIN team t ON t.team_id = b.batting_team_id
LEFT JOIN player_segment ps ON ps.player_id = b.batter_id AND ps.role = 'BAT'
LEFT JOIN segment s ON s.segment_id = ps.segment_id
WHERE b.season_id = 2026 AND NOT b.is_super_over
GROUP BY t.short_name, s.segment_name
ORDER BY t.short_name, share_pct DESC;


-- =====================================================================
-- S2. DO CHAMPIONS BOWL DIFFERENTLY?
-- For 2022-2026: share of overs bowled by each bowling segment, for the
-- season's champion vs every other team.
-- =====================================================================

WITH champion AS (
    SELECT season_id, winner_id AS team_id FROM match WHERE stage = 'Final'
)
SELECT CASE WHEN c.team_id IS NOT NULL THEN 'Champion' ELSE 'Rest' END AS team_group,
       COALESCE(s.segment_name, 'Unclustered')                       AS bowling_segment,
       round(count(*) FILTER (WHERE b.is_legal) / 6.0, 0)            AS overs,
       round(100.0 * count(*) FILTER (WHERE b.is_legal)
             / SUM(count(*) FILTER (WHERE b.is_legal)) OVER (PARTITION BY c.team_id IS NOT NULL), 1) AS share_pct,
       round(6.0 * SUM(b.runs_conceded) / count(*) FILTER (WHERE b.is_legal), 2) AS economy
FROM v_ball b
LEFT JOIN champion c ON c.season_id = b.season_id AND c.team_id = b.bowling_team_id
LEFT JOIN player_segment ps ON ps.player_id = b.bowler_id AND ps.role = 'BOWL'
LEFT JOIN segment s ON s.segment_id = ps.segment_id
WHERE b.season_id >= 2022 AND NOT b.is_super_over
GROUP BY c.team_id IS NOT NULL, s.segment_name
ORDER BY team_group, share_pct DESC;
