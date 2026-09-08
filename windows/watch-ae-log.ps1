# watch-ae-log.ps1 - live view of the TCI commands AetherSDR RECEIVES (Windows).
#
#   *** NEVER RUN ON WINDOWS. Port of watch-ae-log.sh -- but verified where it
#       could be: run under pwsh on macOS against a synthetic AE log, its output
#       was BYTE-IDENTICAL to watch-ae-log.sh on the same input (both kept the
#       four TCI rx lines, both dropped the MSHV vfo:0,0 / modulation:0 polls
#       and the non-TCI line). What is untested is the Windows log PATH. ***
#
# The third diagnostic, and the one that answers a different question from the
# other two:
#
#   tci-probe.ps1    what is the radio state right now?      (asks AE)
#   tci-watch.ps1    what does AE broadcast when I do X?     (listens on the wire)
#   watch-ae-log.ps1 what did the PLUGIN actually send?      (reads AE own log)
#
# That last one is the question you have when a button "does nothing", and the
# wire cannot answer it: Studio swallows plugin stdout through a pipe, so short
# of the DEBUG flag in the plugin there is no view of what a press emitted.
# AetherSDR logs every command it receives - the same evidence from the far end,
# needing no plugin change to get at.
#
# LOG PATH - confirmed from AetherSDR's own source, not guessed:
#   src/core/LogManager.cpp builds the log path as
#       QStandardPaths::GenericConfigLocation + "/AetherSDR/logs/aethersdr.log"
#   with rotated files named aethersdr-<timestamp>.log in the same directory.
#   src/core/SettingsPaths.h documents GenericConfigLocation as
#       ~/.config/AetherSDR (Linux), ~/Library/Preferences/AetherSDR (macOS),
#       %LOCALAPPDATA%/AetherSDR (Windows)
#   so the Windows log directory is %LOCALAPPDATA%\AetherSDR\logs.
#
# MSHV polls `vfo:0,0;` and `modulation:0;` about once a second on the same TCI
# port; that is filtered out below or it buries everything else. Pass -Raw to
# keep it.
#
# Read-only: opens no socket, sends nothing. Safe mid-QSO.
#
#   .\watch-ae-log.ps1              follow every command AE receives
#   .\watch-ae-log.ps1 tune         follow, showing only lines matching `tune`
#   .\watch-ae-log.ps1 -Raw         do not filter the MSHV poll traffic

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Filter = '',
    [switch]$Raw
)

$ErrorActionPreference = 'Stop'

$LogDir = Join-Path $env:LOCALAPPDATA 'AetherSDR\logs'
if (-not (Test-Path $LogDir)) {
    Write-Error @"
No AetherSDR log directory at:
  $LogDir
Start AetherSDR at least once. If it has run and this path is still absent,
the platform mapping in the header is wrong for your build - please correct it
in the repo rather than leaving the next person to re-derive it.
"@
    exit 1
}

# Skip the rolling aethersdr.log and take the newest stamped one, as the macOS
# script does: the stamped file is the current session.
$File = Get-ChildItem -Path $LogDir -Filter 'aethersdr-*.log' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

if (-not $File) {
    Write-Error "No aethersdr-*.log files in $LogDir - has AetherSDR run yet?"
    exit 1
}

Write-Host "watching $($File.Name)  (Ctrl-C to stop)" -ForegroundColor Yellow

Get-Content -Path $File.FullName -Wait -Tail 0 |
    Where-Object { $_ -match 'TCI rx' } |
    Where-Object { $Raw -or ($_ -notmatch '"(vfo:0,0|modulation:0);"') } |
    ForEach-Object { $_ -replace '.*\[([0-9:.]*)\].*TCI rx: ', '$1  ' } |
    Where-Object { -not $Filter -or $_ -match [regex]::Escape($Filter) }
