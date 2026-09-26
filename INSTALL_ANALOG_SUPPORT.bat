@echo off
py -3 -m pip install hidapi
if errorlevel 1 python -m pip install hidapi
pause
