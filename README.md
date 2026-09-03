# Ulanzi D100H → AetherSDR

Local patches that make a **Ulanzi D100H** dial controller drive
**AetherSDR** over its TCI WebSocket, via Ulanzi Studio.

The controller integration itself is
**[AetherSDR Controller](https://github.com/) by Nigel Fenton (G0JKN)** — a
Ulanzi Studio plugin that translates button and dial events into TCI commands.
This repo contains only the local fixes needed to make it work here, plus a
script to re-apply them after a plugin update.

## Why this exists

A plugin update overwrites the plugin directory and wipes `node_modules`. All fifteen
patches below revert, and the failure mode is a controller that looks completely
dead while the Studio profile still looks perfect.

## Usage

```bash
./restore-plugin-patches.sh --check   # report status, change nothing
./restore-plugin-patches.sh           # re-apply patches + npm ci
```

Quit Ulanzi Studio first — it rewrites plugin state on exit, and the script
refuses to run while it is up. Restart Studio afterwards.

## What gets patched

| # | Fix |
|---|-----|
| 1 | TCI port `40001` → `50001` (AetherSDR's actual default) |
| 2 | `npm ci` — upstream ships no `node_modules`, so `import ws` killed the plugin at startup |
| 3 | `setSettings()` persistence + `$UD.connect()` — no inspector setting had ever saved |
| 4 | Mode tokens are lowercase in AE's reports, so the cycle's mixed-case list never matched. (The tokens themselves were fine — an early note here claimed `CW`/`AM`/`FM` didn't exist; they do. See patch 12.) |
| 5 | Band stacking, and band defaults moved off the band edges |
| 6 | `mute:<rx>,<bool>` receiver index; removed the malformed `if:` slice command |
| 7 | TUNE could start a tune cycle but never stop one — wrong parser index, and AetherSDR never broadcasts tune state, so it now queries before acting |
| 8 | AF Gain / Mic Gain sent `volume:0,<v>;` and `mic_level:0,<v>;` to verbs that take **no** receiver index — AE read the index as the value, so every press wrote **0** |
| 9 | Dial tuned the RX VFO under split — `cmdSetFreq()` hardcoded channel 0, so "split, then spin" moved RX and left TX put. Split now steers the knob to VFO B (`vfo:<rx>,1`) |
| 10 | Split was a blind toggle on an unconfirmed mirror — one flip out of step and the dial drove the wrong VFO forever. Now query-then-act, like TUNE (patch 7) |
| 11 | Split now parks the TX slice **1 kHz up on CW, 5 kHz on SSB**, and survives AetherSDR resetting VFO B to VFO A *twice* on enable |
| 12 | Mode cycle listed `cwr` but AE reports `cw`, so `indexOf` returned −1 and the cycle reset to entry 0 whenever the radio was on CW. Now CW / USB / DIGU / LSB |
| 13 | Mute was per-receiver, leaving the other slice audible. Now masters every open slice, tracking the (dynamic) `trx_count` |
| 14 | Knob press is fast/slow tune step. It was VFO A/B swap, which under split trades RX and TX — the wrong thing to have under your thumb mid-pileup |
| 15 | Dial snaps to the step grid. Tuning was a pure increment, so an off-grid VFO (band stack, panadapter click, RIT) kept its offset forever — 7.074123 walked …223, …323 and never reached a 100 Hz boundary. Also corrected the `vfo` tooltip, which still described pre-patch-9/14 behaviour |

Patches 11, 14 and 15 are operator preference, not defects — patch 15's tooltip half
describes *these* patches, so it has nothing to report upstream either. Patch 2 is not a
bug either: upstream documents `npm install` as an install step, and it only bit us
because the plugin was installed by copying the folder.

The rest are genuine upstream bugs, and **they have been reported**, as
[nigelfenton/aethersdr-ulanzi-plugin#3](https://github.com/nigelfenton/aethersdr-ulanzi-plugin/issues/3):

- **Closed by G0JKN's v0.1.7 sync** — the TCI port default (patch 1, now with a
  `migrateTciUrl()` we never wrote) and the malformed `if:` slice command (patch 6,
  Slice Cycle removed outright).
- **Fixed in our [PR #4](https://github.com/nigelfenton/aethersdr-ulanzi-plugin/pull/4)** —
  inspector persistence (patch 3), the mode-cycle case compare (patch 12) and TUNE
  query-then-act (patch 7). Verified on the radio 2026-09-03, which turned up two more
  faults that only appear once settings actually save: `setSettings()` replaces rather
  than merges the stored object, and the form does not repopulate on reopen.

One correction worth keeping visible: the original report claimed `CW`, `AM` and `FM`
were not AetherSDR modes. They are — the wrong list came from `tci-probe.sh` filtering
`modulations_list` out of its own output. G0JKN caught it; see patch 4.

## Assignable actions

[TCI-ACTIONS.md](TCI-ACTIONS.md) lists all 51, probed live against the radio:
what the plugin already does, what can be added, and what AetherSDR simply
does not expose (antenna, slice focus, CW keyer, VFO lock).

## Layout

```
profile/                     the D100H layout (7 buttons + knob)
upstream-original/           pristine upstream v0.1.5, for diffing patches
patched/                     known-good plugin files (base: upstream v0.1.5)
restore-plugin-patches.sh    re-apply them, with version guard + verification
tci-probe.sh                 query TCI safely (one arg = read, two = confirmed write)
tci-watch.sh                 which verbs BROADCAST vs only answer a query (read-only)
backups/                     what was overwritten, timestamped (created on first run)
d100h-aethersdr-macbook.zip  the built bundle, committed for download on the target Mac
INSTALL.md                   installing on another Mac
make-bundle.sh               build the self-contained install zip
HANDOVER.md                  full story, gotchas, open items
TCI-ACTIONS.md               all 51 assignable actions, probe-verified
```

## Installing on another Mac

The built bundle is committed as `d100h-aethersdr-macbook.zip`, so the target Mac
can download it straight from this repo. To rebuild it after a patch:

```bash
./make-bundle.sh            # -> ~/Downloads/d100h-aethersdr-macbook.zip
cp ~/Downloads/d100h-aethersdr-macbook.zip .
```

Bundles the patched plugin **with `node_modules`**, the profile, and
[INSTALL.md](INSTALL.md). The target Mac needs neither npm nor system Node —
Ulanzi Studio ships its own runtime. The script refuses to build if the
installed plugin or the profile has drifted from the repo.

**The committed zip goes stale on every patch** — it is a build artifact, not a
source of truth, and unlike `patched/` nothing guards it. It also carries G0JKN's
full plugin and `node_modules`, neither of which this repo otherwise vendors.
Rebuild and re-commit it in the same cycle as any plugin patch, or delete it and
build on demand. **Quit Studio before building**: it flushes profile state on its
own schedule, so a bundle built while it is running can miss an edit by minutes
(it shipped an unlabelled Mute key that way on 2026-09-02).

## Gotchas

**⚠️ Probe with `./tci-probe.sh`, never a hand-rolled `verb:0;`.** TCI verbs are
either receiver-indexed (`drive:<rx>,<value>`, where `drive:0;` is a safe query) or
not (`volume:<value>`, `mic_level:<value>`, `tx_gain:<value>`, where `verb:0;`
**writes zero**). A verb sweep in the `verb:0;` form silenced this station's TX audio
for two days on 2026-09-01 by zeroing AetherSDR's TCI TX gain — a keyed transmitter
radiating nothing. The script makes reads and writes separate invocations so the
ambiguity cannot bite:

```bash
./tci-probe.sh                 # full state dump
./tci-probe.sh tx_gain         # query — one argument always reads
./tci-probe.sh tx_gain 100     # write — confirms before sending
```

See HANDOVER.md "Known gotchas" for the full story.

**Check whether a verb broadcasts before you mirror it.** AetherSDR announces
some state changes and stays silent on others, and guessing wrong yields a
control that looks right and is subtly wrong — it has cost three patches now
(7, 9, 10). `./tci-watch.sh` settles it without sending anything at all:

```bash
./tci-watch.sh                      # 60 s, every verb, summary
./tci-watch.sh 90 split_enable vfo  # just these, every change timestamped
```

Exercise the control while it runs — a verb nobody touched cannot broadcast, so
"burst only" is not proof of query-only.

AetherSDR also silently discards malformed commands, which is indistinguishable
from a dead button — so probe before coding against a verb.

**The D100H has no per-key displays** — 7 physical buttons and a knob. On-key
labels are impossible.

**Debugging:** set `const DEBUG = true` in `plugin/app.js` to log to
`/tmp/aethersdr-ulanzi-debug.log`. Studio swallows plugin stdout, so this is
the only way to see whether a press reaches the plugin.

See [HANDOVER.md](HANDOVER.md) for the rest, including AetherSDR's verified TCI
limits (no slice switching, no antenna control).
