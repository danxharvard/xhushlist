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
# The published list is one domain per line; this script adds the 0.0.0.0 for the hosts file.
#
# Don't edit this file by hand on GitHub: publish changes with scripts/release.py,
# which sets the version and signs it. Unsigned changes are rejected by every device.
#
# Everything runs from main() on the last line, so a download that is cut short runs nothing.

HUSHLIST_VERSION=4

# BEGIN SIGNING KEY (written by scripts/release.py keygen)
PUBKEY='-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAubfJxkBNrz9SkH30P9G2
isgJCDb7j2MLB2v1b1lXbt6nt2rRZzJ/K7TgApUmrXfCCa3AAXNyHzcomVUFEdUl
c0GH3GM4J7Onq88rjfHewv0zPtj/BHhhUivnt9AsvSauBVHDKVKh09a5zSEb06y9
5oOquu5Gxdq1CqlH3UPNKwxxw9aynecGJBJ8Sm6DJY9h2cuIcNu9BVAatm8ArdLq
Li5QsVuL18V3pZTJcDzoQcsT8FwKDqZNqIeiV1h7hIeRz83CEDzBokNWB9LTkuIz
dHsLx4sbHYh8tNx/R29bJtaxddE2V6ms5AGwwePoYIbF9jfyOHwXU1mQtaGdH876
S4inWgOzH9vGZbFWwsZzrRu46ocg+Eouhzl1wsiXENYps6vviumnjrYR9WC0cCh4
vtLJntL92Apbdpl9ux31VoioBG2SQwDhqkY5PKBAXDFH1hWubHLFsv5tCgMr4muP
pW05YT/hQfQtLj3tMZiT6elWWANK3d+F7x5/Df55u5MzAgMBAAE=
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
# Every download has a time limit, so a stalled connection can never hang the hourly job.
CURL_OPTS=(--retry 3 --connect-timeout 20 --max-time 300)
LOCK="$HOSTS.hushlist-lock"
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
  $SUDO curl -fsSL "${CURL_OPTS[@]}" "$SCRIPT_URL?$(bust)" -o "$1" 2>/dev/null || return 1
  $SUDO curl -fsSL "${CURL_OPTS[@]}" "$SCRIPT_URL.sig?$(bust)" -o "$1.sig" 2>/dev/null || return 1
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

# Turn the downloaded list into hosts lines. Accepts plain domains or hosts lines, skips
# comments, lowercases, drops anything that isn't a valid domain name, and removes duplicates.
to_hosts_lines() {
  tr -d '\r' < "$1" | awk '
    /^[[:space:]]*($|#|!)/ { next }
    {
      if (NF >= 2 && ($1 == "0.0.0.0" || $1 == "127.0.0.1")) d = $2
      else if (NF == 1) d = $1
      else next
      d = tolower(d)
      if (length(d) > 253) next
      if (d !~ /^[a-z0-9_]([a-z0-9_-]*[a-z0-9])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9])?)+$/) next
      if (seen[d]++) next
      print "0.0.0.0 " d
    }'
}

# One run at a time (the hourly job and a manual install could otherwise overlap).
# A lock older than 30 minutes is left over from a crash and is cleared.
take_lock() {
  if $SUDO mkdir "$LOCK" 2>/dev/null; then return 0; fi
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    $SUDO rm -rf "$LOCK"
    $SUDO mkdir "$LOCK" 2>/dev/null && return 0
  fi
  return 1
}

# Keep the background job's error log small.
trim_log() {
  local f="$APP_DIR/update.log"
  if [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 100000 ]; then
    tail -n 200 "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  fi
}

# ---------- How the installer looks: banner and animated progress ----------
# Only when someone is watching in a terminal; hourly runs and piped output stay plain.
FANCY=0
SPIN_PID=""
SPIN_TITLE="Installing, please wait"
setup_ui() {
  if [ "$MODE" != "--update" ] && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "$HUSHLIST_PLAIN" ]; then FANCY=1; fi
  if [ "$MODE" = "--uninstall" ]; then SPIN_TITLE="Removing, please wait"; fi
}

# Five-row letter shapes; every 1 becomes a random digit.
glyph() {
  case "$1$2" in
    H0|H1|H3|H4|U0|U1|U2|U3) G="1   1" ;;
    H2|L4|I0|I4|T0) G="11111" ;;
    U4|S2) G=" 111 " ;;
    S0) G=" 1111" ;;
    S1|L0|L1|L2|L3) G="1    " ;;
    S3) G="    1" ;;
    S4) G="1111 " ;;
    I1|I2|I3|T1|T2|T3|T4) G="  1  " ;;
  esac
}

banner() {
  if [ "$FANCY" != 1 ]; then say "Hushlist for Mac (version $HUSHLIST_VERSION)"; return; fi
  local word="HUSHLIST" r i j f row line ch
  local -a pattern colours
  colours=(51 45 39 33 27)
  for r in 0 1 2 3 4; do
    row=""
    for ((i = 0; i < ${#word}; i++)); do glyph "${word:i:1}" "$r"; row="$row$G  "; done
    pattern[r]="$row"
  done
  printf '\n\033[?25l'
  # Digits flicker a few times, then settle
  for f in 1 2 3 4 5 6 7; do
    for r in 0 1 2 3 4; do
      line=""; row="${pattern[r]}"
      for ((j = 0; j < ${#row}; j++)); do
        ch="${row:j:1}"
        if [ "$ch" = 1 ]; then line="$line$((RANDOM % 10))"; else line="$line "; fi
      done
      printf '  \033[1;38;5;%sm%s\033[0m\033[K\n' "${colours[r]}" "$line"
    done
    if [ $f -lt 7 ]; then sleep 0.06; printf '\033[5A'; fi
  done
  printf '  \033[38;5;244mQuiet the noise.  \xc2\xb7  Mac installer, version %s\033[0m\n\n\033[?25h' "$HUSHLIST_VERSION"
}

# A spinner, the title with a highlight sweeping across it, and the current step.
spin_start() {
  if [ "$FANCY" != 1 ]; then say "$1..."; return; fi
  local step="$1"
  printf '\033[?25l'
  (
    trap 'exit 0' TERM
    frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    msg="$SPIN_TITLE"; n=${#msg}; i=0
    while :; do
      p=$(( i % (n + 10) ))
      printf '\r\033[K  \033[38;5;45m%s\033[0m  \033[38;5;117m%s\033[1;97m%s\033[0;38;5;117m%s\033[0m   \033[38;5;244m%s\033[0m' \
        "${frames[i % 10]}" "${msg:0:p}" "${msg:p:1}" "${msg:p+1}" "$step"
      i=$((i + 1)); sleep 0.07
    done
  ) &
  SPIN_PID=$!
}
spin_halt() {
  if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null || true; wait "$SPIN_PID" 2>/dev/null || true; SPIN_PID=""; fi
  if [ "$FANCY" = 1 ]; then printf '\r\033[K\033[?25h'; fi
}
spin_done() {   # $1 = what was done
  spin_halt
  if [ "$FANCY" = 1 ]; then printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$1"; else say "$1"; fi
}
oops() {        # $1 = what went wrong
  spin_halt
  if [ "$FANCY" = 1 ]; then printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$1"; else echo "$1"; fi
}
fmt_num() { local n="$1" out=""; while [ ${#n} -gt 3 ]; do out=",${n:${#n}-3}$out"; n="${n:0:${#n}-3}"; done; echo "$n$out"; }

main() {
  case "$MODE" in
    --version) echo "$HUSHLIST_VERSION"; exit 0 ;;
    --self-test) self_test; exit $? ;;
  esac

  set -e
  if [ "$(id -u)" -eq 0 ] || [ -n "$HUSHLIST_TEST_DIR" ]; then SUDO=""; else SUDO="sudo"; fi

  if [ "$MODE" = "--update" ]; then trim_log; self_update; fi

  setup_ui
  banner
  if [ -n "$SUDO" ]; then echo "  Your Mac password is needed to change system settings."; sudo -v; echo; fi

  if ! take_lock; then
    oops "Hushlist is already updating on this Mac. Try again in a minute."
    exit 0
  fi
  TMP=$(mktemp)
  trap 'spin_halt; rm -f "$TMP" "$TMP.list" "$TMP.hosts"; $SUDO rm -f "$HOSTS.hushlist-new"; $SUDO rm -rf "$LOCK"' EXIT

  local want="" have=""
  if [ "$MODE" = "--uninstall" ]; then spin_start "removing the blocklist"; else spin_start "downloading the blocklist"; fi
  if [ "$MODE" != "--uninstall" ]; then
    # The list's checksum is tiny: compare it first and skip the 6 MB download when nothing changed.
    want=$(curl -fsS "${CURL_OPTS[@]}" "$LIST_URL.sha256?$(bust)" 2>/dev/null | tr -cd '0-9a-f' | cut -c1-64 || true)
    have=$(cat "$STATE" 2>/dev/null || true)
    if [ "$MODE" = "--update" ] && [ ${#want} -eq 64 ] && [ "$want" = "$have" ] && grep -qF "$BEGIN" "$HOSTS"; then
      spin_halt; exit 0
    fi
  fi

  # Current hosts file without any previous Hushlist block
  $SUDO awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$HOSTS" > "$TMP"

  if [ "$MODE" != "--uninstall" ]; then
    if ! curl -fsSL "${CURL_OPTS[@]}" "$LIST_URL?$(bust)" -o "$TMP.list"; then
      oops "Couldn't download the blocklist. Check your connection and try again."; exit 1
    fi
    if [ ${#want} -eq 64 ] && [ "$(shasum -a 256 "$TMP.list" | cut -c1-64)" != "$want" ]; then
      oops "The download didn't match its checksum (it may be mid-update). Nothing changed."; exit 1
    fi
    spin_done "Downloaded the latest blocklist ($(awk -v b="$(wc -c < "$TMP.list")" 'BEGIN { printf "%.1f", b / 1e6 }') MB)"
    spin_start "checking every domain"
    to_hosts_lines "$TMP.list" > "$TMP.hosts"
    COUNT=$(wc -l < "$TMP.hosts" | tr -d ' ')
    if [ "$COUNT" -lt "$MIN_ENTRIES" ] || [ "$COUNT" -gt "$MAX_ENTRIES" ]; then
      oops "Download looks wrong ($COUNT entries). Nothing changed."; exit 1
    fi
    spin_done "Checked $(fmt_num "$COUNT") domains"
    spin_start "updating your hosts file"
    { echo "$BEGIN"; grep -Ev "$PROTECTED" "$TMP.hosts" || true; echo "$END"; } >> "$TMP"
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
  if [ "$MODE" = "--uninstall" ]; then spin_done "Blocklist removed from your hosts file"
  else spin_done "Hosts file updated (your own entries are untouched)"; fi

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
      spin_done "Hourly updates switched off"
      if [ "$FANCY" = 1 ]; then printf '\n  \033[1;38;5;45mHushlist removed.\033[0m\n'; else echo "Hushlist removed, including hourly updates."; fi
      echo "  Backup of your previous hosts file: $HOSTS.hushlist-backup"
      exit 0 ;;
  esac

  # Install the hourly updater: a signed copy of this script, run by a root launchd job
  spin_start "switching on hourly updates"
  $SUDO mkdir -p "$APP_DIR"
  local rc=0
  fetch_signed "$APP_DIR/update.new" || rc=$?
  if [ $rc -ne 0 ]; then
    $SUDO rm -f "$APP_DIR/update.new" "$APP_DIR/update.new.sig"
    if [ $rc -eq 2 ]; then oops "The updater download isn't signed with the Hushlist key, so it wasn't installed."
    else oops "Couldn't download the updater. Check your connection and try again."; fi
    echo "  Your blocklist is in place, but it won't update by itself until you run this installer again."
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

  spin_done "Hourly updates switched on"
  if [ "$FANCY" = 1 ]; then
    printf '\n  \033[1;38;5;45mDone.\033[0m Hushlist is blocking \033[1m%s\033[0m domains on this Mac.\n' "$(fmt_num "$COUNT")"
    printf '  \033[38;5;244mIt checks for list and app updates every hour. Backup of your old hosts file:\n  %s\033[0m\n\n' "$HOSTS.hushlist-backup"
  else
    echo "Done. Blocking $COUNT domains. Hushlist checks for list and app updates every hour."
    echo "Backup of your previous hosts file: $HOSTS.hushlist-backup"
  fi
}

main "$@"
