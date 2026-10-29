-- =====================================================================
-- CricDB — IPL Match & Player Analytics System
-- 02_ddl.sql : schema, keys, CHECKs, and curated reference data
-- Target: PostgreSQL 18 (15+). Re-runnable: drops and recreates the schema.
-- Design rationale: 01_design.md (BR-n = business rule n)
-- =====================================================================

SET client_min_messages = warning;   -- hide the DROP ... CASCADE notices
DROP SCHEMA IF EXISTS cricdb CASCADE;
CREATE SCHEMA cricdb;
SET search_path = cricdb;

-- ---------------------------------------------------------------------
-- 1. Lookup tables: these hold FDs that look like facts about a ball or
--    a wicket but are really facts about the category (§5.4)
-- ---------------------------------------------------------------------
CREATE TABLE extra_type (
    extra_type         varchar(10) PRIMARY KEY,
    is_legal           boolean NOT NULL,      -- FD6: extra_type → is_legal (BR-10)
    charged_to_bowler  boolean NOT NULL       -- counts in the bowler's economy
);

CREATE TABLE dismissal_kind (
    kind                varchar(25) PRIMARY KEY,
    credited_to_bowler  boolean NOT NULL,     -- FD7 (BR-11)
    counts_as_out       boolean NOT NULL      -- retired hurt is not an out
);

-- ---------------------------------------------------------------------
-- 2. Places, franchises, teams, seasons
-- ---------------------------------------------------------------------
CREATE TABLE city (
    city_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city_name  varchar(40) NOT NULL,
    state      varchar(40),
    country    varchar(30) NOT NULL,
    UNIQUE (city_name, country)
);

CREATE TABLE venue (
    venue_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    venue_name  varchar(80) NOT NULL UNIQUE,  -- canonical (current) name
    city_id     smallint NOT NULL REFERENCES city
);

-- Entity resolution: every spelling Cricsheet uses → one venue (alias → venue_id)
CREATE TABLE venue_alias (
    alias     varchar(120) PRIMARY KEY,
    venue_id  smallint NOT NULL REFERENCES venue ON DELETE CASCADE
);

CREATE TABLE franchise (
    franchise_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    franchise_code  varchar(5) NOT NULL UNIQUE,
    home_city_id    smallint NOT NULL REFERENCES city
);

-- A team = a franchise playing under one name (BCNF split of §5.6)
CREATE TABLE team (
    team_id       smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    team_name     varchar(40) NOT NULL UNIQUE,
    short_name    varchar(5)  NOT NULL,
    franchise_id  smallint NOT NULL REFERENCES franchise
);

CREATE TABLE season (
    season_id  smallint PRIMARY KEY CHECK (season_id BETWEEN 2008 AND 2100),  -- the year
    label      varchar(10) NOT NULL UNIQUE    -- Cricsheet's label, e.g. '2007/08' for 2008
);

CREATE TABLE team_season (
    team_id    smallint REFERENCES team,
    season_id  smallint REFERENCES season,
    PRIMARY KEY (team_id, season_id)
    -- BR-14 (one name per franchise per season) spans team + team_season: trigger in 03
);

-- ---------------------------------------------------------------------
-- 3. People: PERSON → PLAYER, OFFICIAL (overlapping, partial; mapping 8A)
--    Subclass tables exist so FKs can say "a bowler must be a PLAYER".
-- ---------------------------------------------------------------------
CREATE TABLE person (
    person_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cricsheet_id  char(8) NOT NULL UNIQUE,    -- stable registry id; names are not unique
    known_as      varchar(60) NOT NULL
);

CREATE TABLE player (
    person_id  integer PRIMARY KEY REFERENCES person ON DELETE RESTRICT
);

CREATE TABLE official (
    person_id  integer PRIMARY KEY REFERENCES person ON DELETE RESTRICT
);

-- SIGNED_FOR: ternary PLAYER–TEAM–SEASON with FD (player, season) → team (BR-1)
CREATE TABLE squad (
    player_id         integer  REFERENCES player ON DELETE RESTRICT,
    season_id         smallint,
    team_id           smallint NOT NULL,
    acquisition_type  varchar(12) CHECK (acquisition_type IN ('AUCTION', 'RETAINED', 'TRADED', 'REPLACEMENT', 'DRAFT')),
    price_lakh        numeric(7, 2) CHECK (price_lakh >= 0),  -- optional; data/reference/auction_template.csv
    PRIMARY KEY (player_id, season_id),
    FOREIGN KEY (team_id, season_id) REFERENCES team_season
);

-- ---------------------------------------------------------------------
-- 4. Matches
-- ---------------------------------------------------------------------
CREATE TABLE match (
    match_id            integer PRIMARY KEY,  -- Cricsheet match id (natural, stable)
    season_id           smallint NOT NULL REFERENCES season,
    match_no            smallint CHECK (match_no > 0),  -- NULL for playoffs
    match_date          date NOT NULL,        -- first day (2 matches finished on a reserve day)
    venue_id            smallint NOT NULL REFERENCES venue,
    stage               varchar(20) NOT NULL DEFAULT 'League'
                        CHECK (stage IN ('League', 'Qualifier 1', 'Qualifier 2', 'Eliminator', 'Final',
                                         'Semi Final', 'Elimination Final', '3rd Place Play-Off')),
    team1_id            smallint NOT NULL,
    team2_id            smallint NOT NULL,
    toss_winner_id      smallint NOT NULL,
    toss_decision       varchar(5) NOT NULL CHECK (toss_decision IN ('bat', 'field')),
    result_type         varchar(10) NOT NULL CHECK (result_type IN ('RUNS', 'WICKETS', 'TIE', 'NO_RESULT')),
    winner_id           smallint,             -- for a TIE: the super-over winner
    margin              smallint CHECK (margin > 0),
    method              varchar(5) CHECK (method = 'D/L'),
    player_of_match_id  integer REFERENCES player,
    UNIQUE (season_id, match_no),
    -- BR-2: two different teams, both registered for this season
    CHECK (team1_id <> team2_id),
    FOREIGN KEY (team1_id, season_id)       REFERENCES team_season,
    FOREIGN KEY (team2_id, season_id)       REFERENCES team_season,
    FOREIGN KEY (toss_winner_id, season_id) REFERENCES team_season,
    FOREIGN KEY (winner_id, season_id)      REFERENCES team_season,
    -- BR-3
    CHECK (toss_winner_id IN (team1_id, team2_id)),
    CHECK (winner_id IN (team1_id, team2_id)),
    CHECK ((result_type = 'NO_RESULT') = (winner_id IS NULL)),
    CHECK ((result_type IN ('RUNS', 'WICKETS')) = (margin IS NOT NULL)),
    CHECK (method IS NULL OR result_type <> 'NO_RESULT')
);

CREATE TABLE match_official (
    match_id     integer REFERENCES match ON DELETE CASCADE,
    official_id  integer REFERENCES official ON DELETE RESTRICT,
    role         varchar(10) NOT NULL CHECK (role IN ('UMPIRE', 'TV', 'RESERVE', 'REFEREE')),
    PRIMARY KEY (match_id, official_id)
);

-- Source records that break a rule but are kept, with provenance (data/reference/rule_exceptions.csv).
-- The rule's trigger consults this table; nothing is waived silently.
CREATE TABLE rule_exception (
    match_id   integer REFERENCES match ON DELETE CASCADE,
    rule_code  varchar(5) CHECK (rule_code IN ('BR-5')),
    note       text NOT NULL,
    PRIMARY KEY (match_id, rule_code)
);

-- PLAYS_IN: aggregation [SIGNED_FOR] × MATCH. BR-4/BR-5 are triggers (03).
CREATE TABLE playing_xi (
    match_id    integer REFERENCES match ON DELETE CASCADE,
    player_id   integer REFERENCES player ON DELETE RESTRICT,
    team_id     smallint NOT NULL REFERENCES team,
    entry_type  varchar(10) NOT NULL DEFAULT 'XI' CHECK (entry_type IN ('XI', 'IMPACT', 'CONCUSSION')),
    PRIMARY KEY (match_id, player_id)
);

-- ---------------------------------------------------------------------
-- 5. The weak-entity chain: MATCH ⊃ INNINGS ⊃ DELIVERY ⊃ WICKET
-- ---------------------------------------------------------------------
CREATE TABLE innings (
    match_id         integer REFERENCES match ON DELETE CASCADE,
    innings_no       smallint CHECK (innings_no BETWEEN 1 AND 6),   -- BR-9: 3+ are super overs
    batting_team_id  smallint NOT NULL REFERENCES team,
    -- bowling team is NOT stored: it is the match's other team (would break BCNF, §5.7)
    is_super_over    boolean NOT NULL DEFAULT false,
    target_runs      smallint CHECK (target_runs > 0),        -- stored: DLS targets are not derivable
    target_overs     numeric(3, 1) CHECK (target_overs > 0),
    PRIMARY KEY (match_id, innings_no),
    CHECK (is_super_over = (innings_no > 2))
);

-- Overs the umpires miscounted (recorded by Cricsheet). BR-7 allows exactly this many legal balls.
CREATE TABLE over_miscount (
    match_id     integer,
    innings_no   smallint,
    over_no      smallint CHECK (over_no BETWEEN 1 AND 20),
    legal_balls  smallint NOT NULL CHECK (legal_balls BETWEEN 1 AND 9 AND legal_balls <> 6),
    umpire_id    integer REFERENCES official,
    PRIMARY KEY (match_id, innings_no, over_no),
    FOREIGN KEY (match_id, innings_no) REFERENCES innings ON DELETE CASCADE
);

CREATE TABLE delivery (
    match_id         integer,
    innings_no       smallint,
    over_no          smallint CHECK (over_no BETWEEN 1 AND 20),  -- 1-based, as spoken
    ball_seq         smallint CHECK (ball_seq BETWEEN 1 AND 15), -- position in the over, incl. wides
    batter_id        integer  NOT NULL REFERENCES player ON DELETE RESTRICT,
    non_striker_id   integer  NOT NULL REFERENCES player ON DELETE RESTRICT,
    bowler_id        integer  NOT NULL REFERENCES player ON DELETE RESTRICT,
    runs_batter      smallint NOT NULL DEFAULT 0 CHECK (runs_batter BETWEEN 0 AND 7),
    is_non_boundary  boolean  NOT NULL DEFAULT false,  -- 4 runs that were run, not hit to the rope
    PRIMARY KEY (match_id, innings_no, over_no, ball_seq),
    FOREIGN KEY (match_id, innings_no) REFERENCES innings ON DELETE CASCADE,
    CHECK (batter_id <> non_striker_id),              -- BR-6 (part)
    CHECK (bowler_id NOT IN (batter_id, non_striker_id))
);

-- Extras are a repeating group: one ball can be a no-ball AND byes
CREATE TABLE delivery_extra (
    match_id    integer,
    innings_no  smallint,
    over_no     smallint,
    ball_seq    smallint,
    extra_type  varchar(10) REFERENCES extra_type,
    runs        smallint NOT NULL CHECK (runs BETWEEN 1 AND 7),
    PRIMARY KEY (match_id, innings_no, over_no, ball_seq, extra_type),
    FOREIGN KEY (match_id, innings_no, over_no, ball_seq) REFERENCES delivery ON DELETE CASCADE
);

CREATE TABLE wicket (
    match_id       integer,
    innings_no     smallint,
    over_no        smallint,
    ball_seq       smallint,
    player_out_id  integer REFERENCES player ON DELETE RESTRICT,
    kind           varchar(25) NOT NULL REFERENCES dismissal_kind,
    PRIMARY KEY (match_id, innings_no, over_no, ball_seq, player_out_id),
    FOREIGN KEY (match_id, innings_no, over_no, ball_seq) REFERENCES delivery ON DELETE CASCADE
);

-- Multi-valued attribute WICKET.{fielders}
CREATE TABLE wicket_fielder (
    match_id       integer,
    innings_no     smallint,
    over_no        smallint,
    ball_seq       smallint,
    player_out_id  integer,
    fielder_id     integer REFERENCES player ON DELETE RESTRICT,
    is_substitute  boolean NOT NULL DEFAULT false,
    PRIMARY KEY (match_id, innings_no, over_no, ball_seq, player_out_id, fielder_id),
    FOREIGN KEY (match_id, innings_no, over_no, ball_seq, player_out_id) REFERENCES wicket ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 6. Indexes for the FK columns the analytics join on
-- ---------------------------------------------------------------------
CREATE INDEX ix_delivery_batter  ON delivery (batter_id);
CREATE INDEX ix_delivery_bowler  ON delivery (bowler_id);
CREATE INDEX ix_match_season     ON match (season_id);
CREATE INDEX ix_xi_player        ON playing_xi (player_id);
CREATE INDEX ix_wicket_out       ON wicket (player_out_id);

-- =====================================================================
-- 7. Curated reference data (not in Cricsheet; see 01_design.md §5.0)
-- =====================================================================
INSERT INTO extra_type VALUES
    ('wides',   false, true),
    ('noballs', false, true),
    ('byes',    true,  false),
    ('legbyes', true,  false),
    ('penalty', true,  false);

INSERT INTO dismissal_kind VALUES
    ('caught',                true,  true),
    ('bowled',                true,  true),
    ('lbw',                   true,  true),
    ('caught and bowled',     true,  true),
    ('stumped',               true,  true),
    ('hit wicket',            true,  true),
    ('run out',               false, true),
    ('obstructing the field', false, true),
    ('handled the ball',      false, true),
    ('timed out',             false, true),
    ('retired out',           false, true),
    ('retired hurt',          false, false);

INSERT INTO city (city_name, state, country) VALUES
    ('Mumbai', 'Maharashtra', 'India'), ('Navi Mumbai', 'Maharashtra', 'India'), ('Pune', 'Maharashtra', 'India'),
    ('Nagpur', 'Maharashtra', 'India'), ('Kolkata', 'West Bengal', 'India'), ('Delhi', 'Delhi', 'India'),
    ('Chennai', 'Tamil Nadu', 'India'), ('Hyderabad', 'Telangana', 'India'), ('Jaipur', 'Rajasthan', 'India'),
    ('Bengaluru', 'Karnataka', 'India'), ('Mohali', 'Punjab', 'India'), ('Mullanpur', 'Punjab', 'India'),
    ('Ahmedabad', 'Gujarat', 'India'), ('Rajkot', 'Gujarat', 'India'), ('Lucknow', 'Uttar Pradesh', 'India'),
    ('Kanpur', 'Uttar Pradesh', 'India'), ('Dharamsala', 'Himachal Pradesh', 'India'),
    ('Visakhapatnam', 'Andhra Pradesh', 'India'), ('Indore', 'Madhya Pradesh', 'India'),
    ('Guwahati', 'Assam', 'India'), ('Raipur', 'Chhattisgarh', 'India'), ('Cuttack', 'Odisha', 'India'),
    ('Ranchi', 'Jharkhand', 'India'), ('Kochi', 'Kerala', 'India'),
    ('Dubai', NULL, 'UAE'), ('Abu Dhabi', NULL, 'UAE'), ('Sharjah', NULL, 'UAE'),
    ('Durban', 'KwaZulu-Natal', 'South Africa'), ('Centurion', 'Gauteng', 'South Africa'),
    ('Johannesburg', 'Gauteng', 'South Africa'), ('Cape Town', 'Western Cape', 'South Africa'),
    ('Port Elizabeth', 'Eastern Cape', 'South Africa'), ('East London', 'Eastern Cape', 'South Africa'),
    ('Kimberley', 'Northern Cape', 'South Africa'), ('Bloemfontein', 'Free State', 'South Africa');

INSERT INTO venue (venue_name, city_id)
SELECT v.name, c.city_id
FROM (VALUES
    ('Eden Gardens', 'Kolkata'),
    ('Wankhede Stadium', 'Mumbai'),
    ('Brabourne Stadium', 'Mumbai'),
    ('Dr DY Patil Sports Academy', 'Navi Mumbai'),
    ('M Chinnaswamy Stadium', 'Bengaluru'),
    ('Arun Jaitley Stadium', 'Delhi'),
    ('Rajiv Gandhi International Stadium', 'Hyderabad'),
    ('MA Chidambaram Stadium', 'Chennai'),
    ('Sawai Mansingh Stadium', 'Jaipur'),
    ('Narendra Modi Stadium', 'Ahmedabad'),
    ('Punjab Cricket Association IS Bindra Stadium', 'Mohali'),
    ('Maharaja Yadavindra Singh International Cricket Stadium', 'Mullanpur'),
    ('Maharashtra Cricket Association Stadium', 'Pune'),
    ('Ekana Cricket Stadium', 'Lucknow'),
    ('Saurashtra Cricket Association Stadium', 'Rajkot'),
    ('Himachal Pradesh Cricket Association Stadium', 'Dharamsala'),
    ('Dr. Y.S. Rajasekhara Reddy ACA-VDCA Cricket Stadium', 'Visakhapatnam'),
    ('Holkar Cricket Stadium', 'Indore'),
    ('Barsapara Cricket Stadium', 'Guwahati'),
    ('Shaheed Veer Narayan Singh International Stadium', 'Raipur'),
    ('Barabati Stadium', 'Cuttack'),
    ('JSCA International Stadium Complex', 'Ranchi'),
    ('Nehru Stadium', 'Kochi'),
    ('Green Park', 'Kanpur'),
    ('Vidarbha Cricket Association Stadium, Jamtha', 'Nagpur'),
    ('Dubai International Cricket Stadium', 'Dubai'),
    ('Zayed Cricket Stadium', 'Abu Dhabi'),
    ('Sharjah Cricket Stadium', 'Sharjah'),
    ('Kingsmead', 'Durban'),
    ('SuperSport Park', 'Centurion'),
    ('New Wanderers Stadium', 'Johannesburg'),
    ('Newlands', 'Cape Town'),
    ('St George''s Park', 'Port Elizabeth'),
    ('Buffalo Park', 'East London'),
    ('De Beers Diamond Oval', 'Kimberley'),
    ('OUTsurance Oval', 'Bloemfontein')
) AS v(name, city) JOIN city c ON c.city_name = v.city;

INSERT INTO venue_alias (alias, venue_id)
SELECT a.alias, v.venue_id
FROM (VALUES
    ('Eden Gardens', 'Eden Gardens'), ('Eden Gardens, Kolkata', 'Eden Gardens'),
    ('Wankhede Stadium', 'Wankhede Stadium'), ('Wankhede Stadium, Mumbai', 'Wankhede Stadium'),
    ('Brabourne Stadium', 'Brabourne Stadium'), ('Brabourne Stadium, Mumbai', 'Brabourne Stadium'),
    ('Dr DY Patil Sports Academy', 'Dr DY Patil Sports Academy'),
    ('Dr DY Patil Sports Academy, Mumbai', 'Dr DY Patil Sports Academy'),
    ('M Chinnaswamy Stadium', 'M Chinnaswamy Stadium'), ('M.Chinnaswamy Stadium', 'M Chinnaswamy Stadium'),
    ('M Chinnaswamy Stadium, Bengaluru', 'M Chinnaswamy Stadium'),
    ('Feroz Shah Kotla', 'Arun Jaitley Stadium'),               -- renamed 2019
    ('Arun Jaitley Stadium', 'Arun Jaitley Stadium'), ('Arun Jaitley Stadium, Delhi', 'Arun Jaitley Stadium'),
    ('Rajiv Gandhi International Stadium', 'Rajiv Gandhi International Stadium'),
    ('Rajiv Gandhi International Stadium, Uppal', 'Rajiv Gandhi International Stadium'),
    ('Rajiv Gandhi International Stadium, Uppal, Hyderabad', 'Rajiv Gandhi International Stadium'),
    ('MA Chidambaram Stadium', 'MA Chidambaram Stadium'),
    ('MA Chidambaram Stadium, Chepauk', 'MA Chidambaram Stadium'),
    ('MA Chidambaram Stadium, Chepauk, Chennai', 'MA Chidambaram Stadium'),
    ('Sawai Mansingh Stadium', 'Sawai Mansingh Stadium'), ('Sawai Mansingh Stadium, Jaipur', 'Sawai Mansingh Stadium'),
    ('Sardar Patel Stadium, Motera', 'Narendra Modi Stadium'),  -- rebuilt and renamed 2021
    ('Narendra Modi Stadium, Ahmedabad', 'Narendra Modi Stadium'),
    ('Punjab Cricket Association Stadium, Mohali', 'Punjab Cricket Association IS Bindra Stadium'),
    ('Punjab Cricket Association IS Bindra Stadium', 'Punjab Cricket Association IS Bindra Stadium'),
    ('Punjab Cricket Association IS Bindra Stadium, Mohali', 'Punjab Cricket Association IS Bindra Stadium'),
    ('Punjab Cricket Association IS Bindra Stadium, Mohali, Chandigarh', 'Punjab Cricket Association IS Bindra Stadium'),
    ('Maharaja Yadavindra Singh International Cricket Stadium, Mullanpur', 'Maharaja Yadavindra Singh International Cricket Stadium'),
    ('Maharaja Yadavindra Singh International Cricket Stadium, New Chandigarh', 'Maharaja Yadavindra Singh International Cricket Stadium'),
    ('Subrata Roy Sahara Stadium', 'Maharashtra Cricket Association Stadium'),  -- same ground, earlier name
    ('Maharashtra Cricket Association Stadium', 'Maharashtra Cricket Association Stadium'),
    ('Maharashtra Cricket Association Stadium, Pune', 'Maharashtra Cricket Association Stadium'),
    ('Bharat Ratna Shri Atal Bihari Vajpayee Ekana Cricket Stadium, Lucknow', 'Ekana Cricket Stadium'),
    ('Saurashtra Cricket Association Stadium', 'Saurashtra Cricket Association Stadium'),
    ('Himachal Pradesh Cricket Association Stadium', 'Himachal Pradesh Cricket Association Stadium'),
    ('Himachal Pradesh Cricket Association Stadium, Dharamsala', 'Himachal Pradesh Cricket Association Stadium'),
    ('Dr. Y.S. Rajasekhara Reddy ACA-VDCA Cricket Stadium', 'Dr. Y.S. Rajasekhara Reddy ACA-VDCA Cricket Stadium'),
    ('Dr. Y.S. Rajasekhara Reddy ACA-VDCA Cricket Stadium, Visakhapatnam', 'Dr. Y.S. Rajasekhara Reddy ACA-VDCA Cricket Stadium'),
    ('Holkar Cricket Stadium', 'Holkar Cricket Stadium'),
    ('Barsapara Cricket Stadium, Guwahati', 'Barsapara Cricket Stadium'),
    ('Shaheed Veer Narayan Singh International Stadium', 'Shaheed Veer Narayan Singh International Stadium'),
    ('Shaheed Veer Narayan Singh International Stadium, Raipur', 'Shaheed Veer Narayan Singh International Stadium'),
    ('Barabati Stadium', 'Barabati Stadium'),
    ('JSCA International Stadium Complex', 'JSCA International Stadium Complex'),
    ('Nehru Stadium', 'Nehru Stadium'),
    ('Green Park', 'Green Park'),
    ('Vidarbha Cricket Association Stadium, Jamtha', 'Vidarbha Cricket Association Stadium, Jamtha'),
    ('Dubai International Cricket Stadium', 'Dubai International Cricket Stadium'),
    ('Sheikh Zayed Stadium', 'Zayed Cricket Stadium'), ('Zayed Cricket Stadium, Abu Dhabi', 'Zayed Cricket Stadium'),
    ('Sharjah Cricket Stadium', 'Sharjah Cricket Stadium'),
    ('Kingsmead', 'Kingsmead'), ('SuperSport Park', 'SuperSport Park'),
    ('New Wanderers Stadium', 'New Wanderers Stadium'), ('Newlands', 'Newlands'),
    ('St George''s Park', 'St George''s Park'), ('Buffalo Park', 'Buffalo Park'),
    ('De Beers Diamond Oval', 'De Beers Diamond Oval'), ('OUTsurance Oval', 'OUTsurance Oval')
) AS a(alias, venue) JOIN venue v ON v.venue_name = a.venue;

INSERT INTO franchise (franchise_code, home_city_id)
SELECT f.code, c.city_id
FROM (VALUES
    ('MI', 'Mumbai'), ('KKR', 'Kolkata'), ('CSK', 'Chennai'), ('RR', 'Jaipur'), ('RCB', 'Bengaluru'),
    ('SRH', 'Hyderabad'), ('PBKS', 'Mohali'), ('DC', 'Delhi'), ('GT', 'Ahmedabad'), ('LSG', 'Lucknow'),
    ('DCH', 'Hyderabad'), ('KTK', 'Kochi'), ('PWI', 'Pune'), ('RPS', 'Pune'), ('GL', 'Rajkot')
) AS f(code, city) JOIN city c ON c.city_name = f.city;

INSERT INTO team (team_name, short_name, franchise_id)
SELECT t.name, t.short, f.franchise_id
FROM (VALUES
    ('Mumbai Indians', 'MI', 'MI'), ('Kolkata Knight Riders', 'KKR', 'KKR'),
    ('Chennai Super Kings', 'CSK', 'CSK'), ('Rajasthan Royals', 'RR', 'RR'),
    ('Royal Challengers Bangalore', 'RCB', 'RCB'), ('Royal Challengers Bengaluru', 'RCB', 'RCB'),  -- renamed 2024
    ('Sunrisers Hyderabad', 'SRH', 'SRH'),
    ('Kings XI Punjab', 'KXIP', 'PBKS'), ('Punjab Kings', 'PBKS', 'PBKS'),                         -- renamed 2021
    ('Delhi Daredevils', 'DD', 'DC'), ('Delhi Capitals', 'DC', 'DC'),                              -- renamed 2019
    ('Gujarat Titans', 'GT', 'GT'), ('Lucknow Super Giants', 'LSG', 'LSG'),
    ('Deccan Chargers', 'DCH', 'DCH'), ('Kochi Tuskers Kerala', 'KTK', 'KTK'),
    ('Pune Warriors', 'PWI', 'PWI'),
    ('Rising Pune Supergiants', 'RPS', 'RPS'), ('Rising Pune Supergiant', 'RPS', 'RPS'),           -- renamed 2017
    ('Gujarat Lions', 'GL', 'GL')
) AS t(name, short, code) JOIN franchise f ON f.franchise_code = t.code;
