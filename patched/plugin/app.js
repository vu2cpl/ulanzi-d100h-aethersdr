// ─────────────────────────────────────────────────────────────────────────
// MODIFIED FILE — Apache-2.0 section 4(b) notice.
//
// Original: AetherSDR Controller v0.1.5, Copyright (c) Nigel Fenton (G0JKN),
//           https://github.com/nigelfenton/aethersdr-ulanzi-plugin
//           Licensed under the Apache License, Version 2.0.
//
// Changed by Manoj Kumar R (VU2CPL) for the Ulanzi D100H. The unmodified
// original of this file is kept alongside it at upstream-original/ for
// diffing. See README.md for the patch list and NOTICE for attribution.
// ─────────────────────────────────────────────────────────────────────────

// AetherSDR Controller — Ulanzi Studio plugin
//
// Bridges Ulanzi Studio (which manages the D100H dial / LCD button device
// over Bluetooth) to AetherSDR (the desktop SDR app) via TCI WebSocket on
// port 50001.  Studio sends us button-press + dial events; we translate
// them into TCI commands and ship them to AetherSDR.
//
// TCI command vocabulary in this plugin is faithful to the existing
// AetherSDR Stream Deck plugin (com.aethersdr.radio at port 40001) so
// the two plugins behave identically against the same radio.

import UlanziApi from '../libs/common-node/index.js';
import WebSocket from 'ws';
import fs from 'fs';

// Diagnostic log.  Studio consumes plugin stdout through a pipe, so
// console.log is invisible — this is the only way to see what the plugin is
// doing.  Flip DEBUG to true to re-enable (invaluable for "button does
// nothing" reports: it shows whether the press reaches the plugin at all).
const DEBUG = false;
const DEBUG_LOG = '/tmp/aethersdr-ulanzi-debug.log';
function dbg(msg) {
  if (!DEBUG) return;
  // Local Bangalore time (IST), NOT UTC — AetherSDR's own log is local, and
  // mixed timezones make correlating the two logs needlessly painful.
  const ts = new Date().toLocaleString('en-GB',
    { timeZone: 'Asia/Kolkata', hour12: false });
  try { fs.appendFileSync(DEBUG_LOG, `${ts} IST ${msg}\n`); } catch (e) {}
}

// ─── State ───────────────────────────────────────────────────────────────

const PLUGIN_UUID = 'com.g0jkn.aethersdr.controller';

// AetherSDR's TCI WebSocket server.  AetherSDR's own documented default is
// 50001; the upstream plugin shipped 40001, which does not match the app.
const DEFAULT_TCI_URL = 'ws://127.0.0.1:50001';

const ACTION_CACHES = {};
let tci = null;
let tciUrl = DEFAULT_TCI_URL;
let tciReady = false;
let reconnectTimer = 0;

// Live radio state — populated from incoming TCI messages.  Toggles read
// the current value before flipping it (mirrors the Stream Deck plugin's
// approach since TCI doesn't have a server-side "toggle" verb).
const radio = {
  frequency: 14225000,
  mode: 'USB',
  sliceIndex: 0,           // 0..7 (A..H) — incremented locally for "slice cycle"
  transmitting: false,
  tuning: false,
  muted: false,
  volume: 50,
  rfPower: 100,
  tunePower: 25,
  micLevel: 50,            // best-effort tracker — TCI 'mic_level' verb is non-standard
  nbOn: false, nrOn: false, anfOn: false, apfOn: false,
  sqlOn: false, split: false, locked: false,
  ritOn: false, xitOn: false,
  vfoB: null,              // VFO B (channel 1); null until AE reports it
  trxCount: 1,             // receivers AE currently has open — DYNAMIC, see doMuteToggle
  fastStep: false,         // knob press toggles slow <-> fast tuning step
};

// Band centres for "band up" / "band down".  Matches the Stream Deck
// plugin so the two plugins navigate the same way.
const BANDS = {
  '160m': 1840000,  '80m': 3650000,  '60m': 5357000,  '40m': 7100000,
  '30m': 10120000,  '20m': 14200000, '17m': 18130000, '15m': 21300000,
  '12m': 24950000,  '10m': 28400000, '6m':  50150000,
};

// Band-stacking registers.  A real transceiver remembers where you were on
// each band; this does the same.  band key -> { hz, mode }.  Populated as you
// leave a band, so the first visit falls back to the BANDS default above.
const bandStack = {};

// Convention: LSB below 10 MHz, USB above.  Only used for a band you have
// not visited yet in this session.
function defaultModeForBand(band) {
  return BANDS[band] < 10000000 ? 'lsb' : 'usb';
}
const BAND_ORDER = Object.keys(BANDS);

// Mode cycle order — USB → LSB → CW → DIGU → DIGL → AM → FM → loop.
// Tokens verified against AetherSDR's own TCI verb table: usb, lsb, cwr,
// sam, nfm, digu, digl, rtty.  'CW', 'AM' and 'FM' are NOT valid there.
// Operator's working set.  AetherSDR also accepts digl/sam/nfm/rtty, but
// cycling through modes you never use just makes the button slower.
// AetherSDR's full vocabulary (queried via `modulations_list;` 2026-09-01) is
// usb,lsb,cw,cwr,am,sam,fm,nfm,digu,digl,rtty.  Note BOTH `cw` and `cwr` exist
// and AE REPORTS `cw` — the old cycle listed `cwr`, so MODE_CYCLE.indexOf('cw')
// returned -1 and the cycle silently reset to entry 0 every time the radio was
// on CW.  Same class of fault as patch 4.  Operator's requested set, any order.
const MODE_CYCLE = ['cw', 'usb', 'digu', 'lsb'];

function closestBandIndex(freq) {
  let best = 0, bestDist = Infinity;
  for (let i = 0; i < BAND_ORDER.length; i++) {
    const dist = Math.abs(freq - BANDS[BAND_ORDER[i]]);
    if (dist < bestDist) { bestDist = dist; best = i; }
  }
  return best;
}

// ─── TCI WebSocket ───────────────────────────────────────────────────────

function tciConnect(url) {
  tciUrl = url || tciUrl;
  if (tci) {
    try { tci.removeAllListeners(); tci.close(); } catch (_) {}
    tci = null;
  }
  console.log(`[tci] connecting to ${tciUrl}`);
  tci = new WebSocket(tciUrl);

  tci.on('open',    () => { tciReady = true;  console.log('[tci] connected'); });
  tci.on('close',   () => { tciReady = false; console.log('[tci] closed — retry in 5s'); scheduleReconnect(); });
  tci.on('error',   (err) => console.log(`[tci] error: ${err.message}`));
  tci.on('message', (data) => parseTci(data.toString()));
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => { reconnectTimer = 0; tciConnect(); }, 5000);
}

function tciSend(cmd) {
  if (!tci || !tciReady) {
    console.log(`[tci] DROPPED (not connected): ${cmd}`);
    return false;
  }
  console.log(`[tci] -> ${cmd}`);
  tci.send(cmd);
  return true;
}

// Parse incoming TCI messages so toggles know the current state.  Trust
// matrix taken from the Elgato plugin's parseTci — the subset we need
// to handle our 8 actions.
function parseTci(msg) {
  for (const line of msg.split('\n')) {
    const t = line.trim().replace(/;$/, '');
    if (!t) continue;
    const ci = t.indexOf(':');
    if (ci < 0) continue;
    const cmd = t.substring(0, ci).toLowerCase();
    const p = t.substring(ci + 1).split(',');
    switch (cmd) {
      // p = [trx, channel, hz].  Channel 1 is VFO B; previously BOTH channels
      // wrote radio.frequency, so any VFO B report made the knob jump.
      case 'vfo':
        // p = [rx, channel, hz].  Ignore receivers other than the one we
        // currently address, or a second slice would drag our mirror around.
        if (p.length >= 3 && parseInt(p[0]) === radio.sliceIndex) {
          if (parseInt(p[1]) === 1) radio.vfoB = parseInt(p[2]);
          else                      radio.frequency = parseInt(p[2]);
        }
        break;
      // Normalise case: AE reports 'usb' but also 'USB', so MODE_CYCLE
      // lookups returned -1 and pinned the cycle to entry 0.
      case 'modulation':   if (p.length >= 2) radio.mode = String(p[1]).toLowerCase();   break;
      case 'trx':          if (p.length >= 2) radio.transmitting = p[1] === 'true';      break;
      // AetherSDR answers `tune:<rx>,<bool>`, so the state is p[1]; reading p[0]
      // took the RECEIVER INDEX as the boolean.  Targets receiver 0 — ATU tune is
      // radio-level — so this deliberately does not filter on sliceIndex the way
      // vfo/mute/modulation do.  Completes the query started by doTuneToggle().
      case 'tune':
        if (p.length >= 2) {
          radio.tuning = p[1] === 'true';
          if (pendingTuneToggle) {
            pendingTuneToggle = false;
            clearTimeout(tuneFallbackTimer);
            tciSend(`tune:0,${!radio.tuning};`);
          }
        }
        break;
      case 'rit_enable':   if (p.length >= 2) radio.ritOn        = p[1] === 'true';      break;
      // Accept both wire shapes: `split_enable:0,true` and a bare `split_enable:true`.
      // The indexed form MUST be filtered on sliceIndex the way vfo/mute/modulation
      // are: the connect burst reports every receiver, so `split_enable:1,true`
      // arrives right after `split_enable:0,false` and an unfiltered assignment
      // left the mirror holding receiver 1's split state for receiver 0.
      case 'split_enable':
        if (p.length >= 2) {
          if (parseInt(p[0]) === radio.sliceIndex) {
            radio.split = p[1] === 'true';
            // Completes the query started by doSplitToggle(): the radio has just
            // told us its real state, so send the opposite and adopt it locally.
            if (pendingSplitToggle) {
              pendingSplitToggle = false;
              clearTimeout(splitFallbackTimer);
              radio.split = !radio.split;
              tciSend(`split_enable:${radio.sliceIndex},${radio.split};`);
              if (radio.split) placeSplitOffset();
              else { pendingSplitOffsetHz = null; clearTimeout(splitOffsetTimer); }
            }
          }
        } else {
          radio.split = p[0] === 'true';
        }
        break;
      case 'mute':
        if (p.length >= 2 && parseInt(p[0]) === radio.sliceIndex) radio.muted = p[1] === 'true';
        break;
      // Gain / level trackers — keep local mirror in sync so ±5 steps are
      // calculated against the radio's actual current value, not a stale guess.
      //
      // Parameter count is per-verb and does NOT vary by context.  Re-checked
      // against AE's own TCI log 2026-09-01 (init burst, query replies and
      // broadcasts all agree):
      //   - `drive:<rx>,<value>;`   — receiver-indexed, TWO params
      //   - `volume:<value>;`       — NOT indexed, ONE param
      //   - `mic_level:<value>;`    — NOT indexed, ONE param
      // The earlier "asymmetric emit format" note here was wrong; see the
      // single-param hazard warning above cmdAfGain().
      // This is about what AE EMITS.  It says nothing about what AE ACCEPTS —
      // on the command side a leading index is ignored rather than read as the
      // value, which is the opposite of what the hazard block used to claim.
      // Two directions, two different facts; do not merge them again.
      // #3502: AE echoes VOLUME in dB (−60..0). A positive value can only
      // come from a legacy percent-scale AE, so ≥1 = percent, ≤0 = dB.
      case 'volume': {
        const raw = parseInt(p[0]);
        radio.volume = raw >= 1 ? Math.min(raw, 100) : dbToPercent(raw);
        break;
      }
      case 'trx_count':    radio.trxCount = Math.max(1, parseInt(p[0]) || 1); break;
      case 'drive':        radio.rfPower  = parseInt(p.length >= 2 ? p[1] : p[0]); break;
      case 'mic_level':    radio.micLevel = parseInt(p[0]); break;
    }
  }
}

// ─── TCI command builders ────────────────────────────────────────────────

const TX_STEP_HZ      = 100;     // VFO rotate CW/CCW step
const COARSE_MULT     = 10;      // press+rotate is ×10 the step
const GAIN_STEP       = 5;       // ±5 per press for AF / RF / mic gain (range 0–100)

function cmdMoxToggle()       { return `trx:0,${!radio.transmitting};`; }
// TUNE is query-then-act, not a blind toggle.  AetherSDR never BROADCASTS
// tune state changes (verified 2026-09-01: it only answers a direct `tune:0;`
// query), so a parser mirror never updates.  An optimistic local mirror is no
// good either, because an ATU cycle also finishes on its own — the mirror goes
// stale and the button degrades to every-other-press.  So: ask for the live
// value, then send the opposite when the answer arrives.
let pendingTuneToggle = false;
let tuneFallbackTimer = 0;

function doTuneToggle() {
  if (pendingTuneToggle) return;             // ignore double-taps mid-round-trip
  pendingTuneToggle = true;
  tciSend('tune:0;');
  // If no answer arrives, stop tuning rather than start it — this action keys
  // the transmitter, so the safe fallback is always "off".
  clearTimeout(tuneFallbackTimer);
  tuneFallbackTimer = setTimeout(() => {
    if (!pendingTuneToggle) return;
    pendingTuneToggle = false;
    tciSend('tune:0,false;');
  }, 500);
}
function cmdRitToggle()       { return `rit_enable:0,${!radio.ritOn};`; }

// SPLIT is query-then-act, for the same reason TUNE is (see doTuneToggle above),
// but with a worse failure mode.  It used to be a blind toggle:
//
//     split_enable:0,${!radio.split}
//
// which trusts a mirror the radio only refreshes on its own broadcasts.  Get one
// flip out of step — an AetherSDR restart will do it — and the key sends the value
// the radio already holds (a no-op) while the mirror flips anyway.  From then on
// the two disagree permanently, and because patch 9 steers the DIAL off
// radio.split, the knob silently tunes the wrong VFO.  Observed 2026-09-01: AE
// reported split off for a full 75 s while the plugin wrote `vfo:0,1`.
//
// `split_enable:<rx>;` is a genuine query — verified on the radio, it answers
// `split_enable:0,false;` and writes nothing.
//
// Unlike TUNE, the mirror IS updated optimistically here.  That was rejected for
// tune because an ATU cycle also ends by itself, so the mirror would go stale;
// split only ever changes when something commands it, and AetherSDR broadcasts
// the GUI-originated changes (verified: 4 toggles in a 90 s capture).  So the
// value we just commanded is authoritative until told otherwise — which is what
// the dial needs between presses.
let pendingSplitToggle = false;
let splitFallbackTimer = 0;

// How far above the RX frequency the TX slice is parked when split is switched
// on.  Operator's convention, matching normal DX practice: SSB pileups spread
// wider than CW ones.
const SPLIT_OFFSET_SSB_HZ = 5000;
const SPLIT_OFFSET_HZ     = 1000;
function splitOffsetHz() {
  const m = String(radio.mode || '').toLowerCase();
  return (m === 'usb' || m === 'lsb') ? SPLIT_OFFSET_SSB_HZ : SPLIT_OFFSET_HZ;
}

// Set once split has just been switched ON, and consumed by the `vfo` parser
// case below.  AetherSDR resets VFO B to VFO A *after* it processes
// split_enable (observed 2026-09-01: `split_enable:0,true` then
// `vfo:0,1,<A>` in the same tick), so writing the offset immediately would be
// overwritten.  We wait for AE's own channel-1 report and place it then.
let pendingSplitOffsetHz = null;
let splitOffsetTimer = 0;

// Park the TX slice above RX after split comes on.
//
// This CANNOT be done on AetherSDR's channel-1 report: AE resets VFO B to VFO A
// *twice* when split is enabled, and the second reset lands after our write and
// wipes it.  Observed 2026-09-01 on CW:
//
//   32.5s  SPLIT = true
//   32.5s  TX-B -> 21008100   (+1000, ours)
//   32.6s  TX-B -> 21007100   (+0, AE's second reset — offset gone)
//
// So: let AE settle, write the offset, then verify and rewrite once if it was
// clobbered again.  The verify pass is what makes this robust to AE's timing
// rather than to a delay we guessed.
function placeSplitOffset() {
  const target = radio.frequency + splitOffsetHz();
  pendingSplitOffsetHz = target;
  clearTimeout(splitOffsetTimer);
  splitOffsetTimer = setTimeout(() => {
    if (pendingSplitOffsetHz === null) return;
    tciSend(`vfo:${radio.sliceIndex},1,${target};`);
    radio.vfoB = target;
    splitOffsetTimer = setTimeout(() => {
      pendingSplitOffsetHz = null;
      // Still not there — AE overrode us again.  One retry, then leave it be
      // rather than fighting the radio in a loop.
      if (radio.split && radio.vfoB !== target) {
        tciSend(`vfo:${radio.sliceIndex},1,${target};`);
        radio.vfoB = target;
      }
    }, 400);
  }, 600);
}

function doSplitToggle() {
  if (pendingSplitToggle) return;            // ignore double-taps mid-round-trip
  pendingSplitToggle = true;
  tciSend(`split_enable:${radio.sliceIndex};`);
  // If nothing answers, fall back to the old blind toggle rather than leaving the
  // key dead.  Split does not key the transmitter, so unlike TUNE there is no
  // "safe direction" to prefer — best effort on the mirror is the right fallback.
  clearTimeout(splitFallbackTimer);
  splitFallbackTimer = setTimeout(() => {
    if (!pendingSplitToggle) return;
    pendingSplitToggle = false;
    radio.split = !radio.split;
    tciSend(`split_enable:${radio.sliceIndex},${radio.split};`);
  }, 500);
}
// MASTER audio mute.  `mute` is receiver-indexed in AetherSDR (`mute:<rx>,<bool>`
// — patch 6), so muting only radio.sliceIndex left the other slice audible, which
// is not what a mute key is for.  Mute every receiver AE currently reports.
// trx_count is DYNAMIC: it read 1 with a single slice and 2 while split had a
// second slice open (both observed 2026-09-01), so it is tracked from the wire
// rather than assumed.
function doMuteToggle() {
  const next = !radio.muted;
  for (let rx = 0; rx < Math.max(1, radio.trxCount); rx++) tciSend(`mute:${rx},${next};`);
  radio.muted = next;   // optimistic: mute only changes when commanded
}

// Momentary PTT — explicit on/off, NOT a toggle.  Key/dial down keys the
// radio, release unkeys it.  Distinct from `mox` (cmdMoxToggle) which flips.
// Sends absolute state rather than reading radio.transmitting, so a dropped
// echo can never leave the radio stuck in transmit.
function cmdPttOn()           { return `trx:0,true;`; }
function cmdPttOff()          { return `trx:0,false;`; }
function cmdSetFreq(hz)       { return `vfo:${radio.sliceIndex},0,${hz};`; }

// Which VFO the DIAL moves.  With split enabled the operator is setting the
// TRANSMIT frequency — "call up 1-2 on 14002" means move TX, not RX — so the
// knob has to drive VFO B (channel 1).  Tuning channel 0 under split walks the
// receiver off the DX and leaves TX where it was, which is the opposite of
// what split-then-tune means.
//
// AetherSDR mirrors the split TX frequency at BOTH `vfo:<rx>,1` and
// `vfo:<rx+1>,0` (verified 2026-09-01 by watching the broadcast stream: every
// VFO-B move emitted the pair, while `vfo:0,0` stayed pinned).  We write
// channel 1, matching doVfoSwap().
//
// Only the dial uses these.  changeBand() deliberately still moves channel 0:
// a band change is an RX move, and dragging TX along would be a surprise.
function tuneChannel() { return radio.split ? 1 : 0; }

function tuneBaseHz() {
  if (!radio.split) return radio.frequency;
  // vfoB is seeded by the connect burst and re-broadcast whenever split is
  // enabled, so null here means channel 1 has genuinely never been reported.
  // Step from the RX frequency rather than from 0.
  return radio.vfoB === null ? radio.frequency : radio.vfoB;
}

function cmdTuneTo(hz)       { return `vfo:${radio.sliceIndex},${tuneChannel()},${hz};`; }
function cmdSetMode(mode)     { return `modulation:${radio.sliceIndex},${mode};`; }

function cmdModeNext() {
  const i = MODE_CYCLE.indexOf(String(radio.mode || '').toLowerCase());
  const next = MODE_CYCLE[(i + 1) % MODE_CYCLE.length];
  return cmdSetMode(next);
}

// Band change with stacking.  Saves where you were on the band you are
// leaving, then restores where you last were on the band you arrive at
// (frequency AND mode), falling back to the band default on first visit.
function changeBand(delta) {
  const from = closestBandIndex(radio.frequency);
  const to   = Math.min(Math.max(from + delta, 0), BAND_ORDER.length - 1);
  if (to === from) return;                       // already at the end stop

  bandStack[BAND_ORDER[from]] = { hz: radio.frequency, mode: radio.mode };

  const band  = BAND_ORDER[to];
  const saved = bandStack[band];
  const hz    = saved ? saved.hz   : BANDS[band];
  const mode  = saved ? saved.mode : defaultModeForBand(band);

  tciSend(cmdSetFreq(hz));
  if (mode && String(mode).toLowerCase() !== String(radio.mode).toLowerCase()) {
    tciSend(cmdSetMode(String(mode).toLowerCase()));
  }
  radio.frequency = hz;
}

// AetherSDR exposes NO slice-focus verb over TCI: `set_in_focus` and
// `rx_channel_enable` are accepted and silently ignored (probed 2026-08-31),
// and the old `if:<n>;` here was not a slice command at all — `if` is TCI's
// IF-OFFSET verb (`if:<rx>,<sub_rx>,<hz>`), so this was sending a malformed
// IF command on every press.
//
// So Slice Cycle retargets which receiver THIS PLUGIN addresses, rather than
// moving AetherSDR's own focus.  After cycling, the knob and mode buttons act
// on the new receiver.  We re-query the new receiver so the knob steps from
// its real frequency instead of the previous slice's.
const SLICE_COUNT = 2;
function doSliceCycle() {
  radio.sliceIndex = (radio.sliceIndex + 1) % SLICE_COUNT;
  // Re-query the newly selected receiver so the knob steps from ITS
  // frequency rather than the previous slice's.
  tciSend(`vfo:${radio.sliceIndex},0;`);
  tciSend(`modulation:${radio.sliceIndex};`);
}

function cmdVfoStep(direction)       { return cmdSetFreq(radio.frequency + direction * TX_STEP_HZ); }
function cmdVfoStepCoarse(direction) { return cmdSetFreq(radio.frequency + direction * TX_STEP_HZ * COARSE_MULT); }

// Gain ±5 helpers — clamp to 0–100 so we don't blow past the radio's range.
// The wire format is PER-VERB, not uniform — see the hazard block below.
//
// Optimistic local-mirror update: AetherSDR only emits `drive:` over TCI
// at init-burst time — value changes after that are silent.  Verified via
// TCI Monitor 2026-05-27 (Documents/tci-monitor-20260527-210149.log lines
// 49-61: ▲▲▲▲▲▼▼▼▼▲▲▲▲ all sent `drive:0,10` or `drive:0,0`, zero `◀ drive`
// echoes from AE).  If we waited for an echo to update radio.rfPower, ±5
// steps would always compute against the stale init-burst snapshot —
// bouncing between init±5 forever.  So we update the mirror BEFORE sending,
// optimistically assuming AE accepts.  If AE rejects (clamp, lock, etc.),
// the parser still catches any later echo and corrects us.
//
// AF volume is echoed (so parser tracking works there too), but doing the
// optimistic update for it as well keeps the three actions consistent and
// is harmless — the subsequent parser echo just confirms the same value.
//
// `mic_level` is best-effort — not in the published TCI spec, but AE does
// implement it (it appears in AE's TCI init burst as `mic_level:<value>;`).
const clamp01_100 = (v) => Math.max(0, Math.min(100, v));

// ─────────────────────────────────────────────────────────────────────────
// SINGLE-PARAMETER VERB HAZARD — read before touching anything below.
//
// ONE field is the dangerous shape.  A trailing index is not.  These are two
// separate facts and collapsing them into one rule is how this comment came
// to be wrong for nine months:
//
//   receiver-indexed : `drive:<rx>,<value>;`   — `drive:0;`     is a QUERY
//   NOT indexed      : `volume:<value>;`       — `volume:0;`    WRITES ZERO
//                      `mic_level:<value>;`    — `mic_level:0;` WRITES ZERO
//
// The live hazard is REAL and unchanged: on a non-indexed verb the bare
// `verb:0;` form is a write of zero, not a query.  That is what took the
// station off the air on 2026-09-01 — a verb sweep sent `verb:0;` to
// everything as a "query" and silently zeroed `tx_gain`.  See HANDOVER.md
// "Known gotchas".  Never probe with `verb:0;`; use bare `verb;`.
//
// What this block USED to claim, and what is FALSE:
//   "sending the indexed form to a non-indexed verb makes AE read the
//    receiver index as the VALUE — `mic_level:0,55;` sets 0, not 55."
//
// Probed on the radio 2026-09-07, AetherSDR 26.9.1, each step started from a
// different value so a rejected write could not hide as a no-change:
//
//   58  ->  `mic_level:70;`      ->  70    single-param form accepted
//   70  ->  `mic_level:0,40;`    ->  40    TWO-FIELD FORM ALSO ACCEPTED
//   40  ->  `mic_level:58;`      ->  58    restored
//
// AE takes the LAST field as the value and ignores a leading index on these
// verbs.  Upstream's `volume:0,<v>;` / `mic_level:0,<v>;` were correct all
// along, and the patch below is not the bug fix it was written as — both
// forms work.  It survived because "both forms work" reads identically to
// "my form works" unless you test the other one.
//
// The builders below are KEPT: for `volume` the dB scale is worth having on
// its own merits (#3502 — AE echoes dB, −60..0), and for `mic_level` the
// single-param form is the one actually verified on this radio.  They are
// preference now, not a correction of upstream.
//
// `volume:` has NOT been A/B'd the same way, and on this station it does not
// matter: AF Gain and Mic Gain are not bound in the profile (all 7 buttons and
// the knob are taken by vfo/tune/split/ptt/mute/mode/band±), so cmdAfGain is
// unreachable and `volume:` never leaves this plugin.  Neither the upstream
// form nor this patch has ever executed here.
// It becomes a live question ONLY if AF Gain is bound to a key.  If you do
// that, test the verb first — same shape as mic_level so the same answer is
// expected, but if that inference is wrong the failure mode is 0 dB = FULL
// VOLUME into headphones.  At the radio, monitor down, or not at all.
// ─────────────────────────────────────────────────────────────────────────

// TCI VOLUME wire scale is dB (−60..0; −60 = silence) per the spec / AetherSDR
// #3502; AE's internal master volume is 0–100 percent. We keep our mirror in
// percent and convert at the wire. (Mirrors AE's volumePercentFromDb.)
const dbToPercent = (db) => (db <= -60 ? 0 : Math.round(100 * Math.pow(10, db / 20)));
const percentToDb = (pct) =>
  (pct <= 0 ? -60 : Math.max(-60, Math.min(0, Math.round(20 * Math.log10(pct / 100)))));

function cmdAfGain(direction) {
  const v = clamp01_100(radio.volume + direction * GAIN_STEP);
  radio.volume = v;
  // #3502 — AE reads a VALUE of 0 as 0 dB = FULL volume, so silence at the
  // bottom of the dial must be −60 dB, not 0.  (That is about the value, not
  // about the leading index — see the hazard block above.)
  return `volume:${percentToDb(v)};`;
}
function cmdRfGain(direction) {
  const v = clamp01_100(radio.rfPower + direction * GAIN_STEP);
  radio.rfPower = v;
  // Receiver-indexed verb — the `0,` here is a receiver index and belongs.
  return `drive:0,${v};`;
}
function cmdMicGain(direction) {
  const v = clamp01_100(radio.micLevel + direction * GAIN_STEP);
  radio.micLevel = v;
  // `mic_level:<percent>;` — the single-param form, verified on the radio.
  // `mic_level:0,<percent>;` works too; this is not a fix, just the tested one.
  return `mic_level:${v};`;
}

// ─── Studio API ──────────────────────────────────────────────────────────

const $UD = new UlanziApi();
$UD.connect(PLUGIN_UUID);

$UD.onConnected(() => {
  console.log(`[studio] connected as ${PLUGIN_UUID}`);
  tciConnect();
});

$UD.onClose(() => console.log('[studio] disconnected'));
$UD.onError((err) => console.log(`[studio] error: ${err}`));

$UD.onAdd((jsn) => {
  // Studio's add event uses `uuid` (action CLASS) + `actionid` (instance);
  // not `action` like I originally assumed.  Store the class UUID so the
  // dispatch switch below can match against `${PLUGIN_UUID}.mox` etc.
  ACTION_CACHES[jsn.context] = { actionId: jsn.uuid, settings: jsn.param || {} };
  dbg(`ADD   uuid=${jsn.uuid} key=${jsn.key} context=${jsn.context}`);
  if (jsn.param && jsn.param.tci_url && jsn.param.tci_url !== tciUrl) tciConnect(jsn.param.tci_url);
});

$UD.onClear((jsn) => {
  if (!jsn.param) return;
  for (const item of jsn.param) delete ACTION_CACHES[item.context];
});

// Studio forwards saved settings here after a setSettings from the inspector.
// Payload uses `settings`; the paramfrom* path uses `param`, so accept both.
$UD.onDidReceiveSettings((jsn) => {
  const st = jsn.settings || jsn.param || {};
  if (ACTION_CACHES[jsn.context]) ACTION_CACHES[jsn.context].settings = st;
  dbg(`SETTNG uuid=${jsn.uuid} key=${jsn.key} ${JSON.stringify(st)}`);
  if (st.tci_url && st.tci_url !== tciUrl) tciConnect(st.tci_url);
});

$UD.onParamFromPlugin((jsn) => {
  if (ACTION_CACHES[jsn.context]) ACTION_CACHES[jsn.context].settings = jsn.param || {};
  if (jsn.param && jsn.param.tci_url && jsn.param.tci_url !== tciUrl) tciConnect(jsn.param.tci_url);
});

// Keypad — button press.  Studio sends cmd:'keydown' (not cmd:'run');
// the SDK's onKeyDown is the right hook.  jsn.uuid carries the action
// class UUID we need to dispatch on; the SDK pre-resolves jsn.context
// for the per-key cache lookup.
$UD.onKeyDown((jsn) => {
  dbg(`KEYDN uuid=${jsn.uuid} key=${jsn.key} context=${jsn.context} cached=${!!ACTION_CACHES[jsn.context]}`);
  // Fall back to jsn.uuid when the cache has no entry — a missing ADD used to
  // make the button silently dead.
  const cache = ACTION_CACHES[jsn.context] || (jsn.uuid ? { actionId: jsn.uuid, settings: {} } : null);
  if (!cache) {
    dbg('KEYDN dropped — no cache and no uuid');
    return;
  }
  console.log(`[keydown] ${cache.actionId}`);
  switch (cache.actionId) {
    case `${PLUGIN_UUID}.mox`:         tciSend(cmdMoxToggle());   break;
    case `${PLUGIN_UUID}.tune`:        doTuneToggle();            break;
    case `${PLUGIN_UUID}.modeCycle`:   tciSend(cmdModeNext());    break;
    case `${PLUGIN_UUID}.bandUp`:      changeBand(+1);            break;
    case `${PLUGIN_UUID}.bandDown`:    changeBand(-1);            break;
    case `${PLUGIN_UUID}.sliceCycle`:  doSliceCycle();            break;
    case `${PLUGIN_UUID}.ritToggle`:   tciSend(cmdRitToggle());   break;
    case `${PLUGIN_UUID}.splitToggle`: doSplitToggle();            break;
    case `${PLUGIN_UUID}.muteToggle`:  doMuteToggle();            break;
    // Momentary: key DOWN transmits; the onKeyUp handler below unkeys.
    case `${PLUGIN_UUID}.pttMomentary`: tciSend(cmdPttOn());      break;
    // Direct-mode actions — for D200H pages that prefer explicit keys over cycling.
    case `${PLUGIN_UUID}.modeUsb`:     tciSend(cmdSetMode('usb'));  break;
    case `${PLUGIN_UUID}.modeLsb`:     tciSend(cmdSetMode('lsb'));  break;
    case `${PLUGIN_UUID}.modeCw`:      tciSend(cmdSetMode('cwr'));   break;
    case `${PLUGIN_UUID}.modeDigu`:    tciSend(cmdSetMode('digu')); break;
    // Gain trio — each press = ±5; relative to currently-tracked value.
    case `${PLUGIN_UUID}.afGainUp`:    tciSend(cmdAfGain(+1));  break;
    case `${PLUGIN_UUID}.afGainDown`:  tciSend(cmdAfGain(-1));  break;
    case `${PLUGIN_UUID}.rfGainUp`:    tciSend(cmdRfGain(+1));  break;
    case `${PLUGIN_UUID}.rfGainDown`:  tciSend(cmdRfGain(-1));  break;
    case `${PLUGIN_UUID}.micGainUp`:   tciSend(cmdMicGain(+1)); break;
    case `${PLUGIN_UUID}.micGainDown`: tciSend(cmdMicGain(-1)); break;
    default:
      console.log(`[run] unhandled action: ${cache.actionId}`);
  }
});

// Momentary PTT release.  Only this one action responds to key-up; every
// other action is edge-triggered on key-down and must ignore the release.
$UD.onKeyUp((jsn) => {
  if (actionIdFor(jsn) === `${PLUGIN_UUID}.pttMomentary`) tciSend(cmdPttOff());
});

// Resolve which action instance an event belongs to.  Prefer the cache
// populated by onAdd; fall back to jsn.uuid, which Studio sends on every
// event (ActionProps.uuid = the action CLASS uuid).  Returns null only if
// both are absent.
// Per-action settings saved by the property inspector (step_hz, coarse_mult,
// press_action).  The inspector has always offered these; nothing read them
// until now, so they were dead UI.
function settingsFor(jsn) {
  const cache = jsn && jsn.context ? ACTION_CACHES[jsn.context] : null;
  return (cache && cache.settings) || {};
}

function intSetting(jsn, key, fallback) {
  const v = parseInt(settingsFor(jsn)[key]);
  return Number.isFinite(v) && v > 0 ? v : fallback;
}

// Swap VFO A/B.  Guarded: if AetherSDR has never reported channel 1 we do
// nothing rather than QSY to a bogus default.
function doVfoSwap() {
  if (radio.vfoB === null) {
    console.log('[vfo] A/B swap ignored — no vfo:0,1,... seen from AetherSDR yet');
    return;
  }
  const a = radio.frequency, b = radio.vfoB;
  tciSend(cmdSetFreq(b));
  tciSend(`vfo:${radio.sliceIndex},1,${a};`);
  radio.frequency = b; radio.vfoB = a;
}

function actionIdFor(jsn) {
  const cache = jsn && jsn.context ? ACTION_CACHES[jsn.context] : null;
  return (cache && cache.actionId) || (jsn && jsn.uuid) || null;
}

// Encoder (D100H dial) — dispatch on the action actually assigned to the
// knob.  These handlers used to be unconditional, so the dial always tuned
// the VFO no matter what you dropped on it; now any Encoder-capable action
// works there.  Rotation still falls through to VFO tuning when the action
// cannot be resolved, so behaviour degrades to the old default rather than
// going dead.
function dialRotate(jsn, direction, coarse) {
  const id = actionIdFor(jsn);
  if (id !== null && id !== `${PLUGIN_UUID}.vfo`) return;
  // Three rates: slow (step_hz), fast (step_hz x coarse_mult, latched by the
  // knob press), and press-and-rotate which multiplies again on top of either.
  const mult = intSetting(jsn, 'coarse_mult', COARSE_MULT);
  const hz = intSetting(jsn, 'step_hz', TX_STEP_HZ)
           * (radio.fastStep ? mult : 1)
           * (coarse ? mult : 1);
  // Snap to the step grid.  Tuning used to be a pure increment from wherever
  // the VFO happened to sit, so an off-grid base — a band stack, a click in
  // AetherSDR's panadapter, an RIT nudge — kept its offset for the rest of the
  // session (7.074123 walked .123, .223, .323 and never reached a boundary).
  // The first click off-grid lands on the nearest multiple of the step in the
  // direction of travel; every click after that is a full step.  Quantising to
  // `hz` rather than to a fixed 100/1000 means press-and-rotate snaps to its
  // own coarse grid too, and the boundaries follow the inspector's settings.
  const base = tuneBaseHz();
  const off  = base % hz;
  tciSend(cmdTuneTo(off === 0 ? base + direction * hz
                              : direction > 0 ? base - off + hz
                                              : base - off));
}

$UD.onDialRotateRight((jsn)     => dialRotate(jsn, +1, false));
$UD.onDialRotateLeft((jsn)      => dialRotate(jsn, -1, false));
$UD.onDialRotateHoldRight((jsn) => dialRotate(jsn, +1, true));
$UD.onDialRotateHoldLeft((jsn)  => dialRotate(jsn, -1, true));

$UD.onDialDown((jsn) => {
  switch (actionIdFor(jsn)) {
    case `${PLUGIN_UUID}.splitToggle`:  doSplitToggle();            return;
    case `${PLUGIN_UUID}.muteToggle`:   doMuteToggle();            return;
    case `${PLUGIN_UUID}.pttMomentary`: tciSend(cmdPttOn());       return;
  }
  // VFO Tune (or an unresolved action): honour the inspector's
  // "Dial press action" dropdown.  Defaults to MOX, the old hardcoded
  // behaviour, when nothing is saved.
  switch (settingsFor(jsn).press_action || 'mox') {
    case 'none':                                    break;
    case 'mode_cycle': tciSend(cmdModeNext());      break;
    case 'vfo_swap':   doVfoSwap();                 break;
    // Operator's layout: the knob press selects the tuning rate rather than
    // swapping VFOs (a swap is only meaningful with 2+ slices to switch
    // between, and the Split key owns that now).
    case 'step_toggle':
      radio.fastStep = !radio.fastStep;
      console.log(`[vfo] step now ${radio.fastStep ? 'FAST' : 'SLOW'}`);
      break;
    default:           tciSend(cmdMoxToggle());     break;
  }
});

$UD.onDialUp((jsn) => {
  if (actionIdFor(jsn) === `${PLUGIN_UUID}.pttMomentary`) tciSend(cmdPttOff());
});

// ─── Crash hooks ─────────────────────────────────────────────────────────
process.on('unhandledRejection', (err) => console.error('[unhandled]', err));
process.on('uncaughtException',  (err) => console.error('[crash]', err));
