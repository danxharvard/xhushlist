#!/bin/bash
# Hushlist for macOS
#   Install / update:  curl -fsSL https://hushlist.online/install/hushlist-mac.command | bash
#   Uninstall:         curl -fsSL https://hushlist.online/install/hushlist-mac.command | bash -s -- --uninstall
#   Show version:      bash "/Library/Application Support/Hushlist/update.sh" --version
#
# Adds the blocklist to /etc/hosts between Hushlist markers (your own entries are left alone)
# and installs a background job that runs every hour to:
#   1. install a newer version of this script, but only if it is signed with the Hushlist key
#   2. refresh the blocklist, downloading it only when it has changed
#
# Don't edit this file by hand on GitHub: publish changes with scripts/release.py,
# which sets the version and signs it. Unsigned changes are rejected by every device.
#
# Everything runs from main() on the last line, so a download that is cut short runs nothing.

HUSHLIST_VERSION=2

# BEGIN SIGNING KEY (written by scripts/release.py keygen)
PUBKEY='-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAqzSpzSgrdFTXKGeywDta
D8xLoMj78Q2moYu2y0zef0jiBNdm8iZNHQDxf0H56zu96bCBLpm9LxRIrpqlX26h
B9Aby1l5SmY3Tq9mlYZegC4rOSaT7nUxueZU+AMbZTyGJkaaTWaAlHYV8GNHRVho
i5lYWcVt4ln4+K/aVwN+Q8jwRS5r6aqo+jVRgIm9ZuGBZWD6hQeH6HvhRkYWUdNa
8IdWm+nnjOMTCVF23jbTJ1usrGiL0Y31Ekp07vPh+9C2AL2f1Eya/WWKE5i0fMrt
TFougeBL644Oc29xMYqMunFqbF+w/oeao4Jl2rNb8bJ9lPhPhbe4Dp7R2It206+W
SCUBRJHW5RvDaV2qr48+sAkv8GW7Gmie/AomcvCOUSYiVyEg+cHxVU8RTByBKQW9
zrMh1LBz7yZzNgTvuEELBBVZsoYt0drkjrOI3c+iedIA6SdZhgLfoFEF6bJqWoMj
nymEM2vBEzOmcT1BSW5KlD5xjKRoqSN6yWcflm8WHUCNAgMBAAE=
-----END PUBLIC KEY-----'
# END SIGNING KEY

SITE="https://hushlist.online/"
APP_DIR="/Library/Application Support/Hushlist"
PLIST="/Library/LaunchDaemons/com.hushlist.update.plist"
HOSTS="/etc/hosts"
if [ -n "$HUSHLIST_TEST_DIR" ]; then   # testing only: work inside a scratch folder, no sudo, no launchd
  SITE="${HUSHLIST_TEST_SITE:-$SITE}"; APP_DIR="$HUSHLIST_TEST_DIR/app"; HOSTS="$HUSHLIST_TEST_DIR/hosts"
fi
LIST_URL="${SITE}lists/hushlist.txt"
SCRIPT_URL="${SITE}install/hushlist-mac.command"
STATE="$APP_DIR/list.sha256"
LABEL="com.hushlist.update"
BEGIN="# >>> Hushlist BEGIN (managed, do not edit) >>>"
END="# <<< Hushlist END <<<"
MIN_ENTRIES=1000
MAX_ENTRIES=3000000
# Never block these, whatever the list says: the update server and names the system relies on.
PROTECTED='^0\.0\.0\.0[[:space:]]+(hushlist\.online|www\.hushlist\.online|localhost|localhost\.localdomain|local|broadcasthost|ip6-localhost|ip6-loopback)[[:space:]]*$'
MODE="${1:-install}"   # install | --update | --uninstall | --version | --self-test

say() { if [ "$MODE" != "--update" ]; then echo "$@"; fi; }
log() { logger -t hushlist "$*" 2>/dev/null || true; }
bust() { echo "v=$(date +%s)"; }

# Check that file $1 matches the base64 signature in file $2, using the key above.
verify() {
  local dir ok=1
  [ -n "$PUBKEY" ] || return 1
  dir=$(mktemp -d) || return 1
  printf '%s\n' "$PUBKEY" > "$dir/key.pem"
  if openssl base64 -d -A -in "$2" -out "$dir/sig" 2>/dev/null \
     && openssl dgst -sha256 -verify "$dir/key.pem" -signature "$dir/sig" "$1" >/dev/null 2>&1; then ok=0; fi
  rm -rf "$dir"
  return $ok
}

# Download the published script and its signature to $1 and $1.sig (as root, so nothing else
# can swap the file between checking and installing it).
# Returns 0 if signed correctly, 1 if the download failed, 2 if the signature is wrong.
fetch_signed() {
  $SUDO rm -f "$1" "$1.sig"
  $SUDO curl -fsSL --retry 3 "$SCRIPT_URL?$(bust)" -o "$1" 2>/dev/null || return 1
  $SUDO curl -fsSL --retry 3 "$SCRIPT_URL.sig?$(bust)" -o "$1.sig" 2>/dev/null || return 1
  verify "$1" "$1.sig" || return 2
}

# Run by a candidate update before it is installed: it must be able to check its own
# signature with its own key (so it can still accept the update after it) and find its tools.
self_test() {
  local t
  for t in curl openssl awk cmp shasum logger mktemp; do command -v "$t" >/dev/null 2>&1 || return 1; done
  verify "$0" "$0.sig" || return 1
  echo "$HUSHLIST_VERSION"
}

# Install a newer signed version of this script, then carry on with it.
self_update() {
  if [ -n "$HUSHLIST_JUST_UPDATED" ]; then return 0; fi
  local new="$APP_DIR/update.new" rc=0 v out
  fetch_signed "$new" || rc=$?
  if [ $rc -ne 0 ]; then
    if [ $rc -eq 2 ]; then log "Ignored an update that isn't signed with the Hushlist key."; fi
    rm -f "$new" "$new.sig"; return 0
  fi
  v=$(sed -n 's/^HUSHLIST_VERSION=\([0-9][0-9]*\)$/\1/p' "$new" | head -n 1)
  if [ -z "$v" ] || [ "$v" -le "$HUSHLIST_VERSION" ]; then rm -f "$new" "$new.sig"; return 0; fi
  if ! /bin/bash -n "$new" 2>/dev/null; then
    log "Ignored version $v: it failed a syntax check."; rm -f "$new" "$new.sig"; return 0
  fi
  out=$(/bin/bash "$new" --self-test 2>/dev/null) || out=""
  if [ "$out" != "$v" ]; then
    log "Ignored version $v: it failed its self-test."; rm -f "$new" "$new.sig"; return 0
  fi
  cp -p "$APP_DIR/update.sh" "$APP_DIR/update.prev.sh" 2>/dev/null || true
  chmod 755 "$new"
  mv -f "$new" "$APP_DIR/update.sh"     # rename, so this running copy is left intact
  rm -f "$new.sig"
  log "Updated Hushlist from version $HUSHLIST_VERSION to $v."
  HUSHLIST_JUST_UPDATED=1 exec /bin/bash "$APP_DIR/update.sh" --update
}

# Keep the background job's error log small.
trim_log() {
  local f="$APP_DIR/update.log"
  if [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 100000 ]; then
    tail -n 200 "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  fi
}

main() {
  case "$MODE" in
    --version) echo "$HUSHLIST_VERSION"; exit 0 ;;
    --self-test) self_test; exit $? ;;
  esac

  set -e
  if [ "$(id -u)" -eq 0 ] || [ -n "$HUSHLIST_TEST_DIR" ]; then SUDO=""; else SUDO="sudo"; fi

  if [ "$MODE" = "--update" ]; then trim_log; self_update; fi

  say "Hushlist for Mac (version $HUSHLIST_VERSION)"
  if [ -n "$SUDO" ]; then echo "Your Mac password is needed to change system settings."; sudo -v; fi

  TMP=$(mktemp)
  trap 'rm -f "$TMP" "$TMP.list"' EXIT

  local want="" have=""
  if [ "$MODE" != "--uninstall" ]; then
    # The list's checksum is tiny: compare it first and skip the 6 MB download when nothing changed.
    want=$(curl -fsS --retry 2 "$LIST_URL.sha256?$(bust)" 2>/dev/null | tr -cd '0-9a-f' | cut -c1-64 || true)
    have=$(cat "$STATE" 2>/dev/null || true)
    if [ "$MODE" = "--update" ] && [ ${#want} -eq 64 ] && [ "$want" = "$have" ] && grep -qF "$BEGIN" "$HOSTS"; then
      exit 0
    fi
  fi

  # Current hosts file without any previous Hushlist block
  $SUDO awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$HOSTS" > "$TMP"

  if [ "$MODE" != "--uninstall" ]; then
    say "Downloading blocklist…"
    curl -fsSL --retry 3 "$LIST_URL?$(bust)" -o "$TMP.list"
    if [ ${#want} -eq 64 ] && [ "$(shasum -a 256 "$TMP.list" | cut -c1-64)" != "$want" ]; then
      echo "The download didn't match its checksum (it may be mid-update). Nothing changed."; exit 1
    fi
    COUNT=$(grep -c '^0\.0\.0\.0 ' "$TMP.list" || true)
    if [ "$COUNT" -lt "$MIN_ENTRIES" ] || [ "$COUNT" -gt "$MAX_ENTRIES" ]; then
      echo "Download looks wrong ($COUNT entries). Nothing changed."; exit 1
    fi
    { echo "$BEGIN"; grep '^0\.0\.0\.0 ' "$TMP.list" | grep -Ev "$PROTECTED" || true; echo "$END"; } >> "$TMP"
  fi

  # Only touch the hosts file when something changed
  if ! $SUDO cmp -s "$TMP" "$HOSTS"; then
    if [ "$MODE" != "--update" ]; then $SUDO cp "$HOSTS" "$HOSTS.hushlist-backup"; fi
    # Write a complete copy next to it, then swap it in with one rename, so a crash or
    # power cut can never leave a half-written hosts file.
    $SUDO cp "$TMP" "$HOSTS.hushlist-new"
    $SUDO chmod 644 "$HOSTS.hushlist-new"
    if [ -z "$HUSHLIST_TEST_DIR" ]; then $SUDO chown root:wheel "$HOSTS.hushlist-new"; fi
    $SUDO mv -f "$HOSTS.hushlist-new" "$HOSTS"
    $SUDO dscacheutil -flushcache 2>/dev/null || true
    $SUDO killall -HUP mDNSResponder 2>/dev/null || true
    if [ "$MODE" = "--update" ]; then log "List updated: $COUNT domains."; fi
  fi

  case "$MODE" in
    --update)
      if [ ${#want} -eq 64 ]; then echo "$want" > "$STATE"; fi
      exit 0 ;;
    --uninstall)
      if [ -z "$HUSHLIST_TEST_DIR" ]; then
        $SUDO launchctl bootout system "$PLIST" 2>/dev/null || true
        $SUDO rm -f "$PLIST"
      fi
      $SUDO rm -rf "$APP_DIR"
      echo "Hushlist removed, including hourly updates."
      echo "Backup of your previous hosts file: $HOSTS.hushlist-backup"
      exit 0 ;;
  esac

  # Install the hourly updater: a signed copy of this script, run by a root launchd job
  say "Installing the hourly updater…"
  $SUDO mkdir -p "$APP_DIR"
  local rc=0
  fetch_signed "$APP_DIR/update.new" || rc=$?
  if [ $rc -ne 0 ]; then
    $SUDO rm -f "$APP_DIR/update.new" "$APP_DIR/update.new.sig"
    if [ $rc -eq 2 ]; then echo "The updater download isn't signed with the Hushlist key, so it wasn't installed."
    else echo "Couldn't download the updater. Check your connection and try again."; fi
    echo "Your blocklist is in place, but it won't update by itself until you run this installer again."
    exit 1
  fi
  $SUDO chmod 755 "$APP_DIR/update.new"
  $SUDO mv -f "$APP_DIR/update.new" "$APP_DIR/update.sh"
  $SUDO rm -f "$APP_DIR/update.new.sig"
  if [ ${#want} -eq 64 ]; then echo "$want" | $SUDO tee "$STATE" > /dev/null; fi

  if [ -z "$HUSHLIST_TEST_DIR" ]; then
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
  fi

  echo "Done. Blocking $COUNT domains. Hushlist checks for list and app updates every hour."
  echo "Backup of your previous hosts file: $HOSTS.hushlist-backup"
}

main "$@"
