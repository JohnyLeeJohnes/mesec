@echo off
rem Vytvori zastupce "Mesec" s ikonou v nabidce Start a na plose.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Mesec.ps1" -Install
pause
