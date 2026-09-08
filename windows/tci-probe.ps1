# tci-probe.ps1 - query AetherSDR TCI without writing to the radio (Windows).
#
#   *** NEVER RUN ON WINDOWS. Port of tci-probe.sh. The JavaScript below is
#       the proven macOS program, copied byte-for-byte -- only the shell around
#       it is new, and make-bundle.sh refuses to build if the two drift.
#       The wrapper WAS exercised under pwsh on macOS: it located ws and node,
#       wrote the temp .mjs and ran the program, which reached its own error
#       handler with the radio absent. Untested against a real radio here. ***
#
# Exists because `verb:0;` is NOT a universally safe probe. TCI verbs come in
# two shapes and that string means opposite things to them:
#
#   receiver-indexed : drive:<rx>,<value>    `drive:0;`     = query receiver 0
#   NOT indexed      : mic_level:<value>     `mic_level:0;` = SET IT TO ZERO
#
# On 2026-09-01 a verb sweep in the `verb:0;` form sent `tx_gain:0;`, zeroed
# AetherSDR TCI TX gain, and took the station off the air for two days - the
# radio keyed normally on FT8 and radiated nothing. See HANDOVER.md.
#
#   .\tci-probe.ps1                     full state dump (connect burst)
#   .\tci-probe.ps1 mic_level           QUERY - sends `mic_level;`, never writes
#   .\tci-probe.ps1 drive               QUERY - sends `drive;`
#   .\tci-probe.ps1 mic_level 40        WRITE - sends `mic_level:40;`, confirms first
#   .\tci-probe.ps1 -Yes mic_level 40   WRITE without the confirmation prompt
#
# One argument always means READ: the bare `verb;` form is a query for BOTH
# shapes and can never write.

[CmdletBinding()]
param(
    [switch]$Yes,
    [Parameter(Position = 0)][string]$Verb  = '',
    [Parameter(Position = 1)][string]$Value = ''
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

if ($Value) {
    Write-Host "WRITE: ${Verb}:${Value};   ->  $Url"
    Write-Host "This changes the radio. A query needs no value: .\tci-probe.ps1 $Verb"
    if (-not $Yes) {
        $reply = Read-Host 'Send it? [y/N]'
        if ($reply -notmatch '^[yY]') { Write-Host 'aborted'; exit 1 }
    }
}

$env:TCI_WS    = $Ws
$env:TCI_URL   = $Url
$env:TCI_VERB  = $Verb
$env:TCI_VALUE = $Value

# ---8<--- JS copied verbatim from tci-probe.sh; make-bundle.sh enforces it ---
$Program = @'

const { default: WebSocket } = await import(process.env.TCI_WS);
const verb  = process.env.TCI_VERB;
const value = process.env.TCI_VALUE;
const ws = new WebSocket(process.env.TCI_URL);
let ready = false;

// Chatter that drowns out the answer.  ONLY the high-rate meters belong here.
// vfo_limits, if_limits and modulations_list were in this list until 2026-09-03
// and should never have been: they are one-shot burst lines, not chatter, and
// each one states a capability.  Filtering modulations_list hid the mode
// vocabulary from every dump AND from an explicit
//     ./tci-probe.sh modulations_list
// query -- which is how patch 4 came to claim cw, am and fm do not exist when
// the burst lists all three.  That wrong list went out in upstream issue #3.
// If a burst line is verbose, let it be verbose; a probe must never quietly
// withhold an answer.
// (Careful: this whole program is inside a single-quoted shell string, so no
// apostrophes in these comments -- one closes the quote and mangles the file.)
const NOISE = /^(rx_smeter|tx_smeter)/;

ws.on("open", () => {
  if (!verb) return;                       // no verb: just print the connect burst
  setTimeout(() => {
    const cmd = value ? `${verb}:${value};` : `${verb};`;
    console.log(`-> ${cmd}`);
    ws.send(cmd);
    if (value) setTimeout(() => { console.log(`-> ${verb};`); ws.send(`${verb};`); }, 400);
  }, 700);
});

ws.on("message", (d) => {
  const s = d.toString().trim();
  // Do NOT exit on `ready;`.  AetherSDR sends it partway through the connect
  // burst — split_enable, mute, rit/xit, agc and the whole second receiver
  // all arrive AFTER it.  Exiting here truncated the state dump to its first
  // ~8 lines and made absent-from-the-dump look like absent-from-TCI
  // (2026-09-01: it hid split_enable and cost a wrong diagnosis).
  if (s === "ready;") { ready = true; return; }
  if (NOISE.test(s)) return;
  // With a verb, show only its replies; without one, show the whole burst.
  if (verb && !s.startsWith(verb)) return;
  console.log(verb ? `   <- ${s}` : s);
});

ws.on("error", (e) => { console.error(`error: ${e.message}`); process.exit(1); });
// The no-verb dump now runs to this timeout instead of stopping at `ready;`,
// so it needs long enough for the full burst (both receivers).
setTimeout(() => process.exit(0), verb ? (value ? 2200 : 1800) : 4000);

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
