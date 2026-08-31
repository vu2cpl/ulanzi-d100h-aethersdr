# Ulanzi D100H → AetherSDR

Local patches that make a **Ulanzi D100H** dial controller drive
**AetherSDR** over its TCI WebSocket, via Ulanzi Studio.

The controller integration itself is
**[AetherSDR Controller](https://github.com/) by Nigel Fenton (G0JKN)** — a
Ulanzi Studio plugin that translates button and dial events into TCI commands.
This repo contains only the local fixes needed to make it work here, plus a
script to re-apply them after a plugin update.

## Why this exists

A plugin update overwrites the plugin directory and wipes `node_modules`. All seven
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
| 4 | Valid AetherSDR mode tokens (`usb`/`lsb`/`cwr`/`digu`; `CW`/`AM`/`FM` don't exist) |
| 5 | Band stacking, and band defaults moved off the band edges |
| 6 | `mute:<rx>,<bool>` receiver index; removed the malformed `if:` slice command |
| 7 | TUNE could start a tune cycle but never stop one — wrong parser index, and AetherSDR never broadcasts tune state, so it now queries before acting |

Patches 1–4 and 7 are genuine upstream bugs worth reporting to G0JKN.

## Assignable actions

[TCI-ACTIONS.md](TCI-ACTIONS.md) lists all 50, probed live against the radio:
what the plugin already does, what can be added, and what AetherSDR simply
does not expose (antenna, slice focus, CW keyer, VFO lock).

## Layout

```
upstream-original/           pristine upstream v0.1.5, for diffing patches
patched/                     known-good plugin files (base: upstream v0.1.5)
restore-plugin-patches.sh    re-apply them, with version guard + verification
backups/                     what was overwritten, timestamped (created on first run)
HANDOVER.md                  full story, gotchas, open items
TCI-ACTIONS.md               all 50 assignable actions, probe-verified
```

## Gotchas

**Probe a TCI verb before coding against it.** AetherSDR silently discards
malformed commands, which is indistinguishable from a dead button. Send
`verb:0;` as a query to `ws://127.0.0.1:50001` and read back the canonical shape.

**The D100H has no per-key displays** — 7 physical buttons and a knob. On-key
labels are impossible.

**Debugging:** set `const DEBUG = true` in `plugin/app.js` to log to
`/tmp/aethersdr-ulanzi-debug.log`. Studio swallows plugin stdout, so this is
the only way to see whether a press reaches the plugin.

See [HANDOVER.md](HANDOVER.md) for the rest, including AetherSDR's verified TCI
limits (no slice switching, no antenna control).
