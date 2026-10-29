-- =====================================================================
--  CricDB  |  Live demo (about 4 minutes, presenter: M3 / M4)
--
--  Every change runs inside BEGIN ... ROLLBACK, so the demo can be
--  repeated any number of times and never alters the loaded data.
--  Run:  psql -U postgres -h localhost -d cricdb -f 06_demo.sql
--  Errors are EXPECTED in steps 2-4: they are the rules firing.
-- =====================================================================

SET search_path TO cricdb, public;
\set ON_ERROR_STOP 0
\pset footer off

\echo
\echo '=== 1. One ball, reassembled from 7 normalized tables ==='
\echo '    The first ball of the IPL (2008-04-18). It was a leg-bye.'
SELECT r.result, v.season_id, v.over_no || '.' || v.ball_seq AS ball,
       pb.known_as AS batter, pw.known_as AS bowler,
       v.runs_batter, v.runs_extras, e.extra_type, v.is_legal, v.phase
FROM v_ball v
JOIN v_match_result r USING (match_id)
JOIN person pb ON pb.person_id = v.batter_id
JOIN person pw ON pw.person_id = v.bowler_id
LEFT JOIN delivery_extra e USING (match_id, innings_no, over_no, ball_seq)
WHERE v.match_id = 335982 AND v.innings_no = 1 AND v.over_no = 1 AND v.ball_seq = 1;

\echo
\echo '    Entity resolution: three spellings in the source, one venue in the database'
SELECT a.alias AS cricsheet_spelling, v.venue_name, c.city_name
FROM venue_alias a JOIN venue v USING (venue_id) JOIN city c USING (city_id)
WHERE v.venue_name = 'Arun Jaitley Stadium';

\echo
\echo '=== 2. BR-7: a 7th legal ball. The check is DEFERRED, so it fires at COMMIT ==='
BEGIN;
INSERT INTO delivery (match_id, innings_no, over_no, ball_seq, batter_id, non_striker_id, bowler_id, runs_batter)
SELECT match_id, innings_no, over_no, 15, batter_id, non_striker_id, bowler_id, 4
FROM delivery WHERE (match_id, innings_no, over_no, ball_seq) = (335982, 1, 1, 1);
\echo '    ... the INSERT succeeded (a wide could still be added). Now COMMIT:'
COMMIT;

\echo
\echo '    Same ball, but recorded as a wide: legal, so COMMIT would succeed (we roll back)'
BEGIN;
INSERT INTO delivery (match_id, innings_no, over_no, ball_seq, batter_id, non_striker_id, bowler_id, runs_batter)
SELECT match_id, innings_no, over_no, 15, batter_id, non_striker_id, bowler_id, 0
FROM delivery WHERE (match_id, innings_no, over_no, ball_seq) = (335982, 1, 1, 1);
INSERT INTO delivery_extra VALUES (335982, 1, 1, 15, 'wides', 1);
SET CONSTRAINTS ALL IMMEDIATE;      -- run the deferred check now: no error
\echo '    No error. Rolling back.'
ROLLBACK;

\echo
\echo '    Real umpire errors are recorded, not rejected:'
SELECT o.match_id, m.season_id, o.innings_no, o.over_no, o.legal_balls, p.known_as AS umpire
FROM over_miscount o JOIN match m USING (match_id) LEFT JOIN person p ON p.person_id = o.umpire_id
ORDER BY m.season_id;

\echo
\echo '=== 3. BR-6 and BR-8: who may bowl, and who may be out ==='
BEGIN;
-- Kolkata's own batter (Ganguly) tries to bowl to his own side
UPDATE delivery SET bowler_id = (SELECT person_id FROM person WHERE known_as = 'SC Ganguly'),
                    batter_id = (SELECT person_id FROM person WHERE known_as = 'BB McCullum'),
                    non_striker_id = (SELECT person_id FROM person WHERE known_as = 'RT Ponting')
WHERE (match_id, innings_no, over_no, ball_seq) = (335982, 1, 1, 2);
ROLLBACK;
BEGIN;
-- The bowler is given out
INSERT INTO wicket SELECT 335982, 1, 1, 2, bowler_id, 'bowled'
FROM delivery WHERE (match_id, innings_no, over_no, ball_seq) = (335982, 1, 1, 2);
ROLLBACK;

\echo
\echo '=== 4. BR-14: the FD that BCNF could not keep in one table ==='
\echo '    Delhi played as "Delhi Capitals" in 2023; try to register "Delhi Daredevils" too'
BEGIN;
INSERT INTO team_season SELECT team_id, 2023 FROM team WHERE team_name = 'Delhi Daredevils';
ROLLBACK;

\echo
\echo '    BR-5: an Impact Player in 2019, four years before the rule existed'
BEGIN;
INSERT INTO playing_xi (match_id, player_id, team_id, entry_type)
SELECT x.match_id, s.player_id, x.team_id, 'IMPACT'
FROM (SELECT match_id, team_id FROM playing_xi JOIN match USING (match_id)
      WHERE season_id = 2019 LIMIT 1) x
JOIN match m ON m.match_id = x.match_id
JOIN squad s ON s.team_id = x.team_id AND s.season_id = m.season_id
WHERE s.player_id NOT IN (SELECT player_id FROM playing_xi WHERE match_id = x.match_id)
LIMIT 1;
ROLLBACK;

\echo
\echo '=== 5. Weak entities: deleting a match cascades through the chain ==='
BEGIN;
SELECT (SELECT count(*) FROM innings  WHERE match_id = 335982) AS innings,
       (SELECT count(*) FROM delivery WHERE match_id = 335982) AS deliveries,
       (SELECT count(*) FROM wicket   WHERE match_id = 335982) AS wickets;
DELETE FROM match WHERE match_id = 335982;
SELECT (SELECT count(*) FROM innings  WHERE match_id = 335982) AS innings,
       (SELECT count(*) FROM delivery WHERE match_id = 335982) AS deliveries,
       (SELECT count(*) FROM wicket   WHERE match_id = 335982) AS wickets;
\echo '    ... but a player who has batted cannot be deleted (RESTRICT):'
DELETE FROM player WHERE person_id = (SELECT person_id FROM person WHERE known_as = 'BB McCullum');
ROLLBACK;

\echo
\echo '=== 6. Indexing: every ball a batter faced, with and without an index (296k deliveries) ==='
\echo '    TIMING OFF: per-row timing overhead on Windows would otherwise distort the comparison.'
\echo '    Suryavanshi faced 473 balls (0.2% of rows); Kohli faced 7,127 (2.4%).'
\echo '    Expect: the index wins by 10-30x for Suryavanshi, and roughly breaks even (or loses)'
\echo '    for Kohli, whose rows are spread over most pages. An index pays off when the predicate is SELECTIVE.'
BEGIN;
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT * FROM delivery WHERE batter_id = (SELECT person_id FROM person WHERE known_as = 'V Suryavanshi');
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT * FROM delivery WHERE batter_id = (SELECT person_id FROM person WHERE known_as = 'V Kohli');
DROP INDEX ix_delivery_batter;
\echo '    Index dropped (inside the transaction). Same two queries:'
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT * FROM delivery WHERE batter_id = (SELECT person_id FROM person WHERE known_as = 'V Suryavanshi');
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT * FROM delivery WHERE batter_id = (SELECT person_id FROM person WHERE known_as = 'V Kohli');
ROLLBACK;
\echo '    Rolled back: the index is restored.'

\echo
\echo '=== 7. Least privilege: the analytics role can read, not write ==='
SET ROLE cricdb_readonly;
SELECT count(*) AS deliveries_visible FROM delivery;
DELETE FROM delivery WHERE match_id = 335982;
RESET ROLE;
