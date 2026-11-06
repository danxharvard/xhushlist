#!/bin/bash
# Hushlist for macOS
#   Install / update:  download the script to a temporary file, then run it with bash
#   Uninstall:         download the script to a temporary file, then run it with --uninstall
#
# Adds the blocklist to /etc/hosts between Hushlist markers (your own entries are left alone)
# and installs a background job that refreshes it every hour.

LIST_URL="__SITE_URL__lists/hushlist.txt"
HOSTS="${HUSHLIST_HOSTS:-/etc/hosts}"          # override only for testing
APP_DIR="/Library/Application Support/Hushlist"
PLIST="/Library/LaunchDaemons/com.hushlist.update.plist"
LABEL="com.hushlist.update"
BEGIN="# >>> Hushlist BEGIN (managed, do not edit) >>>"
END="# <<< Hushlist END <<<"
MODE="${1:-install}"   # install | --update | --uninstall
SCRIPT_PATH="${BASH_SOURCE[0]}"

set -e
if [ "$(id -u)" -eq 0 ] || [ -n "$HUSHLIST_HOSTS" ]; then SUDO=""; else SUDO="sudo"; fi
say() { if [ "$MODE" != "--update" ]; then echo "$@"; fi; }

say "Hushlist for Mac"
if [ -n "$SUDO" ]; then echo "Your Mac password is needed to change system settings."; sudo -v; fi

TMP=$(mktemp)
trap 'rm -f "$TMP" "$TMP.list"' EXIT

# Remove only complete, well-formed Hushlist blocks. Refuse to touch hosts if markers are damaged.
if ! $SUDO awk -v b="$BEGIN" -v e="$END" '
  $0==b { if (skip) exit 2; skip=1; next }
  $0==e { if (!skip) exit 2; skip=0; next }
  !skip { print }
  END { if (skip) exit 2 }
' "$HOSTS" > "$TMP"; then
  echo "The hosts file contains an incomplete Hushlist block. Nothing changed."
  exit 1
fi

if [ "$MODE" != "--uninstall" ]; then
  say "Downloading blocklist…"
  curl -fsSL --retry 3 "$LIST_URL" -o "$TMP.list"
  COUNT=$(grep -c '^0\.0\.0\.0 ' "$TMP.list" || true)
  if [ "$COUNT" -lt 1000 ]; then echo "Download looks wrong ($COUNT entries). Nothing changed."; exit 1; fi
  { echo "$BEGIN"; grep '^0\.0\.0\.0 ' "$TMP.list"; echo "$END"; } >> "$TMP"
fi

# Only touch the hosts file when something changed
if ! $SUDO cmp -s "$TMP" "$HOSTS"; then
  if [ "$MODE" != "--update" ]; then $SUDO cp "$HOSTS" "$HOSTS.hushlist-backup"; fi
  $SUDO cp "$TMP" "$HOSTS"
  $SUDO dscacheutil -flushcache 2>/dev/null || true
  $SUDO killall -HUP mDNSResponder 2>/dev/null || true
  if [ "$MODE" = "--update" ]; then logger -t hushlist "Updated: $COUNT domains" || true; fi
fi

case "$MODE" in
  --update)
    exit 0 ;;
  --uninstall)
    $SUDO launchctl bootout system "$PLIST" 2>/dev/null || true
    $SUDO rm -f "$PLIST"
    $SUDO rm -rf "$APP_DIR"
    echo "Hushlist removed, including hourly updates."
    echo "Backup of your previous hosts file: $HOSTS.hushlist-backup"
    exit 0 ;;
esac

# Install the hourly updater (a root launchd job)
$SUDO mkdir -p "$APP_DIR"
if [ ! -f "$SCRIPT_PATH" ]; then
  echo "Cannot locate the installer script to install the local updater."
  exit 1
fi
$SUDO cp "$SCRIPT_PATH" "$APP_DIR/update.sh"
$SUDO chmod 755 "$APP_DIR/update.sh"
$SUDO tee "$PLIST" > /dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$APP_DIR/update.sh</string>
    <string>--update</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$APP_DIR/update.log</string>
</dict>
</plist>
PLIST
$SUDO chown root:wheel "$PLIST"
$SUDO chmod 644 "$PLIST"
$SUDO launchctl bootout system "$PLIST" 2>/dev/null || true
$SUDO launchctl bootstrap system "$PLIST"

echo "Done. Blocking $COUNT domains, and checking for updates every hour."
echo "Backup of your previous hosts file: $HOSTS.hushlist-backup"
