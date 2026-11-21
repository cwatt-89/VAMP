@echo off
rem Installs VAMP Tools (shared clipboard with the Mac) for this user.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 pause
