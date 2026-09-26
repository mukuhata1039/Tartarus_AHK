@echo off

cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PREPARE_TO_MOVE.ps1"

