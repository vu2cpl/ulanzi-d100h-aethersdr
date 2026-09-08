# tci-watch.ps1 - which AetherSDR TCI verbs BROADCAST vs only answer a query.
#
#   *** NEVER RUN ON WINDOWS. Port of tci-watch.sh. The JavaScript below is
#       the proven macOS program, copied byte-for-byte -- only the shell around
#       it is new, and make-bundle.sh refuses to build if the two drift.
#       Parsed by PowerShell 7.6; the identical wrapper in tci-probe.ps1 was
#       run under pwsh on macOS. Untested against a real radio here. ***
#
# STRICTLY READ-ONLY. Sends NOTHING AT ALL - not even a query - so it is safe
# to leave running on a live station mid-QSO.
#
#   .\tci-watch.ps1                        watch 60 s, report every verb
#   .\tci-watch.ps1 120                    watch 120 s
#   .\tci-watch.ps1 90 split_enable vfo    only these verbs, every change shown
#
# HOW TO READ THE RESULT
#   broadcasts   the verb changed on its own - a mirror will track it.
#   burst only   announced at connect and never again. NOT proof of query-only:
#                exercise the control and re-run before concluding anything.
#   never seen   absent from the burst too. Query it with tci-probe.ps1 first -
#                a silent response means "not a query", not "not implemented".

[CmdletBinding()]
param(
    [Parameter(Position = 0)][int]$Seconds = 60,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Only = @()
)

$ErrorActionPreference = 'Stop'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Url  = if ($env:TCI_URL) { $env:TCI_URL } else { 'ws://127.0.0.1:50001' }

# Borrow the ws copy that ships inside the installed plugin rather than adding
# a second, independently-versioned dependency. Path per install.ps1.
$Ws = Join-Path $env:APPDATA 'Ulanzi\UlanziDeck\Plugins\com.g0jkn.aethersdr.ulanziPlugin\node_modules\ws\index.js'
if (-not (Test-Path $Ws)) {
    Write-Error "can't find the ws module at:`n  $Ws`nInstall the plugin first (see INSTALL.md), or set `$Ws to another copy."
    exit 1
}

# Studio ships its own Node v20 but does not put it on PATH. Prefer a system
# node; fall back to hunting Studio's copy. If neither is found, say so plainly
# rather than failing with "term not recognized".
$Node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $Node) {
    $Node = Get-ChildItem -Path @("$env:ProgramFiles\Ulanzi*", "${env:ProgramFiles(x86)}\Ulanzi*", "$env:LOCALAPPDATA\Programs\Ulanzi*") `
                -Filter 'node.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Node) {
    Write-Error @"
No Node.js found. Either install Node, or point `$Node at the copy Ulanzi Studio
ships (look for node.exe under the Ulanzi Studio install directory).
On macOS that copy lives at:
  /Applications/Ulanzi Studio.app/Contents/MacOS/NodeJS/node
The Windows equivalent has not been confirmed - if you find it, record the path
in windows/README.md so the next person does not have to hunt.
"@
    exit 1
}

$env:TCI_WS   = $Ws
$env:TCI_URL  = $Url
$env:TCI_SECS = $Seconds
$env:TCI_ONLY = ($Only -join ' ')

Write-Host "watching $Url for ${Seconds}s - read-only, nothing is sent"
Write-Host 'exercise the controls you care about NOW (from the radio UI and from the dial)'
Write-Host ''

# ---8<--- JS copied verbatim from tci-watch.sh; make-bundle.sh enforces it ---
$Program = @'

const { default: WebSocket } = await import(process.env.TCI_WS);
const secs = Number(process.env.TCI_SECS);
const only = process.env.TCI_ONLY.trim().split(/\s+/).filter(Boolean);
const ws = new WebSocket(process.env.TCI_URL);

// Continuous telemetry, not state. It would swamp the report with noise that
// tells us nothing about whether a CONTROL broadcasts.
const METERS = /^(rx_smeter|tx_smeter|rx_sensors|tx_sensors)$/;

const burst = new Map();     // verb -> last value seen during the connect burst
const changes = new Map();   // verb -> count of post-burst changes
const last = new Map();      // verb -> last value seen at all
const t0 = Date.now();
let inBurst = true;

// AetherSDR sends `ready;` partway through the burst and keeps going, so the
// burst boundary is a settle timer, not that token. (tci-probe.sh used to exit
// on `ready;` and silently truncated its dump to ~8 of 120 lines.)
setTimeout(() => {
  inBurst = false;
  console.log(`--- connect burst captured (${burst.size} verbs) — now watching for changes ---\n`);
}, 2000);

ws.on("message", (d) => {
  for (const raw of d.toString().trim().split("\n")) {
    const line = raw.trim().replace(/;$/, "");
    if (!line) continue;
    const ci = line.indexOf(":");
    const verb = (ci < 0 ? line : line.substring(0, ci)).toLowerCase();
    if (METERS.test(verb)) continue;
    if (only.length && !only.includes(verb)) continue;
    const val = ci < 0 ? "" : line.substring(ci + 1);

    if (inBurst) { burst.set(verb, val); last.set(verb, val); continue; }
    if (last.get(verb) === val) continue;          // re-announcement, not a change
    last.set(verb, val);
    changes.set(verb, (changes.get(verb) || 0) + 1);
    // With an explicit verb list the operator wants the detail, not just a tally.
    if (only.length) {
      const t = ((Date.now() - t0) / 1000).toFixed(1).padStart(6);
      console.log(`${t}s  ${line}`);
    }
  }
});

ws.on("error", (e) => { console.error(`error: ${e.message}`); process.exit(1); });

setTimeout(() => {
  const bc = [...changes.keys()].sort();
  const quiet = [...burst.keys()].filter((v) => !changes.has(v)).sort();
  const line = (s) => console.log(s);
  line("");
  line("=".repeat(64));
  line(`BROADCASTS  (changed on their own — safe to mirror)   [${bc.length}]`);
  line("=".repeat(64));
  line(bc.length ? bc.map((v) => `  ${v.padEnd(24)} ${changes.get(v)} change(s)`).join("\n")
                 : "  (none — did you exercise any controls?)");
  line("");
  line("=".repeat(64));
  line(`BURST ONLY  (announced at connect, never again)       [${quiet.length}]`);
  line("=".repeat(64));
  line("  Not proof of query-only: a control nobody touched cannot broadcast.");
  line("  Exercise it and re-run before you build a mirror on it.");
  line("");
  // Column width from the longest name, or `audio_stream_sample_type` and
  // friends run into the next column.
  const w = Math.max(2, ...quiet.map((v) => v.length)) + 2;
  const cols = Math.max(1, Math.floor(76 / w));
  for (let i = 0; i < quiet.length; i += cols) {
    line("  " + quiet.slice(i, i + cols).map((v) => v.padEnd(w)).join("").trimEnd());
  }
  if (only.length) {
    const never = only.filter((v) => !burst.has(v) && !changes.has(v));
    if (never.length) {
      line("");
      line(`NEVER SEEN: ${never.join(", ")}`);
      line("  Absent from the burst too. Query with ./tci-probe.sh <verb> before");
      line("  concluding it is unsupported — a set draws no reply either.");
    }
  }
  process.exit(0);
}, secs * 1000 + 2000);

'@
# ---8<--- end verbatim block ---

# The program is written to a temp .mjs rather than passed with `node -e`:
# the JavaScript is full of quotes, backticks and template literals, and
# PowerShell argument quoting mangles at least one of them on the way through.
# A file has no quoting layer at all, so the program that runs is exactly the
# program below - which is the whole point of copying it verbatim.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tci-" + [guid]::NewGuid().ToString('N') + ".mjs")
Set-Content -Path $tmp -Value $Program -Encoding UTF8
try {
    & $Node $tmp
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}
