#!/usr/bin/env bash
# Copies the SQLite database to ~/backups/ega (safe while the app is running)
# and keeps the newest 30 copies.
# Usage: bin/backup.sh
# Daily at 02:15 with cron: 15 2 * * * /opt/yesuko/webapps/ega/bin/backup.sh >/dev/null
set -euo pipefail
cd "$(dirname "$0")/.."

url=$(grep -E '^DATABASE_URL=' .env | cut -d= -f2-)
db=${url#sqlite://}
dir=${EGA_BACKUP_DIR:-$HOME/backups/ega}
mkdir -p "$dir"
chmod 700 "$dir"

out="$dir/ega-$(date +%F-%H%M).sqlite3"
sqlite3 "$db" ".backup '$out'"
chmod 600 "$out"
ls -1t "$dir"/ega-*.sqlite3 | tail -n +31 | xargs -r rm --
echo "Backed up to $out"
