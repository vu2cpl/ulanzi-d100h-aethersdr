# Pristine upstream — AetherSDR Controller v0.1.5 (G0JKN)

Nigel Fenton (G0JKN)'s plugin **exactly as shipped**, before any local patching.
Kept so the patches in `../patched/` can be diffed against their true baseline,
and so bug reports to G0JKN can cite original line numbers.

Verified unpatched: `DEFAULT_TCI_URL = 'ws://127.0.0.1:40001'`, no `setSettings`
call in either inspector, `MODE_CYCLE = ['USB','LSB','CW','DIGU','DIGL','AM','FM']`,
and 18 actions in `manifest.json` (the local build adds Split Enable, Mute and
PTT (Momentary), making 21).

See what changed:

```bash
diff -u upstream-original/plugin/app.js patched/plugin/app.js
diff -u upstream-original/property-inspector/vfo/inspector.html \
        patched/property-inspector/vfo/inspector.html
```

**Upstream has moved on: v0.1.7 (`909d90b`, 2026-09-03).** This snapshot is still the
right baseline for diffing `../patched/`, which is built on 0.1.5 — but it is the *wrong*
thing to cite in a new bug report. Clone upstream at its current head for that. 0.1.7
drops Slice Cycle, defaults the TCI port to 50001 with a `migrateTciUrl()`, adds five
rotary actions, and trims the dial inspector to the TCI URL alone (that last one is a
silent settings-loss hazard for 0.1.5 profiles — see the top-level README).

Worth noting against the patch-4 story: the `MODE_CYCLE` above — shipped by upstream at
0.1.5 — already contained `CW`, `AM` and `FM`. The claim that those were not AetherSDR
modes was never supported by anything in this directory.

Do not edit anything in this directory — it is a reference copy.
