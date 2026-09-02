# D100H → AetherSDR — install on a second Mac

Self-contained. `node_modules` is bundled, and Ulanzi Studio ships its own Node
runtime, so **no `npm` and no system Node are needed**.

This is Nigel Fenton (G0JKN)'s *AetherSDR Controller* plugin with fifteen local
patches applied — the stock plugin does not work against AetherSDR as shipped.

## Before you start

- **AetherSDR** installed and able to reach the radio.
- **Ulanzi Studio** installed (this bundle was made with 3.2.11).
- **D100H paired** to the MacBook over Bluetooth. Pair it first — Studio needs to
  register the device before the profile will bind to it.

## 1. Quit Ulanzi Studio

Not just close the window — **Cmd-Q**. Studio rewrites plugin and profile state
on exit and will overwrite anything you copy in while it's running.

```bash
osascript -e 'quit app "Ulanzi Studio"'
```

## 2. Copy the plugin and the profile

```bash
UD="$HOME/Library/Application Support/Ulanzi/UlanziDeck"
B="$HOME/Downloads/d100h-aethersdr-macbook"

mkdir -p "$UD/Plugins" "$UD/ProfilesV2"
cp -R "$B/com.g0jkn.aethersdr.ulanziPlugin"                   "$UD/Plugins/"
cp -R "$B/3e14ea8f-bb5d-408e-93ae-1640754bffd3.ulanziProfile" "$UD/ProfilesV2/"
```

## 3. Check AetherSDR's TCI server

The plugin talks to AetherSDR over TCI on **port 50001** (AetherSDR's default).
In AetherSDR, open the **TCI** tile in the applet tray and make sure the server
is started — turn on **Autostart TCI with AetherSDR** so you don't have to think
about it again.

Verify it is listening:

```bash
lsof -nP -iTCP:50001 -sTCP:LISTEN
```

If your AetherSDR uses a different port, set each action's **AetherSDR TCI URL**
field in Studio, or edit `DEFAULT_TCI_URL` at the top of
`Plugins/com.g0jkn.aethersdr.ulanziPlugin/plugin/app.js`.

Once the plugin is installed, `./tci-probe.sh` (shipped in this bundle) dumps
AetherSDR's full TCI state, which confirms the server is reachable and answering:

```bash
./tci-probe.sh                 # state dump
./tci-probe.sh tx_gain         # query one verb — one argument always reads
./tci-watch.sh 60              # which verbs broadcast — sends nothing at all
```

**⚠️ Never probe a TCI verb by hand as `verb:0;`.** For verbs that take no receiver
index — `tx_gain`, `mic_level`, `volume` — that is not a query, it **sets the value
to zero**. `tx_gain:0;` leaves the radio keying with no audio out, and it survives
restarts. Use the script, where reading and writing are separate invocations.

## 4. Start Ulanzi Studio

The profile appears as **"AetherSDR D100H controler"**. Select it for the D100H.

Layout as shipped (7 buttons + knob):

| Position | Action |
|----------|--------|
| Knob | VFO Tune — tunes the **TX** slice always (100 Hz, press = fast/slow step, snaps to the step grid) |
| Group of 3 | Split Enable · Band Up · Band Down |
| Group of 2 | PTT (Momentary) · Mode Cycle |
| Group of 2 | Mute · TUNE / ATU |

Step size, coarse multiplier and the dial-press action are per-action settings
saved in the profile, not compiled in — change them in Studio's property
inspector for the VFO Tune action. The shipped values are the operating desk's:
`step_hz` 100, `coarse_mult` 10, `press_action` step_toggle.

Split is Flex-style: one press opens the TX slice **1 kHz up on CW, 5 kHz on
SSB**, and the knob then tunes that slice while RX stays on the DX.

Taken from the profile manifest, which groups the keys as `1_0…1_2` (the row of
three) and `0_0…0_1` / `2_0…2_1` (the pairs). Which pair lands on the left and
which on the right is not recorded in the manifest — check the dial and swap the
two rows above if they read backwards. There is **no MOX Toggle** in the shipped
profile; an earlier revision of this table listed one and omitted TUNE.

## 5. Verify

Turn the knob — the AetherSDR VFO should follow. If it doesn't:

```bash
# Is the plugin process alive? (absent = it crashed at startup)
ps -axo pid,command | grep -F aethersdr.ulanziPlugin | grep -v grep

# Is it connected to AetherSDR? (ignore any MSHV connection on the same port)
lsof -nP -iTCP:50001 | grep ESTABLISHED
```

## Troubleshooting

**A button does nothing.** Almost always a malformed TCI command, not the
button — AetherSDR silently discards commands it can't parse. Turn on the
plugin's debug log: set `const DEBUG = true` near the top of `plugin/app.js`,
restart Studio, press the button, then read
`/tmp/aethersdr-ulanzi-debug.log`. A `KEYDN` line means the press reached the
plugin and the command is at fault.

**Nothing works at all.** Check the plugin process is running (step 5). If it is
absent, `node_modules` did not copy — re-copy the plugin folder, or run
`cd "$UD/Plugins/com.g0jkn.aethersdr.ulanziPlugin" && npm ci --omit=dev`.

**The profile doesn't bind to the dial.** The profile references the D100H by
device UUID. If Studio shows it greyed out or attached to no device, pair the
D100H first, then re-select the profile — or re-create the layout by hand from
the table above.

**Settings won't save.** Should be fixed in this build. If it returns, the cause
is the inspector calling `sendParamFromPlugin()` instead of `setSettings()`.

**Don't enable AetherSDR's own "Ulanzi Dial" HID option.** It fights Studio for
the dial and leaks keystrokes into whatever app has focus. Leave it off; this
plugin uses TCI instead.

## Keeping it working

A plugin update from upstream reverts all fifteen patches at once and the
controller goes dead while the profile still looks fine. The patches, their
reasoning and a restore script live in the private repo
`vu2cpl/ulanzi-d100h-aethersdr`.

Upstream issue tracking these fixes:
https://github.com/nigelfenton/aethersdr-ulanzi-plugin/issues/3
