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
  try { fs.appendFileSync(DEBUG_LOG, `${new Date().toISOString()} ${msg}\n`); } catch (e) {}
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
const MODE_CYCLE = ['usb', 'lsb', 'digu', 'cwr'];

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
      // AetherSDR answers `tune:<rx>,<bool>` (probed 2026-08-31), so the state
      // is p[1].  Reading p[0] took the RECEIVER INDEX as the boolean, so
      // radio.tuning was permanently false and cmdTuneToggle only ever sent
      // `tune:0,true` — the button could start a tune cycle but never stop it.
      case 'tune':
        // Matches cmdTuneToggle, which targets receiver 0 — ATU tune is a
        // radio-level action, not per-slice.  Don't filter on sliceIndex
        // here or the two would disagree after a slice cycle.
        if (p.length >= 2) radio.tuning = p[1] === 'true';
        break;
      case 'rit_enable':   if (p.length >= 2) radio.ritOn        = p[1] === 'true';      break;
      // Accept both wire shapes: `split_enable:0,true` and a bare `mute:true`.
      case 'split_enable': radio.split  = (p.length >= 2 ? p[1] : p[0]) === 'true';      break;
      case 'mute':
        if (p.length >= 2 && parseInt(p[0]) === radio.sliceIndex) radio.muted = p[1] === 'true';
        break;
      // Gain / level trackers — keep local mirror in sync so ±5 steps are
      // calculated against the radio's actual current value, not a stale guess.
      //
      // AetherSDR has **asymmetric** emit formats for these verbs:
      //   - Init burst (TCI connect)  : `verb:<trx>,<value>;`  — two params
      //   - Steady-state value change : `verb:<value>;`        — single param
      //
      // Verified live 2026-05-27 via TCI Monitor: pressing AF Gain ▲ sends
      // `volume:0,55;` and AE responds with `volume:55;` (no trx prefix).
      // So our parser must accept BOTH lengths — read p[1] when trx-prefixed,
      // otherwise p[0].  Earlier versions only handled the two-param case
      // and dropped every steady-state update, freezing the local mirror at
      // the init-burst snapshot → ±5 steps bounced ±5 around that frozen
      // value forever (e.g. 45 ↔ 55 around an init volume of 50).
      // #3502: AE now echoes VOLUME in dB (−60..0). A positive value can only
      // come from a legacy percent-scale AE, so ≥1 = percent, ≤0 = dB.
      case 'volume': {
        const raw = parseInt(p.length >= 2 ? p[1] : p[0]);
        radio.volume = raw >= 1 ? Math.min(raw, 100) : dbToPercent(raw);
        break;
      }
      case 'drive':        radio.rfPower  = parseInt(p.length >= 2 ? p[1] : p[0]); break;
      case 'mic_level':    radio.micLevel = parseInt(p.length >= 2 ? p[1] : p[0]); break;
    }
  }
}

// ─── TCI command builders ────────────────────────────────────────────────

const TX_STEP_HZ      = 100;     // VFO rotate CW/CCW step
const COARSE_MULT     = 10;      // press+rotate is ×10 the step
const GAIN_STEP       = 5;       // ±5 per press for AF / RF / mic gain (range 0–100)

function cmdMoxToggle()       { return `trx:0,${!radio.transmitting};`; }
function cmdTuneToggle()      { return `tune:0,${!radio.tuning};`; }
function cmdRitToggle()       { return `rit_enable:0,${!radio.ritOn};`; }
function cmdSplitToggle()     { return `split_enable:0,${!radio.split};`; }
function cmdMuteToggle()      { return `mute:${radio.sliceIndex},${!radio.muted};`; }

// Momentary PTT — explicit on/off, NOT a toggle.  Key/dial down keys the
// radio, release unkeys it.  Distinct from `mox` (cmdMoxToggle) which flips.
// Sends absolute state rather than reading radio.transmitting, so a dropped
// echo can never leave the radio stuck in transmit.
function cmdPttOn()           { return `trx:0,true;`; }
function cmdPttOff()          { return `trx:0,false;`; }
function cmdSetFreq(hz)       { return `vfo:${radio.sliceIndex},0,${hz};`; }
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
// Format `verb:<trx>,<value>;` matches the TCI spec and AE accepts it.
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
// `mic_level` is best-effort — not in the published TCI spec; AE may
// silently ignore.
const clamp01_100 = (v) => Math.max(0, Math.min(100, v));

// TCI VOLUME wire scale is dB (−60..0; −60 = silence) per the spec / AetherSDR
// #3502; AE's internal master volume is 0–100 percent. We keep our mirror in
// percent and convert at the wire. (Mirrors AE's volumePercentFromDb.)
const dbToPercent = (db) => (db <= -60 ? 0 : Math.round(100 * Math.pow(10, db / 20)));

function cmdAfGain(direction) {
  const v = clamp01_100(radio.volume + direction * GAIN_STEP);
  radio.volume = v;
  // #3502: never send `volume:0` — AE now reads 0 as 0 dB = FULL volume (was
  // 0% mute). Emit −60 dB for true silence at the bottom of the dial; 1–100
  // are still accepted as legacy percent by AE's compat shim.
  return `volume:0,${v === 0 ? -60 : v};`;
}
function cmdRfGain(direction) {
  const v = clamp01_100(radio.rfPower + direction * GAIN_STEP);
  radio.rfPower = v;
  return `drive:0,${v};`;
}
function cmdMicGain(direction) {
  const v = clamp01_100(radio.micLevel + direction * GAIN_STEP);
  radio.micLevel = v;
  return `mic_level:0,${v};`;
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
    case `${PLUGIN_UUID}.tune`:        tciSend(cmdTuneToggle());  break;
    case `${PLUGIN_UUID}.modeCycle`:   tciSend(cmdModeNext());    break;
    case `${PLUGIN_UUID}.bandUp`:      changeBand(+1);            break;
    case `${PLUGIN_UUID}.bandDown`:    changeBand(-1);            break;
    case `${PLUGIN_UUID}.sliceCycle`:  doSliceCycle();            break;
    case `${PLUGIN_UUID}.ritToggle`:   tciSend(cmdRitToggle());   break;
    case `${PLUGIN_UUID}.splitToggle`: tciSend(cmdSplitToggle()); break;
    case `${PLUGIN_UUID}.muteToggle`:  tciSend(cmdMuteToggle());  break;
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
  const hz = intSetting(jsn, 'step_hz', TX_STEP_HZ)
           * (coarse ? intSetting(jsn, 'coarse_mult', COARSE_MULT) : 1);
  tciSend(cmdSetFreq(radio.frequency + direction * hz));
}

$UD.onDialRotateRight((jsn)     => dialRotate(jsn, +1, false));
$UD.onDialRotateLeft((jsn)      => dialRotate(jsn, -1, false));
$UD.onDialRotateHoldRight((jsn) => dialRotate(jsn, +1, true));
$UD.onDialRotateHoldLeft((jsn)  => dialRotate(jsn, -1, true));

$UD.onDialDown((jsn) => {
  switch (actionIdFor(jsn)) {
    case `${PLUGIN_UUID}.splitToggle`:  tciSend(cmdSplitToggle()); return;
    case `${PLUGIN_UUID}.muteToggle`:   tciSend(cmdMuteToggle());  return;
    case `${PLUGIN_UUID}.pttMomentary`: tciSend(cmdPttOn());       return;
  }
  // VFO Tune (or an unresolved action): honour the inspector's
  // "Dial press action" dropdown.  Defaults to MOX, the old hardcoded
  // behaviour, when nothing is saved.
  switch (settingsFor(jsn).press_action || 'mox') {
    case 'none':                                    break;
    case 'mode_cycle': tciSend(cmdModeNext());      break;
    case 'vfo_swap':   doVfoSwap();                 break;
    default:           tciSend(cmdMoxToggle());     break;
  }
});

$UD.onDialUp((jsn) => {
  if (actionIdFor(jsn) === `${PLUGIN_UUID}.pttMomentary`) tciSend(cmdPttOff());
});

// ─── Crash hooks ─────────────────────────────────────────────────────────
process.on('unhandledRejection', (err) => console.error('[unhandled]', err));
process.on('uncaughtException',  (err) => console.error('[crash]', err));
