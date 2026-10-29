"""Builds cricdb_kmeans.ipynb from the cells below.

Run:  .venv\\Scripts\\python analytics\\build_notebook.py
then: .venv\\Scripts\\jupyter nbconvert --to notebook --execute --inplace analytics\\cricdb_kmeans.ipynb
"""
from pathlib import Path

import nbformat as nbf

HERE = Path(__file__).parent
cells = []


def md(text):
    cells.append(nbf.v4.new_markdown_cell(text.strip()))


def code(text):
    cells.append(nbf.v4.new_code_cell(text.strip()))


md("""
# CricDB Analytics: How T20 Batting and Bowling Styles Sort Themselves

**FDS course project (CricDB).** The database holds every IPL ball from 2008 to 2026
(295,732 deliveries in 23 BCNF tables, loaded from Cricsheet through triggers that enforce
the laws of the game). This notebook asks two questions of that data:

> 1. **How has the game changed?** Scoring, the toss, phases of the innings, home advantage.
> 2. **What playing styles exist today, and do winning teams use a different mix of them?**

**Workflow**

1. **SQL first.** Descriptive statistics run *inside PostgreSQL* (`07_analytics.sql`, A1–A5).
   Only aggregates leave the database.
2. **Statistical tests** on those aggregates: χ², binomial and Welch's t-test.
3. **Feature engineering in SQL.** `v_batter_features` and `v_bowler_features` turn
   ball-by-ball rows into one row per player for 2022–2026.
4. **k-means** on standardized features; *k* chosen by elbow, silhouette and interpretability.
5. **Write back** the labels to the BCNF tables `segment` / `player_segment`, then answer
   S1–S2 in SQL.

*Data: Cricsheet (cricsheet.org), Open Data Commons Attribution License.*
""")

md("""
## 0. Setup

Reads use the role **`cricdb_readonly`** (SELECT only). Only the write-back in §4 connects as
the owner: least privilege. `run_sql()` runs one labelled query from `07_analytics.sql`, so
the SQL on the slides and the SQL executed here are the same text.
""")

code(r'''
import os
import re
import warnings

os.environ.setdefault("LOKY_MAX_CPU_COUNT", "4")   # stops joblib probing the CPU count on Windows
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from scipy import stats
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.metrics import silhouette_score
from sklearn.preprocessing import StandardScaler
from sqlalchemy import create_engine, text

warnings.filterwarnings("ignore", category=UserWarning)
pd.set_option("display.width", 140)

OPTS = {"options": "-c search_path=cricdb,public"}
reader = create_engine("postgresql+psycopg://cricdb_readonly:cricdb_readonly@localhost/cricdb", connect_args=OPTS)
writer = create_engine("postgresql+psycopg://postgres:postgres@localhost/cricdb", connect_args=OPTS)

ROOT = Path.cwd() if (Path.cwd() / "07_analytics.sql").exists() else Path.cwd().parent
SQL_FILE = ROOT / "07_analytics.sql"
FIG = ROOT / "analytics" / "figures"
FIG.mkdir(parents=True, exist_ok=True)

# A labelled query in 07_analytics.sql is a "-- A1. TITLE" header block,
# closed by a "-- ====" line, followed by one statement ending in ";".
_QUERY = re.compile(r"^-- ([AS]\d)\. ([^\n]*)\n.*?^-- =+\n\n(.*?;)\s*$", re.M | re.S)
QUERIES = {m[1]: (m[2].strip(), m[3]) for m in _QUERY.finditer(SQL_FILE.read_text(encoding="utf-8"))}

def run_sql(label):
    title, sql = QUERIES[label]
    print(f"{label}. {title}")
    return query(sql)

def query(sql, **params):
    with reader.connect() as c:
        return pd.read_sql(text(sql), c, params=params)

print("Queries found:", ", ".join(QUERIES))
''')

code(r'''
# Chart style: one recessive grid, thin marks, text in ink colours (never series colours).
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
BLUE, ORANGE, AQUA, YELLOW, RED, MID = "#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e34948", "#f0efec"
PALETTE = [BLUE, ORANGE, AQUA, YELLOW, RED]
plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "axes.titlecolor": INK,
    "axes.titleweight": "bold", "axes.titlesize": 12, "axes.titlelocation": "left",
    "xtick.color": INK2, "ytick.color": INK2, "text.color": INK,
    "axes.grid": True, "axes.axisbelow": True, "grid.color": GRID, "grid.linewidth": 0.8,
    "axes.spines.top": False, "axes.spines.right": False,
    "font.size": 10, "figure.dpi": 110,
})

def save(fig, name):
    fig.savefig(FIG / f"{name}.png", dpi=200, bbox_inches="tight")
''')

md("""
## 1. How has the game changed? (SQL statistics)

### A1. First-innings scores per season
""")

code('a1 = run_sql("A1"); a1')

code(r'''
fig, ax = plt.subplots(figsize=(7.2, 3.6))
ax.bar(a1["season_id"], a1["totals_200_plus"], color=MID, edgecolor=GRID, label="200+ totals (right axis)")
ax.set_ylabel("200+ first-innings totals"); ax.grid(axis="x", visible=False)
ax.set_xticks(range(2008, 2027, 2))
ax2 = ax.twinx()
ax2.plot(a1["season_id"], a1["mean_runs"], color=BLUE, marker="o", lw=2, label="Mean first-innings score")
ax2.set_ylabel("Mean first-innings score"); ax2.grid(False); ax2.spines["right"].set_visible(True)
ax2.axvline(2022.5, color=INK2, ls="--", lw=1)
ax2.annotate("Impact Player rule", (2022.6, a1["mean_runs"].min() + 2), color=INK2, fontsize=9)
ax.set_title("Scoring has inflated, and sharply since the Impact Player rule")
ax.yaxis.tick_right(); ax.yaxis.set_label_position("right"); ax2.yaxis.tick_left(); ax2.yaxis.set_label_position("left")
save(fig, "01_scoring_inflation"); plt.show()
''')

md("""
Is the jump after 2022 real, or season-to-season noise? Welch's t-test compares the
individual first-innings totals of 2018–22 with 2023–26 (unequal variances: the SD in A1 rose
from about 29 to about 37).
""")

code(r'''
totals = query("""
    SELECT era(m.season_id) AS era, s.runs
    FROM v_innings_score s JOIN match m USING (match_id)
    WHERE s.innings_no = 1 AND m.method IS NULL AND m.result_type <> 'NO_RESULT'
      AND m.season_id >= 2018""")
before = totals.loc[totals.era == "2018-22", "runs"]
after = totals.loc[totals.era != "2018-22", "runs"]
t, p = stats.ttest_ind(after, before, equal_var=False)
print(f"2018-22: mean {before.mean():.1f} (n={len(before)})   2023-26: mean {after.mean():.1f} (n={len(after)})")
print(f"Welch t = {t:.2f}, p = {p:.1e}   ->   difference = {after.mean() - before.mean():.1f} runs")
''')

md("""
### A2. Does winning the toss help?
""")

code('a2 = run_sql("A2"); a2')

code(r'''
tot = a2.groupby("toss_decision")[["matches", "toss_winner_won"]].sum()
table = np.column_stack([tot["toss_winner_won"], tot["matches"] - tot["toss_winner_won"]])
chi2, p_dec, _, _ = stats.chi2_contingency(table)
won, n = tot["toss_winner_won"].sum(), tot["matches"].sum()
p_toss = stats.binomtest(int(won), int(n), 0.5).pvalue
print(tot.assign(win_pct=(100 * tot.toss_winner_won / tot.matches).round(1)))
print(f"\nToss winner wins {100 * won / n:.1f}% of {n} matches; binomial test vs 50%: p = {p_toss:.3f}")
print(f"Does the decision matter? chi2 = {chi2:.2f}, p = {p_dec:.3f}")
''')

md("""
### A3. Run rate by phase and era (GROUP BY ROLLUP)
""")

code('a3 = run_sql("A3"); a3')

code(r'''
phases = ["Powerplay", "Middle", "Death"]
eras = [e for e in a3["era"].unique() if e != "All eras"]
d = a3[a3.phase.isin(phases) & a3.era.isin(eras)].pivot(index="phase", columns="era", values="run_rate").loc[phases]
fig, ax = plt.subplots(figsize=(7.2, 3.4))
w = 0.2
for i, era in enumerate(eras):
    bars = ax.bar(np.arange(3) + (i - 1.5) * w, d[era], w, label=era, color=PALETTE[i], edgecolor=SURFACE)
ax.set_xticks(range(3), phases); ax.set_ylabel("Runs per over"); ax.set_ylim(6, 11.5)
ax.grid(axis="x", visible=False); ax.legend(frameon=False, ncol=4, fontsize=8, loc="upper left")
ax.set_title("The powerplay changed most: +2 runs an over since 2008-12")
save(fig, "02_phase_run_rate"); plt.show()
''')

md("""
### A4. Home advantage, and A5. the strike-rate distribution
""")

code(r'''
a4 = run_sql("A4"); display(a4)
allrow = a4[a4.franchise == "ALL"].iloc[0]
p_home = stats.binomtest(int(allrow.home_wins), int(allrow.home_matches), 0.5).pvalue
print(f"Home teams win {allrow.home_win_pct}% of {allrow.home_matches}; binomial test vs 50%: p = {p_home:.3f}")
''')

code('a5 = run_sql("A5"); a5')

md("""
**Reading §1.**
* **Scoring (A1):** Up to 2022 the mean first-innings score drifted from about 155 to about 170.
  It has then jumped to 183–195. Welch's test puts that jump far beyond noise. 200+ totals went
  from 4–13 a season to 37 in 2026.
* **Phases (A3):** The powerplay changed the most. In 2023–26 teams score faster in the first
  six overs (9.5) than they used to at the death in 2008–12 (9.4).
* **Toss (A2):** Winning the toss alone is worth nothing measurable: toss winners win 51.4%
  (binomial p = 0.35). **What they choose does matter:** after choosing to field they win
  54.4%, after choosing to bat 45.4% (χ² p = 0.004). Captains have learned this: fielding first
  went from half of all decisions in 2008–12 to about 3 in 4 since 2018. (Observational data:
  captains may bat first exactly when conditions make it a worse choice.)
* **Home (A4):** Home sides win 53.5% of 798 matches, which is borderline (p = 0.051). The
  average hides a spread: CSK (65.5%) and SRH (62.3%) are strong at home, while DC (43.0%)
  and LSG (40.7%) win less than half there.
* **Strike rates (A5):** Among regular batters (≥ 300 balls since 2022), a third strike at
  140–150. Only two are above 190.
""")

md("""
## 2. Batting styles (k-means)

### 2.1 Features, built in SQL

`v_batter_features` turns ball-by-ball rows into one row per batter (2022–2026, ≥ 300 balls
faced). Each feature describes *how* a batter scores, not just how much:

| Feature | Meaning |
|---|---|
| strike_rate | runs per 100 balls faced |
| average | runs per dismissal (divides by 1 if never out) |
| boundary_pct | % of balls faced hit for 4 or 6 |
| dot_pct | % of balls faced that produced no run |
| death_share | % of balls faced in overs 16–20 |
| avg_entry_over | average over in which the batter came to the crease (1 = opener) |
""")

code(r'''
BAT_FEATURES = ["strike_rate", "average", "boundary_pct", "dot_pct", "death_share", "avg_entry_over"]
bat = query("""SELECT f.*, p.known_as FROM v_batter_features f
               JOIN person p ON p.person_id = f.player_id""")
bat[BAT_FEATURES] = bat[BAT_FEATURES].astype(float)
print(len(bat), "batters"); bat[BAT_FEATURES].describe().T.round(1)
''')

code(r'''
corr = bat[BAT_FEATURES].corr()
fig, ax = plt.subplots(figsize=(5.4, 4.4))
im = ax.imshow(corr, cmap="RdBu_r", vmin=-1, vmax=1)
ax.set_xticks(range(6), BAT_FEATURES, rotation=40, ha="right"); ax.set_yticks(range(6), BAT_FEATURES)
for i in range(6):
    for j in range(6):
        ax.text(j, i, f"{corr.iloc[i, j]:.2f}", ha="center", va="center", fontsize=8,
                color="white" if abs(corr.iloc[i, j]) > 0.6 else INK)
ax.grid(False); ax.set_title("Batting features: correlations")
fig.colorbar(im, ax=ax, shrink=0.8); save(fig, "03_bat_correlation"); plt.show()
''')

md("""
Strike rate and boundary % are strongly correlated (most fast scoring is boundaries), and so
are entry over and death share (late arrivals bat at the death). We keep both of each pair:
the second one adds a distinct shade (dot-ball rate; how much of the innings is spent at
the death). All features are **standardized** (z-scores) first, so no feature dominates
the distances just because of its units.

### 2.2 Choosing k
""")

code(r'''
def choose_k(X, ks=range(2, 9)):
    rows = []
    for k in ks:
        km = KMeans(n_clusters=k, n_init=50, random_state=42).fit(X)
        rows.append((k, km.inertia_, silhouette_score(X, km.labels_)))
    return pd.DataFrame(rows, columns=["k", "inertia", "silhouette"])

def plot_k(res, ax, title, chosen):
    ax.plot(res.k, res.inertia, color=BLUE, marker="o", lw=2); ax.set_xlabel("k"); ax.set_ylabel("Inertia (within-cluster SS)")
    ax2 = ax.twinx(); ax2.plot(res.k, res.silhouette, color=ORANGE, marker="s", lw=2)
    ax2.set_ylabel("Silhouette"); ax2.grid(False); ax2.spines["right"].set_visible(True)
    ax.axvline(chosen, color=INK2, ls="--", lw=1); ax.set_title(title)

Xb = StandardScaler().fit_transform(bat[BAT_FEATURES])
kb = choose_k(Xb); kb.round(3)
''')

md("""
Silhouette is highest at k = 2, but only slightly (0.27 against 0.26 at k = 4): no k
separates the batters much more cleanly than another. Two clusters would only say "openers
vs the rest". The elbow flattens after k = 4, and four clusters each have a clear cricket
meaning. **We choose k = 4** and validate that choice in §2.4 with a variable the model never
saw.
""")

code(r'''
K_BAT = 4
km_bat = KMeans(n_clusters=K_BAT, n_init=50, random_state=42).fit(Xb)
bat["cluster"] = km_bat.labels_
bat["distance"] = np.linalg.norm(Xb - km_bat.cluster_centers_[km_bat.labels_], axis=1)
centroids = bat.groupby("cluster")[BAT_FEATURES].mean()

# Name clusters by rules on the centroids, not by k-means' arbitrary label numbers
names, left = {}, set(centroids.index)
def take(rule_col, how, name):
    c = (centroids.loc[sorted(left), rule_col].idxmax() if how == "max"
         else centroids.loc[sorted(left), rule_col].idxmin())
    names[c] = name; left.discard(c)
take("avg_entry_over", "max", "Finishers")
take("strike_rate", "max", "Powerplay Blasters")
take("average", "max", "Elite Accumulators")
take("average", "min", "Steady Top Order")
bat["segment"] = bat["cluster"].map(names)

BAT_DESC = {
    "Powerplay Blasters": "Openers who attack from ball one: the highest strike rate and boundary %, more dots accepted.",
    "Elite Accumulators": "Top-order run-makers: the highest average (about 42) with a strike rate above par.",
    "Steady Top Order": "Top-order batters who score below today's par (SR about 141) with a lower average: the role most at risk as scoring rises.",
    "Finishers": "Middle and lower order: arrive around over 12 and face over 40% of their balls at the death.",
}
profile = bat.groupby("segment")[BAT_FEATURES].mean().round(1).assign(players=bat.groupby("segment").size())
profile
''')

code(r'''
for seg, g in bat.sort_values("distance").groupby("segment"):
    print(f"{seg:20s} {', '.join(g.known_as.head(8))}")
''')

code(r'''
fig, axes = plt.subplots(1, 2, figsize=(10.5, 3.6))
plot_k(kb, axes[0], "Batters: k = 4", K_BAT)
pca = PCA(2).fit(Xb); P = pca.transform(Xb)
ax = axes[1]
for i, seg in enumerate(BAT_DESC):
    m = bat.segment == seg
    ax.scatter(P[m, 0], P[m, 1], s=28, color=PALETTE[i], label=seg, edgecolor=SURFACE, lw=0.5)
for _, r in bat.loc[bat.groupby("segment")["distance"].idxmin()].iterrows():
    j = r.name; ax.annotate(r.known_as, P[j], xytext=(4, 4), textcoords="offset points", fontsize=8, color=INK)
ax.set_xlabel(f"PC1 ({pca.explained_variance_ratio_[0]:.0%} of variance)")
ax.set_ylabel(f"PC2 ({pca.explained_variance_ratio_[1]:.0%})")
ax.legend(frameon=False, fontsize=8); ax.set_title("Four batting styles (PCA view; most typical player named)")
fig.tight_layout(); save(fig, "04_bat_segments"); plt.show()
''')

code(r'''
z = pd.DataFrame(Xb, columns=BAT_FEATURES).assign(segment=bat.segment).groupby("segment").mean().loc[list(BAT_DESC)]
fig, ax = plt.subplots(figsize=(7.2, 2.8))
im = ax.imshow(z, cmap="RdBu_r", vmin=-2, vmax=2, aspect="auto")
ax.set_xticks(range(6), BAT_FEATURES, rotation=25, ha="right"); ax.set_yticks(range(4), z.index)
for i in range(4):
    for j in range(6):
        ax.text(j, i, f"{z.iloc[i, j]:+.1f}", ha="center", va="center", fontsize=8, color="white" if abs(z.iloc[i, j]) > 1.2 else INK)
ax.grid(False); ax.set_title("Segment fingerprints (centroids in SD units)")
fig.colorbar(im, ax=ax, shrink=0.8); save(fig, "05_bat_fingerprints"); plt.show()
''')

md("""
### 2.3 Validation with a variable the model never saw

If the segments are real, they should differ on outcomes that were **not** clustering inputs.
Two checks: **player-of-the-match awards per match played**, and **runs per innings** (it
depends on how long a batter bats, which only partly overlaps with the features).
Kruskal–Wallis tests whether the segments differ (it doesn't assume normality, and n per
segment is small).
""")

code(r'''
outcome = query("""
    SELECT x.player_id, count(DISTINCT x.match_id) AS matches,
           count(DISTINCT m.match_id) FILTER (WHERE m.player_of_match_id = x.player_id) AS pom
    FROM playing_xi x JOIN match m USING (match_id)
    WHERE m.season_id >= 2022
    GROUP BY x.player_id""")
bat = bat.drop(columns=["matches", "pom"], errors="ignore").merge(outcome, on="player_id")
bat["pom_per_100"] = 100 * bat.pom / bat.matches
bat["runs_per_match"] = bat.runs / bat.matches
for col in ["pom_per_100", "runs_per_match"]:
    groups = [g[col].values for _, g in bat.groupby("segment")]
    h, p = stats.kruskal(*groups)
    print(f"{col:15s} Kruskal-Wallis H = {h:5.2f}, p = {p:.4f}")
bat.groupby("segment")[["pom_per_100", "runs_per_match"]].mean().round(1).loc[list(BAT_DESC)]
''')

md("""
**Reading §2.** The four segments differ strongly on both outcomes the model never saw
(Kruskal–Wallis p < 0.001). Powerplay Blasters win a player-of-the-match award about 9 times
per 100 matches, Elite Accumulators about 8, Steady Top Order about 4 and Finishers about 3.
Finishers are not worse batters: they face fewer balls, and match awards follow volume. The
striking result is the gap between the two top-order segments. They come in at the same point
(over 4–5), but the Steady Top Order wins awards half as often as the Elite Accumulators.
In a game whose par keeps rising, a top-order batter striking at about 141 costs the team.
""")

md("""
## 3. Bowling styles (k-means)

`v_bowler_features` (2022–2026, ≥ 60 overs): **economy**, **bowling strike rate** (balls per
wicket), **dot %**, **boundary % conceded**, and the share of overs bowled in the **powerplay**
and at the **death**.
""")

code(r'''
BOWL_FEATURES = ["economy", "bowling_sr", "dot_pct", "boundary_pct", "pp_share", "death_share"]
bowl = query("""SELECT f.*, p.known_as FROM v_bowler_features f
                JOIN person p ON p.person_id = f.player_id""")
bowl[BOWL_FEATURES] = bowl[BOWL_FEATURES].astype(float)
Xw = StandardScaler().fit_transform(bowl[BOWL_FEATURES])
kw = choose_k(Xw)
print(len(bowl), "bowlers"); kw.round(3)
''')

md("""
The pattern is the same as for batters: silhouette is highest at k = 2 (0.33) and declines
slowly (0.29 at 3, 0.29 at 4). k = 3 gives the expected roles: powerplay, middle overs,
death. **k = 4 adds one more group with a clear meaning:** bowlers who take wickets far less
often. Its silhouette is essentially the same as k = 3, so we use **k = 4**.
""")

code(r'''
K_BOWL = 4
km_bowl = KMeans(n_clusters=K_BOWL, n_init=50, random_state=42).fit(Xw)
bowl["cluster"] = km_bowl.labels_
bowl["distance"] = np.linalg.norm(Xw - km_bowl.cluster_centers_[km_bowl.labels_], axis=1)
centroids = bowl.groupby("cluster")[BOWL_FEATURES].mean()

names, left = {}, set(centroids.index)
take("pp_share", "max", "Powerplay Strike Bowlers")
take("death_share", "max", "Death-overs Specialists")
take("economy", "min", "Middle-overs Controllers")
take("economy", "max", "Change Bowlers")
bowl["segment"] = bowl["cluster"].map(names)

BOWL_DESC = {
    "Powerplay Strike Bowlers": "New-ball bowlers: over half their overs in the powerplay, the most dot balls.",
    "Middle-overs Controllers": "Mostly spinners: the lowest economy and fewest boundaries conceded, overs 7-15.",
    "Death-overs Specialists": "A third of their overs at the death; expensive by necessity, but they take wickets.",
    "Change Bowlers": "Fill-in overs: far fewer wickets per ball than any other group.",
}
display(bowl.groupby("segment")[BOWL_FEATURES].mean().round(1).assign(players=bowl.groupby("segment").size()).loc[list(BOWL_DESC)])
for seg, g in bowl.sort_values("distance").groupby("segment"):
    print(f"{seg:26s} {', '.join(g.known_as.head(8))}")
''')

code(r'''
fig, axes = plt.subplots(1, 2, figsize=(10.5, 3.6))
plot_k(kw, axes[0], "Bowlers: k = 4", K_BOWL)
pca_w = PCA(2).fit(Xw); Q = pca_w.transform(Xw)
ax = axes[1]
for i, seg in enumerate(BOWL_DESC):
    m = bowl.segment == seg
    ax.scatter(Q[m, 0], Q[m, 1], s=28, color=PALETTE[i], label=seg, edgecolor=SURFACE, lw=0.5)
for _, r in bowl.loc[bowl.groupby("segment")["distance"].idxmin()].iterrows():
    j = r.name; ax.annotate(r.known_as, Q[j], xytext=(4, 4), textcoords="offset points", fontsize=8, color=INK)
ax.set_xlabel(f"PC1 ({pca_w.explained_variance_ratio_[0]:.0%} of variance)")
ax.set_ylabel(f"PC2 ({pca_w.explained_variance_ratio_[1]:.0%})")
ax.legend(frameon=False, fontsize=8); ax.set_title("Four bowling styles (PCA view)")
fig.tight_layout(); save(fig, "06_bowl_segments"); plt.show()
''')

md("""
## 4. Write the segments back to the database

The labels go into `segment` and `player_segment`, so SQL can use them. The composite FK
`(segment_id, role)` stops a batting segment being attached as someone's bowling role. This is
the only step that connects as the owner, and it runs in one transaction: a failure leaves
the old segments in place.
""")

code(r'''
with writer.begin() as c:
    c.execute(text("DELETE FROM segment"))                # cascades to player_segment
    for role, df, desc in (("BAT", bat, BAT_DESC), ("BOWL", bowl, BOWL_DESC)):
        ids = {seg: c.execute(text("INSERT INTO segment (role, segment_name, description) "
                                   "VALUES (:r, :n, :d) RETURNING segment_id"),
                              {"r": role, "n": seg, "d": d}).scalar_one()
               for seg, d in desc.items()}
        c.execute(text("INSERT INTO player_segment VALUES (:p, :r, :s, :dist)"),
                  [{"p": int(r.player_id), "r": role, "s": ids[r.segment], "dist": round(float(r.distance), 3)}
                   for r in df.itertuples()])
query("SELECT role, segment_name, players, left(most_typical, 70) AS most_typical FROM v_segment_profile ORDER BY role, players DESC")
''')

md("""
## 5. Using the segments in SQL

### S1. How does each 2026 squad mix the batting styles?
""")

code(r'''
s1 = run_sql("S1")
mix = s1.pivot(index="team", columns="batting_segment", values="share_pct").fillna(0)
mix = mix[[c for c in list(BAT_DESC) + ["Unclustered"] if c in mix.columns]].sort_values("Powerplay Blasters")
fig, ax = plt.subplots(figsize=(7.6, 3.8))
left_ = np.zeros(len(mix))
for i, seg in enumerate(mix.columns):
    ax.barh(mix.index, mix[seg], left=left_, color=(PALETTE + [MID])[i] if seg != "Unclustered" else MID,
            label=seg, edgecolor=SURFACE)
    left_ += mix[seg].values
ax.set_xlabel("% of the team's 2026 balls faced"); ax.set_xlim(0, 100); ax.grid(axis="y", visible=False)
ax.legend(frameon=False, fontsize=8, ncol=3, loc="upper center", bbox_to_anchor=(0.5, -0.18))
ax.set_title("2026 batting mix by team")
save(fig, "07_team_batting_mix"); plt.show()
mix.round(1)
''')

md("""
**Reading S1.** Teams build very different top orders. RR, PBKS and SRH give about a third of
their balls to Powerplay Blasters. GT gives about two thirds to Elite Accumulators (Gill and
Sai Sudharsan). LSG and CSK lean on the Steady Top Order, the segment §2 found least
effective. "Unclustered" is mostly players new since 2022 who haven't yet faced 300 balls;
it is largest for CSK (about half).
""")

md("""
### S2. Do champions bowl differently?
""")

code(r'''
s2 = run_sql("S2"); s2
''')

code(r'''
d = s2.pivot(index="bowling_segment", columns="team_group", values="share_pct").fillna(0)
d = d.loc[[s for s in list(BOWL_DESC) + ["Unclustered"] if s in d.index]]
fig, ax = plt.subplots(figsize=(7.2, 3.2))
y = np.arange(len(d))
ax.barh(y - 0.2, d["Champion"], 0.4, color=BLUE, label="Champion that season")
ax.barh(y + 0.2, d["Rest"], 0.4, color=MID, edgecolor=GRID, label="Every other team")
ax.set_yticks(y, d.index); ax.invert_yaxis(); ax.set_xlabel("% of overs bowled, 2022-2026")
ax.grid(axis="y", visible=False); ax.legend(frameon=False, fontsize=8)
ax.set_title("Who bowls the overs: champions vs the rest")
save(fig, "08_champion_bowling"); plt.show()
''')

md("""
**Reading S2.** Champions give **91.5%** of their overs to established, clustered bowlers;
every other team gives 76%. The rest hand almost a quarter of their overs to "Unclustered"
bowlers (fewer than 60 overs since 2022), and those overs cost about 9.8 an over.
Champions also give a third of their overs to Powerplay Strike Bowlers (against 24%), and
their middle-overs controllers concede 7.6 an over against 8.1.
A stable, specialist attack goes with winning titles. With five champions, this is a
description, not proof.
""")

md("""
## 6. Conclusions

**What changed (§1).** The game is measurably faster: first-innings scores rose by 21.5 runs
after the Impact Player rule (Welch t = 7.9, p < 10⁻¹³), and the powerplay changed most: teams
now score faster in overs 1–6 than they once did at the death. Winning the toss is worth
nothing measurable; choosing to field after winning it is (54% against 45%). Home advantage
is borderline overall and very uneven between franchises.

**What styles exist (§2–3).** Four batting and four bowling styles, built only from
ball-by-ball behaviour, line up with roles any commentator would recognise. Two checks
support them: the most typical member of each segment is a textbook example (Head, Gill,
Dube; Rabada, Rashid, Natarajan), and the segments differ on player-of-the-match awards,
which the model never saw.

**Using them (§5).** Writing the labels back into BCNF tables makes them ordinary data: S1 and
S2 are plain SQL joins. Teams build very different top orders (S1). Champions bowl their overs
with established specialists far more than other teams do (S2). That is descriptive, not
causal: five champions is a very small sample.

**Limitations.**
* Five seasons and 80–86 players per model: the segments are stable enough to describe, too
  small to predict from.
* Batting position is inferred from when a batter arrived, not recorded directly.
* Cricsheet has no player attributes (hand, bowling type), so "mostly spinners" is our reading
  of the members, not a field in the data.
""")

nb = nbf.v4.new_notebook()
nb["cells"] = cells
# Kernel = CricDB/.venv (registered once with: .venv\Scripts\python -m ipykernel install --user --name cricdb)
nb["metadata"]["kernelspec"] = {"name": "cricdb", "display_name": "CricDB (.venv)", "language": "python"}
out = HERE / "cricdb_kmeans.ipynb"
nbf.write(nb, out)
print("wrote", out)
