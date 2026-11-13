@echo off
rem Double-click this file to install Claude Code on the phone plugged into this laptop.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
