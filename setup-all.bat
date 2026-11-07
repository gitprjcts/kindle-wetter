@echo off
REM Starts the automatic setup without execution-policy problems.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-all.ps1" %*
pause
