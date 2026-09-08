#!/usr/bin/env bash
# Build the self-contained install bundle for another Mac.
#
# Produces ~/Downloads/d100h-aethersdr-macbook.zip containing:
#   - the patched plugin, with node_modules bundled (target Mac needs no npm;
#     Ulanzi Studio ships its own Node runtime)
#   - the D100H profile from profile/
#   - INSTALL.md and install.sh (the script does steps 1-2 and the step-5 checks)
#   - tci-probe.sh and tci-watch.sh
#   - windows/ — the untested PowerShell port (install + all three diagnostics)
#
# The plugin is assembled from the INSTALLED copy rather than from patched/,
# because patched/ holds only the four files we modify — the rest of the plugin
# (libs/, assets/, en.json, package.json) is G0JKN's and is deliberately not
# vendored into this repo. The script refuses to build unless the installed
# copy matches patched/ exactly, so a stale or reverted install can't ship.
#
# NOTE (2026-09-07): patched/ gained Apache-2.0 section 4(b) modification
# notices when this repo was published, and the installed plugin has not. The
# cmp guard below will therefore refuse to build until you run
# ./restore-plugin-patches.sh (Studio quit) to push the annotated files out to
# the install. That is the guard doing its job, not a bug — but it is expected
# on the first build after publication, so it is written down here.

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

# Refuse to ship a Windows port whose embedded JavaScript has drifted from the
# proven macOS program. windows/*.ps1 carry the tci-probe / tci-watch programs
# copied verbatim, because AE was not running when they were written and an
# unverifiable refactor of the probe is exactly the wrong risk to take with a
# script that stands between the operator and another tx_gain:0 incident.
# Verbatim only stays true if something checks. This is that something.
python3 - "$HERE" <<'PYGUARD' || exit 1
import pathlib, sys
here = pathlib.Path(sys.argv[1])

def from_sh(name):
    t = (here / f"{name}.sh").read_text()
    s = t.index("node --input-type=module -e '") + len("node --input-type=module -e '")
    return t[s:t.rindex("'\n")]

def from_ps1(name):
    t = (here / "windows" / f"{name}.ps1").read_text()
    s = t.index("$Program = @'\n") + len("$Program = @'\n")
    return t[s:t.index("\n'@", s) + 1]

bad = False
for name in ("tci-probe", "tci-watch"):
    # Compare the program, not the block padding: the .sh keeps the newline
    # straight after `-e \'` and the here-string does not. Leading/trailing
    # blank lines are framing, any other difference is drift.
    if from_sh(name).strip("\n") != from_ps1(name).strip("\n"):
        print(f"  DRIFT: windows/{name}.ps1 JavaScript differs from {name}.sh")
        bad = True
if bad:
    print("  The Windows ports embed the macOS program verbatim. Re-extract it")
    print("  rather than hand-editing one side. Refusing to bundle a mismatch.")
    sys.exit(1)
print("  verified   windows/*.ps1 embed the macOS JS verbatim")
PYGUARD

# Same guard for the PROFILE.  profile/ is a hand-taken snapshot of the installed
# profile and nothing keeps it honest: on 2026-09-01 the installed copy had
# `step_hz` 100 while profile/ still carried the 1000 it was committed with, so a
# second Mac would have tuned ten times coarser than this desk.  Per-action
# settings (step_hz, coarse_mult, press_action, tci_url) live in here, so drift is
# silent and only shows up under the operator's hand.
INSTALLED_PROFILE="$(ls -d "$HOME/Library/Application Support/Ulanzi/UlanziDeck/ProfilesV2/"*.ulanziProfile 2>/dev/null | head -1)"
REPO_PROFILE="$(ls -d "$HERE/profile/"*.ulanziProfile 2>/dev/null | head -1)"
if [[ -z "$INSTALLED_PROFILE" ]]; then
  red "No installed profile found under ProfilesV2 — cannot verify profile/ is current."
  exit 1
elif ! diff -r -x '.DS_Store' "$INSTALLED_PROFILE" "$REPO_PROFILE" >/dev/null 2>&1; then
  red "profile/ differs from the installed profile:"
  diff -r -x '.DS_Store' "$INSTALLED_PROFILE" "$REPO_PROFILE" | head -20
  red ""
  red "Bundling this would ship settings you are not operating with."
  red "If the installed copy is the good one:  rsync -a \"$INSTALLED_PROFILE/\" \"$REPO_PROFILE/\""
  exit 1
else
  grn "installed profile matches profile/"
fi

[[ -d "$PLUGIN/node_modules/ws" ]] || {
  echo "installing deps so the bundle is self-contained..."
  ( cd "$PLUGIN" && npm ci --omit=dev >/dev/null 2>&1 ) || { red "npm ci failed"; exit 1; }
}

rm -rf "$OUT"; mkdir -p "$OUT"
rsync -a --exclude '.DS_Store' "$PLUGIN" "$OUT/"
rsync -a --exclude '.DS_Store' "$HERE/profile/"*.ulanziProfile "$OUT/"
cp "$HERE/INSTALL.md" "$OUT/"
cp "$HERE/install.sh" "$OUT/"            # automates INSTALL.md steps 1-2 + step 5 checks
cp "$HERE/tci-probe.sh" "$OUT/"          # safe TCI probe — see INSTALL.md troubleshooting
cp "$HERE/tci-watch.sh" "$OUT/"          # read-only broadcast-vs-query watcher
# The bundle redistributes G0JKN's Apache-2.0 plugin, in modified form, to a
# machine that may never see this repo. Section 4(a) wants the licence to
# travel with it, and 4(d) the attribution — so they go in the zip, not just
# in the repo root.
cp "$HERE/LICENSE" "$OUT/"
cp "$HERE/NOTICE" "$OUT/"
rsync -a --exclude '.DS_Store' "$HERE/windows" "$OUT/"   # untested Windows port

ZIP="$OUT.zip"; rm -f "$ZIP"
( cd "$(dirname "$OUT")" && zip -qr "$(basename "$ZIP")" "$(basename "$OUT")" -x "*.DS_Store" )
unzip -qt "$ZIP" >/dev/null || { red "zip failed integrity check"; exit 1; }

grn "built $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  plugin actions: $(python3 -c "import json;print(len(json.load(open('$OUT/com.g0jkn.aethersdr.ulanziPlugin/manifest.json'))['Actions']))")"
echo "  node_modules:   $([ -d "$OUT/com.g0jkn.aethersdr.ulanziPlugin/node_modules/ws" ] && echo bundled || echo MISSING)"
echo "  profile:        $(basename "$(ls -d "$OUT"/*.ulanziProfile)")"
