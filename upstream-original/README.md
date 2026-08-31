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

Do not edit anything in this directory — it is a reference copy.
