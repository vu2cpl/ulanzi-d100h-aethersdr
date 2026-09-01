#!/usr/bin/env bash
#
# tci-probe.sh — query AetherSDR's TCI interface without writing to the radio.
#
# Exists because `verb:0;` is NOT a universally safe probe. TCI verbs come in
# two shapes and that string means opposite things to them:
#
#   receiver-indexed : drive:<rx>,<value>    `drive:0;`     = query receiver 0
#   NOT indexed      : mic_level:<value>     `mic_level:0;` = SET IT TO ZERO
#
# On 2026-09-01 a verb sweep in the `verb:0;` form sent `tx_gain:0;`, zeroed
# AetherSDR's TCI TX gain, and took the station off the air for two days — the
# radio keyed normally on FT8 and radiated nothing. See HANDOVER.md.
#
# So this script makes a query and a write two different invocations, instead
# of one string whose meaning depends on knowledge you may not have:
#
#   ./tci-probe.sh                    full state dump (connect burst)
#   ./tci-probe.sh mic_level          QUERY  — sends `mic_level;`, never writes
#   ./tci-probe.sh drive              QUERY  — sends `drive;`
#   ./tci-probe.sh mic_level 40       WRITE  — sends `mic_level:40;`, confirms first
#   ./tci-probe.sh drive 0,25         WRITE  — sends `drive:0,25;` (rx index included)
#   ./tci-probe.sh -y mic_level 40    WRITE without the confirmation prompt
#
# The bare `verb;` form is a query for BOTH shapes and can never write, which is
# why one argument always means "read".
#
set -euo pipefail

YES=0
if [ "${1:-}" = "-y" ]; then YES=1; shift; fi

VERB="${1:-}"
VALUE="${2:-}"
URL="${TCI_URL:-ws://127.0.0.1:50001}"

# `ws` is not installed globally on this Mac; borrow the copy that ships inside
# the installed plugin rather than adding a second, independently-versioned dep.
WS="$HOME/Library/Application Support/Ulanzi/UlanziDeck/Plugins/com.g0jkn.aethersdr.ulanziPlugin/node_modules/ws/index.js"
if [ ! -f "$WS" ]; then
  echo "error: can't find the ws module at:" >&2
  echo "  $WS" >&2
  echo "Install the plugin first (see INSTALL.md), or set WS to another copy." >&2
  exit 1
fi

if [ -n "$VALUE" ]; then
  echo "WRITE: ${VERB}:${VALUE};   ->  $URL"
  echo "This changes the radio. A query needs no value: ./tci-probe.sh $VERB"
  if [ "$YES" -eq 0 ]; then
    read -r -p "Send it? [y/N] " reply
    case "$reply" in [yY]*) ;; *) echo "aborted"; exit 1 ;; esac
  fi
fi

TCI_WS="$WS" TCI_URL="$URL" TCI_VERB="$VERB" TCI_VALUE="$VALUE" \
node --input-type=module -e '
const { default: WebSocket } = await import(process.env.TCI_WS);
const verb  = process.env.TCI_VERB;
const value = process.env.TCI_VALUE;
const ws = new WebSocket(process.env.TCI_URL);
let ready = false;

// Chatter that drowns out the answer.
const NOISE = /^(rx_smeter|tx_smeter|vfo_limits|if_limits|modulations_list)/;

ws.on("open", () => {
  if (!verb) return;                       // no verb: just print the connect burst
  setTimeout(() => {
    const cmd = value ? `${verb}:${value};` : `${verb};`;
    console.log(`-> ${cmd}`);
    ws.send(cmd);
    if (value) setTimeout(() => { console.log(`-> ${verb};`); ws.send(`${verb};`); }, 400);
  }, 700);
});

ws.on("message", (d) => {
  const s = d.toString().trim();
  if (s === "ready;") { ready = true; if (!verb) process.exit(0); return; }
  if (NOISE.test(s)) return;
  // With a verb, show only its replies; without one, show the whole burst.
  if (verb && !s.startsWith(verb)) return;
  console.log(verb ? `   <- ${s}` : s);
});

ws.on("error", (e) => { console.error(`error: ${e.message}`); process.exit(1); });
setTimeout(() => process.exit(0), verb ? (value ? 2200 : 1800) : 4000);
'
