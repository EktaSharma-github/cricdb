"""Load Cricsheet IPL JSON into the normalized CricDB schema.

Each match is loaded in its own transaction, through every trigger in
03_logic.sql, so a match that breaks a rule of the game is rolled back
whole and reported (atomicity, demonstrated on real data).

Usage:  .venv\\Scripts\\python 04_load.py [data\\raw\\ipl_json] [--limit N]
Connection: PGHOST / PGUSER / PGPASSWORD / PGDATABASE (defaults: localhost, postgres, postgres, cricdb)
"""
import csv
import glob
import json
import os
import sys
import time

import psycopg

STAGES = {None: "League"}
ENTRY_TYPE = {"impact_player": "IMPACT", "concussion_substitute": "CONCUSSION"}
OFFICIAL_ROLES = {"umpires": "UMPIRE", "tv_umpires": "TV", "reserve_umpires": "RESERVE", "match_referees": "REFEREE"}


def connect():
    return psycopg.connect(
        host=os.environ.get("PGHOST", "localhost"),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", "postgres"),
        dbname=os.environ.get("PGDATABASE", "cricdb"),
        options="-c search_path=cricdb",
    )


def lookups(cur):
    cur.execute("SELECT team_name, team_id FROM team")
    teams = dict(cur.fetchall())
    cur.execute("SELECT alias, venue_id FROM venue_alias")
    venues = dict(cur.fetchall())
    return teams, venues


def ensure_people(cur, registry, players, officials):
    """Upsert every person in the match registry; return name → person_id."""
    cur.executemany(
        "INSERT INTO person (cricsheet_id, known_as) VALUES (%s, %s) "
        "ON CONFLICT (cricsheet_id) DO UPDATE SET known_as = EXCLUDED.known_as",
        [(pid, name) for name, pid in registry.items()])
    cur.execute("SELECT cricsheet_id, person_id FROM person WHERE cricsheet_id = ANY(%s)",
                (list(registry.values()),))
    by_cid = dict(cur.fetchall())
    ids = {name: by_cid[cid] for name, cid in registry.items()}
    cur.executemany("INSERT INTO player VALUES (%s) ON CONFLICT DO NOTHING", [(ids[n],) for n in players])
    cur.executemany("INSERT INTO official VALUES (%s) ON CONFLICT DO NOTHING", [(ids[n],) for n in officials])
    return ids


def read_exceptions():
    """Known rule-breaking source records, kept with provenance: match_id → [(rule, note)]."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "reference", "rule_exceptions.csv")
    out = {}
    with open(path, encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            out.setdefault(int(row["match_id"]), []).append((row["rule_code"], row["note"]))
    return out


def load_match(cur, match_id, m, teams, venues, exceptions):
    info = m["info"]
    year = int(info["dates"][0][:4])
    cur.execute("INSERT INTO season VALUES (%s, %s) ON CONFLICT DO NOTHING", (year, str(info["season"])))

    t1, t2 = (teams[t] for t in info["teams"])
    team_of = {name: teams[name] for name in info["teams"]}
    for t in (t1, t2):
        cur.execute("INSERT INTO team_season VALUES (%s, %s) ON CONFLICT DO NOTHING", (t, year))

    # Everyone who takes the field is a PLAYER; substitute fielders appear only in wickets
    players = {p for ps in info["players"].values() for p in ps}
    for inn in m["innings"]:
        for ov in inn["overs"]:
            for b in ov["deliveries"]:
                for w in b.get("wickets", []):
                    players.update(f["name"] for f in w.get("fielders", []) if "name" in f)
    players.update(info.get("player_of_match", []))
    officials = {o for key in OFFICIAL_ROLES for o in info.get("officials", {}).get(key, [])}
    ids = ensure_people(cur, info["registry"]["people"], players, officials)

    o = info["outcome"]
    if o.get("result") == "no result":
        result, winner, margin = "NO_RESULT", None, None
    elif o.get("result") == "tie":
        result, winner, margin = "TIE", team_of[o["eliminator"]], None
    else:
        (kind, margin), = o["by"].items()
        result, winner = kind.upper(), team_of[o["winner"]]
    pom = info.get("player_of_match", [])
    cur.execute(
        "INSERT INTO match (match_id, season_id, match_no, match_date, venue_id, stage, team1_id, team2_id, "
        "toss_winner_id, toss_decision, result_type, winner_id, margin, method, player_of_match_id) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
        (match_id, year, info["event"].get("match_number"), info["dates"][0], venues[info["venue"]],
         info["event"].get("stage", "League"), t1, t2, team_of[info["toss"]["winner"]], info["toss"]["decision"],
         result, winner, margin, o.get("method"), ids[pom[0]] if pom else None))

    cur.executemany("INSERT INTO match_official VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
                    [(match_id, ids[n], role) for key, role in OFFICIAL_ROLES.items()
                     for n in info.get("officials", {}).get(key, [])])

    cur.executemany("INSERT INTO rule_exception VALUES (%s, %s, %s)",
                    [(match_id, rule, note) for rule, note in exceptions.get(match_id, [])])

    # Squad = who played for whom that season (Cricsheet has no non-playing squad members)
    entry = {}
    for inn in m["innings"]:
        for ov in inn["overs"]:
            for b in ov["deliveries"]:
                for r in b.get("replacements", {}).get("match", []):
                    if r.get("reason") in ENTRY_TYPE:
                        entry[r["in"]] = ENTRY_TYPE[r["reason"]]
    for team_name, ps in info["players"].items():
        cur.executemany("INSERT INTO squad (player_id, season_id, team_id) VALUES (%s, %s, %s) "
                        "ON CONFLICT DO NOTHING", [(ids[p], year, team_of[team_name]) for p in ps])
        cur.executemany("INSERT INTO playing_xi VALUES (%s, %s, %s, %s)",
                        [(match_id, ids[p], team_of[team_name], entry.get(p, "XI")) for p in ps])

    deliveries, extras, wickets, fielders = [], [], [], []
    for n, inn in enumerate(m["innings"], start=1):
        target = inn.get("target", {})
        cur.execute("INSERT INTO innings VALUES (%s, %s, %s, %s, %s, %s)",
                    (match_id, n, team_of[inn["team"]], inn.get("super_over", False),
                     target.get("runs"), target.get("overs")))
        for over, mc in inn.get("miscounted_overs", {}).items():
            cur.execute("INSERT INTO over_miscount VALUES (%s, %s, %s, %s, %s)",
                        (match_id, n, int(over) + 1, mc["balls"], ids.get(mc.get("umpire"))))
        for ov in inn["overs"]:
            over_no = ov["over"] + 1
            for seq, b in enumerate(ov["deliveries"], start=1):
                key = (match_id, n, over_no, seq)
                deliveries.append(key + (ids[b["batter"]], ids[b["non_striker"]], ids[b["bowler"]],
                                         b["runs"]["batter"], b["runs"].get("non_boundary", False)))
                extras += [key + (t, r) for t, r in b.get("extras", {}).items()]
                for w in b.get("wickets", []):
                    out = ids[w["player_out"]]
                    wickets.append(key + (out, w["kind"]))
                    fielders += [key + (out, ids[f["name"]], f.get("substitute", False))
                                 for f in w.get("fielders", []) if "name" in f]
    cur.executemany("INSERT INTO delivery VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)", deliveries)
    cur.executemany("INSERT INTO delivery_extra VALUES (%s,%s,%s,%s,%s,%s)", extras)
    cur.executemany("INSERT INTO wicket VALUES (%s,%s,%s,%s,%s,%s)", wickets)
    cur.executemany("INSERT INTO wicket_fielder VALUES (%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING", fielders)
    return len(deliveries)


def main():
    args, limit = sys.argv[1:], None
    if "--limit" in args:
        i = args.index("--limit")
        limit = int(args[i + 1])
        del args[i:i + 2]
    src = args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "raw", "ipl_json")

    # Oldest first, so a renamed player's latest name wins the upsert
    files = []
    for f in glob.glob(os.path.join(src, "*.json")):
        m = json.load(open(f, encoding="utf-8"))
        files.append((m["info"]["dates"][0], int(os.path.basename(f)[:-5]), m))
    files.sort(key=lambda x: (x[0], x[1]))
    files = files[:limit]

    start, balls, failed = time.time(), 0, []
    with connect() as conn:
        with conn.cursor() as cur:
            teams, venues = lookups(cur)
        conn.commit()
        exceptions = read_exceptions()
        for i, (_, match_id, m) in enumerate(files, start=1):
            try:
                with conn.transaction():          # one match = one transaction; BR-7 fires at its commit
                    with conn.cursor() as cur:
                        n = load_match(cur, match_id, m, teams, venues, exceptions)
                balls += n                        # only counted once the commit (and BR-7) succeeded
            except (psycopg.Error, KeyError) as e:
                failed.append((match_id, f"{type(e).__name__}: {e}".splitlines()[0]))
            if i % 100 == 0:
                print(f"  {i}/{len(files)} matches, {balls:,} balls, {time.time() - start:.0f}s", flush=True)

    print(f"Loaded {len(files) - len(failed)}/{len(files)} matches, {balls:,} balls in {time.time() - start:.0f}s")
    for match_id, err in failed:
        print(f"  REJECTED {match_id}: {err}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
