#!/usr/bin/env bash
#
# measure-knob.sh — is the dial actually slow, or does it just feel slow?
#
# The fourth diagnostic in this repo, and it answers the question the other
# three cannot:
#
#   tci-probe.sh     what is the radio's state right now?      (asks AE)
#   tci-watch.sh     what does AE broadcast when I do X?       (listens on the wire)
#   watch-ae-log.sh  what did the PLUGIN actually send?        (reads AE's own log)
#   measure-knob.sh  how fast are detents getting through?     (times that log)
#
# Every detent the D100H delivers becomes one `TCI rx: "vfo:0,0,<hz>;"` line in
# AetherSDR's log with a millisecond stamp, so the log already holds the answer.
# The metric is DISTINCT frequency changes per second during a sustained sweep:
#
#   31-36/s   healthy on this station
#   ~10/s     starved — see HANDOVER "A sluggish knob is a Bluetooth problem"
#
# The dial is Bluetooth LE, and an HFP/SCO headset mic on the same radio takes
# reserved slots and starves it. That was the 2026-09-19 outage, and the audio
# profile is the corroborating tell: mono/16000 is HFP and the dial will be
# slow, stereo/44100 is A2DP and it will not. `--audio` prints it.
#
# Count only CHANGES. 31-58% of the commands in any log are the plugin
# recomputing a target the dial already sent, because dialRotate() steps from a
# mirror that only moves when AE echoes back. Those are not detents and counting
# them flatters the result.
#
# Do not use the median gap, and especially not the 10th percentile: queue-drained
# bursts arrive microseconds apart and drag the low percentiles down, which on
# 2026-09-19 reported "healthy" for a sweep the operator was calling sluggish.
#
# Read-only: it opens no socket and sends nothing. Safe mid-QSO.
#
#   ./measure-knob.sh           whole newest log
#   ./measure-knob.sh --watch   wait for a sweep, then report it
#   ./measure-knob.sh --audio   also print the Bluetooth audio profile
#
set -euo pipefail

LOGS="$HOME/Library/Preferences/AetherSDR/logs"
[ -d "$LOGS" ] || { echo "error: no AetherSDR log directory at $LOGS" >&2; exit 1; }

WATCH=0; AUDIO=0
for a in "$@"; do
  case "$a" in
    --watch) WATCH=1 ;;
    --audio) AUDIO=1 ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

# Skip the rolling `aethersdr.log` symlink or the newest file gets measured twice.
LOG="$LOGS/$(ls -t "$LOGS" | grep -v '^aethersdr.log$' | head -1)"
echo "log: $(basename "$LOG")"

if [ "$AUDIO" = 1 ]; then
  echo
  echo "Bluetooth audio profile (mono/16000 = HFP = the dial will be starved):"
  system_profiler SPAudioDataType 2>/dev/null \
    | grep -B1 -A8 "Transport: Bluetooth" \
    | grep -E "^        [A-Za-z].*:$|Channels|SampleRate" || echo "  (no Bluetooth audio device)"
  echo
fi

if [ "$WATCH" = 1 ]; then
  echo "watching — spin the knob; reports once you stop (Ctrl-C to abort)"
  START=$(wc -l < "$LOG")
else
  START=0
fi

python3 - "$LOG" "$START" "$WATCH" <<'PY'
import re, sys, time, os
log, start, watch = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
pat = re.compile(r'^\[(\d\d):(\d\d):(\d\d)\.(\d\d\d)\].*TCI rx: "vfo:0,0,(\d+);"')

def collect():
    ev = []
    with open(log, errors="ignore") as fh:
        for n, ln in enumerate(fh):
            if n < start:
                continue
            m = pat.match(ln)
            if m:
                h, mi, s, ms, hz = m.groups()
                ev.append((int(h)*3600 + int(mi)*60 + int(s) + int(ms)/1000,
                           f"{h}:{mi}:{s}", int(hz)))
    return ev

if watch:
    seen, quiet = 0, 0
    while quiet < 4:
        time.sleep(1)
        ev = collect()
        if len(ev) > seen:
            seen, quiet = len(ev), 0
        elif seen:
            quiet += 1
        if time.time() % 1 and seen and quiet >= 4:
            break
else:
    ev = collect()

per, repeats = {}, 0
for i in range(1, len(ev)):
    if ev[i][2] != ev[i-1][2]:
        per[ev[i][1]] = per.get(ev[i][1], 0) + 1
    else:
        repeats += 1

if not per:
    print("no detents found — spin the knob, or check the plugin is connected")
    sys.exit(0)

busy = sorted(per.values(), reverse=True)
peak = busy[0]
print(f"raw commands: {len(ev)}   detents: {sum(per.values())}   "
      f"repeats: {repeats} ({100*repeats//max(1,len(ev))}%, expected 31-58%)")
print(f"busiest seconds (detents/s): {busy[:5]}")
verdict = ("HEALTHY" if peak >= 28 else
           "DEGRADED — check the Bluetooth audio profile with --audio" if peak >= 15 else
           "STARVED — check the Bluetooth audio profile with --audio")
print(f"peak: {peak}/s   {verdict}")
if peak < 28:
    print("  (a low peak can also just mean nobody spun the knob hard — "
          "sweep continuously for a few seconds and re-run)")
PY
