# AetherSDR TCI — what can be assigned to the D100H

Every verb below was **probed live against AetherSDR 26.9.1** on 2026-09-01, not
read from a header. A verb that answers a query is implemented; one that stays
silent is not, and a button built on it is dead on arrival.

Probe method — use the **bare `verb;` form**, which is read-only for every verb:

```bash
# `verb;` is ALWAYS a query; the reply is the canonical wire shape
node -e "
import('ws').then(({default:WebSocket})=>{
  const ws=new WebSocket('ws://127.0.0.1:50001');
  ws.on('open',()=>setTimeout(()=>ws.send('rx_filter_band;'),800));
  ws.on('message',d=>console.log(d.toString()));
  setTimeout(()=>process.exit(0),3000);
});"
```

> **⚠️ Do not sweep verbs as `verb:0;`.** That form is a query only for
> receiver-indexed verbs. For a non-indexed verb — `volume:<value>`,
> `mic_level:<value>`, `tx_gain:<value>` — it **sets the value to zero**.
> A sweep in that form on 2026-09-01 zeroed AetherSDR's TCI TX gain and left
> the station keying with no audio for two days. The earlier revision of this
> file recommended it; it was how the damage was done. See HANDOVER.md
> "Known gotchas".

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
| 38 | AF Volume 🎛️ (master) | `volume` | `volume:<value>` ⚠️ **not indexed** |
| 39 | RF Power 🎛️ | `drive` | `drive:0,5` |
| 40 | Tune Power 🎛️ | `tune_drive` | `tune_drive:0,10` |
| 41 | Mic Gain 🎛️ | `mic_level` | `mic_level:<value>` ⚠️ **not indexed** |
| 42 | TX Enable Toggle | `tx_enable` | `tx_enable:0,true` |
| 43 | Mode SAM | `modulation` | token `sam` |
| 44 | Mode NFM | `modulation` | token `nfm` |
| 45 | Mode DIGL | `modulation` | token `digl` |
| 46 | Mode RTTY | `modulation` | token `rtty` |
| 47 | IF Offset 🎛️ | `if` | `if:0,0,0` |
| 48 | RX Record Toggle | `rx_record` | `rx_record:0,false` |
| 49 | RX Playback Toggle | `rx_play` | `rx_play:0,false` |
| 50 | RX Channel Enable | `rx_channel_enable` | `rx_channel_enable:0,true` |
| 51 | TCI TX Gain 🎛️ | `tx_gain` | `tx_gain:<value>` ⚠️ **not indexed** |

Informational only, not useful as buttons: `tx_frequency` (derived), `dds`.

**`tx_gain` is the master gain on TX audio arriving over TCI** — 0–100, mapping
directly to the multiplier AetherSDR logs per transmission
(`TCI TX summary ... gain=`): `tx_gain:100` → `gain=1`, `tx_gain:0` → `gain=0`,
i.e. a keyed transmitter radiating silence. It is the single most destructive verb
in this table. Read it with `./tci-probe.sh tx_gain` before touching anything on
the TX path.

## C. NOT possible — probed and silent

**Mode tokens — `cw` AND `cwr` both exist.** `modulations_list;` answers
`usb,lsb,cw,cwr,am,sam,fm,nfm,digu,digl,rtty` (2026-09-01). AetherSDR *reports*
`cw`, so a cycle built on `cwr` never matches the live mode and pins itself to
entry 0 — patch 12. Query the list rather than trusting any written-down set.

**`trx_count` is dynamic**, not a constant: 2 with a second slice open, 1 without.

`vfo_lock`, `mon_enable`, `mon_volume`, `cw_keyer_speed`,
`cw_macros_speed`, `cw_macros_delay`, `spot`, `keyer`, `iq_start`.

These were probed as `verb:0;` and are worth re-checking with the bare `verb;`
form before being trusted as unsupported — see the `tx_gain` correction below.

**`tx_gain` was wrongly listed here, twice.** The original sweep probed it as
`tx_gain:0;`, got no answer, and filed it unimplemented — but that string was a
**set**, and a set draws no reply. It put AetherSDR's TCI TX gain to **0**, which
persisted across restarts and silenced the station for two days (2026-09-01).
Probed properly as `tx_gain;` it answers immediately (`tx_gain:50;`), so it is
fully implemented and now listed as action 51 above.

The lesson generalises: **silence on a probe means "not a query", not "not
supported"** — and every unanswered `verb:0;` should be treated as a write that
may have landed.

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

- *query-then-act* — send the query, act on the reply (used for `tune`,
  because an ATU cycle also ends on its own so a local mirror goes stale).
  `verb:0;` is only a query for receiver-indexed verbs; use bare `verb;`
  unless you have confirmed the verb takes a receiver index.
- *optimistic mirror* — update locally before sending (used upstream for
  `drive`/`volume`, where nothing else changes the value)

Which one a new action needs is generally not knowable until it is built and
watched on the wire.
