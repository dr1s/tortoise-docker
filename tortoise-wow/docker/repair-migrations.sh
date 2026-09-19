#!/usr/bin/env bash
# Repair tw_world.migrations after an init that stored Hash='manual'.
# Safe to re-run. Does not re-import SQL.
set -euo pipefail

SQL_ROOT="${SQL_DIR:-/opt/turtle/sql}"
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
DB_USER="${DB_USER:-mangos}"
DB_PASSWORD="${DB_PASSWORD:-mangos}"
DB_WORLD="${DB_WORLD:-tw_world}"

mysql_cmd() {
  if [[ -n "${DB_ROOT_PASSWORD}" ]]; then
    mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${DB_ROOT_PASSWORD}" --protocol=TCP "$@"
  else
    mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" --protocol=TCP "$@"
  fi
}

shopt -s nullglob
files=("${SQL_ROOT}"/database_updates/*.sql)
if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No migration files under ${SQL_ROOT}/database_updates" >&2
  exit 1
fi

echo "Ensuring migrations.Module column exists..."
mysql_cmd -e "
  ALTER TABLE \`${DB_WORLD}\`.migrations
  ADD COLUMN IF NOT EXISTS Module VARCHAR(255) NOT NULL DEFAULT '';
" || true

echo "Clearing old core migration rows..."
mysql_cmd -e "DELETE FROM \`${DB_WORLD}\`.migrations WHERE Module = '' OR Module IS NULL;"

echo "Inserting ${#files[@]} core migration rows with SHA1 hashes..."
for f in "${files[@]}"; do
  n="$(basename "${f}" .sql)"
  h="$(sha1sum "${f}" | awk '{ print toupper($1) }')"
  mysql_cmd -e "INSERT INTO \`${DB_WORLD}\`.migrations (Name, Module, Hash, AppliedAt) VALUES ('${n}','','${h}',NOW());"
done

count="$(mysql_cmd -N -e "SELECT COUNT(*) FROM \`${DB_WORLD}\`.migrations;")"
echo "Done. migrations rows: ${count}"
