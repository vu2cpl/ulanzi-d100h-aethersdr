# Ulanzi D100H → AetherSDR — HANDOVER

**Last updated:** 2026-09-08
**Licence:** Apache-2.0 (see LICENSE / NOTICE) — the plugin is G0JKN's work
**Status:** Working. Controller drives AetherSDR over TCI via a patched third-party plugin.
**Last verified on the radio:** 2026-09-08, after the bundle rebuild — dial tuning
(`vfo:0,0,…` walking 7138→7126 kHz, every write on the 1 kHz grid), mode cycle
(cw→usb→digu→lsb), TUNE query-then-act both ways, band change with mode following,
mute, PTT, and split parking VFO B 5 kHz up on SSB — all confirmed in AetherSDR's
own log via `./watch-ae-log.sh`, not merely on the wire.

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

Read back from the profile manifest 2026-09-01 — there is **no MOX Toggle** bound.
An earlier revision of this table listed one and omitted TUNE / ATU; INSTALL.md was
corrected first and this table was missed. Regenerate rather than hand-edit:

```bash
python3 -c "import json;d=json.load(open('profile/3e14ea8f-bb5d-408e-93ae-1640754bffd3.ulanziProfile/Profiles/c5e3083c-74a0-4ad8-b8b1-86ce97cdb19c/manifest.json'));[print(k,a['Name']) for c in d['Controllers'] for k,a in sorted(c['Actions'].items())]"
```

| Key | Action |
|-----|--------|
| Encoder `0_2` | VFO Tune (knob) |
| `0_0` | PTT (Momentary) |
| `0_1` | Mode Cycle |
| `1_0` | Split Enable |
| `1_1` | Band Up |
| `1_2` | Band Down |
| `2_0` | Mute |
| `2_1` | TUNE / ATU |

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

Fifteen local patches to the plugin (items 16-17 below are tooling, not patches). **A plugin update reverts every one of them**,
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

4. **Mode tokens are lowercase.** AetherSDR reports `modulation:0,usb`, so a
   mixed-case `MODE_CYCLE` made `indexOf()` return `-1`, pinning the cycle to
   entry 0 so it never advanced. Compare lowercase and it advances.

   The *vocabulary* half of this entry was wrong and is corrected here. It read:
   "`CW`, `AM`, `FM` are not AetherSDR modes. The real vocabulary is
   `usb lsb cwr sam nfm digu digl rtty`." All three exist. AetherSDR's connect
   burst is `modulations_list:usb,lsb,cw,cwr,am,sam,fm,nfm,digu,digl,rtty;` and
   the handler lowercases its argument before the lookup, so `modulation:0,CW;`
   is accepted too — verified on the radio 2026-09-03: `modulation:0,LSB;`
   echoes `modulation:0,lsb;`, `modulation:0,AM;` echoes `modulation:0,am;`.
   `cwr` is CW **reverse** (CWL on the Flex), not plain CW, so a cycle mapping
   CW onto `cwr` puts the sideband on the wrong side — which is what patch 12
   went on to fix. The wrong list came from `tci-probe.sh` filtering
   `modulations_list` as noise: the tool suppressed the authoritative line and
   the gap got filled by inference. It went out in upstream issue #3 and was
   caught there by G0JKN. Probe output must never be silently filtered.

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

8. **AF Gain / Mic Gain — the patch stands, its reasoning does not.**
   `cmdAfGain` sent `volume:0,<v>;` and `cmdMicGain` sent `mic_level:0,<v>;`. This
   was written up on 2026-09-01 as a defect: both verbs are non-indexed, so the
   leading `0` was believed to be read as the value, zeroing the level on every
   press. It now sends `volume:<db>;` (percent→dB per #3502) and
   `mic_level:<percent>;`.
   **Disproved on the radio 2026-09-07** — probed with `tci-probe.sh`, each step
   from a different starting value so a rejected write could not hide as a
   no-change:
   ```
   58  ->  mic_level:70;      ->  70     single-param form accepted
   70  ->  mic_level:0,40;    ->  40     TWO-FIELD form ALSO accepted
   40  ->  mic_level:58;      ->  58     restored
   ```
   AE **ignores a leading index and takes the last field**. Upstream's form was
   correct; this was never a bug. The code is kept — the dB scale is worth having
   on its own merits and the single-param form is the one verified here — but it
   is **preference, not a fix**, and it was never reported upstream, which is the
   one piece of luck in this. G0JKN was told on 2026-09-07 and asked not to spend
   his move-week on it.
   **Why it survived nine months:** both forms work, and "both forms work" reads
   exactly like "my form works" unless you test the other one. The patch was
   never wrong in effect, only in explanation, so nothing ever failed to flag it.
   **The distinction to keep:** ONE field is the dangerous shape — `mic_level:0;`
   really is a write of zero, and that is the trap that zeroed `tx_gain` and took
   the station off the air for two days. A trailing index is harmless. Two facts,
   not one; merging them is what produced the wrong claim.
   **None of this can fire on this station.** AF Gain and Mic Gain are **not bound**
   in the profile — all 7 buttons and the knob are taken by `vfo`, `tune`,
   `splitToggle`, `pttMomentary`, `muteToggle`, `modeCycle`, `bandUp`, `bandDown`
   — and our 0.1.5-based build has no connect-time gain seeding (that arrived in
   0.1.7, and uses the safe bare-verb form). `cmdAfGain` is the only sender of
   `volume:` and nothing reaches it, so neither the upstream form nor this patch
   has ever executed here. Patch 8 is dead code, and so was the defect it claimed.
   **`volume:` is therefore deliberately untested**, and only becomes a live
   question if AF Gain is ever bound to a key. If you bind it, probe the verb
   first: same shape as `mic_level` so the same answer is expected, but if that
   inference is wrong the failure mode is 0 dB = FULL VOLUME into headphones.
   The parser's "asymmetric emit format" comment was a separate matter and is
   still corrected: parameter count is fixed per verb on the **emit** side. That
   says nothing about what AE accepts.

9. **The dial tuned the RX VFO under split.** `cmdSetFreq()` hardcoded the VFO
   channel — `vfo:<rx>,0,<hz>` — and `dialRotate()` stepped from `radio.frequency`,
   which the parser only fills from channel 0. So enabling split and spinning the
   knob walked the *receiver* off frequency and left TX exactly where it was: the
   opposite of what split-then-tune means. Reported from the operating desk
   2026-09-01 ("14002 RX, call up 1-2, dial moves RX not TX").
   The dial now targets channel 1 whenever `radio.split` is set, stepping from
   `radio.vfoB`; `changeBand()` deliberately still moves channel 0, since a band
   change is an RX move and dragging TX along would surprise.
   Probed live before coding, and two assumptions did not survive it:
   - AetherSDR **does broadcast** `split_enable` changes (unlike `tune:`, patch 7),
     so the mirror tracks without polling — 4 toggles seen in a 90 s capture.
   - The split TX frequency is mirrored at **both** `vfo:<rx>,1` and `vfo:<rx+1>,0`;
     every VFO-B move emitted the pair while `vfo:0,0` stayed pinned.
   Also fixed alongside: `split_enable` was parsed **without** the `sliceIndex`
   filter that `vfo`/`mute`/`modulation` all have. The connect burst reports every
   receiver, so `split_enable:1,true` landed immediately after `split_enable:0,false`
   and the mirror ended up holding receiver 1's split state for receiver 0.
   **Verified on the dial 2026-09-01.** Split on, knob spun: TX-B walked
   18104100 → 18107500 while `vfo:0,0` stayed pinned at 18104000 the whole time;
   split off, the knob moved RX again. Note AetherSDR resets VFO B to the RX
   frequency each time split is enabled, so the TX offset is set after enabling,
   not before.

10. **Split was a blind toggle on a mirror the radio never confirmed.**
    `split_enable:0,${!radio.split}` trusts a value AetherSDR only refreshes on
    its *own* broadcasts. One flip out of step — an AE restart will do it — and
    the key sends the state the radio already holds (a no-op) while the mirror
    flips anyway. The two then disagree permanently, and since patch 9 steers the
    dial off `radio.split`, the knob silently tunes the wrong VFO. Caught on the
    wire 2026-09-01: AE reported split off for a full 75 s while the plugin was
    writing `vfo:0,1`. Now query-then-act, the patch-7 shape.
    Unlike TUNE the mirror IS updated optimistically, because split only changes
    when something commands it (and AE broadcasts GUI changes), whereas an ATU
    cycle ends by itself. `split_enable:<rx>;` was verified to be a genuine query.

11. **Split now parks the TX slice, Flex-style.** One press opens the TX slice
    **1 kHz up on CW, 5 kHz up on SSB** (operator's convention — SSB pileups
    spread wider), then the knob tunes that slice while RX stays on the DX.
    DIGU/DIGL/RTTY take the 1 kHz offset as narrow modes; say so if data should
    behave like SSB.
    The trap: AetherSDR resets VFO B to VFO A **twice** when split is enabled,
    and the second reset lands *after* a write placed on the first channel-1
    report — so the event-driven version was silently clobbered:
    `SPLIT=true → TX-B +1000 (ours) → TX-B +0 (AE)`. Now it lets AE settle,
    writes, then verifies and rewrites once. Verified on the radio: +1000 on cw,
    +5000 on usb, both holding.

12. **Mode cycle could not leave CW.** The cycle listed `cwr`, but AetherSDR
    *reports* `cw` — both tokens exist (`modulations_list;` answers
    `usb,lsb,cw,cwr,am,sam,fm,nfm,digu,digl,rtty`). So `MODE_CYCLE.indexOf('cw')`
    returned −1 and the cycle reset to entry 0 every time the radio was on CW.
    Exactly the fault patch 4 fixed, surviving in a different token. Now
    **CW / USB / DIGU / LSB**, the operator's set.

13. **Mute was per-receiver, not master.** `mute:<rx>,<bool>` (patch 6) was sent
    only for `radio.sliceIndex`, so under split the other slice stayed audible.
    Now mutes every open receiver. `trx_count` is tracked from the wire because
    it is **dynamic** — see the correction in Open items.

14. **Knob press is fast/slow tune step, not VFO A/B swap.** Swap trades RX and
    TX under split, which is the last thing wanted under your thumb during a
    pileup; it is only meaningful with 2+ slices to switch between, and the Split
    key owns that now. New `step_toggle` press action, added to the VFO property
    inspector, and the profile switched to it. Three rates: slow (`step_hz`),
    fast (`step_hz × coarse_mult`, latched by the press), and press-and-rotate
    multiplying again on top of either.

15. **The dial snaps to the step grid, and the VFO tooltip stopped lying.** Two
    small fixes landed together because each alone was too cheap to justify the
    Studio quit a redeploy costs. **Verified on the radio 2026-09-02**, off-grid —
    which is the only case that proves anything, since an on-grid base behaves
    identically before and after this patch. (AetherSDR's log confirmed the
    on-grid half independently: every post-deploy fast write landed exactly on a
    1 kHz boundary through direction reversals.)
    *Snap:* `dialRotate()` added `direction * hz` to wherever the VFO happened to
    sit, so an off-grid base — a band stack, a click in AetherSDR's panadapter, an
    RIT nudge — kept its offset for the rest of the session: 7.074123 walked
    …123, …223, …323 on slow and …123, …1123 on fast, never reaching a boundary.
    Now the first click off-grid lands on the nearest multiple of the step *in the
    direction of travel* and every click after that is a full step, so slow lands
    on 100 Hz boundaries and fast on 1 kHz ones with this desk's `step_hz` 100 /
    `coarse_mult` 10. It quantises to the computed step rather than to a hardcoded
    100/1000, so press-and-rotate snaps to its own 10 kHz grid and the boundaries
    follow the inspector if either setting is ever changed. Two consequences worth
    knowing at the knob: the first click off-grid moves *less* than a full step
    (from 7.074999 a fast click up moves 1 Hz to 7.075000 — correct, but it can
    read as a dropped click), and up-then-down no longer returns you to an
    off-grid start, which is how every radio with a step grid behaves.
    *Tooltip:* `manifest.json`'s `vfo` Tooltip still described pre-patch-9/14
    behaviour — "Tune the **active slice** … press = **mode/swap**" — wrong on both
    counts. Now: *Tune the TX slice with the dial. Rotate = step, press = fast/slow
    step, press+rotate = coarse step.* Property-inspector hover text only; no
    behaviour reads it.

16. **`tci-watch.sh` added** — the broadcast-vs-query question has now caused
    three patches (7, 9, 10), so it is a tool rather than a thing to re-derive.
    Strictly read-only: unlike `tci-probe.sh` it sends nothing at all. Its first
    run turned up `active_slice` (see Open items).

17. **Tooling + doc drift, found during the 2026-09-01 sweep.** Added `tci-probe.sh`
   (one argument reads, a value writes and confirms first) so the `verb:0;` mistake
   cannot recur, and shipped it in the install bundle. `INSTALL.md`'s key-layout
   table was wrong — it listed a **MOX Toggle** the profile does not contain and
   omitted **TUNE / ATU**; corrected against the profile manifest. Note the manifest
   does not record which key group is physically left vs right.
    Fixed again 2026-09-01: `tci-probe.sh`'s no-verb state dump exited the moment
    AetherSDR sent `ready;`, which lands ~8 lines into the connect burst — so it
    silently truncated the dump and hid `split_enable`, `mute`, `rit`/`xit`, `agc`
    and the entire second receiver. Absent-from-the-dump read as absent-from-TCI
    and produced a wrong diagnosis during the patch-9 probe. The dump now runs to
    its timeout: 120 state lines instead of 8.

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

**Confirmed 2026-09-01:** probed properly as `tx_gain;` it answers `tx_gain:50;`.
It is a fully implemented, non-indexed, 0–100 verb that maps straight to the TX
audio multiplier AE logs per transmission — `tx_gain:100` → `gain=1`,
`tx_gain:0` → `gain=0`, a keyed transmitter radiating silence. This closes the
case: the outage was not inferred from timing, the verb is real and does exactly
what the logs showed.

**Use `./tci-probe.sh` rather than hand-rolled one-liners.** One argument is always
a query (`./tci-probe.sh tx_gain`); a value makes it a write and it confirms first
(`./tci-probe.sh tx_gain 100`). No arguments dumps the full connect burst. It
borrows `ws` from the installed plugin, since `ws` is not installed globally on
this Mac.

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
- **Which verbs BROADCAST vs only answer a query** — the distinction that produced
  patches 7 and 9, so check it before mirroring any new verb in `radio`:
  - `split_enable` **broadcasts.** 4 GUI toggles seen in a 90 s capture, 2026-09-01.
    A parser mirror is enough; no polling needed.
  - `vfo` **broadcasts**, both channels, and the split TX frequency appears twice —
    at `vfo:<rx>,1` *and* `vfo:<rx+1>,0`, always the same value. `vfo:0,0` stays
    pinned while VFO B moves.
  - `tune` does **not** broadcast — query-only, which is why patch 7 is query-then-act.
  - `drive` is emitted at init only; later changes are silent (hence the optimistic
    local mirror in the gain helpers).
  The connect burst is the cheapest place to check: it carries the initial value of
  every verb AE broadcasts. Read it with `./tci-probe.sh` — but only since the
  `ready;` truncation was fixed, or you will see 8 lines of a 120-line burst.

  **Don't reason about this — measure it with `./tci-watch.sh`.** It watches the
  stream read-only (it sends *nothing*, so it is safe mid-QSO) and reports which
  verbs changed on their own versus which only appeared in the burst:

  ```bash
  ./tci-watch.sh                      # 60 s, every verb
  ./tci-watch.sh 90 split_enable vfo  # just these, every change timestamped
  ```

  Exercise the control while it runs. "Burst only" is **not** proof of query-only —
  a verb nobody touched cannot broadcast, and that ambiguity is exactly what made
  patch 7's diagnosis take so long.

---

## Open items

- [x] **Repo published 2026-09-07**, with the Apache-2.0 obligations met first:
      `LICENSE` (upstream's own Apache-2.0 text), `NOTICE` naming G0JKN and listing
      which files are pristine and which are modified, in-file §4(b) notices on the
      three modified text files, and a README licence section pointing anyone who
      just wants the plugin at upstream rather than here.
      `patched/manifest.json` deliberately carries **no** in-file notice — Ulanzi
      Studio parses it and an unknown comment key risks breaking the plugin, so its
      modification is recorded in NOTICE instead.
      `upstream-original/` deliberately carries none either: those files are
      unmodified, and a "this file was changed" header on them would be false.
      **`make-bundle.sh` refused its next run** — patched/ differed from the
      installed plugin by exactly these notices. Resolved 2026-09-08: Studio quit,
      `./restore-plugin-patches.sh`, then `./make-bundle.sh`. The guard was working
      as designed; recorded so it is not mistaken for drift if it recurs.
      The shipped `d100h-aethersdr-macbook.zip` had predated the notices and was
      rebuilt in the same pass — it is now current, and carries LICENSE and NOTICE,
      so the licence travels with a copy handed to another Mac.

- [x] **Slice switching dropped — operator's call, 2026-09-02. Do not re-propose it.**
      Not worth having on this hardware with this software, in either available form, and
      the decision covers both. **The plugin's Slice Cycle** only retargets which receiver
      the plugin addresses (AetherSDR ignores `set_in_focus` / `rx_channel_enable`), which
      is invisible at both ends — AE's UI does not move, and the D100H has no displays —
      and with one receiver open it aims every command at a receiver that does not exist,
      leaving the mirror silently stale. It was never bound anyway; all 7 keys are taken,
      so binding it costs a key that earns its place. **The AetherSDR-shortcut route**
      (Studio's Hotkey action into AE's own next/previous-slice shortcut) would be real and
      visible, but needs AE focused with View > Keyboard Shortcuts on — a precondition that
      does not hold mid-operating. Both were offered and both declined. If a future session
      is tempted: the prize is one receiver's worth of retargeting on a single-receiver
      desk, and the cost is a key. `SLICE_COUNT` stays hardcoded 2; nothing reads it unless
      the action is bound.

- [x] **Dial snap-to-grid + the stale VFO tooltip — both landed as patch 15, 2026-09-02.**
      Raised as two separate deferrals (the tooltip 2026-09-02, the snap the same day) on the
      grounds that neither alone was worth the Studio quit a redeploy costs; the operator's
      call was to pair them, which is what "wait for the next patch that already earns the
      redeploy" was for. See patch 15 under *What changed* for the behaviour and its two
      knob-feel consequences. The snap arithmetic was checked against off-grid, on-grid,
      boundary-adjacent and reversal cases before deploying.

- [x] **Numbering trap resolved — patch 15 landed and the two lists agree again (2026-09-02).**
      The "What changed" list ran plugin patches 1–14 and then continued 15/16 for tooling
      items that patch no plugin code, while README's table and `restore-plugin-patches.sh`
      counted only the 14 plugin patches. Patch 15 is now inserted as 15 and the tooling
      entries renumbered to 16/17, so "patch N" means the same thing everywhere. **The trap
      is structural, not spent** — the next plugin patch is 16 and item 16 above is *not* it,
      so renumber the tooling entries to 17/18 when it lands. (d36329a and this commit are
      two rounds of the same drift; a third is likely.)

- [x] **The `fastStep` latch is invisible by design — behavioural fix declined 2026-09-02.**
      Patch 14's knob press latches fast (`step_hz × coarse_mult` = 1 kHz on this desk) with
      no indicator, so a stray press tunes ten times too far and the only symptom is the VFO
      running away; `console.log('[vfo] step now …')` does not help, since Studio eats plugin
      stdout. **Do not propose an on-key or on-knob label as the fix** — see *Hardware facts
      that matter*: the D100H has no displays at all, and `setStateIcon` / `setPathIcon` send
      cleanly and render nothing. A label patch was written on 2026-09-02 and backed out for
      exactly this reason. Behavioural alternatives were offered (auto-revert to slow after an
      idle timeout; drop the latch and rely on momentary press-and-rotate; a macOS notification
      on toggle) and the operator chose to keep current behaviour. Recovery is: press the knob
      once, or restart the plugin — `fastStep: false` is in the initial `radio` object.
- [x] **"The dial ignores `step_hz`" was NOT a bug — closed 2026-09-01.**
      The 100 Hz step observed while verifying patch 9 looked like `intSetting()`
      falling back to `TX_STEP_HZ`, and was written up here as a patch-3 regression.
      It was not. Instrumenting `onAdd` showed Studio delivering the setting exactly
      as saved:
      `param={"coarse_mult":"10","press_action":"vfo_swap","step_hz":"100", …}`
      with `context` matching the cache key (`…vfo___0_2___c44be049…`). The settings
      pipeline works and patch 3 is intact.
      The real fault was **profile drift**: the installed profile had `step_hz` 100
      while the repo's `profile/` copy — what `make-bundle.sh` ships to a new Mac —
      still had the 1000 it was committed with in b745ea2. A second Mac would have
      tuned ten times coarser than this desk. Resolved by syncing `profile/` from
      the installed copy (100 Hz is the value actually operated with) and correcting
      INSTALL.md, which documented 1 kHz.
      **Lesson:** `profile/` is a hand-taken snapshot with nothing keeping it honest.
      Diff it against the installed copy before every `make-bundle.sh`:
      ```bash
      diff -r ~/Library/Application\ Support/Ulanzi/UlanziDeck/ProfilesV2/*.ulanziProfile \
              profile/*.ulanziProfile
      ```
- [x] **Patch 9 verified on the dial 2026-09-01** — TX-B moved through 35 kHz while
      `vfo:0,0` stayed pinned; knob returns to RX when split is off.
      Still unhandled: after a **Slice Cycle**, `radio.vfoB` still holds the
      previous slice's channel 1 — `doSliceCycle()` re-queries `vfo:<n>,0` and
      `modulation` but not channel 1 or `split_enable`. Harmless in the shipped
      profile, which has no Slice Cycle key bound.
- [x] **Patch 8 verified on the radio 2026-09-01** — but not from the D100H, because
      AF Gain and Mic Gain are not bound in the operator profile (all 7 keys and the
      knob are taken: PTT, Mode Cycle, Split, Band Up/Down, Mute, TUNE, VFO). That is
      also why the zero-writing bug never fired from a press — no two-param
      `mic_level` appears in any AetherSDR log. Verified over a websocket instead:
      `mic_level;` → 79, `mic_level:40;` → reads back 40, restored to 79. The
      single-param form sets the value it names; the old `mic_level:0,40;` would have
      set 0. Bind the actions to a second Studio page if you want them on the dial.
- [ ] **Decide AetherSDR's TCI TX gain deliberately.** The probe sweep left it at 0;
      it now reads `tx_gain:50` (AE logs `gain=0.5`), while every working session
      through 31 Aug ran at `gain=1` — i.e. `tx_gain:100`. Read it with
      `./tci-probe.sh tx_gain`, set it with `./tci-probe.sh tx_gain 100`.
- [ ] `SLICE_COUNT` is hardcoded to **2**. **`trx_count` is dynamic and counts
      RECEIVERS — not split.** Tested 2026-09-01: with split enabled it stays at
      `1`, because split uses VFO channel B of the same receiver
      (`channels_count:2`) rather than opening a receiver. It reads `2` when a
      second receiver is genuinely open in AE. Two earlier notes here were wrong
      about this — first that it is always 1, then that split makes it 2. Patch 13
      reads it off the wire into `radio.trxCount`; `SLICE_COUNT` should too.
- [x] **`active_slice` tested 2026-09-01 — READ-ONLY, not a slice-focus control.**
      `tci-watch.sh` found `active_slice:0,A;` in the connect burst, which looked
      like it might overturn the "no slice switching" verdict. It does not:
      `active_slice:0,B;` is silently discarded, tested both with one slice and
      with split open. The Studio Hotkey route below remains the only way to move
      AetherSDR's own focus.
      Worth reading though — it **tracks and broadcasts**: enabling split moved it
      `0,A` -> `1,B` unprompted, disabling put it back. That is the active-slice
      state the plugin currently has to infer, available for free.
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
- [x] **G0JKN replied 2026-09-03; PR is open.** He synced the repo to the in-tree
      **v0.1.7** (`909d90b`), which closes findings **1** (port default — with a
      `migrateTciUrl()` that rewrites a persisted 40001, better than our patch) and
      **5** (Slice Cycle removed outright). 0.1.7 also adds five rotary actions and
      keeps our TCI `volume` dB handling.
      He challenged finding 4's mode vocabulary and was right — see the mode-token
      entry above; the wrong list was our own probe filtering `modulations_list`.
      **PR: [nigelfenton/aethersdr-ulanzi-plugin#4](https://github.com/nigelfenton/aethersdr-ulanzi-plugin/pull/4)**,
      from `vu2cpl/aethersdr-ulanzi-plugin` branch `fix/persistence-mode-tune`, four
      commits on `909d90b`: inspector persistence, mode-cycle case compare, TUNE
      query-then-act (its own commit, as he asked), README roadmap.
      **Tested on the radio 2026-09-03** (D100H, Studio 3.2.11, AE on 21.270), then
      the 0.1.5 patched build and the profile were restored. All three fixes verified:
      mode cycle walks all seven modes (proving `am`/`fm` are real — see patch 4);
      TUNE starts AND stops, rapid double-presses alternating at ~250 ms with AE
      answering each query in ~20 ms so the 500 ms fallback never fired; inspector
      settings persist and repopulate. Two further faults surfaced and are fixed in
      the PR (`aaedb8a`): **`setSettings()` REPLACES the stored object**, so saving a
      trimmed form deletes sibling keys — on this profile it wiped `step_hz`,
      `coarse_mult` and `press_action` off the dial, exactly the 10x-coarser-dial
      hazard `make-bundle.sh` guards against, restored from the backup below; and the
      form did not repopulate on reopen (Studio sends `add` on first open only), so it
      showed the HTML default and read as "did not save" when only the display was
      wrong — fixed with `getSettings()` on connect.
      **`watch-ae-log.sh` was added in the same session** — reads AetherSDR's own log
      to show what the *plugin* sent, the one question `tci-probe.sh` and
      `tci-watch.sh` cannot answer (Studio swallows plugin stdout). It is what
      verified all three fixes; filters MSHV's 1 Hz poll.
      **Backups taken before the swap and used to restore:**
      `backups/live-0.1.5-20260903-170828.tar.gz` (plugin) and
      `backups/live-profile-20260903-171129.tar.gz` (profile).
      **Testing this build again costs three keys:** PTT, Split and Mute are our
      local actions and do not exist upstream, so Studio shows "plugin missing" on
      them. Bindings survive — but do NOT rearrange or re-save the profile in
      Studio's UI while an upstream build is installed, or they will be dropped.
      **Debugging an inspector:** the webview has no readable console. Have it beacon
      each SDK event to a throwaway local HTTP server — that is what settled this, and
      it disproved a confident wrong guess (Studio DOES supply `?uuid=`, so a bare
      `$UD.connect()` does not throw; `connect()` is still required because `send()`
      is guarded by `this.websocket &&`).
      Two things learned from him, server-side: AE broadcasts `tune_drive:` but
      **never** `tune:`, and `cmdVolume` reads a sent `0` as 0 dB = **FULL volume**
      (send -60 for silence). He tests on Windows with a D200H/D200X.
      **No `mute` action exists at 0.1.7** — he suggested folding a `mute` index fix
      into the TUNE commit, but there is no manifest action, no `case 'mute'` and no
      builder, only a dead `radio.muted` field. Flagged in the PR; our Mute (patch 13)
      is a local addition, not an upstream fix.
- [x] **PR #4 approved and MERGED 2026-09-06, issue #3 closed.** G0JKN approved at
      `aaedb8a` and merged a minute later. He did not read the claims, he tested them
      — "because two of these can key a transmitter": he drove our TUNE state machine
      through six cases with a stubbed `tciSend`, and went looking specifically for
      the two that matter — an unsolicited `tune:true` with no press pending must send
      **nothing**, and the 500 ms timeout must fail toward `tune:0,false`. Both hold.
      His words for the direction of that fallback: stopping a tune nobody started
      costs nothing, starting one nobody asked for is a keyed transmitter.
      He conceded finding 4 publicly ("you were right and my issue was wrong") and
      called checking the claim instead of implementing it the correct handling of a
      wrong instruction from a maintainer. He rates `aaedb8a` — the `setSettings()`
      data-loss merge — the best commit in the PR, and reproduced the loss on our own
      settings shapes.
      **What he did NOT verify, in his own words:** he has no D100H and never ran it
      against a live AetherSDR or a real ATU. Everything upstream is our hardware
      evidence (D100H, macOS, Studio 3.2.11) plus his stub runs. The TUNE path has
      never been exercised against a real tuner on his side.
      **His one request is done (2026-09-07):** the body listed four commits and the
      branch has five, so `aaedb8a` was invisible to anyone skimming. The commit table
      now has a fifth row plus a short paragraph saying it is the data-loss fix and
      why it could not have existed before the persistence commit. Editing a merged
      PR body changes nothing that ships — it changes what the next reader sees, which
      was the whole point of the request.
- [x] **Write access on `nigelfenton/aethersdr-ulanzi-plugin` — accepted, live.**
      Verified 2026-09-07: `gh api /repos/nigelfenton/aethersdr-ulanzi-plugin` reports
      `push: true`, and the collaborator list is `nigelfenton` (admin), `vu2cpl`
      (write). No invitation is pending.
      **We are the practical maintainer of the D100H side.** He has no D100H and is
      mid-house-move with poor review latency for the next few weeks; his instruction
      is to use our own judgement on anything dial- or Studio-specific.
      **Branch protection:** he says `main` now requires a PR — no direct pushes, no
      force-push, no branch deletion — with **required approvals set to 0**, so we can
      open a PR and merge it ourselves without waiting for him. Admins are not exempt.
      This could NOT be confirmed from here: the protection endpoint 404s for a
      non-admin token (which is what a non-admin sees whether or not protection
      exists) and `/rules/branches/main` is empty, which only rules out rulesets, not
      classic protection. **Assume the PR-only rule is real; do not push to `main`.**
      **The one standing rule he asked for, and it is the right one:** anything that
      keys the transmitter gets the TUNE treatment — query-then-act, fail safe toward
      not transmitting, and say in the code *why*. That is the one class of bug in
      this plugin that can do something worse than not work.
- [ ] `vfo_swap` on knob press is guarded — it does nothing unless AetherSDR has
      reported a VFO B for the slice. Silent by design; may look broken. In practice
      the guard should never fire: the connect burst carries `vfo:<rx>,1` for every
      receiver (confirmed 2026-09-01, once the probe stopped truncating at `ready;`).

---

## Deploying to another Mac

`./make-bundle.sh` produces a self-contained zip (patched plugin including
`node_modules`, the profile from `profile/`, INSTALL.md and `install.sh`). It
refuses to build unless the installed plugin matches `patched/`, so a reverted
install cannot ship.

**`install.sh` runs on the TARGET Mac, from inside the unzipped bundle** — added
2026-09-08. It does INSTALL.md steps 1-2 and the step-5 verification: quits Studio
(prompting, `--yes` to skip), copies plugin + profile, then checks `node_modules/ws`
is present, `app.js` parses, all 21 manifest actions are handled by the source,
port 50001 is in `app.js`, AetherSDR is listening, and the dial is on Bluetooth.
`--check` reports and changes nothing. Two deliberate choices: it **moves** any
existing install into a timestamped `replaced-*` folder rather than deleting it,
because per-action settings (`step_hz`, `coarse_mult`, `press_action`, `tci_url`)
live in the profile and a previous install may hold values that exist nowhere
else; and a missing `node_modules/ws` is treated as a **broken bundle and a hard
error**, not a step to run — the bundle exists precisely so the target needs no
npm, so its absence means the download or the unzip lost files.

Steps 3 (starting AetherSDR's TCI server) and 4 (selecting the profile) stay
manual: both are GUI work inside apps the script cannot drive.

**No Raspberry Pi branch, and that is not an oversight.** The shack rule is that
install scripts branch macOS vs Pi; here there is no Pi to branch to — Ulanzi
Studio ships no Linux or ARM build at all. `install.sh` detects a non-Darwin host
and stops with that reason rather than implying a path that does not exist.

`profile/` is the operator layout — 7 buttons + knob, 8 assignments. It binds to
the D100H by device UUID `4250315A3538380201E26E435603F278`, which comes from the
dial itself, so pair the dial on the target Mac **before** first launching Studio
there or the profile will not attach.

**The built zip IS committed as `d100h-aethersdr-macbook.zip` — reversed on
2026-09-02, operator's call.** It had deliberately not been, on the grounds that it
is derived, drifts from `patched/` silently, and carries `node_modules` that
`.gitignore` excludes; the reason to carry it anyway is that the target Mac can
then download it straight from the private repo instead of needing a file transfer.
The objections still hold and are now the maintenance burden: **rebuild and
re-commit the zip in the same cycle as ANY commit that touches something the
bundle ships**, because nothing guards it the way `make-bundle.sh` guards
`patched/` and `profile/` — a stale zip is indistinguishable from a current one.
Operator's rule, restated 2026-09-08: *rebuild the zip with any commits*, not
merely with plugin patches. Narrowing it to "plugin patch" is what let the
2026-09-02 zip sit five commits stale — `tci-probe.sh` had lost its NOISE-filter
fix and `LICENSE`/`NOTICE` were absent entirely, none of them plugin patches.
The bundle ships the patched plugin, `profile/`, `INSTALL.md`, `tci-probe.sh`,
`tci-watch.sh`, `LICENSE` and `NOTICE` — a commit to any of those seven stales it. It also vendors G0JKN's full plugin, which
this repo otherwise deliberately does not. If it starts drifting in practice,
delete it and go back to building on demand, or attach it to a release instead.

**Build with Studio quit.** `make-bundle.sh` guards against profile drift but has
no Studio-running check the way `restore-plugin-patches.sh` does, and Studio
flushes profile state on its own schedule: a bundle built while it is up can be
minutes stale. On 2026-09-02 that shipped a zip whose Mute key had no label,
caught by the operator, and cost a rebuild and a second profile commit. **Adding the guard
was offered and declined 2026-09-02 — do not re-propose it**; quitting Studio first
is the standing workaround, and the operator's call is that a two-line check is not
worth another plugin-adjacent edit. Recorded here because the gap is written down
right above it, and a future session would otherwise read it as an obvious to-do.

## Windows — ported 2026-09-08, never run on Windows

The operator asked whether this can be used on Windows, then asked for the full
port including diagnostics. `windows/` now holds `install.ps1`, `tci-probe.ps1`,
`tci-watch.ps1`, `watch-ae-log.ps1` and a README. **There is no Windows machine
here**, so none of it has run on the platform it targets — but it is not
unverified either, and the distinction is worth keeping straight:

- all four **parse** under PowerShell 7.6 (installed on this Mac for the purpose);
- `install.ps1` was **run** under `pwsh` on macOS against a scratch `%APPDATA%` —
  fresh install, re-install exercising the move-aside backup, the
  manifest-vs-source verification, and `-Check`;
- `tci-probe.ps1`'s wrapper was **run**: ws located, node located, temp `.mjs`
  written, embedded program executed to its own error handler;
- `watch-ae-log.ps1` was **run against a synthetic AE log and produced output
  byte-identical to `watch-ae-log.sh`** on the same input.

What remains untested is everything only Windows can answer: whether Studio finds
the plugin at these paths, whether the profile binds to the dial, where Studio's
bundled Node lives, and whether the D100H works at the far end.

**The macOS run already paid for itself.** `install.ps1` called
`Get-NetTCPConnection`, which is Windows-only, and with `$ErrorActionPreference =
'Stop'` a missing cmdlet is a *terminating* error — so the script installed
everything correctly, printed every verification, then died red before reaching
"Done", at a purely informational step. On Windows the cmdlet usually exists, so
this would have lain hidden until it met a machine without the NetTCPIP module,
where it would have looked like a failed install that had actually succeeded. Now
guarded with `Get-Command`, with a `netstat` fallback. Run a port anywhere you
can, even on the wrong OS.

**Both halves ship for Windows.** Ulanzi Studio has a Windows 10+ build,
AetherSDR a Windows installer plus a Microsoft Store listing. AetherSDR also
ships a Linux AppImage, but Studio has **no** Linux build, so Linux is out at the
Studio end whatever AetherSDR does. The plugin itself is portable in principle:
JavaScript on the Node runtime Studio ships, over a localhost WebSocket, no Mac
API, no native module, `ws` pure JS under `--omit=dev`.

### Paths — what is confirmed and what is not

Chased to primary sources rather than guessed, because a guessed path in an
install doc looks like knowledge:

- **`%APPDATA%\Ulanzi\UlanziDeck\Plugins`** — CONFIRMED against a shipped
  third-party UlanziDeck plugin (github.com/narlei/ulanzideck_claude), which
  documents that exact path. Same doc confirms end users need no Node.js,
  i.e. Studio bundles its own v20 as on macOS.
- **`%LOCALAPPDATA%\AetherSDR\logs`** — CONFIRMED from AetherSDR's own source.
  `src/core/LogManager.cpp` builds the log path as
  `QStandardPaths::GenericConfigLocation + "/AetherSDR/logs/aethersdr.log"` with
  rotated `aethersdr-*.log` beside it; `src/core/SettingsPaths.h` documents
  `GenericConfigLocation` as `%LOCALAPPDATA%/AetherSDR` on Windows.
- **`%APPDATA%\Ulanzi\UlanziDeck\ProfilesV2`** — INFERRED from the macOS
  layout (ProfilesV2 is a sibling of Plugins). Never seen on Windows. This is
  the half carrying `step_hz`, `press_action` and split behaviour, so a wrong
  path loses the operating settings and not merely the layout. **First suspect
  if the profile does not appear in Studio.**
- **Studio's process name, and where its bundled Node lives** — UNKNOWN. The
  installer matches any process containing "Ulanzi" and reports what it found;
  the diagnostics prefer a system `node` and then hunt for `node.exe` under the
  Ulanzi install dirs.

### The verbatim-JavaScript decision, and the guard that enforces it

`tci-probe.ps1` and `tci-watch.ps1` embed the macOS JavaScript **byte for byte**
between `---8<---` markers; only the shell wrapper is new. The tidier design is a
shared `.mjs` both platforms call — rejected, on purpose: AetherSDR was not
running when these were written, so that refactor could not be verified against
the radio, and `tci-probe.sh` is the file standing between the operator and a
repeat of the 2026-09-01 `tx_gain:0;` incident. An unverifiable refactor of that
script is the wrong risk.

Verbatim is only true while something checks it, so **`make-bundle.sh` now
refuses to build when the embedded JS drifts from the `.sh`**. The guard was
tested in both directions: it passes on the clean tree, and it was proven to fail
by injecting exactly the `modulations_list` NOISE filter that caused the original
mode-list bug. If the program must change, change the `.sh` and re-extract —
never hand-edit one side.

### Not ported, deliberately

`restore-plugin-patches.sh` and `make-bundle.sh` — the maintenance loop. They are
about *this* desk's install, not a target machine; a Windows user consuming the
bundle does not need them.

### Still outstanding

- The `ProfilesV2` path is still inferred, and it is the half carrying the
  operating settings. First suspect if the profile does not appear in Studio.
- Studio's process name and the location of its bundled Node on Windows are both
  still unknown; the scripts probe rather than assume, but a real answer would be
  better than a probe.
- The first datum worth having from any real attempt is whether a plugin process
  appears in Studio's process list on Windows — that alone separates "the plugin
  runs" from "the paths are wrong".
- PowerShell 7.6 is now installed on this Mac (`brew install powershell`), so any
  future port work can be parse-checked and partly exercised without a Windows
  host. That is how the `Get-NetTCPConnection` bug was found.

## Diffing against upstream

`upstream-original/` holds G0JKN's plugin exactly as shipped (v0.1.5), so the
fifteen patches can be inspected against their true baseline and bug reports can
cite original line numbers:

```bash
diff -u upstream-original/plugin/app.js patched/plugin/app.js
```

## Assignable actions

See **[TCI-ACTIONS.md](TCI-ACTIONS.md)** — all 51 assignable actions, probed live
against the radio, split into implemented / available-to-add / confirmed-impossible,
with the observed wire shape for each and the probe method to re-check.

## Related

- AetherSDR 26.9.1, signed Developer ID: Jeremy Fielder (Team `944M585CW5`)
- Ulanzi Studio 3.2.11
- Plugin: `~/Library/Application Support/Ulanzi/UlanziDeck/Plugins/com.g0jkn.aethersdr.ulanziPlugin`
- Profiles: `~/Library/Application Support/Ulanzi/UlanziDeck/ProfilesV2/`
- AetherSDR logs: `~/Library/Preferences/AetherSDR/logs/`
