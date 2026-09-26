$ErrorActionPreference = "SilentlyContinue"
$Root = Split-Path -Parent $PSCommandPath
$Runtime = Join-Path $Root "Tartarus_Runtime.ps1"

if (Test-Path -LiteralPath $Runtime) {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Runtime stop | Out-Null
}

$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
Remove-ItemProperty -Path $RunKey -Name "TartarusPortable" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Tartarusを停止し、自動起動登録を解除しました。"
Write-Host "これでこのフォルダを別の場所へ移動できます。"
Write-Host ""
Write-Host "移動後は、新しい場所で SETUP_PORTABLE.bat を1回実行してください。"
Write-Host ""
Read-Host "Enterで閉じる"
