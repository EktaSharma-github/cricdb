# CricDB — IPL Match & Player Analytics System

A PostgreSQL database of every IPL ball bowled from 2008 to 2026 (1,243 matches, 295,732 deliveries), normalized to BCNF, with triggers that enforce the laws of the game and an analytics layer that clusters players into batting and bowling styles with k-means.

FDS (DBMS) course project, PGDBA, IIM Calcutta.

## What's inside

| File | Contents |
|---|---|
| [01_design.md](01_design.md) | Business rules, EER model, ER → relational mapping, normalization to BCNF, analytics plan and findings |
| [02_ddl.sql](02_ddl.sql) | 23 tables with keys and CHECKs, plus curated reference data (cities, venues and their spellings, franchises, teams) |
| [03_logic.sql](03_logic.sql) | Triggers for the rules of the game (including a deferred constraint trigger), core views, read-only role |
| [04_load.py](04_load.py) | Loads the Cricsheet JSON files; each match is one transaction, checked by every trigger |
| [05_queries.sql](05_queries.sql) | Five advanced queries: window frames, ranking, recursive CTE, relational division, EXCEPT |
| [06_demo.sql](06_demo.sql) | Rollback-only live demo: triggers firing, cascades, indexing with EXPLAIN, roles |
| [07_analytics.sql](07_analytics.sql) | SQL statistics (A1–A5), feature views, segment tables, segment queries (S1–S2) |
| [analytics/](analytics/) | k-means notebook ([HTML export](analytics/cricdb_kmeans.html)), its builder, and figures |
| [data/reference/](data/reference/) | Documented rule exceptions; a blank auction-price template |

## Run it

Needs PostgreSQL 15+ (built on 18) and Python 3.12. From this folder, in PowerShell:

```powershell
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
.venv\Scripts\python -m ipykernel install --user --name cricdb --display-name "CricDB (.venv)"
.\run_all.ps1                     # downloads the data, builds and loads the database (~2.5 min)
.venv\Scripts\jupyter nbconvert --to notebook --execute --inplace analytics\cricdb_kmeans.ipynb
```

`run_all.ps1` takes `-Password`, `-Psql` and `-Database` if your setup differs from the defaults (`postgres` / PostgreSQL 18 / `cricdb`).

Then: `psql -U postgres -h localhost -d cricdb -f 05_queries.sql` (or `06_demo.sql`).

## Data

Ball-by-ball data from [Cricsheet](https://cricsheet.org), used under the [Open Data Commons Attribution License (ODC-By)](https://opendatacommons.org/licenses/by/1-0/). It is downloaded by `run_all.ps1` and not stored in this repository.
