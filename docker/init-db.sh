#!/usr/bin/env bash
set -euo pipefail

MARKER_DIR="${INIT_MARKER_DIR:-/var/lib/turtle-init}"
MARKER_FILE="${MARKER_DIR}/initialized"
SQL_ROOT="${SQL_DIR:-/opt/turtle/sql}"
MODULES_ROOT="${MODULES_DIR:-/src/tortoise-wow/modules}"

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
DB_USER="${DB_USER:-mangos}"
DB_PASSWORD="${DB_PASSWORD:-mangos}"
DB_LOGIN="${DB_LOGIN:-tw_logon}"
DB_WORLD="${DB_WORLD:-tw_world}"
DB_CHAR="${DB_CHAR:-tw_char}"
DB_LOGS="${DB_LOGS:-tw_logs}"

REALM_NAME="${REALM_NAME:-TurtleWoW}"
REALM_ADDRESS="${REALM_ADDRESS:-127.0.0.1}"
WORLD_PORT="${WORLD_PORT:-8090}"
REALM_ID="${REALM_ID:-1}"


if [[ -z "${DB_ROOT_PASSWORD}" ]]; then
  echo "DB_ROOT_PASSWORD (or MYSQL_ROOT_PASSWORD) is required." >&2
  exit 1
fi

mysql_root() {
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${DB_ROOT_PASSWORD}" --protocol=TCP "$@"
}

echo "Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
for i in $(seq 1 90); do
  if mysql_root -e "SELECT 1" &>/dev/null; then
    break
  fi
  if [[ "${i}" -eq 90 ]]; then
    echo "MariaDB did not become ready in time." >&2
    exit 1
  fi
  sleep 2
done
echo "MariaDB is ready."

# Discover core migration files, sorted deepest-first then alphabetically.
shopt -s nullglob
update_files=()
while IFS= read -r f; do
  [[ -n "${f}" ]] && update_files+=("${f}")
done < <(find "${SQL_ROOT}/database_updates" -type f -name "*.sql" \
  | awk -F'/' '{print NF, $0}' \
  | sort -k1,1nr -k2 \
  | cut -d' ' -f2-)

record_migration() {
  local target_db="${1}"
  local module="${2}"
  local f="${3}"
  local n h
  n="$(basename "${f}" .sql)"
  h="$(sha1sum "${f}" | awk '{ print toupper($1) }')"
  mysql_root -e "INSERT INTO ${target_db}.migrations (Name, Module, Hash, AppliedAt) VALUES ('${n}','${module}','${h}',NOW()) ON DUPLICATE KEY UPDATE Hash='${h}', AppliedAt=NOW();"
}

apply_missing_migrations() {
  local applied_file
  applied_file="$(mktemp)"

  mysql_root -N -e "SELECT Name FROM ${DB_WORLD}.migrations WHERE Module='';" 2>/dev/null > "${applied_file}" || true

  local missing=()
  for f in "${update_files[@]}"; do
    local n
    n="$(basename "${f}" .sql)"
    if ! grep -qxF "${n}" "${applied_file}" 2>/dev/null; then
      missing+=("${f}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    echo "No new core migrations to apply."
  else
    echo "Applying ${#missing[@]} missing core migration(s)..."
    for f in "${missing[@]}"; do
      echo "  -> $(basename "${f}")"
      mysql_root --force "${DB_WORLD}" < "${f}" || true
      record_migration "${DB_WORLD}" "" "${f}"
    done
  fi

  # Refresh hashes for already-recorded core migrations so mangosd doesn't retry.
  echo "Refreshing core migration hashes..."
  for f in "${update_files[@]}"; do
    record_migration "${DB_WORLD}" "" "${f}"
  done

  rm -f "${applied_file}"
}

db_dir_to_db_name() {
  case "${1}" in
    world)     echo "${DB_WORLD}" ;;
    char|characters) echo "${DB_CHAR}" ;;
    auth|login) echo "${DB_LOGIN}" ;;
    logs)      echo "${DB_LOGS}" ;;
    *)         echo "" ;;
  esac
}

apply_module_migrations() {
  local module="${1}"
  local target_db="${2}"
  local db_sql_dir="${3}"

  local files=()
  while IFS= read -r f; do
    [[ -n "${f}" ]] && files+=("${f}")
  done < <(find "${db_sql_dir}" -type f -name "*.sql" | sort)

  if [[ "${#files[@]}" -eq 0 ]]; then
    return 0
  fi

  local applied_file
  applied_file="$(mktemp)"

  mysql_root -N -e "SELECT Name FROM ${target_db}.migrations WHERE Module='${module}';" 2>/dev/null > "${applied_file}" || true

  local missing=()
  for f in "${files[@]}"; do
    local n
    n="$(basename "${f}" .sql)"
    if ! grep -qxF "${n}" "${applied_file}" 2>/dev/null; then
      missing+=("${f}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    echo "No new migrations to apply for module '${module}' on ${target_db}."
    return 0
  fi

  echo "Applying ${#missing[@]} missing migration(s) for module '${module}' on ${target_db}..."
  for f in "${missing[@]}"; do
    echo "  -> $(basename "${f}")"
    mysql_root --force "${target_db}" < "${f}" || true
    record_migration "${target_db}" "${module}" "${f}"
  done

  # Refresh hashes for already-recorded module migrations so mangosd doesn't retry.
  echo "Refreshing migration hashes for module '${module}' on ${target_db}..."
  for f in "${files[@]}"; do
    record_migration "${target_db}" "${module}" "${f}"
  done

  rm -f "${applied_file}"
}

apply_module_migrations_all() {
  if [[ ! -d "${MODULES_ROOT}" ]]; then
    return 0
  fi

  local module_dir
  for module_dir in "${MODULES_ROOT}"/*/; do
    local module_name sql_dir
    module_name="$(basename "${module_dir}")"
    sql_dir="${module_dir}/data/sql"
    [[ -d "${sql_dir}" ]] || continue

    local db_dir
    for db_dir in "${sql_dir}"/*/; do
      local db_dir_name target_db
      db_dir_name="$(basename "${db_dir}")"
      target_db="$(db_dir_to_db_name "${db_dir_name}")"
      if [[ -z "${target_db}" ]]; then
        echo "WARNING: Unknown module SQL directory '${db_dir_name}' for module '${module_name}'; skipping." >&2
        continue
      fi
      apply_module_migrations "${module_name}" "${target_db}" "${db_dir}"
    done
  done
}

ensure_migrations_module_column() {
    local db

    for db in "${DB_WORLD}" "${DB_CHAR}" "${DB_LOGIN}"; do
        echo "Ensuring ${db}.migrations.Module exists..."
        mysql_root -e "
            ALTER TABLE \`${db}\`.migrations
            ADD COLUMN IF NOT EXISTS Module VARCHAR(255) NOT NULL DEFAULT '';
        "
    done
}

if [[ -f "${MARKER_FILE}" ]]; then
  echo "Init marker found (${MARKER_FILE}); skipping first-run database setup."
  apply_missing_migrations
  apply_module_migrations_all
  exit 0
fi

if [[ ! -f "${SQL_ROOT}/create_databases.sql" ]]; then
  echo "Missing ${SQL_ROOT}/create_databases.sql" >&2
  exit 1
fi

echo "Creating databases and base schemas..."
mysql_root < "${SQL_ROOT}/create_databases.sql"

# BackupCharacterInventory copies rows with INSERT ... SELECT * and therefore
# requires a structurally identical snapshot table in the character database.
character_inventory_copy_sql="${SQL_ROOT}/character-inventory-copy.sql"
if [[ ! -f "${character_inventory_copy_sql}" ]]; then
  echo "Missing ${character_inventory_copy_sql}" >&2
  exit 1
fi
echo "Ensuring character_inventory_copy exists..."
mysql_root "${DB_CHAR}" < "${character_inventory_copy_sql}"

echo "Creating application user '${DB_USER}' and grants..."
mysql_root <<SQL
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_LOGIN}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_WORLD}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_CHAR}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_LOGS}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

echo "Importing world content from sql/base (this can take several minutes)..."
base_files=("${SQL_ROOT}"/base/*.sql)
if [[ "${#base_files[@]}" -eq 0 ]]; then
  echo "No SQL files found under ${SQL_ROOT}/base" >&2
  exit 1
fi
for f in "${base_files[@]}"; do
  echo "  -> $(basename "${f}")"
  mysql_root "${DB_WORLD}" < "${f}"
done

ensure_migrations_module_column

echo "Applying database_updates with --force (duplicate keys expected)..."
for f in "${update_files[@]}"; do
  echo "  -> $(basename "${f}")"
  mysql_root --force "${DB_WORLD}" < "${f}" || true
  record_migration "${DB_WORLD}" "" "${f}"
done

# Verify a known schema change from migrations landed.
col_count="$(mysql_root -N -e "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_WORLD}' AND TABLE_NAME='spell_template' AND COLUMN_NAME='script_name';")"
if [[ "${col_count}" != "1" ]]; then
  echo "WARNING: spell_template.script_name not found after migrations (got count=${col_count})." >&2
  exit 0
fi

apply_module_migrations_all

echo "Inserting realmlist row..."
mysql_root <<SQL
DELETE FROM ${DB_LOGIN}.realmlist;
INSERT INTO ${DB_LOGIN}.realmlist
  (id, name, address, port, icon, realmflags, timezone, allowedSecurityLevel, realmbuilds)
VALUES
  (${REALM_ID}, '${REALM_NAME}', '${REALM_ADDRESS}', ${WORLD_PORT}, 0, 0, 1, 0, '7272');
SQL

mkdir -p "${MARKER_DIR}"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "${MARKER_FILE}"
echo "Database init complete."
