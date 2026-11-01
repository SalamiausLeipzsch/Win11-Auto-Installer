# bilder-erstellen.ps1 - Bildschirmfotos fuer das README erzeugen.
# Laedt den aktuellen Stand von GitHub und startet die Vorschau (keine Adminrechte, aendert NICHTS am System).
# Aufruf (Windows + R):  powershell -ep bypass -c "irm https://raw.githubusercontent.com/SalamiausLeipzsch/Win11-Auto-Installer/main/werkzeuge/bilder-erstellen.ps1 | iex"
$ErrorActionPreference = 'Stop'
$zip  = Join-Path $env:TEMP 'w11-auto-installer.zip'
$ordn = Join-Path $env:TEMP 'w11-auto-installer'
$ziel = Join-Path $env:USERPROFILE 'Desktop\Win11-Bilder'
Write-Host 'Lade den aktuellen Stand von GitHub ...'
Invoke-WebRequest 'https://github.com/SalamiausLeipzsch/Win11-Auto-Installer/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing
if (Test-Path $ordn) { Remove-Item $ordn -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $ordn -Force
$setup = Join-Path $ordn 'Win11-Auto-Installer-main\Rufus-Version\Windows-Einrichtung\setup.ps1'
Write-Host 'Erstelle Bilder - bitte nichts anklicken (ca. 1 Minute) ...'
Start-Process powershell.exe -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $setup + '"'), '-Vorschau', '-Bilder', ('"' + $ziel + '"'))
Write-Host "Fertig: $ziel" -ForegroundColor Green
Start-Sleep -Seconds 3
