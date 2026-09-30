$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSCommandPath
$AutostartVbs = Join-Path $Root "Tartarus_Autostart.vbs"
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunCommand = 'wscript.exe "' + $AutostartVbs + '"'

if (!(Test-Path -LiteralPath $AutostartVbs)) {
    throw "Tartarus_Autostart.vbs が見つかりません: $AutostartVbs"
}

if (!(Test-Path -LiteralPath $RunKey)) {
    New-Item -Path $RunKey | Out-Null
}

# Set only our own value.  Never recreate the whole Run key and never touch
# other applications' startup entries.
Set-ItemProperty -Path $RunKey -Name "TartarusPortable" -Value $RunCommand

$Saved = (Get-ItemProperty -Path $RunKey -Name "TartarusPortable").TartarusPortable
Write-Host ""
Write-Host "Tartarus 自動起動を登録しました。" -ForegroundColor Green
Write-Host "HKCU Run:"
Write-Host "  $Saved"
Write-Host ""
Write-Host "現在のTartarusも起動確認します..."
Start-Process -FilePath "wscript.exe" -ArgumentList "`"$AutostartVbs`"" -WindowStyle Hidden
Write-Host "完了。次回ログオン時は数秒待ってから自動起動し、失敗時は再試行します。"
