-- =====================================================================
--  CricDB  |  Five advanced queries
--
--  Each query is labelled with:
--    QUESTION            what an analyst or a commentator wants to know
--    FDS CONCEPTS        what the query demonstrates
--    RELATIONAL ALGEBRA  where it adds insight
--
--  Q1  Window frames: SUM/AVG OVER (ROWS 4 PRECEDING)       (form guide)
--  Q2  CTE + DENSE_RANK per partition + verified history    (Orange Cap race)
--  Q3  Recursive CTE over a derived graph                   ("Kohli number")
--  Q4  Relational DIVISION with double NOT EXISTS           (all-ground batters)
--  Q5  Set difference with EXCEPT                           (bowlers' "bunnies")
-- =====================================================================

SET search_path TO cricdb, public;


-- =====================================================================
-- Q1. IS VIRAT KOHLI IN FORM?
-- QUESTION
--   Kohli's last 15 innings, each with his rolling average and strike
--   rate over the five innings up to and including it.
-- FDS CONCEPTS
--   Window functions with an explicit ROWS frame; NULLIF to avoid division
--   by zero (the batting average is undefined until he has been out);
--   queries over a view (v_batting_card) that is itself derived from
--   delivery + delivery_extra + wicket.
-- =====================================================================

WITH innings_log AS (
    SELECT m.match_date, t.short_name AS opponent, b.runs, b.balls, b.is_out,
           SUM(b.runs)          OVER w AS runs_5,
           SUM(b.balls)         OVER w AS balls_5,
           SUM(b.is_out::int)   OVER w AS outs_5,
           ROW_NUMBER() OVER (ORDER BY m.match_date DESC, b.match_id DESC) AS recency
    FROM v_batting_card b
    JOIN person p ON p.person_id = b.player_id
    JOIN match  m ON m.match_id  = b.match_id
    JOIN team   t ON t.team_id   = CASE WHEN b.team_id = m.team1_id THEN m.team2_id ELSE m.team1_id END
    WHERE p.known_as = 'V Kohli'
    WINDOW w AS (ORDER BY m.match_date, b.match_id ROWS BETWEEN 4 PRECEDING AND CURRENT ROW)
)
SELECT match_date, opponent,
       runs || CASE WHEN is_out THEN '' ELSE '*' END       AS score,
       balls,
       round(runs_5::numeric / NULLIF(outs_5, 0), 1)      AS rolling_avg_5,
       round(100.0 * runs_5 / NULLIF(balls_5, 0), 1)      AS rolling_sr_5
FROM innings_log
WHERE recency <= 15
ORDER BY match_date;


-- =====================================================================
-- Q2. WHO WON THE ORANGE CAP EACH SEASON, AND WHO CHASED IT?
-- QUESTION
--   The top three run-scorers of every season, with the gap to the leader.
-- FDS CONCEPTS
--   CTE, GROUP BY, DENSE_RANK() and FIRST_VALUE() partitioned by season,
--   filtering on a window result (which needs the outer query, because
--   window functions run after WHERE).
-- RELATIONAL ALGEBRA
--   γ season, player; sum(runs)→runs (BattingCard), then a per-group top-k,
--   which basic relational algebra cannot express (it needs ranking).
-- =====================================================================

WITH season_runs AS (
    SELECT b.season_id, b.player_id, SUM(b.runs) AS runs, count(*) AS innings,
           round(100.0 * SUM(b.runs) / NULLIF(SUM(b.balls), 0), 1) AS strike_rate
    FROM v_batting_card b
    GROUP BY b.season_id, b.player_id
), ranked AS (
    SELECT s.*,
           DENSE_RANK()  OVER (PARTITION BY season_id ORDER BY runs DESC) AS rnk,
           FIRST_VALUE(runs) OVER (PARTITION BY season_id ORDER BY runs DESC) AS leader_runs
    FROM season_runs s
)
SELECT r.season_id, r.rnk, p.known_as AS batter, r.runs, r.innings, r.strike_rate,
       r.runs - r.leader_runs AS gap_to_leader
FROM ranked r
JOIN person p ON p.person_id = r.player_id
WHERE r.rnk <= 3
ORDER BY r.season_id, r.rnk;


-- =====================================================================
-- Q3. HOW CONNECTED IS THE IPL?  ("KOHLI NUMBERS")
-- QUESTION
--   Two players are linked if they have played in the same XI. A player's
--   Kohli number is the length of the shortest chain of such links to
--   Virat Kohli. How many players are at each distance?
-- FDS CONCEPTS
--   WITH RECURSIVE (breadth-first search); a graph derived on the fly from
--   a self-join of playing_xi; UNION (not UNION ALL) so each
--   (player, distance) pair is visited once; termination by a depth bound.
-- RELATIONAL ALGEBRA
--   Edge = π p1, p2 ( σ p1≠p2 ( XI ⋈ match, team XI' ) ). The recursion is a
--   fixpoint of  R_{k+1} = π p2 ( R_k ⋈ Edge ), which basic relational
--   algebra cannot express. That is why SQL added WITH RECURSIVE.
-- =====================================================================

WITH RECURSIVE edge AS (
    SELECT DISTINCT a.player_id AS p1, b.player_id AS p2
    FROM playing_xi a
    JOIN playing_xi b ON b.match_id = a.match_id AND b.team_id = a.team_id
                     AND b.player_id <> a.player_id
), reach (player_id, distance) AS (
    SELECT person_id, 0 FROM person WHERE known_as = 'V Kohli'
    UNION
    SELECT e.p2, r.distance + 1
    FROM reach r JOIN edge e ON e.p1 = r.player_id
    WHERE r.distance < 4
), kohli_number AS (
    SELECT player_id, MIN(distance) AS kohli_number
    FROM reach GROUP BY player_id
)
SELECT kohli_number,
       count(*) AS players,
       (string_agg(p.known_as, ', ' ORDER BY p.known_as)
            FILTER (WHERE kohli_number >= 3))  AS who
FROM kohli_number k JOIN person p ON p.person_id = k.player_id
GROUP BY kohli_number
UNION ALL                                  -- substitute fielders who never made an XI have no edges
SELECT NULL, count(*), 'unreachable: substitute fielders who never played in an XI'
FROM player WHERE person_id NOT IN (SELECT player_id FROM kohli_number)
ORDER BY kohli_number NULLS LAST;


-- =====================================================================
-- Q4. WHO HAS SCORED A FIFTY AT EVERY ONE OF THE "BIG FIVE" GROUNDS?
-- QUESTION
--   The five grounds that have hosted the most IPL matches. Which batters
--   have made 50+ at every one of them?
-- FDS CONCEPTS
--   Relational DIVISION written as a double NOT EXISTS ("there is no big
--   ground at which there is no fifty by this batter"); the divisor is
--   itself computed (ORDER BY ... LIMIT inside a CTE).
-- RELATIONAL ALGEBRA
--   Fifties(batter, venue) ÷ BigFive(venue)
--   = π batter(Fifties) − π batter( (π batter(Fifties) × BigFive) − Fifties )
-- =====================================================================

WITH big_five AS (
    SELECT venue_id FROM match GROUP BY venue_id ORDER BY count(*) DESC LIMIT 5
), fifties AS (
    SELECT DISTINCT b.player_id, m.venue_id
    FROM v_batting_card b JOIN match m USING (match_id)
    WHERE b.runs >= 50
)
SELECT p.known_as AS batter,
       (SELECT count(*) FROM fifties f2 WHERE f2.player_id = p.person_id) AS grounds_with_a_fifty
FROM person p
WHERE EXISTS (SELECT 1 FROM fifties f WHERE f.player_id = p.person_id)
  AND NOT EXISTS (                         -- no big ground ...
        SELECT 1 FROM big_five g
        WHERE NOT EXISTS (                 -- ... without a fifty by p
              SELECT 1 FROM fifties f
              WHERE f.player_id = p.person_id AND f.venue_id = g.venue_id))
ORDER BY grounds_with_a_fifty DESC, batter;


-- =====================================================================
-- Q5. WHO ARE THE BOWLERS' "BUNNIES"?
-- QUESTION
--   Batter–bowler pairs where the bowler has dismissed the batter at least
--   3 times and the batter has NEVER hit that bowler for a four or a six.
-- FDS CONCEPTS
--   Set difference (EXCEPT) between two projections of the same view;
--   GROUP BY ... HAVING; joining the difference back for context.
-- RELATIONAL ALGEBRA
--   π batter, bowler ( σ dismissals ≥ 3 (γ batter, bowler; count→dismissals (Dismissal)) )
--   − π batter, bowler ( σ is_four ∨ is_six (Ball) )
-- =====================================================================

WITH bunnies AS (
    SELECT d.batter_id, d.bowler_id
    FROM wicket w
    JOIN delivery d USING (match_id, innings_no, over_no, ball_seq)
    JOIN dismissal_kind k USING (kind)
    WHERE k.credited_to_bowler AND w.player_out_id = d.batter_id
    GROUP BY d.batter_id, d.bowler_id
    HAVING count(*) >= 3
    EXCEPT
    SELECT batter_id, bowler_id
    FROM v_ball
    WHERE is_four OR is_six
)
SELECT pb.known_as AS batter, pw.known_as AS bowler,
       count(*) FILTER (WHERE v.is_ball_faced)        AS balls_faced,
       SUM(v.runs_batter)                              AS runs,
       (SELECT count(*) FROM wicket w JOIN delivery d USING (match_id, innings_no, over_no, ball_seq)
         JOIN dismissal_kind k USING (kind)
         WHERE d.batter_id = bn.batter_id AND d.bowler_id = bn.bowler_id
           AND w.player_out_id = d.batter_id AND k.credited_to_bowler) AS dismissals
FROM bunnies bn
JOIN v_ball v  ON v.batter_id = bn.batter_id AND v.bowler_id = bn.bowler_id
JOIN person pb ON pb.person_id = bn.batter_id
JOIN person pw ON pw.person_id = bn.bowler_id
GROUP BY bn.batter_id, bn.bowler_id, pb.known_as, pw.known_as
ORDER BY dismissals DESC, balls_faced DESC;
