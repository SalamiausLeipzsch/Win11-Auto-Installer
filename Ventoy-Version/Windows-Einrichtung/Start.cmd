@echo off
rem Startet die Windows-Einrichtung / Windows-Zentrale mit Adminrechten.
cd /d "%~dp0"
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Adminrechte werden angefordert ...
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit
)
rem Klassisches Protokollfenster, minimiert. Sichtbar sind Auswahloberflaeche/Zentrale und das Fortschrittsfenster.
powershell.exe -NoProfile -Command "Start-Process conhost.exe -WindowStyle Minimized -ArgumentList 'powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File \"%~dp0setup.ps1\" %*'"
exit
