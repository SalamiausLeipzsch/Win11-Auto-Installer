@echo off
rem Vorschau: nur die Oberflaeche ansehen - aendert NICHTS, braucht keine Adminrechte.
rem Mit Bildschirmfotos aller Reiter:  Vorschau.cmd -Bilder "%USERPROFILE%\Desktop\Einrichtung-Bilder"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0setup.ps1" -Vorschau %*
