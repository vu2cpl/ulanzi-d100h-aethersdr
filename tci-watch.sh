#!/usr/bin/env bash
#
# tci-watch.sh — find out which AetherSDR TCI verbs BROADCAST their changes,
# and which only ever answer a direct query.
#
# Exists because that distinction has now caused three separate patches:
#
#   patch 7  `tune` does NOT broadcast. A toggle built on a parser-derived
#            mirror read stale state forever, so TUNE could start a tune cycle
#            but never stop one — while keying the transmitter.
#   patch 9  `vfo` and `split_enable` DO broadcast, so the dial can steer off a
#            mirror without polling.
#   patch 10 ...but a mirror is only as good as what refreshes it. Split was a
#            blind toggle on a value AE never confirms for TCI-originated
#            changes, and once out of step the dial drove the wrong VFO forever.
#
# Guessing wrong in either direction produces a control that looks fine and is
# subtly wrong, so measure before mirroring any new verb in `radio`.
#
# STRICTLY READ-ONLY. Unlike tci-probe.sh this sends NOTHING AT ALL — not even a
# query — so it is safe to leave running on a live station mid-QSO.
#
#   ./tci-watch.sh                     watch 60 s, report every verb
#   ./tci-watch.sh 120                 watch 120 s
#   ./tci-watch.sh 90 split_enable vfo only these verbs, with every change shown
#   TCI_URL=ws://host:50001 ./tci-watch.sh
#
# HOW TO READ THE RESULT
#   broadcasts      the verb changed on its own while we watched — a parser
#                   mirror will track it. Safe to mirror.
#   burst only      AetherSDR announced it at connect and never again. Either
#                   nothing changed it during the window, or it does not
#                   broadcast. EXERCISE THE CONTROL and re-run before concluding
#                   it is query-only — a verb nobody touched proves nothing.
#   never seen      absent from the connect burst too. Query it explicitly with
#                   ./tci-probe.sh <verb> before assuming it is unsupported: a
#                   silent response means "not a query", not "not implemented".
#
set -euo pipefail

SECS="${1:-60}"
if [[ "$SECS" =~ ^[0-9]+$ ]]; then shift || true; else SECS=60; fi
URL="${TCI_URL:-ws://127.0.0.1:50001}"

WS="$HOME/Library/Application Support/Ulanzi/UlanziDeck/Plugins/com.g0jkn.aethersdr.ulanziPlugin/node_modules/ws/index.js"
if [ ! -f "$WS" ]; then
  echo "error: can't find the ws module at:" >&2
  echo "  $WS" >&2
  echo "Install the plugin first (see INSTALL.md), or set WS to another copy." >&2
  exit 1
fi

echo "watching $URL for ${SECS}s — read-only, nothing is sent"
echo "exercise the controls you care about NOW (from the radio UI and from the dial)"
echo

TCI_WS="$WS" TCI_URL="$URL" TCI_SECS="$SECS" TCI_ONLY="$*" \
node --input-type=module -e '
const { default: WebSocket } = await import(process.env.TCI_WS);
const secs = Number(process.env.TCI_SECS);
const only = process.env.TCI_ONLY.trim().split(/\s+/).filter(Boolean);
const ws = new WebSocket(process.env.TCI_URL);

// Continuous telemetry, not state. It would swamp the report with noise that
// tells us nothing about whether a CONTROL broadcasts.
const METERS = /^(rx_smeter|tx_smeter|rx_sensors|tx_sensors)$/;

const burst = new Map();     // verb -> last value seen during the connect burst
const changes = new Map();   // verb -> count of post-burst changes
const last = new Map();      // verb -> last value seen at all
const t0 = Date.now();
let inBurst = true;

// AetherSDR sends `ready;` partway through the burst and keeps going, so the
// burst boundary is a settle timer, not that token. (tci-probe.sh used to exit
// on `ready;` and silently truncated its dump to ~8 of 120 lines.)
setTimeout(() => {
  inBurst = false;
  console.log(`--- connect burst captured (${burst.size} verbs) — now watching for changes ---\n`);
}, 2000);

ws.on("message", (d) => {
  for (const raw of d.toString().trim().split("\n")) {
    const line = raw.trim().replace(/;$/, "");
    if (!line) continue;
    const ci = line.indexOf(":");
    const verb = (ci < 0 ? line : line.substring(0, ci)).toLowerCase();
    if (METERS.test(verb)) continue;
    if (only.length && !only.includes(verb)) continue;
    const val = ci < 0 ? "" : line.substring(ci + 1);

    if (inBurst) { burst.set(verb, val); last.set(verb, val); continue; }
    if (last.get(verb) === val) continue;          // re-announcement, not a change
    last.set(verb, val);
    changes.set(verb, (changes.get(verb) || 0) + 1);
    // With an explicit verb list the operator wants the detail, not just a tally.
    if (only.length) {
      const t = ((Date.now() - t0) / 1000).toFixed(1).padStart(6);
      console.log(`${t}s  ${line}`);
    }
  }
});

ws.on("error", (e) => { console.error(`error: ${e.message}`); process.exit(1); });

setTimeout(() => {
  const bc = [...changes.keys()].sort();
  const quiet = [...burst.keys()].filter((v) => !changes.has(v)).sort();
  const line = (s) => console.log(s);
  line("");
  line("=".repeat(64));
  line(`BROADCASTS  (changed on their own — safe to mirror)   [${bc.length}]`);
  line("=".repeat(64));
  line(bc.length ? bc.map((v) => `  ${v.padEnd(24)} ${changes.get(v)} change(s)`).join("\n")
                 : "  (none — did you exercise any controls?)");
  line("");
  line("=".repeat(64));
  line(`BURST ONLY  (announced at connect, never again)       [${quiet.length}]`);
  line("=".repeat(64));
  line("  Not proof of query-only: a control nobody touched cannot broadcast.");
  line("  Exercise it and re-run before you build a mirror on it.");
  line("");
  // Column width from the longest name, or `audio_stream_sample_type` and
  // friends run into the next column.
  const w = Math.max(2, ...quiet.map((v) => v.length)) + 2;
  const cols = Math.max(1, Math.floor(76 / w));
  for (let i = 0; i < quiet.length; i += cols) {
    line("  " + quiet.slice(i, i + cols).map((v) => v.padEnd(w)).join("").trimEnd());
  }
  if (only.length) {
    const never = only.filter((v) => !burst.has(v) && !changes.has(v));
    if (never.length) {
      line("");
      line(`NEVER SEEN: ${never.join(", ")}`);
      line("  Absent from the burst too. Query with ./tci-probe.sh <verb> before");
      line("  concluding it is unsupported — a set draws no reply either.");
    }
  }
  process.exit(0);
}, secs * 1000 + 2000);
'
