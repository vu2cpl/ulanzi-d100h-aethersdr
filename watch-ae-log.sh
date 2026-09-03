#!/usr/bin/env bash
#
# watch-ae-log.sh — live view of the TCI commands AetherSDR RECEIVES.
#
# The third diagnostic in this repo, and the one that answers a different
# question from the other two:
#
#   tci-probe.sh    what is the radio's state right now?      (asks AE)
#   tci-watch.sh    what does AE broadcast when I do X?       (listens on the wire)
#   watch-ae-log.sh what did the PLUGIN actually send?        (reads AE's own log)
#
# That last one is the question you have when a button "does nothing", and it is
# the one the wire cannot answer: Studio swallows plugin stdout through a pipe,
# so short of the DEBUG flag in the plugin there is no view of what a press
# emitted. AetherSDR logs every command it receives, which is the same evidence
# from the other end -- and needs no plugin change to get at.
#
# This is how all three upstream fixes were verified on 2026-09-03: the mode
# cycle walking usb->lsb->cw->digu->digl->am->fm, and TUNE's query-then-act
# pairs (`tune:0;` then `tune:0,true|false;`) with their timestamps, which is
# what proved a second press could finally stop a tune.
#
# MSHV polls `vfo:0,0;` and `modulation:0;` about once a second on the same TCI
# port; that is filtered out below or it buries everything else. Drop the second
# grep if you want the raw stream.
#
# Read-only: it opens no socket and sends nothing. Safe mid-QSO.
#
#   ./watch-ae-log.sh              follow every command AE receives
#   ./watch-ae-log.sh tune         follow, showing only lines matching `tune`
#
set -euo pipefail

L="$HOME/Library/Preferences/AetherSDR/logs"
if [ ! -d "$L" ]; then
  echo "error: no AetherSDR log directory at $L" >&2
  exit 1
fi

# Skip the `aethersdr.log` symlink/rolling file and take the newest stamped one.
F="$L/$(ls -t "$L" | grep -v '^aethersdr.log$' | head -1)"
echo "watching $(basename "$F")  (ctrl-C to stop)" >&2

FILTER="${1:-}"

tail -n 0 -F "$F" 2>/dev/null \
  | grep --line-buffered 'TCI rx' \
  | grep --line-buffered -vE '"(vfo:0,0|modulation:0);"' \
  | sed -u 's/.*\[\([0-9:.]*\)\].*TCI rx: /\1  /' \
  | { if [ -n "$FILTER" ]; then grep --line-buffered "$FILTER"; else cat; fi; }
