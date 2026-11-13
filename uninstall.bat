@echo off
rem Double-click this file to remove Claude Code from the phone plugged into this laptop.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall
echo.
pause
