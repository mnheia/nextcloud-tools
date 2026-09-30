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

