# Ulanzi D100H → AetherSDR — HANDOVER

**Last updated:** 2026-09-01
**Status:** Working. Controller drives AetherSDR over TCI via a patched third-party plugin.

---

## Current state

The Ulanzi D100H dial controller drives **AetherSDR** through
**Nigel Fenton (G0JKN)'s "AetherSDR Controller" plugin for Ulanzi Studio**
(`com.g0jkn.aethersdr.ulanziPlugin` v0.1.5), which talks to AetherSDR's
**TCI WebSocket** on `ws://127.0.0.1:50001`.

Ulanzi Studio profiles are the configurable-profile layer — pages and per-button
assignments live there, not in AetherSDR.

Original plugin by Nigel Fenton (G0JKN). All work in this repo is local patching
of that plugin; the plugin itself is theirs.

### Hardware facts that matter

- The D100H (Studio device type `Dial`) is **7 physical buttons + 1 knob** —
  three along the top, two on the left, two on the right.
- **There are no per-key displays.** On-key text or icon labels are impossible.
  Don't spend time on `setPathIcon` text feedback; it sends fine and renders nothing.
- It connects over **Bluetooth LE**, not USB: product `Ulanzi Dial`, manufacturer
  `KEHWIN`, VID `0xFFF1` / PID `0x0082`. It will never appear in the IOUSB plane;
  look in `ioreg -c IOHIDDevice`.
- Studio's grid coordinates (`0_0`, `2_1`, …) do **not** map to a visual 3×3 grid.
  Read the assignment from the profile, or from Studio's own device picture.

### Current profile layout

| Key | Action |
|-----|--------|
| Encoder `0_2` | VFO Tune (knob) |
| `0_0` | PTT (Momentary) |
| `0_1` | Mode Cycle |
| `1_0` | Split Enable |
| `1_1` | Band Up |
| `1_2` | Band Down |
| `2_0` | MOX Toggle |
| `2_1` | Mute |

### Do NOT use AetherSDR's built-in "Ulanzi Dial" HID path

It is a separate, inferior route: it reads the dial as a raw BLE HID keyboard, has
**no named profiles** (profiles exist only on the MIDI path), and it fights Ulanzi
Studio for exclusive HID access (`exclusive HID access denied; opening shared`).
In shared mode the dial's keystrokes leak into whatever app has focus.

Keep `HidEncoderEnabled` **off** in `~/Library/Preferences/AetherSDR/AetherSDR.settings`.

AetherSDR *does* need **Input Monitoring** granted if you ever enable that path
(failure signature: `failed to exclusively open HID manager -536870174`, which is
`0xE00002E2` = `kIOReturnNotPermitted`). Not needed for the TCI/plugin route.

---

## What changed

Seven local patches to the plugin. **A plugin update reverts every one of them**,
and the symptom is a controller that looks completely dead while the profile still
looks perfect. Run `./restore-plugin-patches.sh` after any update.

1. **TCI port.** Plugin shipped `ws://127.0.0.1:40001`; AetherSDR's documented
   default is **50001**. Fixed in `plugin/app.js` and both property inspectors.
   Worth reporting upstream — every fresh install hits this.

2. **Missing dependencies.** Upstream ships `package.json` + lockfile but no
   `node_modules`. `import WebSocket from 'ws'` therefore killed the plugin at
   startup and **no plugin process ever appeared**. Fix: `npm ci --omit=dev`.

3. **Settings never persisted.** Both inspectors called `sendParamFromPlugin()`,
   which only *forwards* to the running plugin (payload key `param`). The call that
   **saves** is `setSettings()` (payload key `settings`). Additionally the browser
   SDK defines `$UD` but never calls `connect()`. Consequence: no property-inspector
   field had ever saved for any action — every `ActionParam` was `{}`, including
   `tci_url`, which is why patch 1 was unavoidable. Plugin now also handles
   `onDidReceiveSettings`.

4. **Invalid mode tokens.** `CW`, `AM`, `FM` are not AetherSDR modes. The real
   vocabulary is `usb lsb cwr sam nfm digu digl rtty`, lowercase. A case mismatch
   also made `MODE_CYCLE.indexOf()` return `-1`, pinning the cycle to entry 0 so it
   never advanced. Cycle is now limited to the working set `usb, lsb, digu, cwr`.

5. **Band stacking.** Band up/down jumped to fixed defaults, several of which sat on
   the **band edge** (40m `7.200`, 80m `3.800` are the top limits in Region 3).
   Now remembers frequency *and* mode per band and restores on return; defaults only
   apply on a band's first visit. Defaults moved off the edges.

6. **Malformed TCI commands.** Two verbs were missing their receiver index and were
   being silently discarded by AetherSDR:
   - `mute:true;` → must be `mute:<rx>,<bool>`
   - `if:<n>;` was never a slice command at all — `if` is TCI's **IF-OFFSET** verb
     (`if:<rx>,<sub_rx>,<hz>`), so every Slice Cycle press fired a malformed IF
     command. Removed.

7. **TUNE could not be switched off.** Two compounding faults. The parser read
   the state from `p[0]` — the *receiver index* — instead of `p[1]`. Fixing that
   was not enough: **AetherSDR never broadcasts tune state changes**, it only
   answers a direct `tune:0;` query, so any parser-derived mirror stays stale
   forever and `!radio.tuning` was always `true`. The button could start a tune
   cycle but never stop one, and tune keys the transmitter.
   TUNE is now **query-then-act**: ask for the live value, send the opposite when
   the answer arrives, and fall back to `tune:0,false` if nothing answers within
   500 ms (the safe direction for a transmit action). An optimistic local mirror
   was rejected because an ATU cycle also ends on its own, which would degrade the
   button to every-other-press. **Verified working on the radio 2026-09-01.**
   (`rit_enable:` and `tune:` command formats were both probed and are correct.)

8. **AF Gain / Mic Gain wrote zero on every press.** `cmdAfGain` sent
   `volume:0,<v>;` and `cmdMicGain` sent `mic_level:0,<v>;`. Both verbs take **no**
   receiver index (`volume:<value>`, `mic_level:<value>`), so AetherSDR read our
   leading `0` as the value — every press set the level to **0**, whichever
   direction it was pressed. Harmless only for as long as the plugin pointed at
   port 40001 and nothing was listening; patch 1 made these presses live.
   Now sent as `volume:<db>;` (percent→dB per #3502) and `mic_level:<percent>;`.
   The parser's "asymmetric emit format" comment was also wrong and is corrected:
   parameter count is fixed per verb, not varying by context. Found 2026-09-01
   while tracing the TX-audio outage below; **not yet pressed on the radio.**

Also added: **Split Enable**, **Mute**, and **PTT (Momentary)** actions; per-action
dial dispatch (the encoder handlers were hardcoded and ignored whatever you assigned
to the knob); `onKeyUp` (absent entirely, so momentary anything was impossible);
and the previously-dead `press_action` / `step_hz` / `coarse_mult` inspector fields
are now actually read.

---

## Known gotchas

**⚠️ `verb:0;` IS NOT A SAFE QUERY. It took the station off the air.**

TCI verbs come in two shapes, and the probe form that is a harmless query for one
is a **destructive write of zero** for the other:

| Shape | Example | `verb:0;` means |
|---|---|---|
| receiver-indexed | `drive:<rx>,<value>` | query receiver 0 — safe |
| not indexed | `volume:<value>`, `mic_level:<value>`, `tx_gain:<value>` | **set the value to 0** |

On **2026-09-01 at 00:03:43** a sweep of every known verb in the `verb:0;` form
(the one this section used to recommend) sent `tx_gain:0;`, `mic_level:0;` and
`volume:0;`. AetherSDR's TCI **TX gain went to 0 and stayed there across restarts**.
The radio then keyed normally on FT8 and radiated nothing — MSHV's audio was being
multiplied by zero. From AE's own log:

```
28 Aug (working):  TX_CHRONO ... gain=1   peak=0.905308  rms=0.606374
01 Sep (silent):   TX_CHRONO ... gain=0   peak=0         rms=0
```

215 transmissions at `gain=1` before the sweep, 50 at `gain=0` after. Two days were
lost chasing the plugin, the port change and MSHV before the log gave it up.

**How to tell the shapes apart, safely:** the bare `verb;` form (no colon, no value)
is a query for *both* shapes and can never write. Use it first; only once you know
a verb is receiver-indexed is `verb:0;` safe.

```
-> mute;        <- mute:0,false        receiver-indexed (so mute:<rx>,<bool>)
-> mic_level;   <- mic_level:0;        NOT indexed — `mic_level:0;` would WRITE 0
-> if:0;        <- if:0,0,0            if is IF-OFFSET, not slice select
```

Corollary: a verb that stays silent is not necessarily unimplemented — a *set* draws
no reply either. `tx_gain:0;` was logged as received, answered nothing, and changed
the radio anyway. Silence means "not a query", not "not supported".

**Probe a TCI verb before writing code against it.** Every "button not working"
report in this project turned out to be a malformed TCI command, never the button —
AetherSDR silently discards malformed commands, which is indistinguishable from a
dead button. Probe with the bare `verb;` form per the warning above.

**Debug logging.** `plugin/app.js` has `const DEBUG = false` gating a `dbg()` file
log to `/tmp/aethersdr-ulanzi-debug.log`. Set it `true` to see whether a press even
reaches the plugin — Studio consumes plugin stdout through a pipe, so `console.log`
is invisible and this is the only view. It settles "dead button vs bad command"
in one press.

**MSHV also connects to TCI 50001** for DAX audio. When watching for the plugin's
connection, filter it out or you get a false positive.

**Ulanzi Studio rewrites plugin/profile state on exit** — quit it before editing
plugin files. The restore script refuses to run while it is up.

**Restart Studio after any plugin file change.** `app.js` is only read at plugin start.

### AetherSDR TCI limits — verified by probe, not assumption

- **No slice switching.** `set_in_focus` and `rx_channel_enable` are accepted and
  silently ignored. Slice Cycle therefore only retargets which receiver the *plugin*
  addresses, which is invisible in the AetherSDR UI.
- **No antenna control.** `rx_ant`, `tx_ant`, `ant`, `antenna`, `xvtr` all
  unanswered. Not in the shortcut editor either. The MQTT antenna topics are
  **display names only** ("AetherSDR still sends canonical radio antenna tokens").
  ANT / RX_A is UI-only.

---

## Open items

- [ ] **Untested by operator:** band stacking, Slice Cycle's receiver retargeting,
      and the patch-8 AF Gain / Mic Gain fix (`volume:<db>;` / `mic_level:<percent>;`).
      Press each once and confirm on the wire before trusting them — these two
      actions wrote zeros for their whole life until 2026-09-01.
      (TUNE query-then-act was tested and works — 2026-09-01.)
- [ ] **Restore AetherSDR's TCI TX gain deliberately.** The probe sweep left it at 0;
      it was found and set to 0.5 on 2026-09-01. Confirm 0.5 is the value you actually
      want — the working sessions through 31 Aug all logged `gain=1`.
- [ ] `SLICE_COUNT` is hardcoded to **2**. AetherSDR reports `trx_count:1` yet answers
      on receiver index 1 with independent state (3.553 MHz CW), so the real slice
      count can't be inferred from TCI. Set it to match actual operating practice.
- [ ] **Visible slice switching** is possible via a different route: AetherSDR's
      shortcut editor has a "next/previous slice" action, and Studio ships a built-in
      **Hotkey** action (`com.ulanzi.ulanzideck.system.hotkey`). Needs AetherSDR
      focused and **View → Keyboard Shortcuts ON** (off by default).
- [x] **Reported upstream to G0JKN** — 2026-09-01, as
      [nigelfenton/aethersdr-ulanzi-plugin#3](https://github.com/nigelfenton/aethersdr-ulanzi-plugin/issues/3),
      framed as the "first-light smoke test with D100H" the README lists as an open
      roadmap item. Five findings: patches 1, 3, 4, 6 and 7 here (TCI port default,
      inspector settings never persisting, invalid mode tokens, malformed `if:`
      slice command, TUNE runaway). PR offered.
      Deliberately excluded: band stacking and the band-default frequencies are
      local preference, not defects. **The missing `node_modules` is NOT a bug** —
      upstream's README documents `npm install` as install step 3; it only bit us
      because the plugin was installed by copying the folder rather than following
      that step. Watch the issue for a reply.
- [ ] `vfo_swap` on knob press is guarded — it does nothing unless AetherSDR has
      reported a VFO B for the slice. Silent by design; may look broken.

---

## Deploying to another Mac

`./make-bundle.sh` produces a self-contained zip (patched plugin including
`node_modules`, the profile from `profile/`, and INSTALL.md). It refuses to build
unless the installed plugin matches `patched/`, so a reverted install cannot ship.

`profile/` is the operator layout — 7 buttons + knob, 8 assignments. It binds to
the D100H by device UUID `4250315A3538380201E26E435603F278`, which comes from the
dial itself, so pair the dial on the target Mac **before** first launching Studio
there or the profile will not attach.

The built zip is deliberately NOT committed: it is derived, it would drift from
`patched/` silently, and it carries `node_modules`, which `.gitignore` excludes.
Attach it to a GitHub release if a fixed artifact is ever needed.

## Diffing against upstream

`upstream-original/` holds G0JKN's plugin exactly as shipped (v0.1.5), so the
seven patches can be inspected against their true baseline and bug reports can
cite original line numbers:

```bash
diff -u upstream-original/plugin/app.js patched/plugin/app.js
```

## Assignable actions

See **[TCI-ACTIONS.md](TCI-ACTIONS.md)** — all 50 assignable actions, probed live
against the radio, split into implemented / available-to-add / confirmed-impossible,
with the observed wire shape for each and the probe method to re-check.

## Related

- AetherSDR 26.9.1, signed Developer ID: Jeremy Fielder (Team `944M585CW5`)
- Ulanzi Studio 3.2.11
- Plugin: `~/Library/Application Support/Ulanzi/UlanziDeck/Plugins/com.g0jkn.aethersdr.ulanziPlugin`
- Profiles: `~/Library/Application Support/Ulanzi/UlanziDeck/ProfilesV2/`
- AetherSDR logs: `~/Library/Preferences/AetherSDR/logs/`
