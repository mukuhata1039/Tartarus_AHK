param(
    [ValidateSet("start","restart","stop")]
    [string]$Action = "start"
)

$ErrorActionPreference = "SilentlyContinue"

# Portable root: wherever this folder lives.
$Root = Split-Path -Parent $PSCommandPath
$AhkScript = Join-Path $Root "Tartarus_Main.ahk"
$LedScript = Join-Path $Root "Tartarus_LED_Daemon.py"
$SettingsScript = Join-Path $Root "Tartarus_Settings_Server.py"
$AnalogScript = Join-Path $Root "Tartarus_Analog_Daemon.py"
$CommandFile = Join-Path $Root "Tartarus_Command.txt"
$StateFile = Join-Path $Root "Tartarus_LED_State.txt"
$CurrentMapFile = Join-Path $Root "Tartarus_CurrentMap.txt"
$LogDir = Join-Path $Root "Logs"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir "Tartarus_Runtime.log"

function Log([string]$Text) {
    try {
        Add-Content -LiteralPath $LogFile -Encoding UTF8 `
            -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Text)
    } catch {}
}

# IMPORTANT: Match by script BASENAME, not by this folder's absolute path.
# Older portable test folders use the same localhost port and shared mmap.  If
# they are left alive, the browser can keep showing an old UI even though this
# folder contains newer code.  A restart therefore owns and replaces every
# Tartarus process with these exact script names, regardless of old folder.
function CommandLineContains([object]$Proc, [string]$LeafName) {
    return $Proc.CommandLine -and
        $Proc.CommandLine.IndexOf($LeafName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-TartarusAhkProcesses {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -ieq "AutoHotkey64.exe" -or $_.Name -ieq "AutoHotkey.exe") -and
        (CommandLineContains $_ "Tartarus_Main.ahk")
    })
}

function Get-TartarusLedProcesses {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -ieq "pythonw.exe" -or $_.Name -ieq "python.exe") -and
        (CommandLineContains $_ "Tartarus_LED_Daemon.py")
    })
}

function Get-TartarusSettingsProcesses {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -ieq "pythonw.exe" -or $_.Name -ieq "python.exe") -and
        (CommandLineContains $_ "Tartarus_Settings_Server.py")
    })
}

function Get-TartarusAnalogProcesses {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -ieq "pythonw.exe" -or $_.Name -ieq "python.exe") -and
        (CommandLineContains $_ "Tartarus_Analog_Daemon.py")
    })
}

function Stop-OnlyTartarus {
    Log "STOP requested"

    # Always send the graceful exit command. Process lookup can miss the AHK
    # instance on some systems, but the mapper polls this file every 300 ms.
    Set-Content -LiteralPath $CommandFile -Value "EXIT" -Encoding ASCII
    Start-Sleep -Milliseconds 450

    # If process lookup works, wait a little longer and force only this mapper
    # as a final fallback.
    if ((Get-TartarusAhkProcesses).Count -gt 0) {
        $tries = 0
        while ((Get-TartarusAhkProcesses).Count -gt 0 -and $tries -lt 22) {
            Start-Sleep -Milliseconds 80
            $tries++
        }

        foreach ($p in (Get-TartarusAhkProcesses)) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            Log "Forced mapper PID=$($p.ProcessId)"
        }
    }

    # Runtime alone owns LED daemon shutdown. The mapper must never write this
    # during Cleanup, otherwise a late Cleanup can kill the next daemon after a
    # restart.
    if ((Get-TartarusLedProcesses).Count -gt 0) {
        Set-Content -LiteralPath $StateFile -Value "__EXIT__" -Encoding ASCII
    }

    $tries = 0
    while ((Get-TartarusLedProcesses).Count -gt 0 -and $tries -lt 16) {
        Start-Sleep -Milliseconds 80
        $tries++
    }
    foreach ($p in (Get-TartarusLedProcesses)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Log "Forced LED PID=$($p.ProcessId)"
    }

    foreach ($p in (Get-TartarusSettingsProcesses)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Log "Stopped settings PID=$($p.ProcessId)"
    }
    foreach ($p in (Get-TartarusAnalogProcesses)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Log "Stopped analog PID=$($p.ProcessId)"
    }

    Remove-Item -LiteralPath $CommandFile -Force -ErrorAction SilentlyContinue
}

function Find-Ahk2 {
    $candidates = @(
        "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe",
        "C:\Program Files\AutoHotkey\v2\AutoHotkey.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Find-PythonExe {
    try {
        $p = (& py -3 -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1)
        if ($p) {
            $p = $p.Trim()
            if (Test-Path -LiteralPath $p) { return $p }
        }
    } catch {}

    try {
        $p = (& python -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1)
        if ($p) {
            $p = $p.Trim()
            if (Test-Path -LiteralPath $p) { return $p }
        }
    } catch {}

    return $null
}

function Find-Pythonw {
    $py = Find-PythonExe
    if (-not $py) { return $null }

    $pythonw = Join-Path (Split-Path $py -Parent) "pythonw.exe"
    if (Test-Path -LiteralPath $pythonw) { return $pythonw }
    return $py
}

function Start-SettingsIfNeeded {
    $ps = Get-TartarusSettingsProcesses
    if ($ps.Count -gt 0) { return $true }

    $pyw = Find-Pythonw
    if (-not $pyw) {
        Log "ERROR Python not found"
        return $false
    }

    Start-Process -FilePath $pyw -ArgumentList "`"$SettingsScript`"" -WindowStyle Hidden
    Start-Sleep -Milliseconds 250
    return ((Get-TartarusSettingsProcesses).Count -gt 0)
}

function Start-AnalogIfNeeded {
    $ps = Get-TartarusAnalogProcesses
    if ($ps.Count -gt 0) { return $true }

    $py = Find-PythonExe
    if (-not $py) { Log "ANALOG disabled: Python not found"; return $false }
    & $py -c "import hid" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Log "ANALOG disabled: hidapi package missing; run INSTALL_ANALOG_SUPPORT.bat"
        return $false
    }
    $pyw = Find-Pythonw
    Start-Process -FilePath $pyw -ArgumentList "`"$AnalogScript`"" -WindowStyle Hidden
    Start-Sleep -Milliseconds 300
    return ((Get-TartarusAnalogProcesses).Count -gt 0)
}

function Start-LedIfNeeded {
    $ps = Get-TartarusLedProcesses
    if ($ps.Count -gt 0) { return $true }

    $pyw = Find-Pythonw
    if (-not $pyw) {
        Log "ERROR Python not found"
        return $false
    }

    # Do not let a shutdown marker left by an older version terminate the new
    # daemon immediately. Seed the state with the last valid map when possible.
    $seedMap = ""
    if (Test-Path -LiteralPath $CurrentMapFile) {
        $seedMap = (Get-Content -LiteralPath $CurrentMapFile -Raw).Trim()
    }
    if ($seedMap -and $seedMap -ne "__EXIT__") {
        Set-Content -LiteralPath $StateFile -Value $seedMap -Encoding UTF8
    } else {
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    }

    Start-Process -FilePath $pyw -ArgumentList "`"$LedScript`"" -WindowStyle Hidden
    Start-Sleep -Milliseconds 300
    return ((Get-TartarusLedProcesses).Count -gt 0)
}

function Start-MapperIfNeeded {
    $ps = Get-TartarusAhkProcesses
    if ($ps.Count -gt 0) { return $true }

    # Standalone mode never terminates third-party processes. Synapse captures
    # the same Tartarus input path, so refuse to start until it is closed or
    # uninstalled instead of force-killing RazerAppEngine.
    if ((Get-Process RazerAppEngine -ErrorAction SilentlyContinue).Count -gt 0) {
        Log "ERROR RazerAppEngine is running; mapper start refused"
        return $false
    }

    $ahk2 = Find-Ahk2
    if (-not $ahk2) {
        Log "ERROR AutoHotkey v2 not found"
        return $false
    }

    Remove-Item -LiteralPath $CommandFile -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $ahk2 -ArgumentList "`"$AhkScript`""
    Start-Sleep -Milliseconds 300
    return ((Get-TartarusAhkProcesses).Count -gt 0)
}

# Serialize start/restart/stop. Setup, the tray menu, and OPEN_SETTINGS can
# otherwise launch overlapping runtime processes whose stop/start phases race.
$runtimeMutex = New-Object System.Threading.Mutex($false, "Local\TartarusPortableRuntime")
$runtimeLockTaken = $false

try {
    try {
        $runtimeLockTaken = $runtimeMutex.WaitOne(30000)
    } catch [System.Threading.AbandonedMutexException] {
        $runtimeLockTaken = $true
    }

    if (-not $runtimeLockTaken) {
        Log "ERROR runtime lock timeout action=$Action"
        exit 3
    }

    if ($Action -eq "stop") {
        Stop-OnlyTartarus
        exit
    }

    if ($Action -eq "restart") {
        Stop-OnlyTartarus
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 150
    }

    $settingsOk = Start-SettingsIfNeeded
    # Start analog before the persistent LED control handle. The LED daemon
    # also sends mode-3 now, so either process can restore streaming after a
    # device/daemon restart without depending on a fragile launch race.
    $analogOk = Start-AnalogIfNeeded
    $ledOk = Start-LedIfNeeded
    $ahkOk = Start-MapperIfNeeded
    Log "START AUDIT_FIX1 action=$Action settings=$settingsOk analog=$analogOk led=$ledOk ahk=$ahkOk"
} finally {
    if ($runtimeLockTaken) {
        try { $runtimeMutex.ReleaseMutex() } catch {}
    }
    $runtimeMutex.Dispose()
}
