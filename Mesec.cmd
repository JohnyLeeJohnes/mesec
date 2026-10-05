@echo off
rem Spusti Mesec bez instalace. Zastupce s ikonou vytvori install.cmd.
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Mesec.ps1"
