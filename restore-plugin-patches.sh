#!/usr/bin/env bash
# Re-apply the local patches to G0JKN's AetherSDR Controller plugin for Ulanzi Studio.
#
# WHY THIS EXISTS
#   A plugin update from upstream overwrites the plugin directory and wipes
#   node_modules.  Every one of the fifteen plugin fixes below then reverts, and the
#   symptom is a controller that looks completely dead — the profile still
#   looks correct, the buttons just do nothing.  Run this after any update.
#
# WHAT IT RESTORES  (see HANDOVER.md for the full story on each)
#   1. TCI port 40001 -> 50001 (AetherSDR's actual default)
#   2. npm dependencies (`ws`) — upstream ships no node_modules
#   3. setSettings() persistence + $UD.connect() in both inspectors
#   4. Valid AetherSDR mode tokens (usb/lsb/cwr/digu, lowercase)
#   5. Band stacking + band defaults off the band edges
#   6. mute:<rx>,<bool> receiver index; malformed `if:` slice command removed
#   7. TUNE toggle state read from p[1], not the receiver index — it could
#      start a tune cycle but never stop one (and tune keys the transmitter)
#   8. AF/Mic Gain send volume:<db> and mic_level:<percent>.  NOT a bug fix —
#      the original volume:0,<v> / mic_level:0,<v> also work (probed 2026-09-07:
#      AE ignores a leading index, takes the last field).  Kept for the dB scale
#   9. Dial tuned the RX VFO under split — cmdSetFreq() hardcoded channel 0.
#      Split now steers the knob to VFO B (vfo:<rx>,1), and split_enable is
#      parsed with the sliceIndex filter the other verbs already had
#  10. Split was a blind toggle on a mirror AE never confirmed; once out of step
#      the dial drove the wrong VFO forever.  Now query-then-act, like TUNE
#  11. Split parks the TX slice 1 kHz up on CW / 5 kHz on SSB, and survives AE
#      resetting VFO B to VFO A twice on enable
#  12. Mode cycle listed `cwr` but AE reports `cw`, so it could never leave CW.
#      Now CW / USB / DIGU / LSB
#  13. Mute was per-receiver; now masters every open slice via trx_count
#  14. Knob press is fast/slow tune step, not VFO A/B swap (swap trades RX and
#      TX under split).  Needs press_action=step_toggle in the profile
#  15. Dial snaps to the step grid — tuning was a pure increment, so an off-grid
#      VFO kept its offset forever and never reached a 100 Hz / 1 kHz boundary.
#      Also corrects the `vfo` tooltip, stale since patches 9 and 14
#
# Usage:  ./restore-plugin-patches.sh [--check]
#         --check  report status only, change nothing

set -euo pipefail

PLUGIN="$HOME/Library/Application Support/Ulanzi/UlanziDeck/Plugins/com.g0jkn.aethersdr.ulanziPlugin"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/patched"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

[[ -d "$PLUGIN" ]] || { red "Plugin not found: $PLUGIN"; exit 1; }
[[ -d "$SRC"    ]] || { red "Patched sources not found: $SRC"; exit 1; }

# --- Refuse to clobber a plugin while Studio is running: it rewrites files on exit.
if pgrep -f "Ulanzi Studio.app/Contents/MacOS/UlanziDeck" >/dev/null 2>&1; then
  ylw "Ulanzi Studio is running. Quit it first — it rewrites plugin state on exit."
  [[ $CHECK_ONLY -eq 0 ]] && exit 1
fi

# --- Version guard: our patches were written against a specific upstream release.
BASE="$(cat "$SRC/BASED-ON-VERSION" 2>/dev/null || echo unknown)"
NOW="$(python3 -c "import json;print(json.load(open('$PLUGIN/manifest.json'))['Version'])" 2>/dev/null || echo unknown)"
echo "upstream base: $BASE   installed: $NOW"
if [[ "$NOW" != "$BASE" ]]; then
  ylw "Version differs — upstream may have changed these files."
  ylw "Review the diffs before trusting a blind overwrite:"
  ylw "  diff -u \"$PLUGIN/plugin/app.js\" \"$SRC/plugin/app.js\""
  [[ $CHECK_ONLY -eq 0 ]] && { read -r -p "Overwrite anyway? [y/N] " a; [[ "$a" == [yY] ]] || exit 1; }
fi

FILES=(
  "plugin/app.js"
  "manifest.json"
  "property-inspector/vfo/inspector.html"
  "property-inspector/keypad/inspector.html"
)

if [[ $CHECK_ONLY -eq 1 ]]; then
  for f in "${FILES[@]}"; do
    if cmp -s "$SRC/$f" "$PLUGIN/$f"; then grn "  in sync   $f"; else red "  DIFFERS   $f"; fi
  done
  if [[ -d "$PLUGIN/node_modules/ws" ]]; then grn "  present   node_modules/ws"; else red "  MISSING   node_modules/ws"; fi
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BK="$HERE/backups/$STAMP"
mkdir -p "$BK"
for f in "${FILES[@]}"; do
  mkdir -p "$BK/$(dirname "$f")"
  [[ -f "$PLUGIN/$f" ]] && cp "$PLUGIN/$f" "$BK/$f"
  mkdir -p "$PLUGIN/$(dirname "$f")"
  cp "$SRC/$f" "$PLUGIN/$f"
  echo "  restored  $f"
done
echo "  backup of what was there: $BK"

# --- Dependencies.  Upstream ships package.json + lock but no node_modules,
#     and `import WebSocket from 'ws'` kills the plugin instantly without it.
if [[ ! -d "$PLUGIN/node_modules/ws" ]]; then
  echo "  installing npm deps..."
  ( cd "$PLUGIN" && npm ci --omit=dev >/dev/null 2>&1 ) \
    && echo "  installed  ws" \
    || { red "  npm ci FAILED — run manually: cd '$PLUGIN' && npm ci --omit=dev"; exit 1; }
else
  echo "  deps ok    node_modules/ws present"
fi

# --- Verify before declaring success.
node --check "$PLUGIN/plugin/app.js" || { red "app.js FAILED syntax check"; exit 1; }
python3 - "$PLUGIN" <<'PY' || exit 1
import sys, json, pathlib
P = pathlib.Path(sys.argv[1])
m = json.loads((P/"manifest.json").read_text()); src = (P/"plugin"/"app.js").read_text()
bad = [a['Name'] for a in m['Actions']
       if f"${{PLUGIN_UUID}}.{a['UUID'].split('.')[-1]}`" not in src]
if bad: print("  UNHANDLED ACTIONS:", bad); sys.exit(1)
print(f"  verified   {len(m['Actions'])} actions, all handled")
if "50001" not in src: print("  WARNING: TCI port 50001 not found in app.js"); sys.exit(1)
print("  verified   TCI port 50001")
PY

grn "Done. Start Ulanzi Studio."
