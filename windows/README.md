# Windows port — never run on Windows

**No Windows machine exists in this shack**, so nothing here has been run on the
platform it targets. But it is not unverified either, and the difference matters
when you are deciding how much to trust it.

**What was verified, on macOS:**

- All four scripts **parse** under PowerShell 7.6.
- `install.ps1` was **run** under `pwsh` on macOS against a scratch `%APPDATA%`:
  fresh install, re-install over an existing one (exercising the move-aside
  backup), the manifest-vs-source verification (21 actions, port 50001), and
  `-Check`. That run found a real bug — see below.
- `tci-probe.ps1`'s wrapper chain was **run**: it located `ws` under the
  `%APPDATA%` layout, found node, wrote the temp `.mjs`, and the embedded program
  executed and reached its own error handler with the radio absent.
- `watch-ae-log.ps1` was **run against a synthetic AE log, and its output was
  byte-identical to `watch-ae-log.sh`** on the same input — both kept the four
  `TCI rx` lines, both dropped the MSHV `vfo:0,0` / `modulation:0` polls and the
  non-TCI line.

**What is untested, and can only be tested on Windows:** whether Studio finds the
plugin at these paths, whether the profile binds to the dial, whether Studio's
bundled Node is where the diagnostics look, and whether the D100H works at the
far end. Those are the questions that matter most, and none of them are answered.

Read that as: **expect to fix something.** When you do, please push the fix back
so the next person inherits a tested script instead of this notice.

## The bug the macOS run already caught

`install.ps1` called `Get-NetTCPConnection` to report whether AetherSDR was
listening. That cmdlet is Windows-only — and with `$ErrorActionPreference =
'Stop'`, a missing cmdlet is a *terminating* error. On macOS the script installed
everything correctly, printed every verification, and then **died red before
reaching "Done"**, at a step that is purely informational. On Windows the cmdlet
normally exists, so this might never have shown up until it hit a machine without
the NetTCPIP module — where it would look like a failed install that had, in
fact, succeeded. It is now guarded with `Get-Command` and falls back to `netstat`.

That is the argument for running a port anywhere you can, even the wrong OS.

| Script | Ports | Sends anything? |
|---|---|---|
| `install.ps1` | `../install.sh` | writes to disk; quits Studio |
| `tci-probe.ps1` | `../tci-probe.sh` | queries only, unless given a value |
| `tci-watch.ps1` | `../tci-watch.sh` | **nothing at all** — safe mid-QSO |
| `watch-ae-log.ps1` | `../watch-ae-log.sh` | **nothing** — reads AE's log file |

Start with `.\install.ps1 -Check`. It only reads.

## What is confirmed, and what is a guess

Everything below was checked against a primary source. The distinction matters:
a guessed path in an install document is worse than an admitted gap, because it
looks like knowledge.

**Confirmed — plugin directory.** `%APPDATA%\Ulanzi\UlanziDeck\Plugins`, verified
against a shipped third-party UlanziDeck plugin
([narlei/ulanzideck_claude](https://github.com/narlei/ulanzideck_claude)), which
documents exactly that path for its own install.

**Confirmed — no Node.js needed.** Ulanzi Studio bundles its own Node v20 for
plugins, the same as on macOS, so the plugin runs with nothing else installed.
(The *diagnostic* scripts do need a `node` binary — see below.)

**Confirmed — AetherSDR's log directory.** `%LOCALAPPDATA%\AetherSDR\logs`, from
AetherSDR's own source: `src/core/LogManager.cpp` builds the path as
`QStandardPaths::GenericConfigLocation + "/AetherSDR/logs/aethersdr.log"`, and
`src/core/SettingsPaths.h` documents `GenericConfigLocation` as
`%LOCALAPPDATA%/AetherSDR` on Windows.

**INFERRED — profile directory.** `%APPDATA%\Ulanzi\UlanziDeck\ProfilesV2`. On
macOS `ProfilesV2` sits beside `Plugins` under the same parent, so this follows
by symmetry — but it has never been seen on a Windows install. **If the profile
does not appear in Studio, this is the first thing to check.** It is also the
half that carries `step_hz`, `press_action` and the split behaviour, so getting
it wrong loses the operating settings, not just the layout.

**UNKNOWN — the Studio process name.** `install.ps1` matches any process whose
name contains `Ulanzi` and prints what it found rather than assuming. It calls
`CloseMainWindow()` and never force-kills: Studio flushes profile state on a
clean exit, so killing it can lose settings.

**UNKNOWN — where Studio's bundled Node lives.** On macOS it is
`/Applications/Ulanzi Studio.app/Contents/MacOS/NodeJS/node`. The diagnostics
prefer a system `node`, then hunt for `node.exe` under the Ulanzi install
directories. If you find the real path, record it here.

## The JavaScript in the TCI scripts is copied verbatim

`tci-probe.ps1` and `tci-watch.ps1` contain the *same* JavaScript program as the
macOS scripts, byte for byte, between the `---8<---` markers. Only the shell
around it is new.

That was deliberate. The obvious tidier design is to extract the program into a
shared `.mjs` both platforms call — but AetherSDR was not running when these were
written, so that refactor could not have been verified against the radio, and
`tci-probe.sh` is the script standing between the operator and a repeat of the
2026-09-01 `tx_gain:0;` incident that took the station off the air for two days.
An unverifiable refactor of *that* file is the wrong risk to take.

Verbatim only stays true if something checks, so **`make-bundle.sh` refuses to
build if the two ever drift.** If you need to change the program, change
`../tci-probe.sh` and re-extract — do not hand-edit one side.

The program is written to a temp `.mjs` and run, rather than passed via `node -e`:
it is full of quotes, backticks and template literals, and PowerShell's argument
quoting mangles at least one of them in transit. A file has no quoting layer.

## What is NOT ported

`restore-plugin-patches.sh` and `make-bundle.sh` — the maintenance loop. Both are
macOS-only, and both are about *this* desk's install rather than a target
machine. A Windows user consuming the bundle does not need them; a Windows user
*maintaining* the patches would need them ported too.

## First useful datum

If you try this, the single most valuable thing to report back is whether a
plugin process appears in Studio's process list on Windows. That alone separates
"the plugin runs" from "the paths are wrong", and everything else follows from
knowing which.
