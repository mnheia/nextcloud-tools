Copyright (c) 2026, Mnheia <mnheia@gmail.com>

# nextcloud-tools
Bash utilities for Nextcloud maintenance, updates, permissions, file reindexing and Apache/Nextcloud log auditing.

## Scripts

### update-nextcloud.sh
Interactive Nextcloud server updater for Debian/Ubuntu style installations.

The script:

- checks for a Nextcloud server update before doing anything disruptive
- exits cleanly when no server update is available
- performs preflight checks
- creates database and application backups
- handles maintenance mode
- temporarily adjusts permissions for the built-in updater
- runs `updater.phar` and `occ upgrade`
- runs optional database and repair maintenance
- checks core integrity and setup checks
- optionally restores a custom theme
- restores the configured permission model
- restarts or reloads the configured web service

By default it expects Nextcloud in `/var/www/nextcloud`, Apache as the web service and `www-data` as the web user/group. These can be overridden with environment variables.

Example:

```bash
sudo env NC_DIR=/var/www/nextcloud BACKUP_BASE=/var/backups/nextcloud ./update-nextcloud.sh
```

A custom theme is disabled by default. Enable it only when needed:

```bash
sudo env CUSTOM_THEME_NAME=mytheme ./update-nextcloud.sh
```

The updater checks `occ update:check` before creating a backup directory or enabling maintenance mode. If no Nextcloud server update is reported, it exits without running the update procedure.

**Important:** this is an administrative update script that changes files, ownership, database state and service state. Read the configuration section near the top before using it. Test it against your own Nextcloud layout and backup strategy first.

### reindex-nextcloud.sh
Runs `occ files:scan --all` after validating the Nextcloud path, PHP binary, web user and maintenance-mode state.

```bash
sudo env NCPATH=/var/www/nextcloud ./reindex-nextcloud.sh
```

### set-permissions-nextcloud.sh
Resets a specific Nextcloud permission model with root-owned core files and web-server-owned writable directories.

```bash
sudo env NCPATH=/var/www/nextcloud ./set-permissions-nextcloud.sh
```

This is not a universal permission policy. Review the script before running it and make sure the ownership model matches your installation.

### nextcloud-apache-audit.sh
Read-only security and anomaly triage for Apache access/error logs and Nextcloud logs.

It highlights high request volumes, repeated 401/403/404/5xx responses, scanner probes, suspicious methods and user agents, mod_evasive events, Nextcloud authentication failures, security-related application messages, and IPs appearing in both Apache and Nextcloud failure data.

```bash
./nextcloud-apache-audit.sh /var/log/nextcloud /var/log/apache2
```

Reports use restrictive permissions because they can contain IP addresses, usernames, URLs and security events.

## Requirements
The scripts are Bash-based and primarily intended for Debian/Ubuntu style Nextcloud installations.

Depending on the script, commands used include:

- `php`
- `sudo`
- `rsync`
- `systemctl`
- `flock`
- `jq` for structured Nextcloud audit parsing
- standard GNU/Linux utilities

`update-nextcloud.sh` supports MariaDB/MySQL, PostgreSQL and SQLite database backup handling based on the Nextcloud configuration.

## Security
No credentials are embedded in these public scripts. The updater reads database settings from the local Nextcloud `config.php` only when needed for backup and uses a temporary restricted MySQL/MariaDB client file instead of putting the password on the command line.

Log and report files may still contain operational information. Review them before sharing externally.

## Bugs
Please report bugs or feature requests through the web interface at https://github.com/mnheia/nextcloud-tools/issues
