@echo off
setlocal
cd /d "%~dp0"
where py.exe >nul 2>&1
if not errorlevel 1 (
  py -3 Tartarus_SelfTest.py
) else (
  python Tartarus_SelfTest.py
)
echo.
pause
