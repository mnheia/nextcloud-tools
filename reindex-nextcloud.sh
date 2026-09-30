#!/usr/bin/env bash
set -Eeuo pipefail

NCPATH="${NCPATH:-/var/www/nextcloud}"
OCC="${NCPATH}/occ"
PHP="${PHP:-/usr/bin/php}"
WEBUSER="${WEBUSER:-www-data}"

LOCK="${LOCK:-/run/lock/reindex-nextcloud.lock}"
LOG="${LOG:-/var/log/reindex-nextcloud.log}"

exec >>"$LOG" 2>&1

echo
echo "===== $(date -Is) starting Nextcloud files scan ====="

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

exec 200>"$LOCK"
flock -n 200 || {
  echo "Another Nextcloud reindex/files-scan is already running. Exiting."
  exit 0
}

if [ ! -d "$NCPATH" ]; then
  echo "ERROR: Nextcloud path does not exist: $NCPATH" >&2
  exit 1
fi

if [ ! -f "$NCPATH/config/config.php" ]; then
  echo "ERROR: Nextcloud config.php not found: $NCPATH/config/config.php" >&2
  exit 1
fi

if [ ! -f "$OCC" ]; then
  echo "ERROR: occ not found: $OCC" >&2
  exit 1
fi

if [ ! -x "$PHP" ]; then
  echo "ERROR: PHP binary not found or not executable: $PHP" >&2
  exit 1
fi

if ! id "$WEBUSER" >/dev/null 2>&1; then
  echo "ERROR: web user does not exist: $WEBUSER" >&2
  exit 1
fi

echo "Nextcloud status:"
sudo -u "$WEBUSER" "$PHP" "$OCC" status || true

MAINTENANCE_MODE="$(
  sudo -u "$WEBUSER" "$PHP" "$OCC" maintenance:mode 2>/dev/null | awk -F': ' '{print $2}' | tail -1 || true
)"

if [ "$MAINTENANCE_MODE" = "enabled" ]; then
  echo "ERROR: Nextcloud maintenance mode is enabled. Refusing files:scan." >&2
  exit 1
fi

echo
echo "Running: occ files:scan --all"
sudo -u "$WEBUSER" "$PHP" "$OCC" files:scan --all

echo
echo "Nextcloud files scan completed successfully"
echo "===== $(date -Is) finished Nextcloud files scan ====="
