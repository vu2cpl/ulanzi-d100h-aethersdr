#!/usr/bin/env bash
# install.sh — install the D100H → AetherSDR bundle on this Mac.
#
# Runs from inside the unzipped bundle:
#
#     cd ~/Downloads/d100h-aethersdr-macbook && ./install.sh
#
# It automates INSTALL.md steps 1 and 2 and the step-5 verification. Steps 3
# (AetherSDR's TCI server) and 4 (selecting the profile in Studio) are GUI work
# inside those two apps and stay manual — read INSTALL.md for them.
#
# macOS ONLY, deliberately.
#   The shack rule is that an install script branches macOS vs Raspberry Pi.
#   There is no Pi branch to write here: Ulanzi Studio ships no Linux or ARM
#   build, and AetherSDR is a macOS application. Both ends of this bundle are
#   Mac-only, so the script detects the platform and stops with that reason
#   rather than implying a path that does not exist.
#
# Nothing is deleted. Anything already installed is MOVED aside into a
# timestamped folder next to this script, and the script prints where.
#
#   ./install.sh            install, prompting before it quits Ulanzi Studio
#   ./install.sh --check    report what is installed now; change nothing
#   ./install.sh --yes      no prompts (quits Studio without asking)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UD="$HOME/Library/Application Support/Ulanzi/UlanziDeck"
PLUGIN_NAME="com.g0jkn.aethersdr.ulanziPlugin"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

CHECK_ONLY=0; ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) red "unknown option: $a"; exit 1 ;;
  esac
done

# --- Platform. See the macOS-ONLY note in the header.
if [[ "$(uname -s)" != "Darwin" ]]; then
  red "This bundle installs into Ulanzi Studio and drives AetherSDR."
  red "Both are macOS-only applications — there is no Linux or Raspberry Pi"
  red "build of either, so there is nothing for this script to install here."
  exit 1
fi

# --- What we are shipping.
SRC_PLUGIN="$HERE/$PLUGIN_NAME"
SRC_PROFILE="$(ls -d "$HERE"/*.ulanziProfile 2>/dev/null | head -1 || true)"
[[ -d "$SRC_PLUGIN" ]]  || { red "Bundle incomplete: no $PLUGIN_NAME beside this script."; exit 1; }
[[ -n "$SRC_PROFILE" ]] || { red "Bundle incomplete: no .ulanziProfile beside this script."; exit 1; }
PROFILE_NAME="$(basename "$SRC_PROFILE")"

# node_modules is the difference between a working plugin and a controller that
# looks dead: without `ws`, app.js throws at import and no plugin process ever
# starts. It is bundled precisely so the target Mac needs no npm — so its
# absence means a broken bundle, not a step to run.
[[ -d "$SRC_PLUGIN/node_modules/ws" ]] || {
  red "Bundle incomplete: $PLUGIN_NAME/node_modules/ws is missing."
  red "Without it the plugin dies at startup and no plugin process appears."
  red "Re-download the zip — unzipping with a tool that drops dotfiles or"
  red "nested folders is the usual cause."
  exit 1
}

DEST_PLUGIN="$UD/Plugins/$PLUGIN_NAME"
DEST_PROFILE="$UD/ProfilesV2/$PROFILE_NAME"

report() {
  echo "Ulanzi support dir: $UD"
  [[ -d "$UD" ]] || { ylw "  not present — is Ulanzi Studio installed and launched once?"; return; }
  if [[ -d "$DEST_PLUGIN" ]]; then
    grn "  installed  plugin  $PLUGIN_NAME"
    [[ -d "$DEST_PLUGIN/node_modules/ws" ]] && grn "  present    node_modules/ws" || red "  MISSING    node_modules/ws"
    if diff -r -x '.DS_Store' "$SRC_PLUGIN" "$DEST_PLUGIN" >/dev/null 2>&1; then
      grn "  matches    this bundle"
    else
      ylw "  DIFFERS    from this bundle (upstream update, or local edits)"
    fi
  else
    ylw "  absent     plugin  $PLUGIN_NAME"
  fi
  if [[ -d "$DEST_PROFILE" ]]; then
    grn "  installed  profile $PROFILE_NAME"
  else
    ylw "  absent     profile $PROFILE_NAME"
  fi
}

if [[ $CHECK_ONLY -eq 1 ]]; then report; exit 0; fi

# --- Ulanzi Studio must be quit, not just closed: it rewrites plugin and
#     profile state on exit and will overwrite whatever we copy in.
if pgrep -f "Ulanzi Studio.app/Contents/MacOS/UlanziDeck" >/dev/null 2>&1; then
  if [[ $ASSUME_YES -eq 0 ]]; then
    ylw "Ulanzi Studio is running. It rewrites plugin and profile state on exit,"
    ylw "so it has to be quit before anything is copied in."
    read -r -p "Quit Ulanzi Studio now? [y/N] " a
    [[ "$a" == [yY] ]] || { red "Aborted — nothing was changed."; exit 1; }
  fi
  osascript -e 'quit app "Ulanzi Studio"' >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do
    pgrep -f "Ulanzi Studio.app/Contents/MacOS/UlanziDeck" >/dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -f "Ulanzi Studio.app/Contents/MacOS/UlanziDeck" >/dev/null 2>&1; then
    red "Ulanzi Studio is still running — quit it by hand (Cmd-Q) and re-run."
    exit 1
  fi
  grn "Ulanzi Studio quit"
fi

mkdir -p "$UD/Plugins" "$UD/ProfilesV2"

# --- Move anything already there aside. Never delete: a previous install may
#     hold per-action settings (step_hz, tci_url) that only exist in that copy.
BK="$HERE/replaced-$(date +%Y%m%d-%H%M%S)"
saved=0
for d in "$DEST_PLUGIN" "$DEST_PROFILE"; do
  [[ -e "$d" ]] || continue
  mkdir -p "$BK"; mv "$d" "$BK/"; saved=1
  echo "  moved aside  $(basename "$d")"
done
[[ $saved -eq 1 ]] && echo "  previous install kept at: $BK"

cp -R "$SRC_PLUGIN"  "$UD/Plugins/"
cp -R "$SRC_PROFILE" "$UD/ProfilesV2/"
grn "installed plugin and profile"

# --- Verify before claiming success.
[[ -d "$DEST_PLUGIN/node_modules/ws" ]] || { red "node_modules/ws did not copy — plugin will not start."; exit 1; }

# Studio ships its own Node; a system node is only used here if one happens to
# exist, purely to syntax-check what we copied.
if command -v node >/dev/null 2>&1; then
  node --check "$DEST_PLUGIN/plugin/app.js" >/dev/null \
    && grn "verified   app.js parses" \
    || { red "app.js FAILED syntax check — the copy is corrupt."; exit 1; }
fi

python3 - "$DEST_PLUGIN" <<'PY' || exit 1
import sys, json, pathlib
P = pathlib.Path(sys.argv[1])
m = json.loads((P/"manifest.json").read_text()); src = (P/"plugin"/"app.js").read_text()
bad = [a['Name'] for a in m['Actions']
       if f"${{PLUGIN_UUID}}.{a['UUID'].split('.')[-1]}`" not in src]
if bad:
    print("  UNHANDLED ACTIONS:", bad); sys.exit(1)
print(f"  verified   {len(m['Actions'])} actions, all handled")
if "50001" not in src:
    print("  WARNING: TCI port 50001 not found in app.js"); sys.exit(1)
print("  verified   TCI port 50001")
PY

# --- AetherSDR's TCI server is the other half; report, don't fail on it.
echo
if lsof -nP -iTCP:50001 -sTCP:LISTEN >/dev/null 2>&1; then
  grn "AetherSDR TCI server is listening on 50001"
else
  ylw "Nothing is listening on TCI port 50001 yet."
  ylw "In AetherSDR, open the TCI tile in the applet tray and start the server"
  ylw "(turn on 'Autostart TCI with AetherSDR'). See INSTALL.md step 3."
fi

# Pairing is what binds the profile: the profile references the D100H by the
# device UUID the dial itself supplies.
if ioreg -c IOHIDDevice -r -l 2>/dev/null | grep -q '"Product" = "Ulanzi Dial"'; then
  grn "D100H is paired and present over Bluetooth"
else
  ylw "The D100H is not showing on Bluetooth. Pair it BEFORE launching Studio,"
  ylw "or the profile will not bind to the device."
fi

echo
grn "Done. Start Ulanzi Studio and select the profile 'AetherSDR D100H controler'."
echo "  Then turn the knob — AetherSDR's VFO should follow."
echo "  Layout, settings and troubleshooting: INSTALL.md"
