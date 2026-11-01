# autostart.ps1 - schaltet Autostart-Eintraege fuer ALLE Konten an oder ab (braucht Adminrechte)
# Wird vom Fortschrittsfenster mit Adminabfrage aufgerufen. Aendert nur die Schalter, die auch der
# Task-Manager unter "Autostart" benutzt (StartupApproved) - nichts wird geloescht.
param([Parameter(Mandatory = $true)][string]$Datei)
$ErrorActionPreference = 'Stop'
$AP = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$erlaubt = @("$AP\Run", "$AP\Run32", "$AP\StartupFolder")
try {
  $liste = @(Get-Content -Path $Datei -Raw -Encoding UTF8 | ConvertFrom-Json)
  foreach ($e in $liste) {
    if ($erlaubt -notcontains [string]$e.Appr) { continue }       # nur diese drei Schluessel
    $name = [string]$e.Name
    if (-not $name) { continue }
    if (-not (Test-Path $e.Appr)) { New-Item -Path $e.Appr -Force | Out-Null }
    $wert = [byte[]](@($(if ([bool]$e.An) { 2 } else { 3 })) + @(0) * 11)
    New-ItemProperty -Path $e.Appr -Name $name -Value $wert -PropertyType Binary -Force | Out-Null
  }
  if (-not (Test-Path 'HKLM:\SOFTWARE\Einrichtung')) { New-Item -Path 'HKLM:\SOFTWARE\Einrichtung' -Force | Out-Null }
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Einrichtung' -Name 'AutostartMaschine' -Value 1 -PropertyType DWord -Force | Out-Null
  exit 0
} catch {
  exit 1
}
