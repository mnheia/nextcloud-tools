#!/usr/bin/env bash
set -Eeuo pipefail

NCPATH="${NCPATH:-/var/www/nextcloud}"
HTUSER="${HTUSER:-www-data}"
HTGROUP="${HTGROUP:-www-data}"
ROOTUSER="${ROOTUSER:-root}"
LOCK="${LOCK:-/run/lock/set-permissions-nextcloud.lock}"

echo "Starting Nextcloud permission reset for: ${NCPATH}"

exec 200>"$LOCK"
flock -n 200 || {
  echo "Another Nextcloud permission reset is already running. Exiting."
  exit 0
}

if [ ! -d "$NCPATH" ]; then
  echo "ERROR: Nextcloud path does not exist: $NCPATH" >&2
  exit 1
fi

if [ ! -f "$NCPATH/config/config.php" ]; then
  echo "ERROR: Nextcloud config.php not found: $NCPATH/config/config.php" >&2
  echo "Refusing to continue, because this may be the wrong host or wrong path." >&2
  exit 1
fi

if ! id "$HTUSER" >/dev/null 2>&1; then
  echo "ERROR: user does not exist: $HTUSER" >&2
  exit 1
fi

if ! getent group "$HTGROUP" >/dev/null 2>&1; then
  echo "ERROR: group does not exist: $HTGROUP" >&2
  exit 1
fi

echo "Creating possible missing directories"
mkdir -p "$NCPATH/data"
mkdir -p "$NCPATH/updater"

echo "Setting file permissions to 0640"
find "$NCPATH" -type f -print0 | xargs -0 -r chmod 0640

echo "Setting directory permissions to 0750"
find "$NCPATH" -type d -print0 | xargs -0 -r chmod 0750

echo "Setting base ownership"
chown -R "${ROOTUSER}:${HTGROUP}" "$NCPATH"

echo "Setting writable Nextcloud directories"
for dir in   "$NCPATH/apps"   "$NCPATH/config"   "$NCPATH/data"   "$NCPATH/themes"   "$NCPATH/updater"
do
  if [ -d "$dir" ]; then
    chown -R "${HTUSER}:${HTGROUP}" "$dir"
  else
    echo "WARN: directory not found, skipping: $dir"
  fi
done

if [ -f "$NCPATH/occ" ]; then
  echo "Making occ executable"
  chmod 0750 "$NCPATH/occ"
  chown "${ROOTUSER}:${HTGROUP}" "$NCPATH/occ"
else
  echo "WARN: occ not found: $NCPATH/occ"
fi

echo "Fixing .htaccess files"

if [ -f "$NCPATH/.htaccess" ]; then
  chmod 0644 "$NCPATH/.htaccess"
  chown "${ROOTUSER}:${HTGROUP}" "$NCPATH/.htaccess"
fi

if [ -f "$NCPATH/data/.htaccess" ]; then
  chmod 0644 "$NCPATH/data/.htaccess"
  chown "${ROOTUSER}:${HTGROUP}" "$NCPATH/data/.htaccess"
fi

echo "Nextcloud permission reset completed successfully"
