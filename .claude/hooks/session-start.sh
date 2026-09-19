#!/bin/bash
# SessionStart hook — prepares an OpenSTR dev environment for Claude Code on the web.
#
# Brings up everything needed to run the linters, the test suite and the API:
#   1. npm workspace dependencies
#   2. api/.env + admin/.env (gitignored, so they must be recreated per container)
#   3. a local PostgreSQL 16 cluster, migrated and seeded with demo data
#
# Safe to re-run: every step checks before it acts.
set -euo pipefail

# Local machines already have their own setup; only provision the remote container.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

REPO="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$REPO"

PG_BIN=/usr/lib/postgresql/16/bin
PG_DATA=/var/lib/postgresql/openstr-data
PG_LOG="$PG_DATA/server.log"
PG_USER=openstr
PG_DB=openstr
DB_URL="postgres://${PG_USER}@127.0.0.1:5432/${PG_DB}"

echo "==> Installing npm workspace dependencies"
npm install --no-audit --no-fund

echo "==> Writing local env files"
# .env files are gitignored, so they do not survive into a fresh container.
if [ ! -f api/.env ]; then
  cp api/.env.example api/.env
  # Point the API at the container-local cluster (trust auth, no password).
  sed -i "s|^DATABASE_URL=.*|DATABASE_URL=${DB_URL}|; s|^POSTGRES_HOST=.*|POSTGRES_HOST=127.0.0.1|" api/.env
fi
[ -f admin/.env ] || cp admin/.env.example admin/.env

# ── PostgreSQL ──────────────────────────────────────────────────────────────
# Best effort: the API unit tests mock the pool and pass without a database, so
# a failure here should degrade the session rather than abort it.
setup_postgres() {
  [ -x "$PG_BIN/pg_ctl" ] || { echo "   PostgreSQL 16 not installed; skipping"; return 1; }

  # postgres refuses to run as root, so the cluster is owned by the postgres user.
  if [ ! -s "$PG_DATA/PG_VERSION" ]; then
    echo "==> Initializing PostgreSQL cluster"
    mkdir -p "$PG_DATA" /var/run/postgresql
    chown -R postgres:postgres "$PG_DATA" /var/run/postgresql
    chmod 700 "$PG_DATA"
    su postgres -c "$PG_BIN/initdb -D $PG_DATA -U $PG_USER --auth=trust" >/dev/null
  fi

  # A cached container keeps the data directory but never a running process.
  if ! su postgres -c "$PG_BIN/pg_ctl -D $PG_DATA status" >/dev/null 2>&1; then
    echo "==> Starting PostgreSQL"
    chown -R postgres:postgres "$PG_DATA"
    su postgres -c "$PG_BIN/pg_ctl -D $PG_DATA -o '-p 5432 -c listen_addresses=127.0.0.1' -l $PG_LOG -w start" >/dev/null
  fi

  if ! psql -h 127.0.0.1 -U "$PG_USER" -d postgres -tAc \
       "SELECT 1 FROM pg_database WHERE datname='$PG_DB'" | grep -q 1; then
    echo "==> Creating database $PG_DB"
    psql -h 127.0.0.1 -U "$PG_USER" -d postgres -c "CREATE DATABASE $PG_DB" >/dev/null
  fi

  echo "==> Running migrations"
  ( cd api && npx node-pg-migrate up --database-url-var DATABASE_URL >/dev/null )

  # Seed demo data only into an empty database, so local edits are never clobbered.
  local users
  users=$(psql -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB" -tAc \
          "SELECT count(*) FROM users" 2>/dev/null || echo 0)
  if [ "$users" = "0" ]; then
    echo "==> Seeding demo data"
    ( cd api && npm run --silent db:seed:demo >/dev/null )
  fi
}

if setup_postgres; then
  echo "==> Database ready at $DB_URL"
else
  echo "!! PostgreSQL setup skipped — unit tests still run (they mock the pool)."
fi

# Make the connection details available to the session's shell commands.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export DATABASE_URL=\"$DB_URL\""
    echo "export PGHOST=127.0.0.1"
    echo "export PGUSER=$PG_USER"
    echo "export PGDATABASE=$PG_DB"
  } >> "$CLAUDE_ENV_FILE"
fi

echo "==> OpenSTR environment ready"
