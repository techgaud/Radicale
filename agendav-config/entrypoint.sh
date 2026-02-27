#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
# AgenDAV entrypoint wrapper
#
# Initializes the SQLite schema if needed, then hands off to the original
# run.sh. The DB lives in a persistent mounted volume so it survives restarts.
# ─────────────────────────────────────────────────────────────────────────────

DB_PATH="/var/www/agendav/db/agendav.sqlite"

php -r "
\$db = new PDO('sqlite:$DB_PATH');
\$db->exec('CREATE TABLE IF NOT EXISTS sessions (
    sess_id VARCHAR(128) NOT NULL PRIMARY KEY,
    sess_data BLOB NOT NULL,
    sess_time INTEGER UNSIGNED NOT NULL,
    sess_lifetime INTEGER UNSIGNED NOT NULL
)');
\$db->exec('CREATE TABLE IF NOT EXISTS prefs (
    username VARCHAR(255) NOT NULL PRIMARY KEY,
    options LONGTEXT NOT NULL
)');
echo 'DB initialized: $DB_PATH' . PHP_EOL;
"

exec /usr/local/bin/run.sh apache2
