# bilder-erstellen.ps1 - Bildschirmfotos fuer das README erzeugen.
# Laedt den aktuellen Stand von GitHub und startet die Vorschau (keine Adminrechte, aendert NICHTS am System).
# Hinweis: "irm ... | iex" aus dem Ausfuehren-Dialog blockiert Defender (typisches Schadsoftware-Muster) - zu Recht.
# Einfacher: Repo als ZIP laden, entpacken, im Ordner Windows-Einrichtung in die Explorer-Adresszeile tippen:
#   cmd /k Vorschau.cmd -Bilder "%USERPROFILE%\Desktop\Win11-Bilder"
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
