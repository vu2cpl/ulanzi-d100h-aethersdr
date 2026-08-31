# AetherSDR TCI — what can be assigned to the D100H

Every verb below was **probed live against AetherSDR 26.9.1** on 2026-09-01, not
read from a header. A verb that answers a query is implemented; one that stays
silent is not, and a button built on it is dead on arrival.

Probe method — read-only, safe to repeat:

```bash
# send `verb:0;` as a QUERY; the reply is the canonical wire shape
node -e "
import('ws').then(({default:WebSocket})=>{
  const ws=new WebSocket('ws://127.0.0.1:50001');
  ws.on('open',()=>setTimeout(()=>ws.send('rx_filter_band:0;'),800));
  ws.on('message',d=>console.log(d.toString()));
  setTimeout(()=>process.exit(0),3000);
});"
```

The D100H has **7 buttons + 1 knob**, so this is a menu to choose ~7 from, not a
list to implement wholesale. More capacity comes from extra Studio pages.

🎛️ = suits the knob (continuous value) better than a button.

---

## A. Implemented in the plugin today

| # | Action | # | Action |
|---|--------|---|--------|
| 1 | VFO Tune 🎛️ | 12 | Mode CW |
| 2 | PTT (Momentary) | 13 | Mode DIGU |
| 3 | MOX Toggle | 14 | Band Up |
| 4 | TUNE / ATU | 15 | Band Down |
| 5 | Split Enable | 16 | AF Gain Up |
| 6 | Mute | 17 | AF Gain Down |
| 7 | RIT Toggle | 18 | RF Gain Up |
| 8 | Slice Cycle | 19 | RF Gain Down |
| 9 | Mode Cycle | 20 | Mic Gain Up |
| 10 | Mode USB | 21 | Mic Gain Down |
| 11 | Mode LSB | | |

## B. Verified available, not yet built

| # | Action | Verb | Observed reply |
|---|--------|------|----------------|
| 22 | RIT Offset 🎛️ | `rit_offset` | `rit_offset:0,0` |
| 23 | XIT Toggle | `xit_enable` | `xit_enable:0,false` |
| 24 | XIT Offset 🎛️ | `xit_offset` | `xit_offset:0,0` |
| 25 | Filter Width 🎛️ | `rx_filter_band` | `rx_filter_band:0,0,3000` |
| 26 | Squelch Toggle | `sql_enable` | `sql_enable:0,true` |
| 27 | Squelch Level 🎛️ | `sql_level` | `sql_level:0,20` |
| 28 | AGC Mode Cycle | `agc_mode` | `agc_mode:0,med` |
| 29 | AGC-T / Threshold 🎛️ | `agc_gain` | `agc_gain:0,55` |
| 30 | Noise Blanker Level 🎛️ | `rx_nb_param` | `rx_nb_param:0,0,50` |
| 31 | Noise Filter (NR) Toggle | `rx_nf_enable` | `rx_nf_enable:0,true` |
| 32 | Auto Notch Toggle | `rx_anc_enable` | `rx_anc_enable:0,false` |
| 33 | Binaural Toggle | `rx_bin_enable` | `rx_bin_enable:0,false` |
| 34 | DSE Toggle | `rx_dse_enable` | `rx_dse_enable:0,false` |
| 35 | RX Volume 🎛️ (per-slice) | `rx_volume` | `rx_volume:0,78` |
| 36 | RX Balance 🎛️ | `rx_balance` | `rx_balance:0,0` |
| 37 | RX Mute (per-receiver) | `rx_mute` | `rx_mute:0,false` |
| 38 | AF Volume 🎛️ (master) | `volume` | `volume:0` |
| 39 | RF Power 🎛️ | `drive` | `drive:0,5` |
| 40 | Tune Power 🎛️ | `tune_drive` | `tune_drive:0,10` |
| 41 | Mic Gain 🎛️ | `mic_level` | `mic_level:100` |
| 42 | TX Enable Toggle | `tx_enable` | `tx_enable:0,true` |
| 43 | Mode SAM | `modulation` | token `sam` |
| 44 | Mode NFM | `modulation` | token `nfm` |
| 45 | Mode DIGL | `modulation` | token `digl` |
| 46 | Mode RTTY | `modulation` | token `rtty` |
| 47 | IF Offset 🎛️ | `if` | `if:0,0,0` |
| 48 | RX Record Toggle | `rx_record` | `rx_record:0,false` |
| 49 | RX Playback Toggle | `rx_play` | `rx_play:0,false` |
| 50 | RX Channel Enable | `rx_channel_enable` | `rx_channel_enable:0,true` |

Informational only, not useful as buttons: `tx_frequency` (derived), `dds`.

## C. NOT possible — probed and silent

`tx_gain`, `vfo_lock`, `mon_enable`, `mon_volume`, `cw_keyer_speed`,
`cw_macros_speed`, `cw_macros_delay`, `spot`, `keyer`, `iq_start`.

Also unavailable, for reasons documented in HANDOVER.md:

- **Antenna** (ANT1 / ANT2 / RX_A) — `rx_ant`, `tx_ant`, `ant`, `antenna`,
  `xvtr` all unanswered; absent from AetherSDR's shortcut editor; the MQTT
  antenna topics are display names only. Antenna is UI-only in AetherSDR.
- **Slice focus** — `set_in_focus` and `rx_channel_enable` are accepted and
  ignored for focus purposes. AetherSDR's shortcut editor *does* have a
  next/previous-slice action, so Studio's built-in Hotkey action is the route
  to real, visible slice switching (needs AetherSDR focused and
  View → Keyboard Shortcuts ON, which is off by default).

---

## Implementation gotchas

**Nearly every verb takes a receiver index.** `mute:<rx>,<bool>`, not
`mute:<bool>`. AetherSDR silently discards a malformed command, which is
indistinguishable from a dead button. This bit two actions in this project.

**AetherSDR does not broadcast every state change.** Some verbs only answer a
direct query — `tune` and `drive` are both confirmed like this. A toggle built
on a broadcast-derived mirror will read stale state forever and only ever send
one direction. Two workarounds, both already used here:

- *query-then-act* — send `verb:0;`, act on the reply (used for `tune`,
  because an ATU cycle also ends on its own so a local mirror goes stale)
- *optimistic mirror* — update locally before sending (used upstream for
  `drive`/`volume`, where nothing else changes the value)

Which one a new action needs is generally not knowable until it is built and
watched on the wire.
