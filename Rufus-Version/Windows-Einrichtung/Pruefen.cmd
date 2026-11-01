@echo off
rem Prueft System UND alle Konten (aendert nichts). Braucht die Adminabfrage (.\Verwaltung).
rem Reparieren: Startmenue -> "Windows-Zentrale" -> "Nach Windows-Updates: Reparieren + Pruefen".
cd /d "%~dp0"
powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0setup.ps1\" -Pruefen'"
