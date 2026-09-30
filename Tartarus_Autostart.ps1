$ErrorActionPreference = "SilentlyContinue"

$Root = Split-Path -Parent $PSCommandPath
$RuntimeVbs = Join-Path $Root "Tartarus_Runtime.vbs"
$LogDir = Join-Path $Root "Logs"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir "Tartarus_Autostart.log"

function Log([string]$Text) {
    try {
        Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Text)
    } catch {}
}

function CommandLineContains([object]$Proc, [string]$LeafName) {
    return $Proc.CommandLine -and $Proc.CommandLine.IndexOf($LeafName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Mapper-IsRunning {
    $p = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -ieq "AutoHotkey64.exe" -or $_.Name -ieq "AutoHotkey.exe") -and
        (CommandLineContains $_ "Tartarus_Main.ahk")
    })
    return $p.Count -gt 0
}

Log "AUTOSTART begin root=$Root"

if (!(Test-Path -LiteralPath $RuntimeVbs)) {
    Log "ERROR runtime VBS missing: $RuntimeVbs"
    exit 2
}

# HKCU Run can fire very early during logon.  At that point Explorer, HID
# enumeration, AutoHotInterception and even the user's output keyboard may not
# be ready yet.  The old launcher tried exactly once and then gave up.
# Wait for the shell, then retry only the Tartarus runtime.  No other startup
# apps/processes are touched.
for ($i = 0; $i -lt 20; $i++) {
    if ((Get-Process explorer -ErrorAction SilentlyContinue).Count -gt 0) { break }
    Start-Sleep -Milliseconds 500
}

# Give USB/HID and interception a short settling period after Explorer appears.
Start-Sleep -Seconds 4

if (Mapper-IsRunning) {
    Log "Mapper already running; nothing to do"
    exit 0
}

for ($attempt = 1; $attempt -le 8; $attempt++) {
    Log "runtime start attempt=$attempt"
    Start-Process -FilePath "wscript.exe" -ArgumentList "`"$RuntimeVbs`" start" -WindowStyle Hidden
    Start-Sleep -Milliseconds 1800

    if (Mapper-IsRunning) {
        Log "SUCCESS mapper detected on attempt=$attempt"
        exit 0
    }

    Start-Sleep -Milliseconds 700
}

Log "ERROR mapper did not stay running after retries"
exit 1
