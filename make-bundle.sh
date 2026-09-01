#!/usr/bin/env bash
# Build the self-contained install bundle for another Mac.
#
# Produces ~/Downloads/d100h-aethersdr-macbook.zip containing:
#   - the patched plugin, with node_modules bundled (target Mac needs no npm;
#     Ulanzi Studio ships its own Node runtime)
#   - the D100H profile from profile/
#   - INSTALL.md
#   - tci-probe.sh
#
# The plugin is assembled from the INSTALLED copy rather than from patched/,
# because patched/ holds only the four files we modify — the rest of the plugin
# (libs/, assets/, en.json, package.json) is G0JKN's and is deliberately not
# vendored into this repo. The script refuses to build unless the installed
# copy matches patched/ exactly, so a stale or reverted install can't ship.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$HOME/Library/Application Support/Ulanzi/UlanziDeck/Plugins/com.g0jkn.aethersdr.ulanziPlugin"
OUT="${1:-$HOME/Downloads/d100h-aethersdr-macbook}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }

[[ -d "$PLUGIN" ]] || { red "Plugin not installed: $PLUGIN"; exit 1; }

# Refuse to ship an install that has drifted from the known-good patches.
for f in plugin/app.js manifest.json \
         property-inspector/vfo/inspector.html \
         property-inspector/keypad/inspector.html; do
  cmp -s "$HERE/patched/$f" "$PLUGIN/$f" || {
    red "Installed plugin differs from patched/ at: $f"
    red "Run ./restore-plugin-patches.sh first, or refresh patched/ if the"
    red "installed copy is the newer one. Refusing to bundle a mismatch."
    exit 1
  }
done
grn "installed plugin matches patched/"

[[ -d "$PLUGIN/node_modules/ws" ]] || {
  echo "installing deps so the bundle is self-contained..."
  ( cd "$PLUGIN" && npm ci --omit=dev >/dev/null 2>&1 ) || { red "npm ci failed"; exit 1; }
}

rm -rf "$OUT"; mkdir -p "$OUT"
rsync -a --exclude '.DS_Store' "$PLUGIN" "$OUT/"
rsync -a --exclude '.DS_Store' "$HERE/profile/"*.ulanziProfile "$OUT/"
cp "$HERE/INSTALL.md" "$OUT/"
cp "$HERE/tci-probe.sh" "$OUT/"          # safe TCI probe — see INSTALL.md troubleshooting

ZIP="$OUT.zip"; rm -f "$ZIP"
( cd "$(dirname "$OUT")" && zip -qr "$(basename "$ZIP")" "$(basename "$OUT")" -x "*.DS_Store" )
unzip -qt "$ZIP" >/dev/null || { red "zip failed integrity check"; exit 1; }

grn "built $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  plugin actions: $(python3 -c "import json;print(len(json.load(open('$OUT/com.g0jkn.aethersdr.ulanziPlugin/manifest.json'))['Actions']))")"
echo "  node_modules:   $([ -d "$OUT/com.g0jkn.aethersdr.ulanziPlugin/node_modules/ws" ] && echo bundled || echo MISSING)"
echo "  profile:        $(basename "$(ls -d "$OUT"/*.ulanziProfile)")"
