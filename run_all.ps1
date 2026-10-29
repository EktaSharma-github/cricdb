# Rebuilds the CricDB database from scratch: schema, logic, then the real Cricsheet data.
# Usage (from the CricDB folder):   .\run_all.ps1
# Optional: .\run_all.ps1 -Password yourpassword -Psql "C:\path\to\psql.exe"
# First time only:
#   python -m venv .venv; .venv\Scripts\pip install -r requirements.txt
#   .venv\Scripts\python -m ipykernel install --user --name cricdb --display-name "CricDB (.venv)"

param(
    [string]$Password = "postgres",
    [string]$Psql     = "C:\Program Files\PostgreSQL\18\bin\psql.exe",
    [string]$Database = "cricdb"
)

$ErrorActionPreference = "Stop"
$env:PGPASSWORD = $Password
$env:PGDATABASE = $Database
Set-Location $PSScriptRoot

if (-not (Test-Path "data\raw\ipl_json")) {
    New-Item -ItemType Directory -Force "data\raw" | Out-Null
    Invoke-WebRequest -Uri "https://cricsheet.org/downloads/ipl_json.zip" -OutFile "data\raw\ipl_json.zip" -UseBasicParsing
    Expand-Archive -Force "data\raw\ipl_json.zip" "data\raw\ipl_json"
}

$exists = & $Psql -U postgres -h localhost -tAc "SELECT 1 FROM pg_database WHERE datname = '$Database'"
if (-not $exists) {
    & $Psql -U postgres -h localhost -c "CREATE DATABASE $Database"
}

foreach ($file in "02_ddl.sql", "03_logic.sql") {
    Write-Host "== $file"
    & $Psql -U postgres -h localhost -d $Database -q -v ON_ERROR_STOP=1 -f $file | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$file failed (exit $LASTEXITCODE)" }
}

Write-Host "== 04_load.py (about 1,250 matches; each one is a transaction)"
& ".venv\Scripts\python.exe" 04_load.py
if ($LASTEXITCODE -ne 0) { throw "04_load.py rejected some matches (see above)" }

& $Psql -U postgres -h localhost -d $Database -q -c "ANALYZE"

Write-Host "== 07_analytics.sql"
& $Psql -U postgres -h localhost -d $Database -q -v ON_ERROR_STOP=1 -f 07_analytics.sql -o NUL
if ($LASTEXITCODE -ne 0) { throw "07_analytics.sql failed (exit $LASTEXITCODE)" }

Write-Host "CricDB rebuilt. Try:  psql -U postgres -h localhost -d $Database -f 05_queries.sql   (or 06_demo.sql)"
Write-Host "Segments are empty after a rebuild; re-run the notebook to fill them:"
Write-Host "  .venv\Scripts\jupyter nbconvert --to notebook --execute --inplace analytics\cricdb_kmeans.ipynb"
