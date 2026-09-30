$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSCommandPath
$Lib = Join-Path $Root "Lib"
$Config = Join-Path $Root "Tartarus_Config.tsv"
$DefaultConfig = Join-Path $Root "Tartarus_Config.default.tsv"
$RuntimeVbs = Join-Path $Root "Tartarus_Runtime.vbs"
$RuntimePs1 = Join-Path $Root "Tartarus_Runtime.ps1"
$AutostartVbs = Join-Path $Root "Tartarus_Autostart.vbs"
$Logs = Join-Path $Root "Logs"
New-Item -ItemType Directory -Path $Logs -Force | Out-Null

Write-Host ""
Write-Host "Tartarus TEST11 FIX3 - startup-safe setup" -ForegroundColor Cyan
Write-Host "Install folder: $Root"
Write-Host ""

# Standalone edition never kills Razer software behind the user's back.
# Synapse competes for the same Tartarus input, so stop here with a clear
# message until migration is complete.
if ((Get-Process RazerAppEngine -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Host "Razer Synapse (RazerAppEngine) が起動中です。" -ForegroundColor Red
    Write-Host "先にRazer Synapseをアンインストールし、Windowsを再起動してください。"
    Write-Host "その後、このSETUP_PORTABLE.batをもう一度実行してください。"
    Write-Host ""
    Read-Host "Enterで閉じる"
    exit 2
}

# 1) Stop the old v8 runtime if present.
$OldRoot = "C:\Tools\AutoHotInterception"
$OldRuntime = Join-Path $OldRoot "Tartarus_Runtime.ps1"
if (Test-Path -LiteralPath $OldRuntime) {
    Write-Host "旧v8を停止中..."
    try {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OldRuntime stop | Out-Null
    } catch {}
    Start-Sleep -Milliseconds 300
}

# 2) Bring the current user config across BEFORE falling back to defaults.
$OldConfig = Join-Path $OldRoot "Tartarus_Config.tsv"
$OldBackup = Join-Path $OldRoot "Tartarus_Config.backup.tsv"

if (Test-Path -LiteralPath $OldConfig) {
    Copy-Item -LiteralPath $OldConfig -Destination $Config -Force
    Write-Host "現在のキー配置を旧v8から移行しました。" -ForegroundColor Green
} elseif (!(Test-Path -LiteralPath $Config)) {
    Copy-Item -LiteralPath $DefaultConfig -Destination $Config -Force
    Write-Host "v7互換の初期キー配置を作成しました。"
}

if (Test-Path -LiteralPath $OldBackup) {
    Copy-Item -LiteralPath $OldBackup -Destination (Join-Path $Root "Tartarus_Config.backup.tsv") -Force
}

# 3) Make the AHI user library local to this portable folder.
if (!(Test-Path -LiteralPath (Join-Path $Lib "AutoHotInterception.ahk"))) {
    $LibCandidates = @(
        (Join-Path $OldRoot "Lib"),
        (Join-Path (Split-Path $Root -Parent) "AutoHotInterception\Lib"),
        "D:\Tools\AutoHotInterception\Lib"
    )

    $Copied = $false
    foreach ($candidate in $LibCandidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate "AutoHotInterception.ahk")) {
            Copy-Item -LiteralPath $candidate -Destination $Lib -Recurse -Force
            Write-Host "AutoHotInterception\Lib をローカルへコピーしました:"
            Write-Host "  $candidate -> $Lib"
            $Copied = $true
            break
        }
    }

    if (-not $Copied) {
        throw @"
AutoHotInterception の Lib フォルダを見つけられませんでした。

このフォルダの中に
  Lib\AutoHotInterception.ahk
が存在するように、既存の AutoHotInterception\Lib を丸ごとコピーしてから
SETUP_PORTABLE.bat をもう一度実行してください。
"@
    }
}

# 4) Verify Python and hidapi.
$py = $null
try {
    $py = (& py -3 -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1).Trim()
} catch {}
if (!$py -or !(Test-Path -LiteralPath $py)) {
    try {
        $py = (& python -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1).Trim()
    } catch {}
}
if (!$py -or !(Test-Path -LiteralPath $py)) {
    throw "Python 3 が見つかりません。"
}

& $py -c "import hid" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "hidapiをインストール中..."
    & $py -m pip install --user hidapi
    if ($LASTEXITCODE -ne 0) {
        throw "hidapi のインストールに失敗しました。"
    }
}

# 5) Verify AutoHotkey v2.
$AhkCandidates = @(
    "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe",
    "C:\Program Files\AutoHotkey\v2\AutoHotkey.exe",
    "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe"
)
$AhkFound = $false
foreach ($a in $AhkCandidates) {
    if (Test-Path -LiteralPath $a) {
        $AhkFound = $true
        break
    }
}
if (-not $AhkFound) {
    throw "AutoHotkey v2 が見つかりません。"
}

# 6) Run static/config self-test before registering autostart.
$SelfTest = Join-Path $Root "Tartarus_SelfTest.py"
if (Test-Path -LiteralPath $SelfTest) {
    & $py $SelfTest
    if ($LASTEXITCODE -ne 0) {
        throw "Tartarus self-test failed. Autostart was not changed."
    }
}

# 7) Autostart via HKCU Run registry. No Startup-folder file.
# Use the delayed/retrying launcher instead of firing the runtime only once
# during the fragile first seconds of logon.
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunCommand = 'wscript.exe "' + $AutostartVbs + '"'
if (-not (Test-Path -LiteralPath $RunKey)) {
    New-Item -Path $RunKey | Out-Null
}
Set-ItemProperty -Path $RunKey -Name "TartarusPortable" -Value $RunCommand

# 8) Start the portable runtime.
Start-Process -FilePath "wscript.exe" -ArgumentList "`"$RuntimeVbs`" restart" -WindowStyle Hidden
Start-Sleep -Milliseconds 1100

# 9) Only after the new files are in place, remove OUR old Tartarus files from C:\Tools\AutoHotInterception.
#    The AutoHotInterception program/Lib itself is intentionally left untouched.
if ($Root.TrimEnd("\") -ine $OldRoot.TrimEnd("\")) {
    $OldTartarusFiles = @(
        "Tartarus_Main.ahk",
        "Tartarus_LED_Daemon.py",
        "Tartarus_Settings_Server.py",
        "Tartarus_Runtime.ps1",
        "Tartarus_Runtime.vbs",
        "Tartarus_Config.tsv",
        "Tartarus_Config.default.tsv",
        "Tartarus_Config.backup.tsv",
        "Tartarus_LED_State.txt",
        "Tartarus_Command.txt",
        "Tartarus_CurrentMap.txt"
    )

    foreach ($name in $OldTartarusFiles) {
        $p = Join-Path $OldRoot $name
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        }
    }

    $OldStartup = Join-Path ([Environment]::GetFolderPath("Startup")) "Tartarus_Autostart.vbs"
    if (Test-Path -LiteralPath $OldStartup) {
        Remove-Item -LiteralPath $OldStartup -Force -ErrorAction SilentlyContinue
    }

    Write-Host "旧C:\Tools\AutoHotInterception 内の Tartarus 関連ファイルだけ削除しました。" -ForegroundColor Green
    Write-Host "AutoHotInterception本体/Lib/ドライバには触れていません。"
}

Start-Process "http://127.0.0.1:8765/"

Write-Host ""
Write-Host "完了。" -ForegroundColor Green
Write-Host "今後のTartarus本体ファイルは、このフォルダだけです:"
Write-Host "  $Root"
Write-Host ""
Write-Host "このフォルダをバックアップすれば、キー配置もUIもコードもまとめて保存できます。"
Write-Host ""
Read-Host "Enterで閉じる"
