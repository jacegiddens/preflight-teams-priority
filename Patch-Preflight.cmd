@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Patch-Preflight.ps1"
if errorlevel 1 pause
