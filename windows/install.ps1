# install.ps1 - install the D100H -> AetherSDR bundle on Windows.
#
#   *** NEVER RUN ON WINDOWS. No Windows machine exists in this shack. ***
#
# Port of install.sh. Its LOGIC has been exercised: parsed by PowerShell 7.6,
# and run under pwsh on macOS against a scratch %APPDATA% -- fresh install,
# re-install over an existing one (the move-aside path), the manifest-vs-source
# verification, and -Check. What has NEVER been tested is the part that only
# Windows can answer: whether Studio finds the plugin at these paths, whether
# the profile binds to the dial, and whether the D100H works at the far end.
# If you run it, run `.\install.ps1 -Check` FIRST -- that path only reads.
#
# WHAT IS CONFIRMED, AND WHAT IS NOT
#   confirmed  %APPDATA%\Ulanzi\UlanziDeck\Plugins  is the plugin directory.
#              Verified against a shipped third-party UlanziDeck plugin
#              (github.com/narlei/ulanzideck_claude), not from memory.
#   confirmed  Ulanzi Studio bundles its own Node.js v20 for plugins, so the
#              target needs no system Node -- same as macOS.
#   INFERRED   %APPDATA%\Ulanzi\UlanziDeck\ProfilesV2 for the profile. On macOS
#              ProfilesV2 is a sibling of Plugins under the same parent, so this
#              follows by symmetry -- but it has never been seen on Windows.
#              If the profile does not appear in Studio, this path is the first
#              thing to check, and please correct it in the repo.
#   UNKNOWN    the Ulanzi Studio process name on Windows. The quit step matches
#              any running process whose name contains "Ulanzi" and reports what
#              it found rather than assuming.
#
# Usage:
#   .\install.ps1 -Check    report what is installed; change nothing
#   .\install.ps1           install, prompting before quitting Studio
#   .\install.ps1 -Yes      install without prompts

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$Here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginName  = 'com.g0jkn.aethersdr.ulanziPlugin'
$UD          = Join-Path $env:APPDATA 'Ulanzi\UlanziDeck'
$DestPlugins = Join-Path $UD 'Plugins'
$DestProfiles= Join-Path $UD 'ProfilesV2'

function Red ($m) { Write-Host $m -ForegroundColor Red }
function Grn ($m) { Write-Host $m -ForegroundColor Green }
function Ylw ($m) { Write-Host $m -ForegroundColor Yellow }

# The bundle lives one level up: this script ships in windows\ inside the zip.
$BundleRoot = if (Test-Path (Join-Path $Here $PluginName)) { $Here } else { Split-Path -Parent $Here }

$SrcPlugin  = Join-Path $BundleRoot $PluginName
$SrcProfile = Get-ChildItem -Path $BundleRoot -Filter '*.ulanziProfile' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not (Test-Path $SrcPlugin)) {
    Red "Bundle incomplete: no $PluginName found in $BundleRoot"
    Red "Run this from inside the unzipped bundle (windows\install.ps1)."
    exit 1
}
if (-not $SrcProfile) {
    Red "Bundle incomplete: no .ulanziProfile directory in $BundleRoot"
    exit 1
}

# Without ws, app.js throws at import and NO plugin process ever starts -- the
# failure that looks like dead hardware. It is bundled so the target needs no
# npm, so its absence means a broken download, not a step to run.
if (-not (Test-Path (Join-Path $SrcPlugin 'node_modules\ws'))) {
    Red "Bundle incomplete: $PluginName\node_modules\ws is missing."
    Red "Without it the plugin dies at startup and no plugin process appears."
    Red "Re-download the zip and unzip with Explorer or Expand-Archive."
    exit 1
}

$DestPlugin  = Join-Path $DestPlugins $PluginName
$DestProfile = Join-Path $DestProfiles $SrcProfile.Name

function Report {
    Write-Host "Ulanzi support dir: $UD"
    if (-not (Test-Path $UD)) {
        Ylw '  not present - is Ulanzi Studio installed and launched once?'
        Ylw '  (if Studio IS installed, this path is wrong - see the header)'
        return
    }
    if (Test-Path $DestPlugin) {
        Grn "  installed  plugin  $PluginName"
        if (Test-Path (Join-Path $DestPlugin 'node_modules\ws')) {
            Grn '  present    node_modules\ws'
        } else {
            Red '  MISSING    node_modules\ws'
        }
    } else {
        Ylw "  absent     plugin  $PluginName"
    }
    if (Test-Path $DestProfile) {
        Grn "  installed  profile $($SrcProfile.Name)"
    } else {
        Ylw "  absent     profile $($SrcProfile.Name)"
    }
}

if ($Check) { Report; exit 0 }

# --- Studio must be quit: it rewrites plugin and profile state on exit.
$studio = Get-Process | Where-Object { $_.ProcessName -like '*Ulanzi*' }
if ($studio) {
    Ylw "Ulanzi Studio appears to be running as: $(($studio | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')"
    Ylw 'It rewrites plugin and profile state on exit, so it must be quit first.'
    if (-not $Yes) {
        $a = Read-Host 'Quit it now? [y/N]'
        if ($a -notmatch '^[yY]') { Red 'Aborted - nothing was changed.'; exit 1 }
    }
    $studio | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 3
    $still = Get-Process | Where-Object { $_.ProcessName -like '*Ulanzi*' }
    if ($still) {
        Red 'Ulanzi Studio is still running. Quit it by hand and re-run.'
        Red 'Deliberately NOT force-killed: Studio flushes profile state on a'
        Red 'clean exit, and killing it can lose settings you are operating with.'
        exit 1
    }
    Grn 'Ulanzi Studio quit'
}

New-Item -ItemType Directory -Force -Path $DestPlugins, $DestProfiles | Out-Null

# --- Move anything already there aside. Never delete: a previous install can
#     hold per-action settings (step_hz, coarse_mult, press_action, tci_url)
#     that exist in that copy and nowhere else.
$bk = Join-Path $Here ('replaced-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$saved = $false
foreach ($d in @($DestPlugin, $DestProfile)) {
    if (Test-Path $d) {
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        Move-Item -Path $d -Destination $bk
        Write-Host "  moved aside  $(Split-Path -Leaf $d)"
        $saved = $true
    }
}
if ($saved) { Write-Host "  previous install kept at: $bk" }

Copy-Item -Path $SrcPlugin -Destination $DestPlugins -Recurse
Copy-Item -Path $SrcProfile.FullName -Destination $DestProfiles -Recurse
Grn 'installed plugin and profile'

if (-not (Test-Path (Join-Path $DestPlugin 'node_modules\ws'))) {
    Red 'node_modules\ws did not copy - the plugin will not start.'
    exit 1
}

# --- Verify the manifest against the source, exactly as the macOS script does:
#     every declared action must be handled, or that button silently does
#     nothing. Written in PowerShell so no Python is needed on the target.
$manifest = Get-Content (Join-Path $DestPlugin 'manifest.json') -Raw | ConvertFrom-Json
$src      = Get-Content (Join-Path $DestPlugin 'plugin\app.js') -Raw
$bad = @()
foreach ($a in $manifest.Actions) {
    $tail = ($a.UUID -split '\.')[-1]
    if ($src -notmatch [regex]::Escape('${PLUGIN_UUID}.' + $tail + '`')) { $bad += $a.Name }
}
if ($bad.Count) { Red "  UNHANDLED ACTIONS: $($bad -join ', ')"; exit 1 }
Grn "  verified   $($manifest.Actions.Count) actions, all handled"
if ($src -notmatch '50001') { Red '  WARNING: TCI port 50001 not found in app.js'; exit 1 }
Grn '  verified   TCI port 50001'

Write-Host ''
# Get-NetTCPConnection is Windows-only AND is a terminating error when absent,
# because of $ErrorActionPreference = 'Stop' above -- so an unguarded call kills
# the script AFTER a successful install, at a step that is only informational.
# Caught by running this script under pwsh on macOS: everything above printed,
# then it died red and never reached "Done". Guarded, with a netstat fallback.
$listening = $false
if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    $listening = [bool](Get-NetTCPConnection -LocalPort 50001 -State Listen -ErrorAction SilentlyContinue)
} else {
    $listening = [bool]((netstat -an 2>$null) -match '[:.]50001\s.*LISTEN')
}
if ($listening) {
    Grn 'AetherSDR TCI server is listening on 50001'
} else {
    Ylw 'Nothing is listening on TCI port 50001 yet.'
    Ylw "In AetherSDR, open the TCI tile in the applet tray and start the server"
    Ylw "(turn on 'Autostart TCI with AetherSDR'). See INSTALL.md step 3."
}

Write-Host ''
Grn "Done. Start Ulanzi Studio and select the profile 'AetherSDR D100H controler'."
Write-Host '  Then turn the knob - AetherSDR VFO should follow.'
Write-Host '  If the profile is missing, the ProfilesV2 path above is the suspect.'
