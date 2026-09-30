#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    echo "This script must be run with bash, not sh."
    echo "Run it with:"
    echo "  bash $0"
    exit 1
fi

set -Eeuo pipefail
umask 077

#
# Nextcloud updater
# Debian / Apache2 / PHP compatible
#
# Notes:
# - MariaDB/MySQL backups use a temporary client config file instead of MYSQL_PWD.
# - Custom theme handling is optional. Leave CUSTOM_THEME_NAME empty to disable it.
# - The script checks for a Nextcloud server update before creating backups or entering maintenance mode.
#

NC_DIR="${NC_DIR:-/var/www/nextcloud}"
WEB_USER="${WEB_USER:-www-data}"
WEB_GROUP="${WEB_GROUP:-www-data}"
ROOT_USER="${ROOT_USER:-root}"
PHP_BIN="${PHP_BIN:-/usr/bin/php}"

# Leave empty if this Nextcloud installation has no custom theme.
CUSTOM_THEME_NAME="${CUSTOM_THEME_NAME:-}"
CUSTOM_THEME_DIR=""

BACKUP_BASE="${BACKUP_BASE:-/var/backups/nextcloud}"
DATE="$(date +'%Y%m%d')"
BACKUP_DIR=""
LOG_FILE=""

# Set to true only if you want this script to also back up the Nextcloud data directory.
# This can be huge. Database, config, apps, themes and updater are always backed up.
BACKUP_DATA="${BACKUP_DATA:-false}"

# Set to true only if you want recursive permission repair on data.
# For large instances, keep false to avoid long downtime.
TOUCH_DATA_PERMISSIONS="${TOUCH_DATA_PERMISSIONS:-false}"

# Post-upgrade database/application maintenance.
RUN_EXPENSIVE_REPAIR="${RUN_EXPENSIVE_REPAIR:-true}"
RUN_MISSING_INDICES="${RUN_MISSING_INDICES:-true}"
RUN_MISSING_COLUMNS="${RUN_MISSING_COLUMNS:-true}"
RUN_MISSING_PRIMARY_KEYS="${RUN_MISSING_PRIMARY_KEYS:-true}"

# Bigint conversion can be heavy. Keep false unless Nextcloud setup checks specifically ask for it.
RUN_FILECACHE_BIGINT="${RUN_FILECACHE_BIGINT:-false}"

# Final checks.
RUN_CORE_INTEGRITY="${RUN_CORE_INTEGRITY:-true}"
RUN_SETUPCHECKS="${RUN_SETUPCHECKS:-true}"

# Production safety checks.
CHECK_DEBUG_PRODUCTION="${CHECK_DEBUG_PRODUCTION:-true}"

# AUTO_DISABLE_DEBUG:
#   ask   - ask what to do if debug=true
#   true  - automatically set debug=false
#   false - only warn
AUTO_DISABLE_DEBUG="${AUTO_DISABLE_DEBUG:-ask}"

# MANAGE_ALLOWED_ADMIN_RANGES:
#   ask     - interactive control
#   enforce - set ALLOWED_ADMIN_RANGES_JSON automatically
#   disable - set allowed_admin_ranges to []
#   skip    - do nothing
#
# WARNING:
# If allowed_admin_ranges is non-empty, admin actions must originate from these IP/CIDR ranges.
# Put your VPN/public office/admin IP ranges here before using enforce.
#
# Example:
# ALLOWED_ADMIN_RANGES_JSON='["198.51.100.10/32","2001:db8::/64"]'
ALLOWED_ADMIN_RANGES_MODE="${ALLOWED_ADMIN_RANGES_MODE:-ask}"
ALLOWED_ADMIN_RANGES_JSON="${ALLOWED_ADMIN_RANGES_JSON:-[]}"

WEB_SERVICE="${WEB_SERVICE:-apache2}"
SERVICE_ACTION="${SERVICE_ACTION:-restart}"

LOCK_FILE="${LOCK_FILE:-/run/lock/update-nextcloud.lock}"

TEMP_FILES=()

cleanup_temp_files() {
    local file

    for file in "${TEMP_FILES[@]:-}"; do
        if [[ -n "${file}" && -f "${file}" ]]; then
            rm -f -- "${file}" || true
        fi
    done
}

trap cleanup_temp_files EXIT

custom_theme_enabled() {
    [[ -n "${CUSTOM_THEME_NAME}" ]]
}

run_as_web() {
    sudo -E -u "${WEB_USER}" "${PHP_BIN}" --define apc.enable_cli=1 "${NC_DIR}/occ" "$@"
}

log() {
    local message="[$(date +'%F %T')] $*"
    echo "${message}"

    if [[ -n "${LOG_FILE}" ]]; then
        echo "${message}" >> "${LOG_FILE}"
    fi
}

fail() {
    echo
    log "ERROR: $*"
    echo
    echo "Nextcloud may still be in maintenance mode."
    echo "Check with:"
    echo "  sudo -u ${WEB_USER} ${PHP_BIN} ${NC_DIR}/occ maintenance:mode"
    echo
    echo "To disable maintenance mode manually, only if the installation is healthy:"
    echo "  sudo -u ${WEB_USER} ${PHP_BIN} ${NC_DIR}/occ maintenance:mode --off"
    echo
    exit 1
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Run this script as root."
        exit 1
    fi
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || fail "flock is missing. Install util-linux."

    exec 200>"${LOCK_FILE}"

    if ! flock -n 200; then
        echo "Another Nextcloud update process appears to be running."
        echo "Lock file: ${LOCK_FILE}"
        exit 1
    fi
}

check_for_server_update() {
    local output rc

    log "Checking for an available Nextcloud server update"

    set +e
    output="$(LC_ALL=C sudo -E -u "${WEB_USER}" "${PHP_BIN}" --define apc.enable_cli=1 "${NC_DIR}/occ" update:check 2>&1)"
    rc=$?
    set -e

    echo "${output}"

    if [[ "${rc}" -ne 0 ]]; then
        echo "ERROR: could not check for a Nextcloud server update" >&2
        exit 1
    fi

    if grep -Eq '^Nextcloud[[:space:]]+[^[:space:]]+[[:space:]]+is available' <<< "${output}"; then
        log "A Nextcloud server update is available"
        return 0
    fi

    log "No Nextcloud server update is available. Nothing to do."
    exit 0
}

choose_backup_dir() {
    mkdir -p "${BACKUP_BASE}"

    local base_dir="${BACKUP_BASE}/nextcloud-${DATE}"

    if [[ ! -e "${base_dir}" ]]; then
        BACKUP_DIR="${base_dir}"
    else
        echo
        echo "Backup directory already exists:"
        echo "  ${base_dir}"
        echo
        echo "Choose:"
        echo "  1) Use next available suffix, for example nextcloud-${DATE}-02"
        echo "  2) Reuse existing directory"
        echo "  3) Abort"
        echo
        read -r -p "Choice [1/2/3]: " choice

        case "${choice}" in
            1|"")
                local i=2
                while true; do
                    local candidate
                    candidate="$(printf "%s-%02d" "${base_dir}" "${i}")"

                    if [[ ! -e "${candidate}" ]]; then
                        BACKUP_DIR="${candidate}"
                        break
                    fi

                    i=$((i + 1))
                done
                ;;
            2)
                BACKUP_DIR="${base_dir}"
                ;;
            3)
                echo "Aborted."
                exit 0
                ;;
            *)
                echo "Invalid choice."
                exit 1
                ;;
        esac
    fi

    mkdir -p "${BACKUP_DIR}"
    LOG_FILE="${BACKUP_DIR}/update.log"
    touch "${LOG_FILE}"
}

preflight() {
    [[ -d "${NC_DIR}" ]] || fail "Nextcloud directory not found: ${NC_DIR}"
    [[ -f "${NC_DIR}/occ" ]] || fail "occ not found in ${NC_DIR}"
    [[ -f "${NC_DIR}/config/config.php" ]] || fail "config.php not found"
    [[ -d "${NC_DIR}/apps" ]] || fail "apps directory not found"
    [[ -d "${NC_DIR}/themes" ]] || fail "themes directory not found"
    [[ -d "${NC_DIR}/updater" ]] || fail "updater directory not found"
    [[ -f "${NC_DIR}/updater/updater.phar" ]] || fail "Nextcloud updater.phar not found"

    if custom_theme_enabled; then
        CUSTOM_THEME_DIR="${NC_DIR}/themes/${CUSTOM_THEME_NAME}"
        [[ -d "${CUSTOM_THEME_DIR}" ]] || fail "Custom theme not found: ${CUSTOM_THEME_DIR}"
    fi

    command -v rsync >/dev/null 2>&1 || fail "rsync is missing"
    command -v sudo >/dev/null 2>&1 || fail "sudo is missing"
    command -v systemctl >/dev/null 2>&1 || fail "systemctl is missing"
    [[ -x "${PHP_BIN}" ]] || fail "PHP binary not found or not executable: ${PHP_BIN}"

    if "${PHP_BIN}" -i | grep -i "^disable_functions" | grep -qw "system"; then
        log "PHP CLI has system() disabled. This is OK. The script will handle the updater auto-occ failure."
    fi

    log "Preflight check completed"
}

get_config_value() {
    local key="$1"

    sudo -u "${WEB_USER}" "${PHP_BIN}" -r '
        $CONFIG = [];
        include $argv[1];
        $key = $argv[2];

        if (isset($CONFIG[$key])) {
            if (is_array($CONFIG[$key])) {
                echo json_encode($CONFIG[$key], JSON_UNESCAPED_SLASHES);
            } else {
                if (is_bool($CONFIG[$key])) {
                    echo $CONFIG[$key] ? "true" : "false";
                } else {
                    echo $CONFIG[$key];
                }
            }
        }
    ' "${NC_DIR}/config/config.php" "${key}"
}

is_config_true() {
    local value="${1:-}"
    [[ "${value}" == "true" || "${value}" == "1" || "${value}" == "yes" || "${value}" == "on" ]]
}

get_data_dir() {
    local data_dir
    data_dir="$(get_config_value datadirectory || true)"

    if [[ -z "${data_dir}" ]]; then
        data_dir="${NC_DIR}/data"
    fi

    echo "${data_dir}"
}

safe_copy_config_snapshot() {
    log "Saving current system config snapshot"
    run_as_web config:list system > "${BACKUP_DIR}/config-list-system-before.json" 2>> "${LOG_FILE}" || true
}

backup_database() {
    local dbtype dbname dbuser dbpass dbhost dump_file

    dbtype="$(get_config_value dbtype || true)"
    dbname="$(get_config_value dbname || true)"
    dbuser="$(get_config_value dbuser || true)"
    dbpass="$(get_config_value dbpassword || true)"
    dbhost="$(get_config_value dbhost || true)"

    [[ -n "${dbtype}" ]] || fail "Could not detect database type from config.php"
    [[ -n "${dbname}" ]] || fail "Could not detect database name from config.php"

    log "Detected database type: ${dbtype}"
    log "Backing up database: ${dbname}"

    case "${dbtype}" in
        mysql|mysqli)
            local dump_bin mysql_args host port socket defaults_file rc

            [[ -n "${dbuser}" ]] || fail "Could not detect database user from config.php"
            [[ -n "${dbpass}" ]] || fail "Database password is empty. Check dbpassword in ${NC_DIR}/config/config.php"

            if command -v mariadb-dump >/dev/null 2>&1; then
                dump_bin="mariadb-dump"
            elif command -v mysqldump >/dev/null 2>&1; then
                dump_bin="mysqldump"
            else
                fail "mariadb-dump or mysqldump is missing"
            fi

            dump_file="${BACKUP_DIR}/database-${dbname}-${DATE}.sql"

            log "Database config check: dbuser=${dbuser}, dbhost=${dbhost:-localhost}, dbpassword_length=${#dbpass}"

            defaults_file="$(mktemp "${BACKUP_DIR}/mariadb-client.XXXXXX.cnf")"
            TEMP_FILES+=("${defaults_file}")
            chmod 600 "${defaults_file}"

            {
                printf '[client]\n'
                printf 'user=%s\n' "${dbuser}"
                printf 'password=%s\n' "${dbpass}"
            } > "${defaults_file}"

            mysql_args=(--single-transaction --default-character-set=utf8mb4)

            if [[ -z "${dbhost}" ]]; then
                mysql_args+=(-h "localhost")
            elif [[ "${dbhost}" == *":/"* ]]; then
                host="${dbhost%%:*}"
                socket="${dbhost#*:}"
                [[ -n "${host}" ]] && mysql_args+=(-h "${host}")
                mysql_args+=(--socket="${socket}")
            elif [[ "${dbhost}" == /* ]]; then
                mysql_args+=(--socket="${dbhost}")
            elif [[ "${dbhost}" == *":"* ]]; then
                host="${dbhost%%:*}"
                port="${dbhost##*:}"
                mysql_args+=(-h "${host}" -P "${port}")
            else
                mysql_args+=(-h "${dbhost}")
            fi

            set +e
            "${dump_bin}" --defaults-extra-file="${defaults_file}" "${mysql_args[@]}" "${dbname}" > "${dump_file}"
            rc=$?
            set -e

            rm -f "${defaults_file}"

            if [[ "${rc}" -ne 0 ]]; then
                rm -f "${dump_file}" || true
                fail "Database backup failed with exit code ${rc}"
            fi

            [[ -s "${dump_file}" ]] || fail "Database backup is empty: ${dump_file}"
            ;;

        pgsql)
            command -v pg_dump >/dev/null 2>&1 || fail "pg_dump is missing"

            [[ -n "${dbuser}" ]] || fail "Could not detect database user from config.php"

            dump_file="${BACKUP_DIR}/database-${dbname}-${DATE}.sql"

            PGPASSWORD="${dbpass}" pg_dump \
                -h "${dbhost:-localhost}" \
                -U "${dbuser}" \
                -F p \
                "${dbname}" > "${dump_file}"

            [[ -s "${dump_file}" ]] || fail "Database backup is empty: ${dump_file}"
            ;;

        sqlite3)
            local sqlite_path

            sqlite_path="${NC_DIR}/data/${dbname}"
            [[ -f "${sqlite_path}" ]] || fail "SQLite database file not found: ${sqlite_path}"

            cp -a "${sqlite_path}" "${BACKUP_DIR}/database-sqlite-${DATE}.sqlite3"
            ;;

        *)
            fail "Unsupported database type: ${dbtype}"
            ;;
    esac

    log "Database backup completed"
}

backup_files() {
    log "Backing up config directory"
    rsync -Aavx --delete "${NC_DIR}/config/" "${BACKUP_DIR}/config/" >> "${LOG_FILE}" 2>&1

    log "Backing up apps directory"
    rsync -Aavx --delete "${NC_DIR}/apps/" "${BACKUP_DIR}/apps/" >> "${LOG_FILE}" 2>&1

    log "Backing up themes directory"
    rsync -Aavx --delete "${NC_DIR}/themes/" "${BACKUP_DIR}/themes/" >> "${LOG_FILE}" 2>&1

    if custom_theme_enabled; then
        CUSTOM_THEME_DIR="${NC_DIR}/themes/${CUSTOM_THEME_NAME}"
        log "Backing up custom theme explicitly: ${CUSTOM_THEME_NAME}"
        rsync -Aavx --delete "${CUSTOM_THEME_DIR}/" "${BACKUP_DIR}/theme-${CUSTOM_THEME_NAME}/" >> "${LOG_FILE}" 2>&1
    else
        log "No custom theme configured, skipping explicit custom theme backup"
    fi

    log "Backing up updater directory"
    rsync -Aavx --delete "${NC_DIR}/updater/" "${BACKUP_DIR}/updater/" >> "${LOG_FILE}" 2>&1

    log "Saving Nextcloud app list before update"
    run_as_web app:list > "${BACKUP_DIR}/app-list-before.txt" 2>> "${LOG_FILE}" || true

    log "Saving Nextcloud status before update"
    run_as_web status > "${BACKUP_DIR}/status-before.txt" 2>> "${LOG_FILE}" || true

    if [[ "${BACKUP_DATA}" == "true" ]]; then
        local data_dir
        data_dir="$(get_data_dir)"

        if [[ -d "${data_dir}" ]]; then
            log "Backing up data directory: ${data_dir}"
            rsync -Aavx "${data_dir}/" "${BACKUP_DIR}/data/" >> "${LOG_FILE}" 2>&1
        else
            fail "BACKUP_DATA=true but data directory was not found: ${data_dir}"
        fi
    else
        log "Data directory backup skipped by setting BACKUP_DATA=${BACKUP_DATA}"
    fi
}

check_known_updater_blockers() {
    local blockers=("assets")
    local rel path target_dir choice confirm_delete

    for rel in "${blockers[@]}"; do
        path="${NC_DIR}/${rel}"

        if [[ -e "${path}" ]]; then
            echo
            echo "Known Nextcloud updater blocker found:"
            echo "  ${path}"
            echo
            echo "The Nextcloud updater may fail with:"
            echo "  Unknown files detected within the installation folder: ${rel}"
            echo
            echo "Choose:"
            echo "  1) Move it to the backup folder - recommended"
            echo "  2) Delete it"
            echo "  3) Leave it and continue anyway"
            echo "  4) Abort"
            echo
            read -r -p "Choice [1/2/3/4]: " choice

            case "${choice}" in
                1|"")
                    target_dir="${BACKUP_DIR}/moved-before-update"
                    mkdir -p "${target_dir}"
                    log "Moving updater blocker ${path} to ${target_dir}/${rel}"
                    mv "${path}" "${target_dir}/${rel}"
                    ;;
                2)
                    read -r -p "Type DELETE to remove ${path}: " confirm_delete

                    if [[ "${confirm_delete}" == "DELETE" ]]; then
                        log "Deleting updater blocker ${path}"
                        rm -rf -- "${path}"
                    else
                        echo "Delete not confirmed. Aborting."
                        exit 1
                    fi
                    ;;
                3)
                    log "Leaving updater blocker in place: ${path}"
                    ;;
                4)
                    echo "Aborted."
                    exit 0
                    ;;
                *)
                    echo "Invalid choice."
                    exit 1
                    ;;
            esac
        fi
    done
}

set_maintenance_on() {
    log "Enabling maintenance mode"
    run_as_web maintenance:mode --on >> "${LOG_FILE}" 2>&1 || fail "Could not enable maintenance mode"
}

set_maintenance_off() {
    log "Disabling maintenance mode"
    run_as_web maintenance:mode --off >> "${LOG_FILE}" 2>&1 || fail "Could not disable maintenance mode"
}

chmod_core_tree() {
    log "Applying chmod to Nextcloud core tree, excluding data directory"

    find "${NC_DIR}" \
        -path "${NC_DIR}/data" -prune -o \
        -type f -exec chmod 0640 {} \; >> "${LOG_FILE}" 2>&1

    find "${NC_DIR}" \
        -path "${NC_DIR}/data" -prune -o \
        -type d -exec chmod 0750 {} \; >> "${LOG_FILE}" 2>&1

    chmod +x "${NC_DIR}/occ"

    if [[ -f "${NC_DIR}/.htaccess" ]]; then
        chmod 0644 "${NC_DIR}/.htaccess"
    fi

    if [[ -f "${NC_DIR}/data/.htaccess" ]]; then
        chmod 0644 "${NC_DIR}/data/.htaccess"
    fi
}

apply_update_permissions() {
    log "Switching Nextcloud installation to update permissions"

    echo
    echo "Temporarily setting Nextcloud code ownership to:"
    echo "  ${WEB_USER}:${WEB_GROUP}"
    echo
    echo "This is required because the updater must overwrite core files."
    echo

    chown "${WEB_USER}:${WEB_GROUP}" "${NC_DIR}"

    while IFS= read -r -d '' item; do
        chown -R "${WEB_USER}:${WEB_GROUP}" "${item}" >> "${LOG_FILE}" 2>&1
    done < <(find "${NC_DIR}" -mindepth 1 -maxdepth 1 -not -name "data" -print0)

    if [[ "${TOUCH_DATA_PERMISSIONS}" == "true" && -d "${NC_DIR}/data" ]]; then
        log "Also touching data directory permissions because TOUCH_DATA_PERMISSIONS=true"
        chown -R "${WEB_USER}:${WEB_GROUP}" "${NC_DIR}/data" >> "${LOG_FILE}" 2>&1
    fi

    chmod_core_tree

    if [[ -d "${NC_DIR}/data" ]]; then
