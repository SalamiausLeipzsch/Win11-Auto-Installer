# setup.ps1 - Windows-Einrichtung und -Wartung (alles aus einem Programm: "Zentrale")
# Start ueber "Start.cmd" vom Stick oder Startmenue -> "Windows-Zentrale" (holt die Adminrechte).
#   ohne Parameter : Zentrale (Einrichten, Pruefen, Reparieren, Updates, Treiber, Programme, Pflege, Autostart)
#   -Einrichten    : direkt die Auswahloberflaeche
#   -Pruefen       : prueft System und alle Konten, aendert nichts
#   -Erststart     : nach Installation mit autounattend.xml (wird auch automatisch erkannt)
#   -Nachlauf      : automatisch (Aufgabenplanung, als SYSTEM): Updates mit Neustarts, Pflege, Reparatur, Pruefung
#   -Vorschau      : nur die Oberflaeche ansehen - ohne Adminrechte, aendert NICHTS ("Start" ist abgeschaltet)
#   -Bilder <Ordner> : (mit -Vorschau) speichert Bildschirmfotos aller Reiter, der Zentrale und des Fortschrittsfensters
param([switch]$Pruefen, [switch]$Erststart, [switch]$Nachlauf, [switch]$Einrichten, [switch]$Vorschau, [string]$Bilder)
$script:Vorschau = [bool]$Vorschau
$script:VBilder = if ($Vorschau -and $Bilder) { $Bilder } else { $null }

$ErrorActionPreference = 'Continue'
$Basis        = Split-Path -Parent $MyInvocation.MyCommand.Path
$Ziel         = Join-Path $env:ProgramData 'Einrichtung'
$AuswahlDatei = Join-Path $Ziel 'auswahl.json'

$istAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $istAdmin -and -not $Vorschau) {
  Write-Host 'Bitte ueber Start.cmd starten - das Skript braucht Adminrechte.' -ForegroundColor Red
  Read-Host 'Enter zum Beenden'
  exit 1
}

# ---------------------------------------------------------------- Protokollfenster entschaerfen
# Klickt man in ein klassisches Konsolenfenster, schaltet es in den Markiermodus ("Auswaehlen" im Titel) und
# HAELT das Skript an, bis Esc gedrueckt wird. Darum: Markiermodus aus, Fenster benennen und minimieren.
function Konsole-OhneMarkieren {
  try {
    if (-not ('Einr.KonsoleModus' -as [type])) {
      Add-Type -Namespace Einr -Name KonsoleModus -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int n); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out uint m); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, uint m);'
    }
    $h = [Einr.KonsoleModus]::GetStdHandle(-10); [uint32]$m = 0
    if ([Einr.KonsoleModus]::GetConsoleMode($h, [ref]$m)) {
      [void][Einr.KonsoleModus]::SetConsoleMode($h, [uint32](($m -band 0xFFFFFFBF) -bor 0x80))   # 0x40 = Markiermodus aus, 0x80 = erweiterte Flags
    }
  } catch {}
}
if (-not $Nachlauf) {
  Konsole-OhneMarkieren
  try { $Host.UI.RawUI.WindowTitle = 'Windows-Einrichtung (Protokoll) - laeuft, bitte nicht schliessen' } catch {}
}

# ---------------------------------------------------------------- System erkennen
$cv            = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$Edition       = [string]$cv.EditionID
$IstHome       = $Edition -like 'Core*'
$IstLTSC       = $Edition -like 'EnterpriseS*'
$IstEnterprise = $Edition -match 'Enterprise|Education|IoT'
$Build         = [int]$cv.CurrentBuild
$Version       = [string]$cv.DisplayVersion
$Laptop        = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$Hersteller    = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer
$CpuName       = [string](Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name
$GpuNamen      = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$GpuErkannt    = 'Keine'
if ($GpuNamen -match 'NVIDIA') { $GpuErkannt = 'NVIDIA' }
elseif ($GpuNamen -match 'Radeon.*(RX|PRO)') { $GpuErkannt = 'AMD' }
$Tpm = $false
try { $Tpm = [bool](Get-Tpm -ErrorAction Stop).TpmPresent } catch {}
$AdminName = $env:USERNAME -replace '^ADMIN_', ''   # bei aktivem Administratorschutz heisst das Fenster ADMIN_<Name>
if ($script:Vorschau) { $AdminName = 'Verwaltung' }   # Vorschau/Bilder: keine echten Kontonamen zeigen
$TeleWert  = if ($IstEnterprise) { 0 } else { 1 }  # 0 gibt es nur in Enterprise/Education/LTSC

# ---------------------------------------------------------------- Hilfsfunktionen
$script:Probe = $false; $script:Fehler = 0; $script:Ok = 0; $script:Abw = 0

function Schritt([string]$SchrittText, [scriptblock]$SchrittCode) {
  if ($script:Probe) { Write-Host "  [Probe] $SchrittText" -ForegroundColor DarkGray; return }
  $ErrorActionPreference = 'Stop'
  try { & $SchrittCode; Write-Host "  [OK] $SchrittText" -ForegroundColor Green }
  catch { Write-Host "  [!!] $SchrittText - $($_.Exception.Message)" -ForegroundColor Yellow; $script:Fehler++ }
}
function Set-Reg($Pfad, $Name, $Wert, $Typ = 'DWord') {
  if (-not (Test-Path $Pfad)) { New-Item -Path $Pfad -Force | Out-Null }
  else {
    $ist = (Get-ItemProperty -Path $Pfad -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($null -ne $ist -and "$ist" -eq "$Wert") { return }     # stimmt schon - nicht anfassen
  }
  New-ItemProperty -Path $Pfad -Name $Name -Value $Wert -PropertyType $Typ -Force | Out-Null
}
# Nie Passwoerter, Schluessel oder SecureStrings in Dateien schreiben (Profile, Auswahl)
function Ohne-Geheimnisse($o) {
  $verboten = '^(Pw|Pass.*|Passwort.*|Kennwort.*|Key|Produktkey|.*Secure.*)$'
  if ($null -eq $o) { return $null }
  if ($o -is [System.Security.SecureString]) { return $null }
  if ($o -is [System.Collections.IDictionary]) {
    $n = [ordered]@{}
    foreach ($k in @($o.Keys)) { if ([string]$k -match $verboten -or $o[$k] -is [System.Security.SecureString]) { continue }; $n[[string]$k] = Ohne-Geheimnisse $o[$k] }
    return $n
  }
  if ($o -is [System.Management.Automation.PSCustomObject]) {
    $n = [ordered]@{}
    foreach ($p in $o.PSObject.Properties) { if ($p.Name -match $verboten -or $p.Value -is [System.Security.SecureString]) { continue }; $n[$p.Name] = Ohne-Geheimnisse $p.Value }
    return $n
  }
  if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { return , @(foreach ($x in $o) { Ohne-Geheimnisse $x }) }
  return $o
}
function Get-Reg($Pfad, $Name) {
  try { (Get-ItemProperty -Path $Pfad -Name $Name -ErrorAction Stop).$Name } catch { 'fehlt' }
}
function RegWert($P, $N, $W, $T = 'DWord') { @{ P = $P; N = $N; W = $W; T = $T } }
function Titel($T) { Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }
function Info($T)  { Write-Host "  [i]  $T" -ForegroundColor Gray }
function Pruefe($Name, $Ist, $Soll) {
  if ("$Ist" -eq "$Soll") { Write-Host "  [OK] $Name" -ForegroundColor Green; $script:Ok++ }
  else { Write-Host "  [!!] $Name   (ist: '$Ist' / soll: '$Soll')" -ForegroundColor Yellow; $script:Abw++ }
}
# ---------------------------------------------------------------- Fortschritt (status.json fuer das Fortschrittsfenster)
$StatusDatei   = Join-Path $Ziel 'status.json'
$AnfrageOrdner = Join-Path $Ziel 'anfrage'      # Knoepfe im Fortschrittsfenster legen hier Dateien ab (Benutzer duerfen schreiben)
$NetzKey       = 'HKLM:\SOFTWARE\Einrichtung\NetzGetrennt'
$PolSys        = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$script:StatusAn = $false; $script:St = $null
function Status-Schreiben {
  if (-not $script:StatusAn) { return }
  $script:St.Zeit = (Get-Date).ToString('s')
  try {
    $b = [Text.Encoding]::UTF8.GetBytes(($script:St | ConvertTo-Json -Depth 5 -Compress))
    for ($v = 0; $v -lt 5; $v++) {
      try {
        $fs = [IO.File]::Open($StatusDatei, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try { $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
        break
      } catch { Start-Sleep -Milliseconds 150 }   # liest das Fenster gerade - kurz warten
    }
  } catch {}
}
function Status-Start([string]$Modus, [string]$Standard, [switch]$Fortsetzen) {
  $alt = $null
  if ($Fortsetzen -and (Test-Path $StatusDatei)) { try { $alt = Get-Content $StatusDatei -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  $script:St = [ordered]@{ Lauf = [guid]::NewGuid().ToString(); Modus = $Modus; Phase = ''; Schritt = ''; Gesamt = 0; Unter = -1
                           Standard = $Standard; Hinweis = $null; Fertig = $false; Autostart = $false; Ergebnis = ''; Zeit = ''; Nr = 0
                           Zeilen = (New-Object System.Collections.ArrayList) }
  if ($alt) {
    $script:St.Lauf = [string]$alt.Lauf; $script:St.Nr = [int]$alt.Nr; $script:St.Gesamt = [int]$alt.Gesamt
    foreach ($z in @($alt.Zeilen)) { if ($z) { [void]$script:St.Zeilen.Add(@{ N = [int]$z.N; Z = [string]$z.Z; A = [string]$z.A; T = [string]$z.T }) } }
  }
  if (Test-Path $AnfrageOrdner) { Remove-Item (Join-Path $AnfrageOrdner '*') -Force -ErrorAction SilentlyContinue }
  $script:StatusAn = $true
  Status-Schreiben
}
function Status {
  param([string]$Phase, [int]$Gesamt, [string]$Schritt, [int]$Unter, $Hinweis)
  if (-not $script:StatusAn) { return }
  foreach ($k in 'Phase', 'Gesamt', 'Schritt', 'Unter', 'Hinweis') { if ($PSBoundParameters.ContainsKey($k)) { $script:St[$k] = $PSBoundParameters[$k] } }
  Status-Schreiben
}
function Status-Zeile([string]$Art, [string]$Text) {
  if (-not $script:StatusAn) { return }
  $script:St.Nr++
  [void]$script:St.Zeilen.Add(@{ N = $script:St.Nr; Z = (Get-Date -Format 'HH:mm:ss'); A = $Art; T = $Text })
  while ($script:St.Zeilen.Count -gt 400) { $script:St.Zeilen.RemoveAt(0) }
  Status-Schreiben
}
function Status-Ende([string]$Text, [string]$Phase = 'Einrichtung abgeschlossen', [switch]$Autostart) {
  if (-not $script:StatusAn) { return }
  $script:St.Fertig = $true; $script:St.Modus = 'Fertig'; $script:St.Autostart = [bool]$Autostart; $script:St.Ergebnis = $Text
  Status -Phase $Phase -Gesamt 100 -Unter 100 -Schritt $Text -Hinweis $null
}
# Jede Bildschirmzeile mit [OK] / [!!] / [i] / Ueberschrift landet zusaetzlich im Fortschrittsfenster
function Write-Host {
  param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor, [switch]$NoNewline, $Separator = ' ')
  $text = (@($Object) | ForEach-Object { "$_" }) -join $Separator
  $p = @{ Object = $text }
  if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $p.ForegroundColor = $ForegroundColor }
  if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $p.BackgroundColor = $BackgroundColor }
  if ($NoNewline) { $p.NoNewline = $true }
  Microsoft.PowerShell.Utility\Write-Host @p
  if (-not $script:StatusAn) { return }
  $t = $text.Trim()
  if ($t -match '^\[OK\]\s*(.*)$') { Status-Zeile 'ok' $Matches[1] }
  elseif ($t -match '^\[!!\]\s*(.*)$') { Status-Zeile 'warn' $Matches[1] }
  elseif ($t -match '^\[(i|--|Probe)\]\s*(.*)$') { Status-Zeile 'info' $Matches[2] }
  elseif ($t -match '^== (.*) ==$') { $script:St.Schritt = $Matches[1]; Status-Zeile 'titel' $Matches[1] }
}
function Anfrage-Da([string]$Name) {
  $p = Join-Path $AnfrageOrdner "$Name.txt"
  if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; return $true }
  return $false
}
function Warte-Anfrage([string]$Name, [int]$Sekunden) {
  $ende = (Get-Date).AddSeconds($Sekunden)
  while ((Get-Date) -lt $ende) { if (Anfrage-Da $Name) { return $true }; Start-Sleep -Seconds 1 }
  return $false
}
function Ziel-Vorbereiten {
  # Ordner fuer Skripte, Auswahl und Protokolle: nur Admins/SYSTEM duerfen schreiben, Benutzer nur lesen
  New-Item -Path $Ziel -ItemType Directory -Force | Out-Null
  & icacls.exe $Ziel /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
  New-Item -Path (Join-Path $Ziel 'logs') -ItemType Directory -Force | Out-Null
  New-Item -Path $AnfrageOrdner -ItemType Directory -Force | Out-Null
  & icacls.exe $AnfrageOrdner /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
  if ($Basis -ne $Ziel) {
    foreach ($d in 'setup.ps1', 'konto.ps1', 'programme.csv', 'fortschritt.ps1', 'autostart.ps1') {
      $q = Join-Path $Basis $d; if (Test-Path $q) { Copy-Item $q $Ziel -Force }
    }
  }
  # Zentrale ohne Stick: Startmenue -> "Windows-Zentrale" (fragt nach Adminrechten)
  try {
    $zc = Join-Path $Ziel 'Zentrale.cmd'
    @('@echo off', 'rem Windows-Zentrale: Einrichtung, Pruefung, Reparatur, Updates, Treiber, Programme, Pflege (mit Adminrechten)',
      'net session >nul 2>&1', 'if %errorlevel% neq 0 (',
      '  powershell.exe -NoProfile -Command "Start-Process -FilePath ''%~f0'' -Verb RunAs"', '  exit', ')',
      'powershell.exe -NoProfile -Command "Start-Process conhost.exe -WindowStyle Minimized -ArgumentList ''powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File \"%~dp0setup.ps1\" %*''"',
      'exit') | Set-Content -Path $zc -Encoding ASCII
    $lnk = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Windows-Zentrale.lnk'
    $sh = New-Object -ComObject WScript.Shell; $l = $sh.CreateShortcut($lnk)
    $l.TargetPath = $zc; $l.WorkingDirectory = $Ziel; $l.Description = 'Einrichtung, Pruefung, Reparatur, Updates und Pflege'
    $l.IconLocation = "$env:SystemRoot\System32\shell32.dll,21"; $l.Save()
  } catch {}
}
function Fortschritt-Laeuft {
  $m = $null
  try { if ([System.Threading.Mutex]::TryOpenExisting('Local\EinrichtungFortschritt', [ref]$m)) { $m.Dispose(); return $true } } catch { return $true }
  return $false
}
function Konsole-Zeigen {
  try { Konsole-Typ; [void][Einr.Konsole]::ShowWindow([Einr.Konsole]::GetConsoleWindow(), 9) } catch {}
}
function Starte-Fortschritt([switch]$NurAutostart) {
  $fp = Join-Path $Ziel 'fortschritt.ps1'
  if (-not (Test-Path $fp)) { return }
  if (-not $NurAutostart -and (Fortschritt-Laeuft)) { return }
  # Gleicher Weg wie nach dem Neustart (dort lief es): unsichtbare Konsole, sichtbares Fenster
  $arg = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "' + $fp + '"'
  if ($NurAutostart) { $arg += ' -NurAutostart' }
  try { Start-Process -FilePath 'conhost.exe' -ArgumentList $arg -ErrorAction Stop }
  catch { Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $fp + '"')) + $(if ($NurAutostart) { @('-NurAutostart') } else { @() })) }
  if ($NurAutostart) { return }
  for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 500; if (Fortschritt-Laeuft) { return } }
  Write-Host "  [!!] Fortschrittsfenster hat sich nicht geoeffnet - der Stand steht im Protokollfenster. Fehlertext: $env:TEMP\einrichtung-fortschritt-fehler.txt" -ForegroundColor Yellow
  Konsole-Zeigen
}
function Startmenue-Schliessen {
  # Windows oeffnet beim ersten Anmelden gern das Startmenue - das bleibt sonst hinter den Fenstern offen
  try {
    $sid = (Get-Process -Id $PID).SessionId
    Get-Process StartMenuExperienceHost, SearchHost -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sid } |
      Stop-Process -Force -ErrorAction SilentlyContinue
  } catch {}
}
function Bild-Vorbereiten {
  # fuer scharfe Bildschirmfotos: Prozess DPI-bewusst machen (vor dem ersten Fenster)
  if (-not ('EinrB.Bild' -as [type])) {
    Add-Type -Namespace EinrB -Name Bild -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(System.IntPtr h, int a, out RECT r, int s);
public struct RECT { public int L; public int T; public int R; public int B; }
'@
  }
  try { [void][EinrB.Bild]::SetProcessDPIAware() } catch {}
}
function Bild-Speichern($Form, [string]$Datei) {
  # Fenster genau so abfotografieren, wie es auf dem Bildschirm steht (ohne Schatten/Rand)
  try {
    $Form.TopMost = $true; $Form.Activate()
    for ($i = 0; $i -lt 8; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    $r = New-Object EinrB.Bild+RECT
    $x = $Form.Left; $y = $Form.Top; $w = $Form.Width; $h = $Form.Height
    if ([EinrB.Bild]::DwmGetWindowAttribute($Form.Handle, 9, [ref]$r, 16) -eq 0) { $x = $r.L; $y = $r.T; $w = $r.R - $r.L; $h = $r.B - $r.T }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose(); $bmp.Save($Datei, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  } catch {
    try { $bmp = New-Object System.Drawing.Bitmap($Form.Width, $Form.Height)
          $Form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $Form.Width, $Form.Height)))
          $bmp.Save($Datei, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose() } catch {}
  }
}
function Konsole-Typ {
  if (-not ('Einr.Konsole' -as [type])) {
    Add-Type -Namespace Einr -Name Konsole -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);'
  }
}
function Konsole-Minimieren {
  try {
    if (-not ('Einr.Konsole' -as [type])) {
      Add-Type -Namespace Einr -Name Konsole -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);'
    }
    [void][Einr.Konsole]::ShowWindow([Einr.Konsole]::GetConsoleWindow(), 6)
  } catch {}
}
function Frage([string]$Text) {
  Add-Type -AssemblyName System.Windows.Forms
  $o = New-Object System.Windows.Forms.Form; $o.TopMost = $true; $o.ShowInTaskbar = $false; $o.Opacity = 0; $o.StartPosition = 'CenterScreen'; $o.Show()
  try { return ([System.Windows.Forms.MessageBox]::Show($o, $Text, 'Windows-Einrichtung', 'YesNo', 'Question') -eq 'Yes') } finally { $o.Dispose() }
}
function Hinweisfenster([string]$Text, [string]$Symbol = 'Information') {
  Add-Type -AssemblyName System.Windows.Forms
  $o = New-Object System.Windows.Forms.Form; $o.TopMost = $true; $o.ShowInTaskbar = $false; $o.Opacity = 0; $o.StartPosition = 'CenterScreen'; $o.Show()
  try { [void][System.Windows.Forms.MessageBox]::Show($o, $Text, 'Windows-Einrichtung', 'OK', $Symbol) } finally { $o.Dispose() }
}
# --- Netzwerk: bis zur Programminstallation getrennt (falls noch ein Kabel steckt), dann bei Bedarf freigeben
function Netz-Trennen {
  $schon = @(); $kk = Get-Item -Path $NetzKey -ErrorAction SilentlyContinue; if ($kk) { $schon = @($kk.GetValueNames()) }
  $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disabled' -and $schon -notcontains $_.Name })
  if (-not $ad.Count) { return }
  if (-not (Test-Path $NetzKey)) { New-Item -Path $NetzKey -Force | Out-Null }
  foreach ($a in $ad) {
    New-ItemProperty -Path $NetzKey -Name $a.Name -Value '' -PropertyType String -Force | Out-Null
    Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
  }
  Write-Host "  [i]  Netzwerk getrennt bis zur Programminstallation: $(@($ad | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Gray
}
function Netz-Freigeben {
  $k = Get-Item -Path $NetzKey -ErrorAction SilentlyContinue
  if (-not $k) { return $false }
  foreach ($n in $k.GetValueNames()) { if ($n) { Enable-NetAdapter -Name $n -Confirm:$false -ErrorAction SilentlyContinue } }
  Remove-Item -Path $NetzKey -Force -ErrorAction SilentlyContinue
  Write-Host '  [i]  Netzwerk wieder freigegeben' -ForegroundColor Gray
  if ($script:Cfg -and (Hat 'S_Netz')) { Start-Sleep -Seconds 3; NetBIOS-Aus }   # neu erkannte Adapter gleich mit absichern
  if ($script:Cfg -and (Hat 'C_DNS') -and -not $script:Probe) {
    $o = $Optionen | Where-Object { $_.Id -eq 'C_DNS' }; if ($o.Code) { try { & $o.Code } catch {} } }
  return $true
}
function NetBIOS-Aus {
  Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' -ErrorAction SilentlyContinue |
    ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name 'NetbiosOptions' -Value 2 -ErrorAction SilentlyContinue }
}
# --- Hinweis auf dem Anmeldebildschirm, solange der Nachlauf laeuft
function Anmeldehinweis-Setzen([string]$Std) {
  Set-Reg $PolSys 'legalnoticecaption' 'Windows-Einrichtung läuft noch' 'String'
  Set-Reg $PolSys 'legalnoticetext' ("Bitte jetzt mit 'VERWALTUNG' anmelden. Dort laufen Updates, Pruefung und Nachbesserung sichtbar im Fortschrittsfenster bis zum Ende.`r`n`r`n" +
    "Erst wenn 'Einrichtung abgeschlossen' erscheint: abmelden und mit dem Alltagskonto '$Std' anmelden - dort werden dann deine persoenlichen Einstellungen gesetzt.`r`n`r`n" +
    "Dieser Hinweis verschwindet, sobald die Einrichtung fertig ist.") 'String'
}
function Anmeldehinweis-Entfernen {
  foreach ($n in 'legalnoticecaption', 'legalnoticetext') { Remove-ItemProperty -Path $PolSys -Name $n -ErrorAction SilentlyContinue }
}
function Lizenz-Produkt {
  @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop |
    Where-Object { $_.Name -like 'Windows*' }) | Select-Object -First 1
}
function Lizenz-Stand {
  try {
    $p = Lizenz-Produkt
    $oa3 = [string](Get-CimInstance SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey
    if ($p -and $p.LicenseStatus -eq 1) { return 'Windows ist bereits aktiviert - Feld leer lassen.' }
    if ($oa3) { return 'Noch nicht aktiviert. Im BIOS ist ein Windows-Key hinterlegt - Windows aktiviert sich damit von selbst, sobald Internet da ist. Feld leer lassen.' }
    return 'Noch nicht aktiviert, kein Key im BIOS. Hat das Geraet eine digitale Lizenz, aktiviert es sich online von selbst (Feld leer lassen) - sonst eigenen Key eintragen. Der Key wird nirgends gespeichert.'
  } catch { return 'Lizenzstatus nicht lesbar. Eigenen Key nur eintragen, wenn Windows nicht aktiviert ist.' }
}

function Opt {
  param($Id, $Tab, $Text, [bool]$Office = $true, [bool]$Gaming = $true, [bool]$Verfuegbar = $true,
        $Grund = '', $Reg = @(), [scriptblock]$Code = $null, [scriptblock]$Check = $null, $Pakete = @(), [bool]$Konto = $false)
  [pscustomobject]@{ Id = $Id; Tab = $Tab; Text = $Text; Office = $Office; Gaming = $Gaming; Verfuegbar = $Verfuegbar
                     Grund = $Grund; Reg = $Reg; Code = $Code; Check = $Check; Pakete = $Pakete; Konto = $Konto }
}

# Erststart: Windows wurde mit autounattend.xml installiert und das Konto automatisch angemeldet
$Winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
if (-not $Erststart -and ((Get-Reg $Winlogon 'AutoAdminLogon') -eq '1' -or (Test-Path "$env:SystemRoot\Panther\unattend.xml"))) { $Erststart = $true }

$P   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$UAC = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$EdgeP = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$GrundHome = 'nicht in Windows Home'
$Def = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$PolSysW = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
# ASR-Regeln (Microsoft Defender, Angriffsflaechen-Reduzierung) - Kennungen laut Microsoft-Referenz
$AsrRegeln = @(
  '56a863a9-875e-4185-98a7-b882c64b5ce5',  # anfaellige signierte Treiber missbrauchen
  '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2',  # Anmeldedaten aus LSASS stehlen
  'e6db77e5-3df2-4cf1-b95a-636979351e5b',  # Dauerhaftigkeit ueber WMI-Ereignisse
  '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c',  # Adobe Reader startet Unterprozesse
  'd4f940ab-401b-4efc-aadc-ad5f3c50688a',  # Office startet Unterprozesse
  'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550',  # ausfuehrbare Inhalte aus E-Mail/Webmail
  '5beb7efe-fd9a-4556-801d-275e5ffc04cc',  # verschleierte Skripte
  'd3e037e1-3eb8-44c8-a917-57927947596d',  # JS/VBS startet heruntergeladene Programme
  '3b576869-a4ec-4529-8536-b80a7769e899',  # Office erzeugt ausfuehrbare Dateien
  '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84',  # Office schleust Code in andere Prozesse
  '26190899-1602-49e8-8b27-eb1d0a1ce869',  # Office-Kommunikation startet Unterprozesse
  'd1e49aac-8f56-4280-b9ba-993a6d77406c',  # Prozesse ueber PsExec/WMI
  'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4',  # unsignierte Programme vom USB-Stick
  '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b',  # Win32-Aufrufe aus Office-Makros
  'c1db55ab-c21a-4637-bb3f-a12568109d35')  # erweiterter Ransomware-Schutz
$AsrStreng = @('01443614-cd74-433a-b99e-2ecdc07bfc25',   # unbekannte/seltene Programme
               'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb')   # kopierte/getarnte Systemwerkzeuge

# ---------------------------------------------------------------- Optionen: Sicherheit
$Optionen = @(
  Opt 'U_Updates'  'Updates' 'Windows-Updates nach dem ersten Neustart automatisch installieren (inkl. aller noetigen Neustarts)'
  Opt 'U_Optional' 'Updates' 'Optionale Updates mitnehmen (Treiber und Vorschau-Updates; Treiber nicht, wenn "Keine Treiber ueber Windows Update" gewaehlt ist)'
  Opt 'U_Store'    'Updates' 'Microsoft-Store-Apps aktualisieren (kostenlos, ohne Anmeldung)'
  Opt 'U_MsKonto'  'Updates' 'Anmeldung bei Microsoft Store / Xbox NUR in den Apps erlauben - das Windows-Konto bleibt lokal (Umwandlung in ein Microsoft-Konto wird gesperrt)' -Office $false -Gaming $true -Reg @(
    (RegWert 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'NoConnectedUser' 1),
    (RegWert 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'MSAOptional' 1),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Services\wlidsvc' 'Start' 3))
  Opt 'S_UAC' 'Sicherheit' 'Adminabfrage nur mit Passwort, auf dem sicheren Desktop (auch im Admin-Konto)' -Reg @(
    (RegWert $UAC 'EnableLUA' 1), (RegWert $UAC 'ConsentPromptBehaviorAdmin' 1), (RegWert $UAC 'ConsentPromptBehaviorUser' 1), (RegWert $UAC 'PromptOnSecureDesktop' 1))
  Opt 'S_Adminschutz' 'Sicherheit' 'Administratorschutz: Adminrechte nur kurzzeitig ueber ein verstecktes Konto (neuere Builds; sonst wirkungslos)' -Reg @(
    (RegWert $UAC 'TypeOfAdminApprovalMode' 2))
  Opt 'S_Sperre' 'Sicherheit' 'Kontosperre nach 5 Fehlversuchen fuer 15 Minuten' -Code {
    net accounts /lockoutthreshold:5 /lockoutduration:15 /lockoutwindow:15 | Out-Null
  } -Check {
    $na = net accounts
    Pruefe 'Kontosperre nach 5 Fehlversuchen' (($na | Where-Object { $_ -match 'schwelle|threshold' }) -replace '^.*:\s*', '') '5'
  }
  Opt 'S_Fern' 'Sicherheit' 'Remotedesktop und Remoteunterstuetzung aus' -Reg @(
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 1),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 0))
  Opt 'S_Netz' 'Sicherheit' 'LLMNR und NetBIOS aus, alle Netzwerke oeffentlich, keine automatische Hotspot-Verbindung' -Reg @(
    (RegWert 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0),
    (RegWert 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config' 'AutoConnectAllowedOEM' 0)) -Code {
    NetBIOS-Aus
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | Set-NetConnectionProfile -NetworkCategory Public -ErrorAction SilentlyContinue
  } -Check {
    $nb = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' | Where-Object { (Get-ItemProperty $_.PSPath).NetbiosOptions -ne 2 })
    Pruefe 'NetBIOS auf allen Adaptern aus' $nb.Count 0
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { Pruefe "Netzwerk $($_.InterfaceAlias) oeffentlich" $_.NetworkCategory 'Public' }
  }
  Opt 'S_Firewall' 'Sicherheit' 'Firewall in allen Profilen an' -Code { Set-NetFirewallProfile -All -Enabled True } -Check {
    Get-NetFirewallProfile | ForEach-Object { Pruefe "Firewall $($_.Name) an" $_.Enabled 'True' }
  }
  Opt 'S_Alt' 'Sicherheit' 'Veraltete Funktionen aus: SMB1, PowerShell 2.0, Telnet' -Code {
    foreach ($ft in 'SMB1Protocol', 'MicrosoftWindowsPowerShellV2Root', 'TelnetClient') {
      $fe = Get-WindowsOptionalFeature -Online -FeatureName $ft -ErrorAction SilentlyContinue
      if ($fe -and [string]$fe.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName $ft -NoRestart -ErrorAction SilentlyContinue | Out-Null } }
  } -Check {
    $smb = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
    if ($smb) { Pruefe 'SMB1 aus' $smb.State 'Disabled' } else { Info 'SMB1 nicht vorhanden (gut)' }
  }
  Opt 'S_Defender' 'Sicherheit' 'Defender: unerwuenschte Apps blockieren, Netzwerkschutz an' -Code {
    Set-MpPreference -PUAProtection Enabled
    Set-MpPreference -EnableNetworkProtection Enabled
  } -Check {
    $mp = Get-MpPreference -ErrorAction SilentlyContinue
    Pruefe 'Unerwuenschte Apps blockieren' $mp.PUAProtection 1
    Pruefe 'Netzwerkschutz an' $mp.EnableNetworkProtection 1
    $ms = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($ms) { Pruefe 'Echtzeitschutz an' $ms.RealTimeProtectionEnabled 'True'; Pruefe 'Manipulationsschutz an' $ms.IsTamperProtected 'True' }
  }
  Opt 'S_BitLocker' 'Sicherheit' 'BitLocker fuer Laufwerk C:, Wiederherstellungsschluessel als Datei auf den Stick (Office-Profil: aus - bei Bedarf hier anhaken)' -Office $false -Gaming $false `
    -Verfuegbar ((-not $IstHome) -and $Tpm) -Grund $(if ($IstHome) { $GrundHome } else { 'kein TPM gefunden' }) -Code {
    $lw = $env:SystemDrive
    $bv = Get-BitLockerVolume -MountPoint $lw
    if ($bv.VolumeStatus -eq 'FullyDecrypted') {
      Enable-BitLocker -MountPoint $lw -EncryptionMethod XtsAes128 -UsedSpaceOnly -TpmProtector -SkipHardwareTest -WarningAction SilentlyContinue | Out-Null
    }
    $bv = Get-BitLockerVolume -MountPoint $lw
    if (-not ($bv.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })) {
      Add-BitLockerKeyProtector -MountPoint $lw -RecoveryPasswordProtector -WarningAction SilentlyContinue | Out-Null
    }
    $bv = Get-BitLockerVolume -MountPoint $lw
    if (-not ($bv.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'Tpm' })) {
      Add-BitLockerKeyProtector -MountPoint $lw -TpmProtector -WarningAction SilentlyContinue | Out-Null
    }
    $bv = Get-BitLockerVolume -MountPoint $lw
    if ($bv.ProtectionStatus -eq 'Off') { try { Resume-BitLocker -MountPoint $lw | Out-Null } catch {} }
    $kp = (Get-BitLockerVolume -MountPoint $lw).KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
    $datei = Join-Path $Basis "BitLocker-Schluessel-$env:COMPUTERNAME.txt"
    @("Computer: $env:COMPUTERNAME", "Datum: $(Get-Date -Format 'dd.MM.yyyy HH:mm')", "Schluessel-ID: $($kp.KeyProtectorId)",
      "Wiederherstellungsschluessel: $($kp.RecoveryPassword)") | Set-Content -Path $datei -Encoding UTF8
    Write-Host "       Schluessel gespeichert: $datei - zusaetzlich ausdrucken oder an zweitem Ort sichern!" -ForegroundColor Cyan
    if ($Basis -like "$lw*") { Write-Host '       ACHTUNG: Die Datei liegt auf C: selbst. Sofort auf einen Stick kopieren!' -ForegroundColor Red }
  } -Check {
    $bv = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
    if ($bv) { Info "BitLocker C:: $($bv.VolumeStatus), Schutz $($bv.ProtectionStatus), $($bv.EncryptionPercentage) %" }
  }
  Opt 'S_Treiber' 'Sicherheit' 'Keine Treiber ueber Windows Update (Grafiktreiber selbst pflegen)' -Office $false -Gaming $true `
    -Verfuegbar (-not $IstHome) -Grund $GrundHome -Reg @((RegWert "$P\WindowsUpdate" 'ExcludeWUDriversInQualityUpdate' 1))
  Opt 'S_Version' 'Sicherheit' "Funktionsupdates auf Version $Version festhalten (Sicherheitsupdates kommen weiter)" `
    -Verfuegbar ((-not $IstHome) -and (-not $IstLTSC) -and [bool]$Version) -Grund $(if ($IstLTSC) { 'LTSC braucht das nicht' } else { $GrundHome }) -Reg @(
    (RegWert "$P\WindowsUpdate" 'TargetReleaseVersion' 1), (RegWert "$P\WindowsUpdate" 'ProductVersion' 'Windows 11' 'String'),
    (RegWert "$P\WindowsUpdate" 'TargetReleaseVersionInfo' $Version 'String'))
  Opt 'S_Zeit' 'Sicherheit' 'Zeitzone Berlin fest einstellen (nicht automatisch per Standort)' -Reg @(
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate' 'Start' 4)) -Code { Set-TimeZone -Id 'W. Europe Standard Time' } -Check {
    Pruefe 'Zeitzone Berlin' (Get-TimeZone).Id 'W. Europe Standard Time'
  }

# ---------------------------------------------------------------- Optionen: Cybersicherheit
  Opt 'C_ASR' 'Cyber' 'Angriffsflaechen-Reduzierung (Defender-ASR, 15 Regeln): blockiert Makro-, Skript-, USB-, LSASS- und Ransomware-Tricks' -Reg (@(
    (RegWert "$Def\Windows Defender Exploit Guard\ASR" 'ExploitGuard_ASR_Rules' 1)) + @($AsrRegeln | ForEach-Object { RegWert "$Def\Windows Defender Exploit Guard\ASR\Rules" $_ '1' 'String' }))
  Opt 'C_Cloud' 'Cyber' 'Defender: Cloud-Schutz hoch, "Blockieren beim ersten Auftreten", sichere Proben automatisch senden' -Reg @(
    (RegWert "$Def\Spynet" 'SpynetReporting' 2), (RegWert "$Def\Spynet" 'SubmitSamplesConsent' 1),
    (RegWert "$Def\MpEngine" 'MpCloudBlockLevel' 2), (RegWert "$Def\MpEngine" 'MpBafsExtendedTimeout' 50))
  Opt 'C_Scan' 'Cyber' 'Defender: Archive, USB-Laufwerke und E-Mails mitpruefen, Virensignaturen alle 4 Stunden' -Reg @(
    (RegWert "$Def\Scan" 'DisableArchiveScanning' 0), (RegWert "$Def\Scan" 'DisableRemovableDriveScanning' 0),
    (RegWert "$Def\Scan" 'DisableEmailScanning' 0), (RegWert "$Def\Scan" 'CheckForSignaturesBeforeRunningScan' 1),
    (RegWert "$Def\Signature Updates" 'SignatureUpdateInterval' 4))
  Opt 'C_Kern' 'Cyber' 'Kernisolierung: Speicherintegritaet (HVCI), Sperrliste fuer anfaellige Treiber, LSA-Schutz (wirkt nach Neustart)' -Reg @(
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 1),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'RequirePlatformSecurityFeatures' 1),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 1),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable' 1),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL' 1))
  Opt 'C_Anmeldung' 'Cyber' 'Anmeldedaten schuetzen: nur NTLMv2, keine anonymen Abfragen, keine Klartext-Passwoerter im Speicher, keine Auto-Anmeldung nach Updates' -Reg @(
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LmCompatibilityLevel' 5), (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'NoLMHash' 1),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RestrictAnonymous' 1), (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RestrictAnonymousSAM' 1),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'EveryoneIncludesAnonymous' 0),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential' 0),
    (RegWert $PolSysW 'DisableAutomaticRestartSignOn' 1))
  Opt 'C_SMB' 'Cyber' 'Netzlaufwerke: Signierung Pflicht, kein unsicherer Gastzugriff (sehr alte NAS-Geraete gehen dann evtl. nicht)' -Reg @(
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' 'RequireSecuritySignature' 1),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' 'EnableSecuritySignature' 1),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'RequireSecuritySignature' 1),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'EnableSecuritySignature' 1),
    (RegWert "$P\LanmanWorkstation" 'AllowInsecureGuestAuth' 0))
  Opt 'C_AutoRun' 'Cyber' 'Autostart von USB-Sticks/CDs komplett aus (AutoRun/AutoPlay)' -Reg @(
    (RegWert 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255),
    (RegWert 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoAutorun' 1),
    (RegWert "$P\Explorer" 'NoAutoplayfornonVolume' 1))
  Opt 'C_SmartScreen' 'Cyber' 'SmartScreen fuer Programme und Downloads fest an (warnt vor unbekannten Dateien)' -Reg @(
    (RegWert "$P\System" 'EnableSmartScreen' 1), (RegWert "$P\System" 'ShellSmartScreenLevel' 'Warn' 'String'))
  Opt 'C_Sperre' 'Cyber' 'Bildschirm sperrt nach 10 Minuten ohne Eingabe, Passwort nach dem Aufwachen' -Reg @(
    (RegWert $PolSysW 'InactivityTimeoutSecs' 600),
    (RegWert 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\0e796bdb-100d-47d6-a2d5-f7d2daa51f51' 'ACSettingIndex' 1),
    (RegWert 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\0e796bdb-100d-47d6-a2d5-f7d2daa51f51' 'DCSettingIndex' 1))
  Opt 'C_Dienste' 'Cyber' 'Remote-Registrierung aus (Fernzugriff auf die Registry)' -Reg @(
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Services\RemoteRegistry' 'Start' 4))
  Opt 'C_Passwort' 'Cyber' 'Kennwort-Mindestlaenge 8 Zeichen fuer alle lokalen Konten' -Code {
    net accounts /minpwlen:8 | Out-Null
  } -Check {
    $na = net accounts
    Pruefe 'Kennwort-Mindestlaenge 8' (($na | Where-Object { $_ -match 'Kennwortl|password length' } | Select-Object -First 1) -replace '^.*:\s*', '') '8'
  }
  Opt 'C_Protokoll' 'Cyber' 'Sicherheitsprotokoll: Anmeldungen, Kontosperren, Programmstarts (mit Befehlszeile), PowerShell und blockierte Verbindungen aufzeichnen' -Reg @(
    (RegWert "$PolSysW\Audit" 'ProcessCreationIncludeCmdLine_Enabled' 1),
    (RegWert "$P\PowerShell\ScriptBlockLogging" 'EnableScriptBlockLogging' 1)) -Code {
    foreach ($g in '0CCE9215', '0CCE9217', '0CCE921B', '0CCE922B', '0CCE9235', '0CCE9237') {
      & auditpol.exe /set /subcategory:"{$g-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable | Out-Null }
    & wevtutil.exe sl Security /ms:201326592 | Out-Null
    & wevtutil.exe sl 'Microsoft-Windows-PowerShell/Operational' /ms:67108864 | Out-Null
    Set-NetFirewallProfile -All -LogBlocked True -LogMaxSizeKilobytes 16384
  } -Check {
    Get-NetFirewallProfile | ForEach-Object { Pruefe "Firewall $($_.Name): blockierte Verbindungen protokolliert" $_.LogBlocked 'True' }
  }
  Opt 'C_Browser' 'Cyber' 'Browser absichern: Firefox mit uBlock Origin, HTTPS-only und Tracking-Schutz; Chrome mit uBlock Origin Lite; Drittanbieter-Cookies aus' -Reg @(
    (RegWert 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' 'DisableTelemetry' 1),
    (RegWert 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' 'DisableFirefoxStudies' 1),
    (RegWert 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' 'HttpsOnlyMode' 'enabled' 'String'),
    (RegWert 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' 'ExtensionSettings' '{"uBlock0@raymondhill.net":{"installation_mode":"force_installed","install_url":"https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"}}' 'String'),
    (RegWert 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\EnableTrackingProtection' 'Value' 1),
    (RegWert 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\EnableTrackingProtection' 'Cryptomining' 1),
    (RegWert 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\EnableTrackingProtection' 'Fingerprinting' 1),
    (RegWert 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist' '1' 'ddkjiahejlhfcafbddmgiahcphecmpfh;https://clients2.google.com/service/update2/crx' 'String'),
    (RegWert 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BlockThirdPartyCookies' 1),
    (RegWert 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'BlockThirdPartyCookies' 1))
  Opt 'C_ASRStreng' 'Cyber' '[Streng] ASR zusaetzlich: unbekannte/seltene Programme und getarnte Systemwerkzeuge blockieren (kann neue Installationen verhindern)' -Office $false -Gaming $false -Reg (
    @($AsrStreng | ForEach-Object { RegWert "$Def\Windows Defender Exploit Guard\ASR\Rules" $_ '1' 'String' }))
  Opt 'C_Ransom' 'Cyber' '[Streng] Ransomware-Schutz (ueberwachter Ordnerzugriff): nur vertrauenswuerdige Programme duerfen in Dokumente/Bilder schreiben' -Office $false -Gaming $false -Reg @(
    (RegWert "$Def\Windows Defender Exploit Guard\Controlled Folder Access" 'EnableControlledFolderAccess' 1))
  Opt 'C_DNS' 'Cyber' '[Streng] DNS ueber Quad9 (blockiert bekannte Schadseiten) mit DNS-Verschluesselung - manche Hotel-/Gast-WLANs gehen damit nicht' -Office $false -Gaming $false -Reg @(
    (RegWert 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'DoHPolicy' 2)) -Code {
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
      Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @('9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9') -ErrorAction SilentlyContinue }
  } -Check {
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
      $dns = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
      Pruefe "DNS $($a.Name): Quad9" ($dns -contains '9.9.9.9') 'True' }
  }
  Opt 'C_USB' 'Cyber' '[Streng] Programme direkt von USB-Sticks starten verboten (die Zentrale laeuft von C:, Start.cmd vom Stick dann evtl. nicht)' -Office $false -Gaming $false -Reg @(
    (RegWert "$P\RemovableStorageDevices\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}" 'Deny_Execute' 1))
  Opt 'C_WSH' 'Cyber' '[Streng] Windows Script Host aus (.vbs/.js-Schadskripte laufen nicht mehr; sehr alte Installer evtl. auch nicht)' -Office $false -Gaming $false -Reg @(
    (RegWert 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings' 'Enabled' 0))
  Opt 'C_Freigabe' 'Cyber' '[Streng] Freigabe-Dienste aus: Datei-/Druckerfreigabe dieses PCs, UPnP-Geraetesuche (LocalSend geht weiter)' -Office $false -Gaming $false -Reg @(
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer' 'Start' 4),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Services\SSDPSRV' 'Start' 4),
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Services\upnphost' 'Start' 4))
  Opt 'C_Sandbox' 'Cyber' '[Streng] Windows-Sandbox einschalten: unbekannte Programme gefahrlos in einer Wegwerf-Umgebung testen (braucht Virtualisierung im BIOS)' -Office $false -Gaming $false `
    -Verfuegbar (-not $IstHome) -Grund $GrundHome -Code {
    Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -All -NoRestart -ErrorAction Stop | Out-Null
  } -Check {
    $sb = Get-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -ErrorAction SilentlyContinue
    if ($sb) { Pruefe 'Windows-Sandbox eingeschaltet' ($sb.State -match 'Enable') 'True' }
  }

# ---------------------------------------------------------------- Optionen: Datenschutz
  Opt 'D_Telemetrie' 'Datenschutz' "Diagnosedaten auf Minimum (Stufe $TeleWert), Telemetrie-Dienste und -Aufgaben aus" -Reg @(
    (RegWert "$P\DataCollection" 'AllowTelemetry' $TeleWert), (RegWert "$P\DataCollection" 'DoNotShowFeedbackNotifications' 1)) -Code {
    foreach ($d in 'DiagTrack', 'dmwappushservice') {
      Stop-Service $d -Force -ErrorAction SilentlyContinue
      Set-Service $d -StartupType Disabled -ErrorAction SilentlyContinue }
    foreach ($tp in '\Microsoft\Windows\Application Experience\', '\Microsoft\Windows\Customer Experience Improvement Program\') {
      Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
  } -Check {
    foreach ($d in 'DiagTrack', 'dmwappushservice') { $s = Get-Service $d -ErrorAction SilentlyContinue; if ($s) { Pruefe "Dienst $d deaktiviert" $s.StartType 'Disabled' } }
  }
  Opt 'D_Fehler' 'Datenschutz' 'Fehlerberichte an Microsoft aus' -Reg @((RegWert "$P\Windows Error Reporting" 'Disabled' 1))
  Opt 'D_KI' 'Datenschutz' 'Copilot, Recall und KI-Datenanalyse aus' -Reg @(
    (RegWert "$P\WindowsCopilot" 'TurnOffWindowsCopilot' 1), (RegWert "$P\WindowsAI" 'AllowRecallEnablement' 0), (RegWert "$P\WindowsAI" 'DisableAIDataAnalysis' 1))
  Opt 'D_Suche' 'Datenschutz' 'Keine Websuche und kein Bing im Startmenue, keine Cloudsuche' -Reg @(
    (RegWert "$P\Explorer" 'DisableSearchBoxSuggestions' 1), (RegWert "$P\Windows Search" 'AllowCloudSearch' 0),
    (RegWert "$P\Windows Search" 'ConnectedSearchUseWeb' 0), (RegWert "$P\Windows Search" 'DisableWebSearch' 1))
  Opt 'D_Werbung' 'Datenschutz' 'Werbe-ID, Werbe-Apps und Aktivitaetsverlauf aus' -Reg @(
    (RegWert "$P\AdvertisingInfo" 'DisabledByGroupPolicy' 1), (RegWert "$P\CloudContent" 'DisableWindowsConsumerFeatures' 1),
    (RegWert "$P\System" 'PublishUserActivities' 0), (RegWert "$P\System" 'UploadUserActivities' 0), (RegWert "$P\System" 'EnableActivityFeed' 0))
  Opt 'D_Widgets' 'Datenschutz' 'Widgets (Nachrichten-Feed) aus' -Reg @((RegWert 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0))
  Opt 'D_OneDrive' 'Datenschutz' 'OneDrive sperren und entfernen (auch fuer kuenftige Konten)' -Reg @((RegWert "$P\OneDrive" 'DisableFileSyncNGSC' 1)) -Code {
    if (Test-Path "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe") {
      foreach ($od in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
        if (Test-Path $od) { Start-Process $od -ArgumentList '/uninstall /allusers' -Wait; break } } }
  }
  Opt 'D_Standort' 'Datenschutz' 'Standort komplett aus (auch keine Standort-Rueckfragen von Apps), "Mein Geraet suchen" aus' -Reg @(
    (RegWert 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'),
    (RegWert 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1),
    (RegWert 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableWindowsLocationProvider' 1),
    (RegWert "$P\AppPrivacy" 'LetAppsAccessLocation' 2),
    (RegWert 'HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice' 'AllowFindMyDevice' 0))
  Opt 'D_Hintergrund' 'Datenschutz' 'Store-Apps duerfen nicht im Hintergrund laufen (spart Akku und CPU)' -Office $true -Gaming $false -Reg @(
    (RegWert "$P\AppPrivacy" 'LetAppsRunInBackground' 2))
  Opt 'D_Edge' 'Datenschutz' 'Edge zaehmen: kein Vorstart, keine Seitenleiste, keine Datenweitergabe' -Reg @(
    (RegWert $EdgeP 'StartupBoostEnabled' 0), (RegWert $EdgeP 'BackgroundModeEnabled' 0), (RegWert $EdgeP 'HubsSidebarEnabled' 0),
    (RegWert $EdgeP 'PersonalizationReportingEnabled' 0), (RegWert $EdgeP 'ShowRecommendationsEnabled' 0), (RegWert $EdgeP 'DiagnosticData' 0),
    (RegWert $EdgeP 'EdgeShoppingAssistantEnabled' 0), (RegWert $EdgeP 'HideFirstRunExperience' 1), (RegWert $EdgeP 'UserFeedbackAllowed' 0))
  Opt 'D_EdgeWeg' 'Datenschutz' 'Edge deinstallieren (nur im EU-Raum moeglich, WebView2 bleibt; vorher anderen Browser waehlen)' -Office $false -Gaming $false -Code {
    $msedge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (-not (Test-Path $msedge)) { return }
    # Microsoft erlaubt die Deinstallation nur, wenn die Geraeteregion im EU-Raum liegt - deutsche Installation: Region Deutschland (94)
    if ((Get-WinSystemLocale).Name -like '*-DE' -or (Get-Culture).Name -like '*-DE') {
      Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion' 'DeviceRegion' 94 }
    $es = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\*\Installer\setup.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $es) { throw 'Edge-Setup nicht gefunden' }
    Start-Process $es.FullName -ArgumentList '--uninstall --system-level --verbose-logging --force-uninstall' -Wait
    Start-Sleep -Seconds 5
    if (Test-Path $msedge) {
      # 2. Weg (bekannte Umgehung, siehe github.com/ave9858): Sperr-Merker weg, AllowUninstall, Platzhalter fuer die alte Edge-App,
      # Deinstallation ueber eine als dllhost.exe benannte cmd-Kopie
      $hk = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32).OpenSubKey('SOFTWARE\Microsoft', $true)
      $cs = $hk.OpenSubKey('EdgeUpdate\ClientState\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}', $true)
      if ($cs -and $null -ne $cs.GetValue('experiment_control_labels')) { $cs.DeleteValue('experiment_control_labels') }
      $hk.CreateSubKey('EdgeUpdateDev').SetValue('AllowUninstall', '')
      $un = $hk.OpenSubKey('Windows\CurrentVersion\Uninstall\Microsoft Edge')
      $us = if ($un) { [string]$un.GetValue('UninstallString') } else { '' }
      if (-not $us) { $us = '"' + $es.FullName + '" --uninstall --system-level --verbose-logging' }
      $us += ' --force-uninstall'
      $tmp = Join-Path $env:SystemRoot 'SystemTemp'
      if (-not (Test-Path $tmp)) { $tmp = Join-Path $env:SystemRoot ('Temp\' + [guid]::NewGuid()); New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
      $fake = Join-Path $tmp 'dllhost.exe'
      Copy-Item "$env:SystemRoot\System32\cmd.exe" $fake -Force
      $uwp = "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
      $ordnerNeu = -not (Test-Path $uwp); $dateiNeu = -not (Test-Path "$uwp\MicrosoftEdge.exe")
      try {
        try {
          if ($ordnerNeu) { New-Item -ItemType Directory -Path $uwp -Force -ErrorAction Stop | Out-Null }
          if ($dateiNeu) { New-Item -ItemType File -Path "$uwp\MicrosoftEdge.exe" -Force -ErrorAction Stop | Out-Null }
        } catch { Info "Platzhalter in SystemApps nicht moeglich ($($_.Exception.Message)) - versuche es ohne" }
        Start-Process $fake -ArgumentList "/c $us" -WindowStyle Hidden -Wait
      } finally {
        if ($dateiNeu) { Remove-Item "$uwp\MicrosoftEdge.exe" -Force -ErrorAction SilentlyContinue }
        if ($ordnerNeu) { Remove-Item $uwp -Force -Recurse -ErrorAction SilentlyContinue }
        Remove-Item $fake -Force -ErrorAction SilentlyContinue
      }
      Start-Sleep -Seconds 5
    }
    if (Test-Path $msedge) {
      $ver = (Get-Item $msedge).VersionInfo.ProductVersion
      Set-Reg 'HKLM:\SOFTWARE\Einrichtung' 'EdgeAbgelehnt' ([string]$ver) 'String'
      throw "Edge ist noch da - Microsoft hat beide Wege abgelehnt (Version $ver). Edge bleibt, ist aber nicht Standard. Neuer Versuch automatisch nach dem naechsten Edge-Update."
    }
    Remove-ItemProperty 'HKLM:\SOFTWARE\Einrichtung' -Name 'EdgeAbgelehnt' -ErrorAction SilentlyContinue
  } -Check {
    $msedge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    $abg = Get-Reg 'HKLM:\SOFTWARE\Einrichtung' 'EdgeAbgelehnt'
    if ((Test-Path $msedge) -and $abg -ne 'fehlt' -and $abg -eq [string](Get-Item $msedge).VersionInfo.ProductVersion) {
      Info "Edge: Microsoft laesst das Entfernen auf diesem PC nicht zu (Version $abg, beide Wege versucht) - Edge bleibt, ist aber nicht Standard"
    } else { Pruefe 'Edge entfernt' (-not (Test-Path $msedge)) 'True' }
  }

# ---------------------------------------------------------------- Optionen: Microsoft-Apps entfernen
  Opt 'A_Bing'      'Apps' 'Bing News, Wetter, Bing-Suche'                -Pakete @('Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch')
  Opt 'A_Clipchamp' 'Apps' 'Clipchamp (Videoeditor)'                      -Pakete @('Clipchamp.Clipchamp')
  Opt 'A_Solitaire' 'Apps' 'Solitaire Collection'                         -Pakete @('Microsoft.MicrosoftSolitaireCollection')
  Opt 'A_Todo'      'Apps' 'Microsoft To Do'                              -Pakete @('Microsoft.Todos')
  Opt 'A_Automate'  'Apps' 'Power Automate'                               -Pakete @('Microsoft.PowerAutomateDesktop')
  Opt 'A_Family'    'Apps' 'Microsoft Family'                             -Pakete @('MicrosoftCorporationII.MicrosoftFamily')
  Opt 'A_Remote'    'Apps' 'Remotehilfe (Quick Assist) - Einfallstor fuer Telefonbetrug' -Pakete @('MicrosoftCorporationII.QuickAssist')
  Opt 'A_Hilfe'     'Apps' 'Hilfe anfordern, Tipps'                       -Pakete @('Microsoft.GetHelp', 'Microsoft.Getstarted')
  Opt 'A_Feedback'  'Apps' 'Feedback-Hub'                                 -Pakete @('Microsoft.WindowsFeedbackHub')
  Opt 'A_Outlook'   'Apps' 'Outlook (neu) und alte Mail/Kalender-App'     -Pakete @('Microsoft.OutlookForWindows', 'microsoft.windowscommunicationsapps')
  Opt 'A_Teams'     'Apps' 'Microsoft Teams'                              -Pakete @('MSTeams', 'MicrosoftTeams')
  Opt 'A_Office'    'Apps' 'Microsoft 365 / Office-Hub (Werbe-App)'       -Pakete @('Microsoft.MicrosoftOfficeHub')
  Opt 'A_Copilot'   'Apps' 'Copilot-App'                                  -Pakete @('Microsoft.Copilot')
  Opt 'A_Phone'     'Apps' 'Smartphone-Link'                              -Pakete @('Microsoft.YourPhone')
  Opt 'A_Notizen'   'Apps' 'Kurznotizen'                                  -Pakete @('Microsoft.MicrosoftStickyNotes')
  Opt 'A_Uhr'       'Apps' 'Uhr / Wecker'                                 -Pakete @('Microsoft.WindowsAlarms')
  Opt 'A_Karten'    'Apps' 'Karten, Personen'                             -Pakete @('Microsoft.WindowsMaps', 'Microsoft.People')
  Opt 'A_DevHome'   'Apps' 'Dev Home'                                     -Pakete @('Microsoft.Windows.DevHome')
  Opt 'A_Rekorder'  'Apps' 'Sprachrekorder'                               -Pakete @('Microsoft.WindowsSoundRecorder')
  Opt 'A_Xbox'      'Apps' 'Xbox-App, Game Bar, Xbox-Dienste (fuer Gaming behalten!)' -Office $true -Gaming $false `
    -Pakete @('Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.Xbox.TCUI', 'Microsoft.GamingServices')
  Opt 'A_Medien'    'Apps' 'Media Player und Filme & TV (Ersatz: VLC)'    -Office $false -Gaming $false -Pakete @('Microsoft.ZuneMusic', 'Microsoft.ZuneVideo')
  Opt 'A_Fotos'     'Apps' 'Fotos (Ersatz: IrfanView)'                    -Office $false -Gaming $false -Pakete @('Microsoft.Windows.Photos')
  Opt 'A_Kamera'    'Apps' 'Kamera (fuer Videocalls lieber behalten)'     -Office $false -Gaming $false -Pakete @('Microsoft.WindowsCamera')
  Opt 'A_Snipping'  'Apps' 'Snipping Tool (Ersatz: ShareX/Flameshot)'     -Office $false -Gaming $false -Pakete @('Microsoft.ScreenSketch')
  Opt 'A_Paint'     'Apps' 'Paint'                                        -Office $false -Gaming $false -Pakete @('Microsoft.Paint')
  Opt 'A_Editor'    'Apps' 'Editor/Notepad (Ersatz: Notepad++)'           -Office $false -Gaming $false -Pakete @('Microsoft.WindowsNotepad')
  Opt 'A_Rechner'   'Apps' 'Rechner'                                      -Office $false -Gaming $false -Pakete @('Microsoft.WindowsCalculator')
  Opt 'A_Store'     'Apps' 'Microsoft Store (ACHTUNG: kaum zurueckzuholen; winget geht weiter)' -Office $false -Gaming $false -Pakete @('Microsoft.WindowsStore')

# ---------------------------------------------------------------- Optionen: Komfort (pro Konto, setzt konto.ps1)
  Opt 'K_Werbung'    'Komfort' 'Keine Werbung, Tipps und stillen App-Installationen in Start und Explorer' -Konto $true
  Opt 'K_Daten'      'Komfort' 'Datenschutz im Konto: Werbe-ID, Sprachliste, Feedback, Freihand/Text, Suchverlauf aus' -Konto $true
  Opt 'K_Dunkel'     'Komfort' 'Dunkelmodus fuer Windows und Apps' -Konto $true
  Opt 'K_Kontext'    'Komfort' 'Klassisches Rechtsklick-Kontextmenue' -Konto $true
  Opt 'K_Task'       'Komfort' '"Task beenden" per Rechtsklick in der Taskleiste' -Konto $true
  Opt 'K_Endungen'   'Komfort' 'Dateiendungen anzeigen (Schutz vor "Rechnung.pdf.exe")' -Konto $true
  Opt 'K_Taskleiste' 'Komfort' 'Taskleiste: Suche nur als Symbol, Aufgabenansicht aus' -Konto $true
  Opt 'K_Einrasten'  'Komfort' 'Einrastfunktion (5x Umschalt) aus' -Konto $true
  Opt 'K_Maus'       'Komfort' 'Mausbeschleunigung aus (fuer Spiele; am Touchpad Geschmackssache)' -Office $false -Gaming $true -Konto $true
  Opt 'K_Animation'  'Komfort' 'Animationen und Transparenz aus (schneller auf schwacher Hardware)' -Office $true -Gaming $false -Konto $true
  Opt 'K_Aufnahme'   'Komfort' 'Keine Hintergrundaufnahme der Game Bar' -Konto $true
  Opt 'K_GameBarAus' 'Komfort' 'Game-Bar-Aufnahmen komplett aus' -Office $true -Gaming $false -Konto $true
  Opt 'K_Spielmodus' 'Komfort' 'Spielmodus an' -Office $false -Gaming $true -Konto $true
  Opt 'E_Ultimate' 'Komfort' 'Energieplan "Ultimative Leistung" zur Auswahl freischalten (aktiv bleibt "Ausbalanciert")' -Code {
    $ziel = 'e9a42b02-d5df-448d-aa00-03f14749eb62'   # feste Kennung, damit kein Duplikat bei erneutem Lauf entsteht
    if (-not ((powercfg /list) -match $ziel)) { powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 $ziel | Out-Null }
    powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e
  } -Check {
    Pruefe 'Plan "Ultimative Leistung" vorhanden' ([bool]((powercfg /list) -match 'e9a42b02-d5df-448d-aa00-03f14749eb62')) 'True'
    Pruefe 'Aktiver Plan: Ausbalanciert' ([bool]((powercfg /getactivescheme) -match '381b4222-f694-41f0-9685-ff5bb260df2e')) 'True'
  }
  Opt 'E_Leistung' 'Komfort' 'Energiemodus: am Netzteil "Beste Leistung", im Akkubetrieb ausbalanciert und sparsam' -Code {
    $plan = '381b4222-f694-41f0-9685-ff5bb260df2e'   # Ausbalanciert
    powercfg /setacvalueindex $plan SUB_PROCESSOR PERFBOOSTMODE 2      # Netzteil: Turbo aggressiv
    powercfg /setdcvalueindex $plan SUB_PROCESSOR PERFBOOSTMODE 3      # Akku: Turbo effizient
    powercfg /setacvalueindex $plan SUB_PROCESSOR PROCTHROTTLEMAX 100
    powercfg /setdcvalueindex $plan SUB_PROCESSOR PROCTHROTTLEMAX 100
    powercfg /setacvalueindex $plan SUB_PCIEXPRESS ASPM 0              # Netzteil: PCIe ohne Stromsparen
    powercfg /setdcvalueindex $plan SUB_PCIEXPRESS ASPM 2              # Akku: maximal sparen
    powercfg /setactive $plan
    # Der Energiemodus-Schieberegler (Netzteil: Beste Leistung) wird ganz am Ende gesetzt,
    # weil jedes spaetere "powercfg /setactive" ihn sonst wieder zuruecksetzt.
  } -Check {
    $q = powercfg /qh SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE
    $ac = [string]($q | Select-String 'Wechselstrom|AC Power Setting' | Select-Object -First 1)
    $dc = [string]($q | Select-String 'Gleichstrom|DC Power Setting' | Select-Object -First 1)
    Pruefe 'Netzteil: Turbo aggressiv' ($ac -match '0x0+2$') 'True'
    Pruefe 'Akku: Turbo effizient' ($dc -match '0x0+3$') 'True'
    $ov = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' 'ActiveOverlayAcPowerScheme'
    if ($ov -eq 'fehlt') { Info 'Energiemodus am Netzteil: in Einstellungen > System > Energie pruefen (Wert hier nicht lesbar)' }
    else { Pruefe 'Energiemodus Netzteil: Beste Leistung' $ov 'ded574b5-45a0-4f42-8737-46345c09c238' }
  }
  Opt 'E_Standby' 'Komfort' 'Am Netzteil nie Energiesparmodus/Ruhezustand (im Akkubetrieb bleibt alles normal)' -Code {
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
  } -Check {
    $q = powercfg /qh SCHEME_CURRENT SUB_SLEEP STANDBYIDLE
    $ac = [string]($q | Select-String 'Wechselstrom|AC Power Setting' | Select-Object -First 1)
    Pruefe 'Netzbetrieb: Energiesparmodus nie' ($ac -match '0x0+$') 'True'
  }
  Opt 'E_WLAN' 'Komfort' 'WLAN am Netzteil ohne Energiesparen, Adapter darf nicht abgeschaltet werden (gegen Haenger nach Sperre/Ruhezustand)' -Office $Laptop -Gaming $Laptop -Code {
    foreach ($plan in '381b4222-f694-41f0-9685-ff5bb260df2e', 'e9a42b02-d5df-448d-aa00-03f14749eb62') {
      if (-not ((powercfg /list) -match $plan)) { continue }
      powercfg /setacvalueindex $plan 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0   # Netzteil: maximale Leistung
    }
    powercfg /setactive SCHEME_CURRENT
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802\.11' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN' })) {
      foreach ($dev in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue | Where-Object { $_.InstanceName -like "$($a.PnPDeviceID)*" })) {
        try { $dev.Enable = $false; Set-CimInstance -InputObject $dev -ErrorAction Stop } catch {} }
    }
  } -Check {
    $q = powercfg /qh SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a
    $ac = [string]($q | Select-String 'Wechselstrom|AC Power Setting' | Select-Object -First 1)
    Pruefe 'WLAN am Netzteil: maximale Leistung' ($ac -match '0x0+$') 'True'
  }
  Opt 'E_USB' 'Komfort' 'USB am Netzteil immer volle Leistung (kein selektives Energiesparen, Geraete nicht abschalten)' -Code {
    powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
    powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 d4e98f31-5ffe-4ce1-be31-1b38b384c009 0
    powercfg /setactive SCHEME_CURRENT
    foreach ($dev in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue | Where-Object { $_.InstanceName -like 'USB*' })) {
      try { $dev.Enable = $false; Set-CimInstance -InputObject $dev -ErrorAction Stop } catch {}
    }
  } -Check {
    $q = powercfg /qh SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226
    $ac = [string]($q | Select-String 'Wechselstrom|AC Power Setting' | Select-Object -First 1)
    Pruefe 'USB: selektives Energiesparen am Netzteil aus' ($ac -match '0x0+$') 'True'
  }
  Opt 'E_Tasten' 'Komfort' 'Ein/Aus-Taste = Herunterfahren; Zuklappen: Akku = Energie sparen, Netzteil = weiterlaufen (nur Bildschirm aus)' -Code {
    foreach ($plan in '381b4222-f694-41f0-9685-ff5bb260df2e', 'e9a42b02-d5df-448d-aa00-03f14749eb62') {
      if (-not ((powercfg /list) -match $plan)) { continue }
      powercfg /setacvalueindex $plan SUB_BUTTONS PBUTTONACTION 3   # 3 = Herunterfahren
      powercfg /setdcvalueindex $plan SUB_BUTTONS PBUTTONACTION 3
      powercfg /setacvalueindex $plan SUB_BUTTONS LIDACTION 0       # 0 = nichts tun
      powercfg /setdcvalueindex $plan SUB_BUTTONS LIDACTION 1       # 1 = Energie sparen
    }
    powercfg /setactive SCHEME_CURRENT
  } -Check {
    $q = powercfg /qh SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION
    $ac = [string]($q | Select-String 'Wechselstrom|AC Power Setting' | Select-Object -First 1)
    Pruefe 'Ein/Aus-Taste: Herunterfahren' ($ac -match '0x0+3$') 'True'
    $q = powercfg /qh SCHEME_CURRENT SUB_BUTTONS LIDACTION
    $ac = [string]($q | Select-String 'Wechselstrom|AC Power Setting' | Select-Object -First 1)
    $dc = [string]($q | Select-String 'Gleichstrom|DC Power Setting' | Select-Object -First 1)
    Pruefe 'Zuklappen am Netzteil: weiterlaufen' ($ac -match '0x0+$') 'True'
    Pruefe 'Zuklappen im Akkubetrieb: Energie sparen' ($dc -match '0x0+1$') 'True'
  }
  Opt 'E_Bluetooth' 'Komfort' 'Bluetooth ausschalten (spart Akku; bei Bedarf in den Schnelleinstellungen wieder an)' -Office $true -Gaming $false -Code {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    function Warte-Async($op, [Type]$typ) { $t = $asTask.MakeGenericMethod($typ).Invoke($null, @($op)); $t.Wait(-1) | Out-Null; $t.Result }
    [void][Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime]
    [void][Windows.Devices.Radios.RadioAccessStatus,Windows.System.Devices,ContentType=WindowsRuntime]
    [void](Warte-Async ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus]))
    $funk = Warte-Async ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
    $bt = @($funk | Where-Object { $_.Kind -eq 'Bluetooth' })
    if (-not $bt.Count) { throw 'kein Bluetooth-Adapter gefunden' }
    foreach ($r in $bt) { [void](Warte-Async ($r.SetStateAsync('Off')) ([Windows.Devices.Radios.RadioAccessStatus])) }
  } -Check {
    $dev = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue)
    Info "Bluetooth-Geraete vorhanden: $($dev.Count) - Status in den Schnelleinstellungen (Windows + A) pruefen"
  }
  Opt 'E_Schnellstart' 'Komfort' 'Schnellstart aus: Herunterfahren faehrt wirklich ganz herunter' -Reg @(
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0))
  Opt 'K_TaskLinks'  'Komfort' 'Taskleiste links ausrichten' -Konto $true
  Opt 'K_TaskPins'   'Komfort' 'Taskleiste: nur Explorer + gewaehlter Browser angeheftet (Edge, Store, Outlook weg)' -Konto $true
  Opt 'K_StartPins'  'Komfort' 'Startmenue: nur noch installierte Programme angeheftet (keine MS-Platzhalter)' -Konto $true `
    -Verfuegbar (-not $IstHome) -Grund $GrundHome
  Opt 'K_StartKlein' 'Komfort' 'Startmenue klein: Bereich "Empfohlen" ausblenden, keine zuletzt geoeffneten Dateien' -Konto $true
  Opt 'K_StartListe' 'Komfort' 'Startmenue: "Alle" als Liste anzeigen' -Konto $true
  Opt 'K_Desktop'    'Komfort' 'Desktop aufraeumen: Verknuepfungen der Installationen entfernen, keine neue Edge-Verknuepfung' -Konto $true
  Opt 'K_Tray'       'Komfort' 'Infobereich: immer alle Symbole anzeigen, auch neu hinzukommende' -Konto $true
  Opt 'K_ExplorerNav' 'Komfort' 'Explorer: "Start" und "Katalog" links ausblenden, oeffnet mit "Dieser PC"' -Konto $true
  Opt 'K_ExplorerAnsicht' 'Komfort' 'Explorer: versteckte Dateien zeigen, Ordnerkonflikte nie ausblenden, voller Pfad in der Titelleiste' -Konto $true
  Opt 'K_SysDateienAdmin' 'Komfort' 'Geschuetzte Systemdateien anzeigen - nur im Admin-Konto' -Konto $true
  Opt 'K_SysDateienAlle'  'Komfort' 'Geschuetzte Systemdateien anzeigen - auch im Alltagskonto' -Office $false -Gaming $false -Konto $true

# ---------------------------------------------------------------- Optionen: Grafik
  Opt 'G_HAGS' 'Grafik' 'Hardwarebeschleunigte GPU-Planung an (nur mit dedizierter Grafikkarte)' -Office $false -Gaming $true -Reg @(
    (RegWert 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2))
  Opt 'G_Stick' 'Grafik' 'Grafiktreiber-Installer aus dem Ordner "Treiber" auf dem Stick starten (falls vorhanden)' -Office $false -Gaming $true
  Opt 'G_Link'  'Grafik' 'Link zur offiziellen Treiberseite (AMD/NVIDIA, ggf. AMD-Chipsatz) auf den Desktop legen' -Office $false -Gaming $true
  Opt 'G_Herst' 'Grafik' "Link zur Treiberseite des Geraeteherstellers ($Hersteller) auf den Desktop legen" -Office $true -Gaming $true
)

# ---------------------------------------------------------------- Programme (winget)
function Prog($Kat, $Name, $Id, [bool]$Office = $false, [bool]$Gaming = $false, [bool]$Konto = $false, $Info = '', $Link = '', [bool]$Oss = $false) {
  $zusatz = if ($Konto) { '   [im Alltagskonto]' } else { '' }
  $t = if ($Info) { "$Name  -  $Info$zusatz" } else { "$Name$zusatz" }
  [pscustomobject]@{ Id = "W:$Id"; WingetId = $Id; Kat = $Kat; Name = $Name; Text = $t; Office = $Office; Gaming = $Gaming
                     Verfuegbar = $true; Konto = $Konto; Link = $Link; Oss = $Oss }
}
# Liste: rund 250 bekannte Programme, kategorisiert. Eigene Zeilen in programme.csv ergaenzen.
$ProgDatei = Join-Path $Basis 'programme.csv'
if (-not (Test-Path $ProgDatei)) { $ProgDatei = Join-Path $Ziel 'programme.csv' }
$Programme = @()
if (Test-Path $ProgDatei) {
  $Programme = @(Get-Content $ProgDatei -Encoding UTF8 | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ConvertFrom-Csv -Delimiter ';' |
    Where-Object { $_.WingetId } | ForEach-Object {
      Prog $_.Kategorie $_.Name $_.WingetId ($_.Office -eq '1') ($_.Gaming -eq '1') (($_.Konto -eq '1') -or ($_.WingetId -like 'msstore:*')) $_.Beschreibung $_.Link ($_.OpenSource -eq '1') })
} else { Write-Host 'Hinweis: programme.csv fehlt - der Reiter Programme bleibt leer.' -ForegroundColor Yellow }
$ProgKategorien = @($Programme | ForEach-Object { $_.Kat } | Select-Object -Unique)

# ---------------------------------------------------------------- Standard-Apps (Dateizuordnungen)
function StdApp($Name, $Ids, $RegApp, $Exe, $Befehl = '"%EXE%" "%1"') {
  [pscustomobject]@{ Name = $Name; Ids = @($Ids); RegApp = $RegApp; Exe = @($Exe); Befehl = $Befehl } }
function StdRolle($Key, $Name, $Endungen, $Kandidaten) {
  [pscustomobject]@{ Key = $Key; Name = $Name; Endungen = @($Endungen); Kandidaten = @($Kandidaten) } }
$StdRollen = @(
  StdRolle 'Browser' 'Webbrowser (Links, .html)' @('http', 'https', '.htm', '.html', '.xht', '.xhtml') @(
    (StdApp 'Firefox' @('Mozilla.Firefox.de', 'Mozilla.Firefox', 'Mozilla.Firefox.ESR') '^Firefox' @('firefox.exe')),
    (StdApp 'LibreWolf' 'LibreWolf.LibreWolf' '^LibreWolf' @('librewolf.exe')),
    (StdApp 'Brave' 'Brave.Brave' '^Brave' @('brave.exe')),
    (StdApp 'Vivaldi' 'Vivaldi.Vivaldi' '^Vivaldi' @('vivaldi.exe')),
    (StdApp 'Waterfox' 'Waterfox.Waterfox' '^Waterfox' @('waterfox.exe')),
    (StdApp 'Floorp' 'Ablaze.Floorp' '^Floorp' @('floorp.exe')),
    (StdApp 'Zen Browser' 'Zen-Team.Zen-Browser' '^Zen' @('zen.exe')),
    (StdApp 'Helium' 'ImputNet.Helium' '^Helium' @()),
    (StdApp 'Mullvad Browser' 'MullvadVPN.MullvadBrowser' '^Mullvad' @()),
    (StdApp 'Chromium / Ungoogled Chromium' @('Hibbiki.Chromium', 'eloston.ungoogled-chromium') '^Chromium' @()),
    (StdApp 'Google Chrome' 'Google.Chrome' '^Google Chrome' @('chrome.exe')))
  StdRolle 'PDF' 'PDF-Dateien' @('.pdf') @(
    (StdApp 'PDF-XChange Editor' 'TrackerSoftware.PDF-XChangeEditor' 'PDF-?XChange' @('PDFXEdit.exe', 'PDFXEdit*.exe')),
    (StdApp 'Okular' 'KDE.Okular' 'Okular' @('okular.exe')),
    (StdApp 'SumatraPDF' 'SumatraPDF.SumatraPDF' 'SumatraPDF' @('SumatraPDF.exe')),
    (StdApp 'Foxit PDF Reader' 'Foxit.FoxitReader' 'Foxit' @('FoxitPDFReader.exe')),
    (StdApp 'PDFgear' 'PDFgear.PDFgear' 'PDFgear' @('PDFgear.exe')),
    (StdApp 'Adobe Acrobat Reader' 'Adobe.Acrobat.Reader.64-bit' 'Acrobat' @('Acrobat.exe', 'AcroRd32.exe')))
  StdRolle 'Bilder' 'Bilder / Fotos' @('.jpg', '.jpeg', '.jpe', '.jfif', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.ico') @(
    (StdApp 'IrfanView' 'IrfanSkiljan.IrfanView' 'IrfanView' @('i_view64.exe', 'i_view32.exe')),
    (StdApp 'ImageGlass' 'DuongDieuPhap.ImageGlass' 'ImageGlass' @('ImageGlass.exe')),
    (StdApp 'nomacs' 'nomacs.nomacs' 'nomacs' @('nomacs.exe')),
    (StdApp 'JPEGView' 'sylikc.JPEGView' 'JPEGView' @('JPEGView.exe')))
  StdRolle 'Video' 'Videos' @('.mp4', '.m4v', '.mkv', '.avi', '.mov', '.wmv', '.webm', '.mpg', '.mpeg', '.flv', '.ts', '.m2ts', '.3gp', '.vob') @(
    (StdApp 'VLC' 'VideoLAN.VLC' '^VLC' @('vlc.exe') '"%EXE%" --started-from-file "%1"'),
    (StdApp 'MPC-HC' 'clsid2.mpc-hc' 'MPC-HC' @('mpc-hc64.exe', 'mpc-hc.exe')),
    (StdApp 'mpc-qt' 'mpc-qt.mpc-qt' 'mpc-qt' @('mpc-qt.exe')),
    (StdApp 'mpv' 'shinchiro.mpv' '^mpv' @('mpv.exe')))
  StdRolle 'Musik' 'Musik / Audio' @('.mp3', '.flac', '.wav', '.m4a', '.aac', '.ogg', '.oga', '.opus', '.wma', '.ape') @(
    (StdApp 'foobar2000' 'PeterPawlowski.foobar2000' 'foobar2000' @('foobar2000.exe')),
    (StdApp 'AIMP' 'AIMP.AIMP' '^AIMP' @('AIMP.exe')),
    (StdApp 'VLC' 'VideoLAN.VLC' '^VLC' @('vlc.exe') '"%EXE%" --started-from-file "%1"'),
    (StdApp 'MPC-HC' 'clsid2.mpc-hc' 'MPC-HC' @('mpc-hc64.exe', 'mpc-hc.exe')))
  StdRolle 'Text' 'Textdateien (.txt, .log, .ini, .json ...)' @('.txt', '.log', '.ini', '.cfg', '.conf', '.xml', '.json', '.yaml', '.yml', '.md') @(
    (StdApp 'Notepad++' 'Notepad++.Notepad++' 'Notepad\+\+' @('notepad++.exe')),
    (StdApp 'Sublime Text' 'SublimeHQ.SublimeText.4' 'Sublime' @('sublime_text.exe')),
    (StdApp 'VSCodium' 'VSCodium.VSCodium' 'VSCodium' @('VSCodium.exe')),
    (StdApp 'VS Code' 'Microsoft.VisualStudioCode' 'Visual Studio Code' @('Code.exe')))
  StdRolle 'Archiv' 'Archive (.zip, .7z, .rar ...)' @('.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.zst') @(
    (StdApp '7-Zip' '7zip.7zip' '7-Zip' @('7zFM.exe')),
    (StdApp 'PeaZip' 'Giorgiotani.Peazip' 'PeaZip' @('peazip.exe')),
    (StdApp 'WinRAR' 'RARLab.WinRAR' 'WinRAR' @('WinRAR.exe')))
  StdRolle 'Office' 'Office-Dokumente (Word, Excel, PowerPoint, ODF)' @('.doc', '.docx', '.dot', '.dotx', '.odt', '.ott', '.rtf', '.xls', '.xlsx', '.xlsm', '.ods', '.csv', '.ppt', '.pptx', '.pps', '.ppsx', '.odp') @(
    (StdApp 'LibreOffice' 'TheDocumentFoundation.LibreOffice' 'LibreOffice' @('soffice.exe') '"%EXE%" -o "%1"'),
    (StdApp 'ONLYOFFICE' 'ONLYOFFICE.DesktopEditors' 'ONLYOFFICE' @('DesktopEditors.exe')))
  StdRolle 'Mail' 'E-Mail (mailto-Links, .eml)' @('mailto', '.eml') @(
    (StdApp 'Thunderbird' @('Mozilla.Thunderbird.de', 'Mozilla.Thunderbird') '^Thunderbird' @('thunderbird.exe') '"%EXE%" -osint -compose "%1"'),
    (StdApp 'Betterbird' 'Betterbird.Betterbird' '^Betterbird' @('betterbird.exe') '"%EXE%" -osint -compose "%1"'))
)

# ---------------------------------------------------------------- Oberflaeche
function Zeige-Oberflaeche {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [System.Windows.Forms.Application]::EnableVisualStyles()

  $script:Form = New-Object System.Windows.Forms.Form
  $art = if ($Laptop) { 'Notebook' } else { 'Desktop' }
  $script:Form.Text = "Windows-Einrichtung  |  $Edition $Version (Build $Build)  |  $art  |  GPU: $GpuErkannt"
  # an den Bildschirm anpassen, damit die Knoepfe unten immer sichtbar sind (auch bei 125/150 % Skalierung)
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $script:Form.Size = New-Object System.Drawing.Size([Math]::Min(1180, $wa.Width - 20), [Math]::Min(760, $wa.Height - 20))
  $script:Form.MinimumSize = New-Object System.Drawing.Size(760, 480)
  $script:Form.StartPosition = 'CenterScreen'
  $script:Form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
  $script:Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

  $tabs  = New-Object System.Windows.Forms.TabControl; $tabs.Dock = 'Fill'
  $unten = New-Object System.Windows.Forms.FlowLayoutPanel; $unten.Dock = 'Bottom'; $unten.AutoSize = $true; $unten.WrapContents = $true
  $unten.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 0)
  $leiste = New-Object System.Windows.Forms.FlowLayoutPanel; $leiste.Dock = 'Bottom'; $leiste.Height = 52; $leiste.FlowDirection = 'RightToLeft'
  $leiste.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
  $script:Form.Controls.Add($tabs); $script:Form.Controls.Add($unten); $script:Form.Controls.Add($leiste)
  $script:Boxen = New-Object System.Collections.ArrayList

  function Neue-Seite($Name, $Beschreibung) {
    $tp = New-Object System.Windows.Forms.TabPage; $tp.Text = $Name; $tp.Padding = New-Object System.Windows.Forms.Padding(8)
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Dock = 'Top'; $lbl.Height = 48; $lbl.Text = $Beschreibung
    $tabs.TabPages.Add($tp)
    return @{ Seite = $tp; Label = $lbl }
  }
  function Neue-Liste($Seite, $Label, $Eintraege) {
    $lb = New-Object System.Windows.Forms.CheckedListBox
    $lb.Dock = 'Fill'; $lb.CheckOnClick = $true; $lb.IntegralHeight = $false
    $lb.Tag = New-Object System.Collections.ArrayList
    foreach ($e in $Eintraege) {
      $t = $e.Text
      if (-not $e.Verfuegbar) { $t = "$t   [nicht verfuegbar: $($e.Grund)]" }
      [void]$lb.Items.Add($t); [void]$lb.Tag.Add($e)
    }
    $lb.Add_ItemCheck({ param($s, $ev) if (-not $s.Tag[$ev.Index].Verfuegbar) { $ev.NewValue = [System.Windows.Forms.CheckState]::Unchecked } })
    $Seite.Controls.Add($lb); if ($Label) { $Seite.Controls.Add($Label) }
    [void]$script:Boxen.Add($lb)
    return $lb
  }
  function Feld($Tabelle, $Beschriftung, [bool]$Passwort = $false, $Vorgabe = '') {
    $l = New-Object System.Windows.Forms.Label; $l.Text = $Beschriftung; $l.AutoSize = $true; $l.Anchor = 'Left'
    $l.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)
    $tb = New-Object System.Windows.Forms.TextBox; $tb.Width = 320; $tb.Text = $Vorgabe; $tb.Anchor = 'Left'
    if ($Passwort) { $tb.UseSystemPasswordChar = $true }
    $Tabelle.Controls.Add($l); $Tabelle.Controls.Add($tb)
    return $tb
  }

  # --- Seite Konten
  $s = Neue-Seite 'Konten' 'Alle Passwoerter legst du hier selbst fest. Sie werden nirgends gespeichert und nicht protokolliert. Mindestens 8 Zeichen. Das Alltagskonto bekommt keine Adminrechte.'
  $tl = New-Object System.Windows.Forms.TableLayoutPanel; $tl.Dock = 'Fill'; $tl.ColumnCount = 2; $tl.AutoScroll = $true
  $tl.Padding = New-Object System.Windows.Forms.Padding(4, 8, 4, 4)
  [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 300)))
  [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  $s.Seite.Controls.Add($tl); $s.Seite.Controls.Add($s.Label)
  function Zwischentitel($Text) {
    $z = New-Object System.Windows.Forms.Label; $z.Text = $Text; $z.AutoSize = $true
    $z.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $z.Margin = New-Object System.Windows.Forms.Padding(3, 12, 3, 3)
    $tl.Controls.Add($z); $tl.SetColumnSpan($z, 2)
  }
  # Bei erneutem Start: Namen des bereits eingerichteten Alltagskontos vorschlagen
  $vorschlag = 'Alltag'
  if (-not $script:Vorschau) { try { if (Test-Path $AuswahlDatei) { $alt = (Get-Content $AuswahlDatei -Raw | ConvertFrom-Json).Standard; if ($alt) { $vorschlag = $alt } } } catch {} }
  Zwischentitel 'Alltagskonto (ohne Adminrechte)'
  $script:tbStd      = Feld $tl 'Name' $false $vorschlag
  $script:tbStdPw    = Feld $tl 'Passwort (leer = bestehendes bleibt)' $true
  $script:tbStdPw2   = Feld $tl 'Passwort wiederholen' $true
  Zwischentitel 'Weitere Konten (optional, z. B. fuer Familie oder Gaeste)'
  if ($null -eq $script:WeitereKonten) {
    $script:WeitereKonten = New-Object System.Collections.ArrayList
    if (-not $script:Vorschau) { try { if (Test-Path $AuswahlDatei) { foreach ($w in @((Get-Content $AuswahlDatei -Raw | ConvertFrom-Json).WeitereKonten)) { if ($w.Name) { [void]$script:WeitereKonten.Add(@{ Name = [string]$w.Name; Admin = [bool]$w.Admin; Pw = $null }) } } } } catch {} }
  }
  $script:lvKonten = New-Object System.Windows.Forms.ListView; $script:lvKonten.View = 'Details'; $script:lvKonten.FullRowSelect = $true
  $script:lvKonten.Width = 640; $script:lvKonten.Height = 96; $script:lvKonten.HideSelection = $false
  [void]$script:lvKonten.Columns.Add('Name', 180); [void]$script:lvKonten.Columns.Add('Art', 200); [void]$script:lvKonten.Columns.Add('Passwort', 230)
  $tl.Controls.Add($script:lvKonten); $tl.SetColumnSpan($script:lvKonten, 2)
  $kb = New-Object System.Windows.Forms.FlowLayoutPanel; $kb.AutoSize = $true
  $bKNeu = New-Object System.Windows.Forms.Button; $bKNeu.Text = 'Konto hinzufuegen ...'; $bKNeu.AutoSize = $true
  $bKAend = New-Object System.Windows.Forms.Button; $bKAend.Text = 'Aendern / Passwort ...'; $bKAend.AutoSize = $true
  $bKWeg = New-Object System.Windows.Forms.Button; $bKWeg.Text = 'Aus der Liste nehmen'; $bKWeg.AutoSize = $true
  $lKInfo = New-Object System.Windows.Forms.Label; $lKInfo.AutoSize = $true; $lKInfo.ForeColor = [System.Drawing.Color]::DimGray; $lKInfo.Margin = New-Object System.Windows.Forms.Padding(8, 7, 0, 0)
  $lKInfo.Text = '(loescht kein bestehendes Windows-Konto)'
  $kb.Controls.AddRange(@($bKNeu, $bKAend, $bKWeg, $lKInfo)); $tl.Controls.Add($kb); $tl.SetColumnSpan($kb, 2)
  $bKNeu.Add_Click({ $k = Konto-Dialog $null; if ($k) { [void]$script:WeitereKonten.Add($k); Zeige-WeitereKonten } })
  $bKAend.Add_Click({
    if ($script:lvKonten.SelectedIndices.Count -eq 0) { return }
    $i = $script:lvKonten.SelectedIndices[0]
    $k = Konto-Dialog $script:WeitereKonten[$i]; if ($k) { $script:WeitereKonten[$i] = $k; Zeige-WeitereKonten }
  })
  $bKWeg.Add_Click({ if ($script:lvKonten.SelectedIndices.Count) { $script:WeitereKonten.RemoveAt($script:lvKonten.SelectedIndices[0]); Zeige-WeitereKonten } })
  Zeige-WeitereKonten
  Zwischentitel "Admin-Konto: $AdminName (dieses Konto)"
  $script:cbAdmPw = New-Object System.Windows.Forms.CheckBox; $script:cbAdmPw.Text = 'Passwort neu setzen'; $script:cbAdmPw.AutoSize = $true
  if ($Erststart) {
    $script:cbAdmPw.Checked = $true; $script:cbAdmPw.Enabled = $false
    $script:cbAdmPw.Text = 'Pflicht: eigenes Passwort statt des vorlaeufigen aus der Installation'
  }
  $tl.Controls.Add($script:cbAdmPw); $tl.SetColumnSpan($script:cbAdmPw, 2)
  $script:tbAdmPw    = Feld $tl 'Neues Passwort' $true
  $script:tbAdmPw2   = Feld $tl 'Passwort wiederholen' $true
  Zwischentitel 'Eingebautes Konto "Administrator" (wird danach deaktiviert)'
  $script:tbEinPw    = Feld $tl 'Passwort' $true
  $script:tbEinPw2   = Feld $tl 'Passwort wiederholen' $true
  Zwischentitel 'Geraet'
  $script:tbPc       = Feld $tl 'PC-Name (leer = unveraendert)' $false ''
  Zwischentitel 'Windows-Lizenz (optional)'
  $script:lblLizenz = New-Object System.Windows.Forms.Label; $script:lblLizenz.AutoSize = $true; $script:lblLizenz.MaximumSize = New-Object System.Drawing.Size(900, 0)
  $script:lblLizenz.ForeColor = [System.Drawing.Color]::DimGray; $script:lblLizenz.Text = (Lizenz-Stand)
  $tl.Controls.Add($script:lblLizenz); $tl.SetColumnSpan($script:lblLizenz, 2)
  $script:tbKey      = Feld $tl 'Produktkey (XXXXX-XXXXX-XXXXX-XXXXX-XXXXX)' $false ''
  $script:tbKey.CharacterCasing = 'Upper'; $script:tbKey.MaxLength = 29
  $hinweis = New-Object System.Windows.Forms.Label; $hinweis.AutoSize = $true; $hinweis.MaximumSize = New-Object System.Drawing.Size(900, 0)
  $hinweis.Margin = New-Object System.Windows.Forms.Padding(3, 12, 3, 3); $hinweis.ForeColor = [System.Drawing.Color]::DimGray
  $hinweis.Text = 'PC-Name: hoechstens 15 Zeichen, nur Buchstaben, Ziffern und Bindestrich, keine echten Namen. Passwoerter: mindestens 8 Zeichen, aufschreiben und sicher aufbewahren.'
  $tl.Controls.Add($hinweis); $tl.SetColumnSpan($hinweis, 2)

  # --- Optionsseiten
  $s = Neue-Seite 'Updates & Store' 'Laeuft nach dem ersten Neustart automatisch im Hintergrund (Haken unten "Danach automatisch ..."). Ein Fortschrittsfenster zeigt jederzeit den Stand. Alles ist vorausgewaehlt.'
  [void](Neue-Liste $s.Seite $s.Label @($Optionen | Where-Object { $_.Tab -eq 'Updates' }))
  $hx = New-Object System.Windows.Forms.Label; $hx.Dock = 'Bottom'; $hx.Height = 96; $hx.ForeColor = [System.Drawing.Color]::DimGray
  $hx.Text = "Microsoft Store / Xbox spaeter anmelden: App oeffnen -> Profilbild -> Anmelden. Fragt Windows, ob das Konto 'ueberall auf diesem Geraet' verwendet werden soll, " +
             "immer 'Nur Microsoft-Apps' bzw. 'Nur diese App' waehlen. Mit der Option oben ist die Umwandlung in ein Microsoft-Konto zusaetzlich gesperrt - dein Konto bleibt lokal.`r`n" +
             "Dafuer duerfen im Reiter Microsoft-Apps 'Xbox' und 'Microsoft Store' NICHT angehakt sein."
  $s.Seite.Controls.Add($hx)
  $s = Neue-Seite 'Sicherheit' 'Haertung gegen Angriffe von aussen und Schadsoftware. Grau markierte Punkte gibt es in dieser Windows-Edition nicht.'
  $script:SichBox = Neue-Liste $s.Seite $s.Label @($Optionen | Where-Object { $_.Tab -eq 'Sicherheit' })
  $s = Neue-Seite 'Cybersicherheit' 'Zusaetzliche Haertung ueber Microsoft Defender und Windows-Richtlinien. Ohne "[Streng]" = empfohlen (vorausgewaehlt, stoert im Alltag nicht). "[Streng]" schuetzt noch mehr, kann aber einzelne Programme, Geraete oder WLANs stoeren. Sicherheits-Programme (Virenscanner, Firewall, Verschluesselung, Backup) stehen im Reiter Programme.'
  $script:CyberBox = Neue-Liste $s.Seite $s.Label @($Optionen | Where-Object { $_.Tab -eq 'Cyber' })
  $pcy = New-Object System.Windows.Forms.FlowLayoutPanel; $pcy.Dock = 'Bottom'; $pcy.Height = 40; $pcy.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
  $bCyE = New-Object System.Windows.Forms.Button; $bCyE.Text = 'Empfohlen'; $bCyE.AutoSize = $true
  $bCyM = New-Object System.Windows.Forms.Button; $bCyM.Text = 'Maximal (alles an)'; $bCyM.AutoSize = $true
  $bCyK = New-Object System.Windows.Forms.Button; $bCyK.Text = 'Keine'; $bCyK.AutoSize = $true
  $pcy.Controls.AddRange(@($bCyE, $bCyM, $bCyK)); $s.Seite.Controls.Add($pcy)
  $bCyE.Add_Click({ for ($i = 0; $i -lt $script:CyberBox.Items.Count; $i++) { $o = $script:CyberBox.Tag[$i]; $script:CyberBox.SetItemChecked($i, [bool]($o.Verfuegbar -and $o.Text -notlike '`[Streng`]*')) } })
  $bCyM.Add_Click({ for ($i = 0; $i -lt $script:CyberBox.Items.Count; $i++) { $script:CyberBox.SetItemChecked($i, [bool]$script:CyberBox.Tag[$i].Verfuegbar) } })
  $bCyK.Add_Click({ for ($i = 0; $i -lt $script:CyberBox.Items.Count; $i++) { $script:CyberBox.SetItemChecked($i, $false) } })
  $s = Neue-Seite 'Datenschutz' 'Systemweite Richtlinien gegen Datensammlung, Werbung und KI-Funktionen.'
  [void](Neue-Liste $s.Seite $s.Label @($Optionen | Where-Object { $_.Tab -eq 'Datenschutz' }))
  $s = Neue-Seite 'Microsoft-Apps' 'Angehakte Apps werden fuer alle Konten entfernt und nicht neu installiert. Unten in der Liste stehen Apps, die viele noch brauchen - nur mit Ersatz entfernen.'
  [void](Neue-Liste $s.Seite $s.Label @($Optionen | Where-Object { $_.Tab -eq 'Apps' }))
  $s = Neue-Seite 'Komfort' 'Gilt fuer jedes Konto: wird beim naechsten Anmelden automatisch gesetzt (auch fuer spaeter angelegte Konten).'
  [void](Neue-Liste $s.Seite $s.Label @($Optionen | Where-Object { $_.Tab -eq 'Komfort' }))

  $s = Neue-Seite 'Programme' 'Installation ueber winget aus offiziellen Quellen. Rund 250 Programme in Kategorien (erweiterbar in programme.csv). "[im Alltagskonto]" = gibt es nur pro Konto, wird beim ersten Anmelden des Alltagskontos installiert. Unten: Infos zum markierten Eintrag.'
  $innen = New-Object System.Windows.Forms.TabControl; $innen.Dock = 'Fill'; $innen.Multiline = $true
  $script:ProgTabs = $innen
  $script:ProgBoxen = New-Object System.Collections.ArrayList
  foreach ($kat in $ProgKategorien) {
    $tp = New-Object System.Windows.Forms.TabPage; $tp.Text = $kat; $tp.Tag = $kat
    $lb = Neue-Liste $tp $null @($Programme | Where-Object { $_.Kat -eq $kat })
    $lb.Add_SelectedIndexChanged({
      param($sender, $e)
      if ($sender.SelectedIndex -ge 0) {
        $o = $sender.Tag[$sender.SelectedIndex]
        $oss = if ($o.Oss) { 'ja' } else { 'nein' }
        $script:lblProgInfo.Text = "$($o.Name)   |   winget-ID: $($o.WingetId)   |   Open Source: $oss   |   $($o.Link)"
      }
    })
    [void]$script:ProgBoxen.Add($lb); $innen.TabPages.Add($tp)
  }
  $script:lblProgInfo = New-Object System.Windows.Forms.Label; $script:lblProgInfo.Dock = 'Bottom'; $script:lblProgInfo.Height = 24
  $script:lblProgInfo.ForeColor = [System.Drawing.Color]::DimGray; $script:lblProgInfo.AutoEllipsis = $true
  $script:lblProgInfo.Text = 'Eintrag anklicken = Infos hier.'
  $pnl = New-Object System.Windows.Forms.FlowLayoutPanel; $pnl.Dock = 'Bottom'; $pnl.Height = 40
  $pnl.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
  $bKat = New-Object System.Windows.Forms.Button; $bKat.Text = 'Kategorie an'; $bKat.AutoSize = $true
  $bAn  = New-Object System.Windows.Forms.Button; $bAn.Text = 'Alle an'; $bAn.AutoSize = $true
  $bAus = New-Object System.Windows.Forms.Button; $bAus.Text = 'Alle aus'; $bAus.AutoSize = $true
  $bWie = New-Object System.Windows.Forms.Button; $bWie.Text = 'Wie Profil'; $bWie.AutoSize = $true
  $script:lblAnzahl = New-Object System.Windows.Forms.Label; $script:lblAnzahl.AutoSize = $true; $script:lblAnzahl.Margin = New-Object System.Windows.Forms.Padding(10, 7, 3, 0)
  $lx = New-Object System.Windows.Forms.Label; $lx.Text = '   Weitere winget-IDs:'; $lx.AutoSize = $true; $lx.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 0)
  $script:tbExtra = New-Object System.Windows.Forms.TextBox; $script:tbExtra.Width = 300
  $pnl.Controls.AddRange(@($bKat, $bAn, $bAus, $bWie, $script:lblAnzahl, $lx, $script:tbExtra))
  $s.Seite.Controls.Add($innen); $s.Seite.Controls.Add($script:lblProgInfo); $s.Seite.Controls.Add($pnl); $s.Seite.Controls.Add($s.Label)
  function Setze-Programme([scriptblock]$Soll) {
    foreach ($lb in $script:ProgBoxen) { for ($i = 0; $i -lt $lb.Items.Count; $i++) { $lb.SetItemChecked($i, [bool](& $Soll $lb.Tag[$i])) } }
  }
  $bKat.Add_Click({
    if ($script:ProgTabs.SelectedIndex -lt 0) { return }
    $lb = $script:ProgBoxen[$script:ProgTabs.SelectedIndex]
    for ($i = 0; $i -lt $lb.Items.Count; $i++) { $lb.SetItemChecked($i, $true) }
  })
  $bAn.Add_Click({
    $n = @($Programme).Count
    $a = [System.Windows.Forms.MessageBox]::Show("Wirklich alle $n Programme anhaken?`r`nDie Installation dauert dann mehrere Stunden und braucht sehr viel Speicherplatz.`r`nMeist besser: 'Kategorie an' oder einzeln anhaken.", 'Alle Programme', 'YesNo', 'Question')
    if ($a -eq 'Yes') { Setze-Programme { $true } }
  })
  $bAus.Add_Click({ Setze-Programme { $false } })
  $bWie.Add_Click({
    # Stand aus geladener Profildatei, sonst Vorgabe des gewaehlten Profils
    $gaming = [string]$script:cbProfil.SelectedItem -ne 'Office'
    Setze-Programme { param($o) if ($script:GeladenesProfil) { $script:GeladenesProfil -contains $o.Id } elseif ($gaming) { $o.Gaming } else { $o.Office } }
  })
  # Zaehler im Reiter: "Browser (2)" und "Ausgewaehlt: n"
  $script:ZaehlTimer = New-Object System.Windows.Forms.Timer; $script:ZaehlTimer.Interval = 400
  $script:ZaehlTimer.Add_Tick({
    # BitLocker-Hinweis beim Office-Profil
    $bitAn = $true; $bitDa = $false
    for ($k = 0; $k -lt $script:SichBox.Items.Count; $k++) {
      if ($script:SichBox.Tag[$k].Id -eq 'S_BitLocker') { $bitDa = [bool]$script:SichBox.Tag[$k].Verfuegbar; $bitAn = $script:SichBox.GetItemChecked($k) }
    }
    $script:lblBit.Visible = ($bitDa -and -not $bitAn -and ([string]$script:cbProfil.SelectedItem -eq 'Office'))
    # Windows-App entfernen -> Ersatzprogramm anhaken (und umgekehrt): Fotos -> IrfanView, Editor -> Notepad++
    if (-not $script:ErsatzVorher) { $script:ErsatzVorher = @{} }
    foreach ($paar in @(@('A_Fotos', 'IrfanSkiljan.IrfanView'), @('A_Editor', 'Notepad++.Notepad++'))) {
      $weg = $false
      foreach ($lb in $script:Boxen) { for ($k = 0; $k -lt $lb.Items.Count; $k++) { if ($lb.Tag[$k].Id -eq $paar[0]) { $weg = $lb.GetItemChecked($k) } } }
      if ($script:ErsatzVorher.ContainsKey($paar[0]) -and $weg -ne $script:ErsatzVorher[$paar[0]]) {
        foreach ($lb in $script:ProgBoxen) { for ($k = 0; $k -lt $lb.Items.Count; $k++) { if ($lb.Tag[$k].WingetId -eq $paar[1]) { $lb.SetItemChecked($k, $weg) } } }
      }
      $script:ErsatzVorher[$paar[0]] = $weg
    }
    # Standard-Apps: das gewaehlte Ersatzprogramm eintragen (solange nicht von Hand geaendert)
    $gewP = @(foreach ($lb in $script:ProgBoxen) { foreach ($k in $lb.CheckedIndices) { $lb.Tag[$k].WingetId } })
    foreach ($r in $StdRollen) {
      if ($script:StdManuell[$r.Key]) { continue }
      $treffer = @($r.Kandidaten | Where-Object { $kd = $_; @($kd.Ids | Where-Object { $gewP -contains $_ }).Count }) | Select-Object -First 1
      $soll = if ($treffer) { $treffer.Name } else { 'Nicht aendern' }
      if ([string]$script:StdBoxen[$r.Key].SelectedItem -ne $soll) { $script:StdBoxen[$r.Key].SelectedItem = $soll }
    }
    $summe = 0
    for ($k = 0; $k -lt $script:ProgBoxen.Count; $k++) {
      $n = $script:ProgBoxen[$k].CheckedItems.Count; $summe += $n
      $tp = $script:ProgTabs.TabPages[$k]
      $soll = if ($n) { "$($tp.Tag) ($n)" } else { [string]$tp.Tag }
      if ($tp.Text -ne $soll) { $tp.Text = $soll }
    }
    $script:lblAnzahl.Text = "Ausgewaehlt: $summe"
  })
  $script:ZaehlTimer.Start()
  $script:Form.Add_FormClosed({ $script:ZaehlTimer.Stop() })

  $s = Neue-Seite 'Standard-Apps' 'Welches Programm oeffnet welche Dateien? Eingetragen wird automatisch das Programm, das du im Reiter Programme als Ersatz angehakt hast (z. B. Firefox statt Edge). "Nicht aendern" = Windows-Programm bleibt (z. B. Fotos). Von Hand geaenderte Zeilen bleiben so. Gilt fuer alle Konten.'
  $ts = New-Object System.Windows.Forms.TableLayoutPanel; $ts.Dock = 'Fill'; $ts.ColumnCount = 3; $ts.AutoScroll = $true
  $ts.Padding = New-Object System.Windows.Forms.Padding(4, 8, 4, 4)
  [void]$ts.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 300)))
  [void]$ts.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 280)))
  [void]$ts.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  $s.Seite.Controls.Add($ts); $s.Seite.Controls.Add($s.Label)
  $script:StdBoxen = @{}; $script:StdManuell = @{}
  foreach ($r in $StdRollen) {
    $l = New-Object System.Windows.Forms.Label; $l.Text = $r.Name; $l.AutoSize = $true; $l.Anchor = 'Left'
    $l.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
    $cb = New-Object System.Windows.Forms.ComboBox; $cb.DropDownStyle = 'DropDownList'; $cb.Width = 260; $cb.Anchor = 'Left'
    [void]$cb.Items.Add('Automatisch'); [void]$cb.Items.Add('Nicht aendern')
    foreach ($k in $r.Kandidaten) { [void]$cb.Items.Add($k.Name) }
    $cb.SelectedIndex = 1
    $cb.Tag = $r.Key
    $cb.Add_SelectionChangeCommitted({ param($q, $ev) $script:StdManuell[[string]$q.Tag] = $true })
    $le = New-Object System.Windows.Forms.Label; $le.Text = ($r.Endungen -join ' '); $le.AutoSize = $true; $le.Anchor = 'Left'
    $le.ForeColor = [System.Drawing.Color]::DimGray; $le.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
    $ts.Controls.Add($l); $ts.Controls.Add($cb); $ts.Controls.Add($le)
    $script:StdBoxen[$r.Key] = $cb
  }

  $s = Neue-Seite 'Grafik' "Erkannt: $($GpuNamen -join ' | ')   CPU: $CpuName"
  $gb = New-Object System.Windows.Forms.GroupBox; $gb.Text = 'Grafikkarte'; $gb.Dock = 'Top'; $gb.Height = 130
  $fl = New-Object System.Windows.Forms.FlowLayoutPanel; $fl.Dock = 'Fill'; $fl.FlowDirection = 'TopDown'
  $script:rbAuto  = New-Object System.Windows.Forms.RadioButton; $script:rbAuto.Text  = "Automatisch (erkannt: $GpuErkannt)"; $script:rbAuto.AutoSize = $true
  $script:rbKeine = New-Object System.Windows.Forms.RadioButton; $script:rbKeine.Text = 'Keine dedizierte Grafikkarte (Office, Prozessorgrafik)'; $script:rbKeine.AutoSize = $true
  $script:rbAmd   = New-Object System.Windows.Forms.RadioButton; $script:rbAmd.Text   = 'AMD Radeon'; $script:rbAmd.AutoSize = $true
  $script:rbNv    = New-Object System.Windows.Forms.RadioButton; $script:rbNv.Text    = 'NVIDIA GeForce'; $script:rbNv.AutoSize = $true
  $fl.Controls.AddRange(@($script:rbAuto, $script:rbKeine, $script:rbAmd, $script:rbNv)); $gb.Controls.Add($fl)
  $lbG = Neue-Liste $s.Seite $s.Label @($Optionen | Where-Object { $_.Tab -eq 'Grafik' })
  $s.Seite.Controls.Add($gb); $s.Seite.Controls.SetChildIndex($gb, 1)

  # --- untere Leiste
  $lp = New-Object System.Windows.Forms.Label; $lp.Text = 'Profil:'; $lp.AutoSize = $true; $lp.Margin = New-Object System.Windows.Forms.Padding(0, 6, 4, 0)
  $script:cbProfil = New-Object System.Windows.Forms.ComboBox; $script:cbProfil.DropDownStyle = 'DropDownList'; $script:cbProfil.Width = 150
  [void]$script:cbProfil.Items.AddRange(@('Office', 'Gaming (AMD)', 'Gaming (NVIDIA)'))
  $bLaden = New-Object System.Windows.Forms.Button; $bLaden.Text = 'Profil laden...'; $bLaden.AutoSize = $true
  $bSpeichern = New-Object System.Windows.Forms.Button; $bSpeichern.Text = 'Profil speichern...'; $bSpeichern.AutoSize = $true
  $bLetztes = New-Object System.Windows.Forms.Button; $bLetztes.Text = 'Letztes Profil laden'; $bLetztes.AutoSize = $true
  $script:cbProbe = New-Object System.Windows.Forms.CheckBox; $script:cbProbe.Text = 'Probelauf (nur anzeigen, nichts aendern)'; $script:cbProbe.AutoSize = $true
  $script:cbProbe.Margin = New-Object System.Windows.Forms.Padding(20, 6, 20, 0)
  $script:cbNach = New-Object System.Windows.Forms.CheckBox; $script:cbNach.AutoSize = $true; $script:cbNach.Checked = $true
  $script:cbNach.Text = 'Danach automatisch: Neustart, Updates bis aktuell, Pruefung'
  $script:cbNach.Margin = New-Object System.Windows.Forms.Padding(0, 6, 20, 0)
  $script:cbNetz = New-Object System.Windows.Forms.CheckBox; $script:cbNetz.AutoSize = $true
  $script:cbNetz.Text = 'Netzwerk bis zur Programminstallation trennen'
  $script:cbNetz.Checked = ([bool]$Erststart -or (Test-Path $NetzKey))
  $script:cbNetz.Margin = New-Object System.Windows.Forms.Padding(0, 6, 20, 0)
  $bStart = New-Object System.Windows.Forms.Button; $bStart.Text = 'Start'; $bStart.Width = 150; $bStart.Height = 36
  $bStart.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
  $bAbbr  = New-Object System.Windows.Forms.Button; $bAbbr.Text = 'Abbrechen'; $bAbbr.Width = 120; $bAbbr.Height = 36
  $script:lblBit = New-Object System.Windows.Forms.Label; $script:lblBit.AutoSize = $true; $script:lblBit.Visible = $false
  $script:lblBit.ForeColor = [System.Drawing.Color]::DarkOrange; $script:lblBit.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
  $script:lblBit.Text = "Hinweis Office-Profil: BitLocker (Laufwerksverschluesselung) wird NICHT eingerichtet. Bei Bedarf: Reiter Sicherheit -> 'BitLocker fuer Laufwerk C:' anhaken."
  $unten.Controls.AddRange(@($lp, $script:cbProfil, $bLetztes, $bLaden, $bSpeichern, $script:cbProbe, $script:cbNach, $script:cbNetz, $script:lblBit))
  $leiste.Controls.AddRange(@($bAbbr, $bStart))
  $script:Form.AcceptButton = $null

  $script:cbProfil.Add_SelectedIndexChanged({ Setze-Profil $script:cbProfil.SelectedItem })
  $bLaden.Add_Click({ Lade-ProfilDatei })
  $bSpeichern.Add_Click({ Speichere-ProfilDatei })
  $bLetztes.Add_Click({ Lade-LetztesProfil })
  $bAbbr.Add_Click({ $script:Ergebnis = 'abbruch'; $script:Form.Close() })
  $bStart.Add_Click({
    $meldung = Pruefe-Eingaben
    if ($meldung) { [void][System.Windows.Forms.MessageBox]::Show($meldung, 'Bitte pruefen', 'OK', 'Warning'); return }
    if ($script:Vorschau) {
      [void][System.Windows.Forms.MessageBox]::Show('Vorschau: Die Eingaben sind in Ordnung. Es wird nichts veraendert - zum echten Einrichten Start.cmd benutzen.', 'Windows-Einrichtung - Vorschau', 'OK', 'Information')
      return
    }
    Sichere-ProfilAuto
    $script:Ergebnis = 'start'; $script:Form.Close()
  })

  $start = 'Office'
  if ($GpuErkannt -eq 'AMD') { $start = 'Gaming (AMD)' } elseif ($GpuErkannt -eq 'NVIDIA') { $start = 'Gaming (NVIDIA)' }
  if ($script:Cfg) { $start = $script:Cfg.Profil }
  $script:cbProfil.SelectedItem = $start
  $script:rbAuto.Checked = $true
  if ($script:Cfg) {
    # nach einem Probelauf: vorige Auswahl wieder einsetzen (Passwoerter muessen neu eingegeben werden)
    $gew = @($script:Cfg.Gewaehlt)
    foreach ($lb in $script:Boxen) {
      for ($i = 0; $i -lt $lb.Items.Count; $i++) { $lb.SetItemChecked($i, [bool](($gew -contains $lb.Tag[$i].Id) -and $lb.Tag[$i].Verfuegbar)) }
    }
    switch ($script:Cfg.GPU) { 'AMD' { $script:rbAmd.Checked = $true } 'NVIDIA' { $script:rbNv.Checked = $true } default { $script:rbKeine.Checked = $true } }
    $script:tbStd.Text = $script:Cfg.Standard; $script:tbPc.Text = $script:Cfg.PCName
    $script:tbExtra.Text = (@($script:Cfg.ExtraIds) -join ', ')
    if ($null -ne $script:Cfg.Nachlauf) { $script:cbNach.Checked = [bool]$script:Cfg.Nachlauf }
    if ($null -ne $script:Cfg.NetzTrennen) { $script:cbNetz.Checked = [bool]$script:Cfg.NetzTrennen }
    Setze-StdAuswahl $script:Cfg.StdApps
    if (-not $script:GeladenesProfil) { $script:GeladenesProfil = $gew }
  }
  if (-not $script:Vorschau) { Profile-Bereinigen }
  $script:Ergebnis = 'abbruch'
  if ($script:Vorschau) { $script:Form.Text = "VORSCHAU (aendert nichts)  |  " + $script:Form.Text }
  $script:VTabs = $tabs
  if ($script:VBilder) {
    $script:Form.Add_Shown({
      $nr = 10
      foreach ($tp in @($script:VTabs.TabPages)) {
        $script:VTabs.SelectedTab = $tp
        $name = ($tp.Text -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
        Bild-Speichern $script:Form (Join-Path $script:VBilder ("{0:D2}-oberflaeche-{1}.png" -f $nr, $name)); $nr++
      }
      $script:Form.Close()
    })
  } else { $script:Form.Add_Shown({ Startmenue-Schliessen; $script:Form.Activate() }) }
  [void]$script:Form.ShowDialog()
  return ($script:Ergebnis -eq 'start')
}

function Zeige-WeitereKonten {
  $script:lvKonten.Items.Clear()
  foreach ($k in $script:WeitereKonten) {
    $da = [bool](Get-LocalUser -Name $k.Name -ErrorAction SilentlyContinue)
    $it = New-Object System.Windows.Forms.ListViewItem([string]$k.Name)
    [void]$it.SubItems.Add($(if ($k.Admin) { 'Administrator' } else { 'Standard (ohne Adminrechte)' }))
    [void]$it.SubItems.Add($(if ($k.Pw) { 'wird gesetzt' } elseif ($da) { 'bleibt (Konto besteht)' } else { 'FEHLT - Aendern druecken' }))
    [void]$script:lvKonten.Items.Add($it)
  }
}
function Konto-Dialog($Alt) {
  $d = New-Object System.Windows.Forms.Form; $d.Text = 'Weiteres Konto'; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
  $d.StartPosition = 'CenterParent'; $d.Font = New-Object System.Drawing.Font('Segoe UI', 9.5); $d.AutoSize = $true; $d.AutoSizeMode = 'GrowAndShrink'
  $t = New-Object System.Windows.Forms.TableLayoutPanel; $t.ColumnCount = 2; $t.AutoSize = $true; $t.Padding = New-Object System.Windows.Forms.Padding(10)
  $d.Controls.Add($t)
  function DFeld($Text, [bool]$Pw, $Wert) {
    $l = New-Object System.Windows.Forms.Label; $l.Text = $Text; $l.AutoSize = $true; $l.Anchor = 'Left'
    $b = New-Object System.Windows.Forms.TextBox; $b.Width = 260; $b.Text = $Wert; if ($Pw) { $b.UseSystemPasswordChar = $true }
    $t.Controls.Add($l); $t.Controls.Add($b); return $b
  }
  $tN = DFeld 'Name' $false $(if ($Alt) { $Alt.Name } else { '' })
  $tP = DFeld 'Passwort (mind. 8 Zeichen)' $true ''
  $tP2 = DFeld 'Passwort wiederholen' $true ''
  $cA = New-Object System.Windows.Forms.CheckBox; $cA.Text = 'Administrator (nur wenn wirklich noetig)'; $cA.AutoSize = $true
  if ($Alt) { $cA.Checked = [bool]$Alt.Admin }
  $t.Controls.Add($cA); $t.SetColumnSpan($cA, 2)
  $h = New-Object System.Windows.Forms.Label; $h.AutoSize = $true; $h.MaximumSize = New-Object System.Drawing.Size(460, 0); $h.ForeColor = [System.Drawing.Color]::DimGray
  $h.Text = 'Besteht das Konto schon, Passwort leer lassen = es bleibt. Neue Konten bekommen dieselben Komfort- und Datenschutz-Einstellungen wie das Alltagskonto.'
  $t.Controls.Add($h); $t.SetColumnSpan($h, 2)
  $fl = New-Object System.Windows.Forms.FlowLayoutPanel; $fl.AutoSize = $true; $fl.FlowDirection = 'RightToLeft'; $fl.Dock = 'Fill'
  $bA = New-Object System.Windows.Forms.Button; $bA.Text = 'Abbrechen'; $bA.DialogResult = 'Cancel'
  $bO = New-Object System.Windows.Forms.Button; $bO.Text = 'OK'
  $fl.Controls.AddRange(@($bA, $bO)); $t.Controls.Add($fl); $t.SetColumnSpan($fl, 2)
  $d.CancelButton = $bA
  $script:KdErg = $null
  $bO.Add_Click({
    $n = $tN.Text.Trim(); $f = @()
    if ($n -notmatch '^[^"/\\\[\]:;|=,+*?<>@]{1,20}$') { $f += 'Name: 1-20 Zeichen, keine Sonderzeichen wie " / \ [ ] : ; | = , + * ? < > @' }
    if ($n -eq $script:tbStd.Text.Trim() -or $n -eq $AdminName) { $f += 'Der Name ist schon das Alltags- bzw. Admin-Konto.' }
    foreach ($w in $script:WeitereKonten) { if ($w.Name -eq $n -and -not ($Alt -and $Alt.Name -eq $n)) { $f += 'Dieses Konto steht schon in der Liste.' } }
    $da = [bool](Get-LocalUser -Name $n -ErrorAction SilentlyContinue)
    if ($tP.Text -or -not $da) {
      if ($tP.Text.Length -lt 8) { $f += 'Passwort: mindestens 8 Zeichen' + $(if (-not $da) { ' (neues Konto braucht ein Passwort).' } else { '.' }) }
      elseif ($tP.Text -ne $tP2.Text) { $f += 'Die beiden Passwoerter sind nicht gleich.' }
    }
    if ($f.Count) { [void][System.Windows.Forms.MessageBox]::Show(($f -join "`r`n"), 'Bitte pruefen', 'OK', 'Warning'); return }
    $pw = if ($tP.Text) { ConvertTo-SecureString $tP.Text -AsPlainText -Force } elseif ($Alt) { $Alt.Pw } else { $null }
    $tP.Text = ''; $tP2.Text = ''
    $script:KdErg = @{ Name = $n; Admin = $cA.Checked; Pw = $pw }
    $d.DialogResult = 'OK'; $d.Close()
  })
  [void]$d.ShowDialog($script:Form)
  return $script:KdErg
}
function Setze-Profil($Name) {
  $gaming = $Name -ne 'Office'
  foreach ($lb in $script:Boxen) {
    for ($i = 0; $i -lt $lb.Items.Count; $i++) {
      $o = $lb.Tag[$i]
      $soll = if ($gaming) { $o.Gaming } else { $o.Office }
      $lb.SetItemChecked($i, [bool]($soll -and $o.Verfuegbar))
    }
  }
  if ($Name -eq 'Gaming (AMD)') { $script:rbAmd.Checked = $true }
  elseif ($Name -eq 'Gaming (NVIDIA)') { $script:rbNv.Checked = $true }
  elseif ($script:rbKeine) { $script:rbKeine.Checked = $true }
}
function Gewaehlte-Ids {
  $ids = New-Object System.Collections.ArrayList
  foreach ($lb in $script:Boxen) { foreach ($i in $lb.CheckedIndices) { [void]$ids.Add($lb.Tag[$i].Id) } }
  return , $ids.ToArray()
}
function Std-Auswahl {
  $h = [ordered]@{}
  foreach ($r in $StdRollen) { $h[$r.Key] = [string]$script:StdBoxen[$r.Key].SelectedItem }
  return $h
}
function Setze-StdAuswahl($Werte) {
  if (-not $Werte) { return }
  foreach ($r in $StdRollen) {
    $w = [string]$Werte.($r.Key)
    if ($w -and $w -ne 'Automatisch' -and $script:StdBoxen[$r.Key].Items.Contains($w)) { $script:StdBoxen[$r.Key].SelectedItem = $w; $script:StdManuell[$r.Key] = $true }
  }
}
function Gpu-Auswahl {
  if ($script:rbAmd.Checked) { return 'AMD' }
  if ($script:rbNv.Checked) { return 'NVIDIA' }
  if ($script:rbKeine.Checked) { return 'Keine' }
  return $GpuErkannt
}
function Profil-Daten {
  [ordered]@{ Profil = [string]$script:cbProfil.SelectedItem; Gewaehlt = (Gewaehlte-Ids); GPU = (Gpu-Auswahl)
              Standard = $script:tbStd.Text; PCName = $script:tbPc.Text; ExtraIds = $script:tbExtra.Text; StdApps = (Std-Auswahl)
              WeitereKonten = @($script:WeitereKonten | ForEach-Object { [ordered]@{ Name = $_.Name; Admin = [bool]$_.Admin } })
              Gesichert = (Get-Date -Format 'dd.MM.yyyy HH:mm') }
}
function Profil-Ordner { return @((Join-Path $Basis 'Profile'), (Join-Path $Ziel 'Profile')) | Select-Object -Unique }
function Sichere-ProfilAuto {
  # beim Druck auf "Start": Auswahl automatisch sichern (ohne Passwoerter) - auf dem Stick und auf C:
  $json = Ohne-Geheimnisse (Profil-Daten) | ConvertTo-Json -Depth 4
  $pc = if ($script:tbPc.Text.Trim()) { $script:tbPc.Text.Trim() } else { $env:COMPUTERNAME }
  $name = 'Profil-{0}-{1}.json' -f $pc, (Get-Date -Format 'yyyyMMdd-HHmm')
  foreach ($o in (Profil-Ordner)) {
    try {
      New-Item -Path $o -ItemType Directory -Force | Out-Null
      Set-Content -Path (Join-Path $o $name) -Value $json -Encoding UTF8
      Set-Content -Path (Join-Path $o 'Letztes-Profil.json') -Value $json -Encoding UTF8
    } catch {}
  }
}
function Speichere-ProfilDatei {
  $d = New-Object System.Windows.Forms.SaveFileDialog
  $d.Filter = 'Einrichtungsprofil (*.json)|*.json'; $d.FileName = 'mein-profil.json'
  $d.InitialDirectory = $(if (Test-Path (Join-Path $Basis 'Profile')) { Join-Path $Basis 'Profile' } else { $Basis })
  if ($d.ShowDialog() -ne 'OK') { return }
  Ohne-Geheimnisse (Profil-Daten) | ConvertTo-Json -Depth 4 | Set-Content -Path $d.FileName -Encoding UTF8
}
function Lade-Profil($Pfad) {
  $daten = Get-Content $Pfad -Raw | ConvertFrom-Json
  # zuerst das Grundprofil waehlen (setzt Vorgaben), danach die gespeicherten Haken
  if ($daten.Profil -and $script:cbProfil.Items.Contains([string]$daten.Profil)) { $script:cbProfil.SelectedItem = [string]$daten.Profil }
  $gew = @($daten.Gewaehlt)
  $script:GeladenesProfil = $gew
  foreach ($lb in $script:Boxen) {
    for ($i = 0; $i -lt $lb.Items.Count; $i++) { $lb.SetItemChecked($i, [bool](($gew -contains $lb.Tag[$i].Id) -and $lb.Tag[$i].Verfuegbar)) }
  }
  switch ($daten.GPU) { 'AMD' { $script:rbAmd.Checked = $true } 'NVIDIA' { $script:rbNv.Checked = $true } default { $script:rbKeine.Checked = $true } }
  if ($daten.Standard) { $script:tbStd.Text = $daten.Standard }
  if ($daten.WeitereKonten) {
    $script:WeitereKonten.Clear()
    foreach ($w in @($daten.WeitereKonten)) { if ($w.Name) { [void]$script:WeitereKonten.Add(@{ Name = [string]$w.Name; Admin = [bool]$w.Admin; Pw = $null }) } }
    Zeige-WeitereKonten
  }
  $script:tbPc.Text = [string]$daten.PCName
  $script:tbExtra.Text = [string]$daten.ExtraIds
  Setze-StdAuswahl $daten.StdApps
  return $daten
}
function Profile-Bereinigen {
  # Sicherheitsnetz: vorhandene Profildateien ohne jede Art von Passwort/Schluessel neu schreiben
  foreach ($o in (Profil-Ordner)) {
    foreach ($dt in @(Get-ChildItem -Path $o -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      try {
        $roh = Get-Content $dt.FullName -Raw
        if ($roh -match '"(Pw|Pass[^"]*|Passwort[^"]*|Kennwort[^"]*|Key|Produktkey)"\s*:') {
          Ohne-Geheimnisse ($roh | ConvertFrom-Json) | ConvertTo-Json -Depth 4 | Set-Content -Path $dt.FullName -Encoding UTF8 }
      } catch {}
    }
  }
}
function Lade-ProfilDatei {
  $d = New-Object System.Windows.Forms.OpenFileDialog
  $d.Filter = 'Einrichtungsprofil (*.json)|*.json'
  $d.InitialDirectory = $(if (Test-Path (Join-Path $Basis 'Profile')) { Join-Path $Basis 'Profile' } else { $Basis })
  if ($d.ShowDialog() -ne 'OK') { return }
  [void](Lade-Profil $d.FileName)
}
function Lade-LetztesProfil {
  $kand = @(foreach ($o in (Profil-Ordner)) { Get-Item (Join-Path $o 'Letztes-Profil.json') -ErrorAction SilentlyContinue }) | Sort-Object LastWriteTime -Descending
  if (-not $kand.Count) {
    [void][System.Windows.Forms.MessageBox]::Show('Noch keine automatische Sicherung vorhanden. Sie entsteht beim ersten Druck auf "Start".', 'Letztes Profil', 'OK', 'Information'); return }
  $d = Lade-Profil $kand[0].FullName
  [void][System.Windows.Forms.MessageBox]::Show("Geladen: Auswahl vom $($d.Gesichert)`r`n($($kand[0].FullName))`r`n`r`nNur noch die Passwoerter im Reiter Konten eintragen.", 'Letztes Profil', 'OK', 'Information')
}
function Pruefe-Eingaben {
  $f = @()
  $nameMuster = '^[^"/\\\[\]:;|=,+*?<>@]{1,20}$'
  $std = $script:tbStd.Text.Trim()
  if ($std -notmatch $nameMuster) { $f += 'Name des Alltagskontos: 1-20 Zeichen, keine Sonderzeichen wie " / \ [ ] : ; | = , + * ? < > @' }
  if ($std -eq $AdminName) { $f += 'Das Alltagskonto darf nicht dasselbe wie das Admin-Konto sein.' }
  if ($script:tbPc.Text -and ($script:tbPc.Text -notmatch '^(?=.*[A-Za-z])[A-Za-z0-9-]{1,15}$')) { $f += 'PC-Name: 1-15 Zeichen, nur Buchstaben, Ziffern und Bindestrich.' }
  if (-not $script:cbProbe.Checked) {
    $gibts = [bool](Get-LocalUser -Name $std -ErrorAction SilentlyContinue)
    function PwOk($a, $b, $Pflicht, $Was) {
      if (-not $a.Text -and -not $Pflicht) { return $null }
      if ($a.Text.Length -lt 8) { return "${Was}: mindestens 8 Zeichen." }
      if ($a.Text -ne $b.Text) { return "${Was}: die beiden Eingaben sind nicht gleich." }
      return $null
    }
    $f += PwOk $script:tbStdPw $script:tbStdPw2 (-not $gibts) 'Passwort Alltagskonto'
    $f += PwOk $script:tbEinPw $script:tbEinPw2 $true 'Passwort eingebautes Administrator-Konto'
    if ($script:cbAdmPw.Checked) { $f += PwOk $script:tbAdmPw $script:tbAdmPw2 $true 'Passwort Admin-Konto' }
  }
  foreach ($w in $script:WeitereKonten) {
    if ($w.Name -eq $std) { $f += "Weiteres Konto '$($w.Name)' heisst wie das Alltagskonto." }
    if (-not $w.Pw -and -not $script:cbProbe.Checked -and -not (Get-LocalUser -Name $w.Name -ErrorAction SilentlyContinue)) { $f += "Weiteres Konto '$($w.Name)': Passwort fehlt (Konto markieren -> 'Aendern / Passwort ...')." }
  }
  $pk = $script:tbKey.Text.Trim().ToUpper()
  if ($pk -and $pk -notmatch '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$') { $f += 'Produktkey: Format XXXXX-XXXXX-XXXXX-XXXXX-XXXXX (25 Zeichen mit Bindestrichen) - oder Feld leer lassen.' }
  $wahl = Gewaehlte-Ids
  if ($wahl -contains 'U_MsKonto') {
    if ($wahl -contains 'A_Store') { $f += 'Store-Anmeldung gewaehlt, aber "Microsoft Store" soll entfernt werden: im Reiter Microsoft-Apps abhaken (oder die Anmelde-Option abwaehlen).' }
    if ($wahl -contains 'A_Xbox') { $f += 'Xbox-Anmeldung gewaehlt, aber "Xbox" soll entfernt werden: im Reiter Microsoft-Apps abhaken (oder die Anmelde-Option abwaehlen).' }
  }
  if (($wahl -contains 'U_Store') -and ($wahl -contains 'A_Store')) { $f += 'Store-Updates gewaehlt, aber der Store soll entfernt werden: eins von beiden abwaehlen.' }
  $f = @($f | Where-Object { $_ })
  if ($f.Count) { return ($f -join "`r`n") }
  # Eingaben uebernehmen, Klartext sofort aus den Feldern loeschen
  $script:Pw = @{}
  foreach ($paar in @(@('Std', $script:tbStdPw, $script:tbStdPw2), @('Ein', $script:tbEinPw, $script:tbEinPw2), @('Adm', $script:tbAdmPw, $script:tbAdmPw2))) {
    if ($paar[1].Text) { $script:Pw[$paar[0]] = ConvertTo-SecureString $paar[1].Text -AsPlainText -Force }
    $paar[1].Text = ''; $paar[2].Text = ''
  }
  if (-not $script:cbAdmPw.Checked) { $script:Pw.Remove('Adm') }
  if ($pk) { $script:Pw['Key'] = ConvertTo-SecureString $pk -AsPlainText -Force }
  $script:tbKey.Text = ''; $pk = $null
  $script:Cfg = [ordered]@{
    Profil = [string]$script:cbProfil.SelectedItem; Gewaehlt = (Gewaehlte-Ids); GPU = (Gpu-Auswahl)
    Standard = $std; Admin = $AdminName; PCName = $script:tbPc.Text.Trim()
    WeitereKonten = @($script:WeitereKonten | ForEach-Object { [ordered]@{ Name = $_.Name; Admin = [bool]$_.Admin } })
    ExtraIds = @($script:tbExtra.Text -split '[,; ]+' | Where-Object { $_ })
    Probe = $script:cbProbe.Checked; Nachlauf = $script:cbNach.Checked; NetzTrennen = $script:cbNetz.Checked; StdApps = (Std-Auswahl); Datum = (Get-Date -Format 'yyyy-MM-dd HH:mm')
  }
  return $null
}

# ---------------------------------------------------------------- Einrichtung
function Hat($Id) { return ($script:Cfg.Gewaehlt -contains $Id) }

function Einrichtung-WeitereKonten {
  foreach ($w in @($script:WeitereKonten)) {
    if (-not $w -or -not $w.Name) { continue }
    $n = $w.Name
    if (-not (Get-LocalUser -Name $n -ErrorAction SilentlyContinue)) {
      Schritt "Weiteres Konto '$n' angelegt" {
        New-LocalUser -Name $n -Password $w.Pw -PasswordNeverExpires -AccountNeverExpires | Out-Null
        Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $n -ErrorAction SilentlyContinue }
    } elseif ($w.Pw) {
      Schritt "Passwort von '$n' neu gesetzt" { Set-LocalUser -Name $n -Password $w.Pw }
    }
    $istAdm = [bool](@(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match ('\\' + [regex]::Escape($n) + '$') }).Count)
    if ($w.Admin -and -not $istAdm) { Schritt "'$n' ist Administrator" { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $n } }
    if (-not $w.Admin -and $istAdm) { Schritt "'$n' hat keine Adminrechte mehr" { Remove-LocalGroupMember -SID 'S-1-5-32-544' -Member $n } }
    $w.Pw = $null
  }
}
function Einrichtung-Konten {
  Titel 'Konten'
  $k = $script:Cfg
  $a500 = Get-LocalUser | Where-Object { $_.SID -like '*-500' }
  Schritt "Eingebautes Konto '$($a500.Name)': dein Passwort gesetzt, deaktiviert" {
    $a500 | Set-LocalUser -Password $script:Pw['Ein']; $a500 | Disable-LocalUser }
  Schritt 'Gastkonto deaktiviert' { Get-LocalUser | Where-Object { $_.SID -like '*-501' } | Disable-LocalUser }
  if ($script:Pw.ContainsKey('Adm')) { Schritt "Passwort von '$($k.Admin)' neu gesetzt" { Set-LocalUser -Name $k.Admin -Password $script:Pw['Adm'] } }
  if (-not (Get-LocalUser -Name $k.Standard -ErrorAction SilentlyContinue)) {
    Schritt "Alltagskonto '$($k.Standard)' angelegt (Gruppe Benutzer)" {
      New-LocalUser -Name $k.Standard -Password $script:Pw['Std'] -PasswordNeverExpires -AccountNeverExpires | Out-Null
      Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $k.Standard }
  } elseif ($script:Pw.ContainsKey('Std')) {
    Schritt "Passwort von '$($k.Standard)' neu gesetzt" { Set-LocalUser -Name $k.Standard -Password $script:Pw['Std'] }
  }
  Einrichtung-WeitereKonten
  Schritt "'$($k.Standard)' hat keine Adminrechte" {
    $m = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.Name -match ('\\' + [regex]::Escape($k.Standard) + '$') })
    if ($m.Count) { Remove-LocalGroupMember -SID 'S-1-5-32-544' -Member $k.Standard } }
  Schritt 'Passwoerter laufen nie ab' { foreach ($n in @($k.Admin, $k.Standard)) { Set-LocalUser -Name $n -PasswordNeverExpires $true -ErrorAction SilentlyContinue } }
  if ($k.PCName -and ($k.PCName -ne $env:COMPUTERNAME)) { Schritt "PC-Name wird nach dem Neustart '$($k.PCName)'" { Rename-Computer -NewName $k.PCName -Force -WarningAction SilentlyContinue } }
}

function Rueckbau-Cyber {
  # Cybersicherheit: was beim letzten Mal angehakt war und jetzt nicht mehr, wird auf Windows-Standard zurueckgesetzt
  $vorher = @($script:VorherGewaehlt)
  $weg = @($Optionen | Where-Object { $_.Tab -eq 'Cyber' -and ($vorher -contains $_.Id) -and -not (Hat $_.Id) })
  if (-not $weg.Count) { return }
  Titel 'Cybersicherheit: abgewaehlte Punkte zuruecknehmen'
  $dienstStart = @{ LanmanServer = 2; SSDPSRV = 3; upnphost = 3; RemoteRegistry = 3 }
  foreach ($o in $weg) {
    Schritt "Zurueckgenommen: $($o.Text)" {
      foreach ($r in $o.Reg) {
        if ($r.N -eq 'Start' -and $r.P -match 'Services\\([^\\]+)$' -and $dienstStart.ContainsKey($Matches[1])) { Set-Reg $r.P 'Start' $dienstStart[$Matches[1]] }
        else { Remove-ItemProperty -Path $r.P -Name $r.N -ErrorAction SilentlyContinue }
      }
      if ($o.Id -eq 'C_DNS') { Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue } }
      if ($o.Id -eq 'C_Sandbox') { Disable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -NoRestart -ErrorAction SilentlyContinue | Out-Null }
    }
  }
}
function Einrichtung-Optionen($Tab, $Ohne = @()) {
  Titel $(if ($Tab -eq 'Cyber') { 'Cybersicherheit' } else { $Tab })
  foreach ($o in @($Optionen | Where-Object { $_.Tab -eq $Tab -and -not $_.Konto -and ($_.Reg.Count -or $_.Code) })) {
    if (-not (Hat $o.Id)) { continue }
    if ($Ohne -contains $o.Id) { continue }
    if ($o.Id -eq 'D_EdgeWeg') { continue }   # kommt erst nach den Programmen (Ersatzbrowser)
    if (-not $o.Verfuegbar) { Write-Host "  [--] $($o.Text) (nicht verfuegbar)" -ForegroundColor DarkGray; continue }
    Schritt $o.Text {
      foreach ($r in $o.Reg) { Set-Reg $r.P $r.N $r.W $r.T }
      if ($o.Code) { & $o.Code }
    }
  }
}

function Einrichtung-Apps($Ueberschrift = 'Microsoft-Apps entfernen') {
  Titel $Ueberschrift
  $provAlle = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object { $_.DisplayName })
  foreach ($o in @($Optionen | Where-Object { $_.Tab -eq 'Apps' })) {
    if (-not (Hat $o.Id)) { continue }
    $da = @(foreach ($pk in $o.Pakete) { if ((Get-AppxPackage -AllUsers -Name $pk -ErrorAction SilentlyContinue) -or ($provAlle -contains $pk)) { $pk } })
    if (-not $da.Count) { continue }
    Schritt $o.Text {
      $probleme = @()
      foreach ($pk in $o.Pakete) {
        # Reihenfolge wichtig: erst die Vorlage fuer neue Konten, dann die installierten Kopien.
        # Jedes Paket einzeln absichern, damit ein Fehler nicht die restlichen Pakete der Gruppe ueberspringt.
        foreach ($pv in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $pk })) {
          try { Remove-AppxProvisionedPackage -Online -PackageName $pv.PackageName -ErrorAction Stop | Out-Null }
          catch { if (Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $pk }) { $probleme += "Vorlage $pk" } }
        }
        foreach ($ap in @(Get-AppxPackage -AllUsers -Name $pk -ErrorAction SilentlyContinue)) {
          try { Remove-AppxPackage -Package $ap.PackageFullName -AllUsers -ErrorAction Stop }
          catch { if (Get-AppxPackage -AllUsers -Name $pk -ErrorAction SilentlyContinue) { $probleme += "$pk ($($_.Exception.Message.Trim()))" } }
        }
      }
      if ($o.Id -eq 'A_Xbox') { Set-Reg "$P\GameDVR" 'AllowGameDVR' 0 }
      if ($probleme.Count) { throw ('nicht entfernbar: ' + ($probleme -join '; ')) }
    }
  }
}

function Schreibe-Hive($Root, $Befehl) {
  $ro = "Registry::$Root\Software\Microsoft\Windows\CurrentVersion\RunOnce"
  if (-not (Test-Path $ro)) { New-Item -Path $ro -Force | Out-Null }
  New-ItemProperty -Path $ro -Name 'Einrichtung' -Value $Befehl -PropertyType String -Force | Out-Null
  if (Hat 'D_OneDrive') {
    Remove-ItemProperty -Path "Registry::$Root\Software\Microsoft\Windows\CurrentVersion\Run" -Name 'OneDriveSetup' -ErrorAction SilentlyContinue }
}
function Hive-Laden($Name, $Datei) {
  $ErrorActionPreference = 'Continue'
  $null = & reg.exe load "HKU\$Name" $Datei 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Profil konnte nicht geladen werden: $Datei" }
}
function Hive-Entladen($Name) {
  $ErrorActionPreference = 'Continue'
  for ($i = 0; $i -lt 5; $i++) {
    [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 500
    $null = & reg.exe unload "HKU\$Name" 2>&1
    if ($LASTEXITCODE -eq 0) { return }
  }
  Write-Host "       Hinweis: HKU\$Name liess sich nicht entladen (erledigt sich beim Neustart)." -ForegroundColor DarkYellow
}

function Autostart-Abbauen {
  # Nach dem Ende von Einrichtung/Wartung startet nichts mehr automatisch: kein Fortschrittsfenster beim Anmelden.
  # (Das Autostart-Pruefen in noch nicht angemeldeten Konten macht konto.ps1 einmalig beim ersten Anmelden.)
  if (Get-ScheduledTask -TaskName 'Einrichtung-Nachlauf' -ErrorAction SilentlyContinue) { return }
  Unregister-ScheduledTask -TaskName 'Einrichtung-Fortschritt' -Confirm:$false -ErrorAction SilentlyContinue
  # alte Fassung lief alle 10 Minuten - auf "nur beim Anmelden" umstellen
  $t = Get-ScheduledTask -TaskName 'Einrichtung-Infobereich' -ErrorAction SilentlyContinue
  if ($t -and @($t.Triggers | Where-Object { $_.Repetition -and $_.Repetition.Interval }).Count) {
    try { $n = New-ScheduledTaskTrigger -AtLogOn; $n.Delay = 'PT30S'
          Set-ScheduledTask -TaskName 'Einrichtung-Infobereich' -Trigger $n -ErrorAction Stop | Out-Null } catch {}
  }
}
function Plane-Infobereich {
  Schritt 'Infobereich/Startmenue-Liste: kurze Aufgabe nur beim Anmelden (kein Autostart-Eintrag, kein Dauerlauf)' {
    $arg = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Ziel 'tray.ps1') + '"'
    $aktion = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arg
    $ausl = New-ScheduledTaskTrigger -AtLogOn; $ausl.Delay = 'PT30S'
    $wer = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $einst = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -Priority 7
    Register-ScheduledTask -TaskName 'Einrichtung-Infobereich' -Action $aktion -Trigger $ausl -Principal $wer -Settings $einst -Force | Out-Null
  }
}
function Einrichtung-Kontoeinstellungen {
  Titel 'Einstellungen fuer alle Konten vorbereiten'
  Schritt "Ordner $Ziel angelegt (nur Admins duerfen schreiben)" {
    Ziel-Vorbereiten
    $komfort = @($Optionen | Where-Object { $_.Konto -and (Hat $_.Id) } | ForEach-Object { $_.Id })
    $kontoProg = @($Programme | Where-Object { $_.Konto -and (Hat $_.Id) } | ForEach-Object { $_.WingetId })
    $daten = [ordered]@{ Datum = $script:Cfg.Datum; Profil = $script:Cfg.Profil; Standard = $script:Cfg.Standard; Admin = $script:Cfg.Admin
                         Gewaehlt = $script:Cfg.Gewaehlt; Komfort = $komfort; OneDriveWeg = (Hat 'D_OneDrive')
                         KontoProgramme = $kontoProg; GPU = $script:Cfg.GPU; Edition = $Edition
                         WeitereKonten = @($script:Cfg.WeitereKonten); StdApps = $script:Cfg.StdApps; ExtraIds = @($script:Cfg.ExtraIds) }
    Ohne-Geheimnisse $daten | ConvertTo-Json -Depth 4 | Set-Content -Path $AuswahlDatei -Encoding UTF8
    # Infobereich + Startmenue-Liste: kurzes Skript, laeuft einmal beim Anmelden als Aufgabe
    # (kein dauerhaft laufendes PowerShell und kein Eintrag im Autostart)
    @('# tray.ps1 - zeigt alle Symbole im Infobereich an und haelt die Startmenue-Liste (laeuft kurz und beendet sich)',
      'Get-ChildItem ''HKCU:\Control Panel\NotifyIconSettings'' -ErrorAction SilentlyContinue | ForEach-Object {',
      '  if ((Get-ItemProperty -Path $_.PSPath -Name IsPromoted -ErrorAction SilentlyContinue).IsPromoted -ne 1) {',
      '    Set-ItemProperty -Path $_.PSPath -Name IsPromoted -Value 1 -Type DWord -ErrorAction SilentlyContinue }',
      '}',
      'if ((Get-ItemProperty ''HKCU:\Software\Einrichtung'' -Name StartListe -ErrorAction SilentlyContinue).StartListe -eq 1) {',
      '  $sk = ''HKCU:\Software\Microsoft\Windows\CurrentVersion\Start''',
      '  if ((Get-ItemProperty $sk -Name AllAppsViewMode -ErrorAction SilentlyContinue).AllAppsViewMode -ne 2) {',
      '    if (-not (Test-Path $sk)) { New-Item $sk -Force | Out-Null }',
      '    New-ItemProperty $sk -Name AllAppsViewMode -Value 2 -PropertyType DWord -Force | Out-Null } }',
      'if (-not (Test-Path ''HKCU:\Software\Einrichtung'')) { New-Item ''HKCU:\Software\Einrichtung'' -Force | Out-Null }',
      'New-ItemProperty ''HKCU:\Software\Einrichtung'' -Name TrayLauf -Value (Get-Date -Format s) -PropertyType String -Force | Out-Null'
     ) | Set-Content -Path (Join-Path $Ziel 'tray.ps1') -Encoding UTF8
  }
  if ((Hat 'K_Tray') -or (Hat 'K_StartListe')) { Plane-Infobereich }
  $befehl = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Ziel 'konto.ps1') + '"'
  Schritt 'Vorlage fuer neue Konten (Default-Profil)' {
    Hive-Laden 'EinrDefault' "$env:SystemDrive\Users\Default\NTUSER.DAT"
    try { Schreibe-Hive 'HKEY_USERS\EinrDefault' $befehl } finally { Hive-Entladen 'EinrDefault' }
  }
  $n = 0
  foreach ($pr in @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.SID -like 'S-1-5-21-*' })) {
    $n++
    $nameAnzeige = Split-Path $pr.LocalPath -Leaf
    Schritt "Konto-Profil '$nameAnzeige': Einstellungen beim naechsten Anmelden" {
      if ($pr.Loaded) { Schreibe-Hive "HKEY_USERS\$($pr.SID)" $befehl }
      else {
        $hn = "EinrP$n"
        Hive-Laden $hn (Join-Path $pr.LocalPath 'NTUSER.DAT')
        try { Schreibe-Hive "HKEY_USERS\$hn" $befehl } finally { Hive-Entladen $hn }
      }
    }
  }
}

function Finde-Winget {
  $c = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  # Im Admin-Fenster fehlt oft der Aufruf-Alias - dann direkt aus dem App-Installer-Paket
  $pkg = Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
         Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
  if ($pkg) { $exe = Join-Path $pkg.InstallLocation 'winget.exe'; if (Test-Path $exe) { return $exe } }
  try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch {}
  $c = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $null
}
function Ist-Online {
  try { $t = New-Object System.Net.Sockets.TcpClient; $ok = $t.ConnectAsync('cdn.winget.microsoft.com', 443).Wait(4000); $t.Close(); return $ok }
  catch { return $false }
}
function Warte-AufNetz([string]$Wofuer = 'die Programme') {
  if (Netz-Freigeben) { for ($i = 0; $i -lt 25 -and -not (Ist-Online); $i++) { Start-Sleep -Seconds 1 } }   # Kabel/WLAN braucht ein paar Sekunden
  if (Ist-Online) { return $true }
  [void](Anfrage-Da 'ohne-netz')
  Write-Host "  [i]  Fuer $Wofuer wird Internet gebraucht - WLAN-Liste wird geoeffnet" -ForegroundColor Cyan
  Status -Unter -1 -Schritt "Warte auf Internet fuer $Wofuer" -Hinweis @{ Art = 'netz'; Text = "Für $Wofuer wird jetzt Internet gebraucht.`r`nUnten rechts ist die WLAN-Liste geöffnet: WLAN anklicken -> Verbinden -> Passwort eingeben. Oder ein Netzwerkkabel einstecken. Danach geht es von selbst weiter." }
  try { Start-Process 'ms-availablenetworks:' } catch {}
  while (-not (Ist-Online)) {
    if (Anfrage-Da 'ohne-netz') {
      Status -Hinweis $null
      Write-Host "  [!!] Ohne Internet weiter - $Wofuer spaeter mit Start.cmd nachholen" -ForegroundColor Yellow
      return $false
    }
    Start-Sleep -Seconds 3
  }
  Status -Hinweis $null
  Write-Host '  [OK] Internet verbunden' -ForegroundColor Green
  return $true
}
function Einrichtung-Programme {
  $ids = @($Programme | Where-Object { (Hat $_.Id) -and -not $_.Konto } | ForEach-Object { $_.WingetId }) + @($script:Cfg.ExtraIds)
  $ids = @($ids | Where-Object { $_ } | Select-Object -Unique)
  if (-not $ids.Count) { return }
  Titel 'Programme installieren (winget)'
  if ($script:Probe) { foreach ($id in $ids) { Write-Host "  [Probe] winget install $id" -ForegroundColor DarkGray }; return }
  if (-not (Warte-AufNetz)) { Info 'Programme uebersprungen - spaeter Start.cmd erneut ausfuehren oder winget selbst nutzen.'; return }
  $wg = Finde-Winget
  if (-not $wg) { Write-Host '  [!!] winget nicht gefunden. App-Installer (Microsoft.DesktopAppInstaller) darf nicht entfernt sein.' -ForegroundColor Yellow; $script:Fehler++; return }
  & $wg source update 2>&1 | Out-Null
  $nurKonto = New-Object System.Collections.ArrayList
  $nr = 0
  foreach ($id in $ids) {
    $nr++
    Status -Gesamt ([int](30 + 25 * ($nr - 1) / $ids.Count)) -Unter ([int](100 * ($nr - 1) / $ids.Count)) -Schritt "Programm $nr von $($ids.Count): $id"
    Write-Host "  -> $id" -ForegroundColor Cyan
    & $wg install --id $id --exact --silent --scope machine --accept-package-agreements --accept-source-agreements | Out-Host
    $rc = $LASTEXITCODE
    if ($rc -eq -1978335135 -or $rc -eq -1978335189) { Write-Host "  [OK] $id (schon installiert und aktuell)" -ForegroundColor Green; continue }
    if ($rc -eq -1978335216) {
      # 0x8A150010: kein systemweiter Installer -> gibt es nur pro Konto -> beim ersten Anmelden des Alltagskontos
      Write-Host "  [i] $id gibt es nur pro Konto - wird beim ersten Anmelden des Alltagskontos installiert" -ForegroundColor Gray
      [void]$nurKonto.Add($id); continue
    }
    if ($rc -ne 0) {
      Write-Host '     systemweit nicht moeglich - versuche Standardinstallation' -ForegroundColor DarkYellow
      & $wg install --id $id --exact --silent --accept-package-agreements --accept-source-agreements | Out-Host
      $rc = $LASTEXITCODE
      if ($rc -eq 0) { Write-Host "  [OK] $id (evtl. nur fuer dieses Admin-Konto - pruefen, ob es im Alltagskonto auftaucht)" -ForegroundColor Green }
    } else { Write-Host "  [OK] $id" -ForegroundColor Green }
    if ($rc -ne 0) { Write-Host "  [!!] $id - Fehlercode $rc (oft: kurz nicht erreichbar oder ID falsch)" -ForegroundColor Yellow; $script:Fehler++ }
  }
  if ($nurKonto.Count) {
    Schritt "An das Alltagskonto uebergeben: $($nurKonto -join ', ')" {
      $j = Get-Content $AuswahlDatei -Raw | ConvertFrom-Json
      $j.KontoProgramme = @(@($j.KontoProgramme) + @($nurKonto) | Where-Object { $_ } | Select-Object -Unique)
      $j | ConvertTo-Json -Depth 4 | Set-Content -Path $AuswahlDatei -Encoding UTF8
    }
  }
}
function Finde-Exe($Namen, $Muster, $Endungen) {
  foreach ($n in @($Namen)) {
    foreach ($ap in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$n", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$n")) {
      $p = (Get-ItemProperty -Path $ap -ErrorAction SilentlyContinue).'(default)'
      if ($p) { $p = $p.Trim('"'); if (Test-Path $p) { return $p } }
    }
  }
  $wurzeln = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path $_) }
  foreach ($n in @($Namen)) {
    foreach ($w in $wurzeln) {
      $f = Get-ChildItem -Path $w -Filter $n -Recurse -Depth 4 -File -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($f) { return $f.FullName }
    }
  }
  # Programme, die nichts registrieren: ueber "Apps & Features" (Deinstallations-Eintraege) suchen
  if ($Muster) {
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
      foreach ($e in @(Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $Muster })) {
        $ic = ([string]$e.DisplayIcon -split ',')[0].Trim('"')
        if ($ic -like '*.exe' -and (Test-Path $ic)) { return $ic }
        if ($e.InstallLocation -and (Test-Path $e.InstallLocation)) {
          $f = Get-ChildItem -Path $e.InstallLocation -Filter '*.exe' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
               Where-Object { $x = $_.Name; @($Namen | Where-Object { $x -like ($_ -replace '\.exe$', '*.exe') }).Count } | Select-Object -First 1
          if ($f) { return $f.FullName }
        }
      }
    }
    # Programmordner, deren Name passt (z. B. "C:\Program Files\PDF-XChange") - die groesste passende Programmdatei
    foreach ($w in $wurzeln) {
      foreach ($d in @(Get-ChildItem -Path $w -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $Muster })) {
        $exes = @(Get-ChildItem -Path $d.FullName -Filter '*.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notmatch 'unins|setup|update|install|helper|crash|report|service|svc|host|broker|plugin|ocr|conv|print' })
        $f = $exes | Where-Object { $x = $_.Name; @($Namen | Where-Object { $x -like $_ }).Count } | Select-Object -First 1
        if (-not $f) { $f = $exes | Where-Object { [string]$_.VersionInfo.FileDescription -match 'Editor|Viewer|Reader' } | Sort-Object Length -Descending | Select-Object -First 1 }
        if ($f) { return $f.FullName }
      }
    }
    # Oeffnen-Befehle der Dateitypen (z. B. .pdf -> OpenWithProgids), in denen der Programmname vorkommt
    foreach ($e in @($Endungen | Where-Object { $_ -and $_.StartsWith('.') })) {
      $ow = Get-Item -Path "HKLM:\SOFTWARE\Classes\$e\OpenWithProgids" -ErrorAction SilentlyContinue
      if (-not $ow) { continue }
      foreach ($pg in $ow.GetValueNames()) {
        if (-not $pg) { continue }
        $cmd = [string](Get-ItemProperty -Path "HKLM:\SOFTWARE\Classes\$pg\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
        if (-not $cmd -or $cmd -notmatch $Muster) { continue }
        $p = $null
        if ($cmd -match '^\s*"([^"]+?\.exe)"') { $p = $Matches[1] } elseif ($cmd -match '^\s*(\S+?\.exe)') { $p = $Matches[1] }
        if ($p -and (Test-Path $p)) { return $p }
      }
    }
  }
  return $null
}
function Finde-Faehigkeiten($Muster) {
  # Programme melden ihre Dateitypen unter RegisteredApplications -> Capabilities (so macht es auch "Standard-Apps" in Windows)
  foreach ($root in @('HKLM:\SOFTWARE\RegisteredApplications', 'HKLM:\SOFTWARE\WOW6432Node\RegisteredApplications')) {
    $k = Get-Item -Path $root -ErrorAction SilentlyContinue
    if (-not $k) { continue }
    foreach ($n in $k.GetValueNames()) { if ($n -match $Muster) { return ('HKLM:\' + $k.GetValue($n)) } }
  }
  return $null
}
function ProgId-Fuer($Endung, $Faehig, $Exe) {
  if ($Faehig) {
    $unter = if ($Endung.StartsWith('.')) { 'FileAssociations' } else { 'URLAssociations' }
    $p = Get-Reg "$Faehig\$unter" $Endung
    if ($p -ne 'fehlt' -and $p -and (Test-Path "HKLM:\SOFTWARE\Classes\$p")) { return $p }
  }
  if ($Exe -and $Endung.StartsWith('.')) {
    $ow = Get-Item -Path "HKLM:\SOFTWARE\Classes\$Endung\OpenWithProgids" -ErrorAction SilentlyContinue
    if ($ow) {
      $exeName = Split-Path $Exe -Leaf
      foreach ($pg in $ow.GetValueNames()) {
        if (-not $pg) { continue }
        $cmd = Get-Reg "HKLM:\SOFTWARE\Classes\$pg\shell\open\command" '(default)'
        if ($cmd -ne 'fehlt' -and $cmd -like "*$exeName*") { return $pg }
      }
    }
  }
  return $null
}
function Eigene-ProgId($Rolle, $App, $Exe) {
  # Fallback, wenn das Programm selbst keine Dateitypen anmeldet (z. B. 7-Zip): eigener Typ "Einrichtung.<Rolle>"
  $id = "Einrichtung.$($Rolle.Key)"; $k = "HKLM:\SOFTWARE\Classes\$id"
  Set-Reg $k '(default)' "$($Rolle.Name) - $($App.Name)" 'String'
  Set-Reg $k 'URL Protocol' '' 'String'
  Set-Reg "$k\DefaultIcon" '(default)' "`"$Exe`",0" 'String'
  Set-Reg "$k\shell\open\command" '(default)' ($App.Befehl.Replace('%EXE%', $Exe)) 'String'
  foreach ($e in $Rolle.Endungen) { if ($e.StartsWith('.')) { Set-Reg "HKLM:\SOFTWARE\Classes\$e\OpenWithProgids" $id '' 'String' } }
  return $id
}
function Einrichtung-Standardapps {
  $wahl = $script:Cfg.StdApps
  if (-not $wahl) { return }
  Titel 'Standard-Apps (welches Programm oeffnet welche Dateien)'
  $datei = Join-Path $Ziel 'Standardapps.xml'
  $zeilen = New-Object System.Collections.ArrayList
  foreach ($r in $StdRollen) {
    $w = [string]$wahl.($r.Key)
    if (-not $w -or $w -eq 'Nicht aendern') { continue }
    if ($w -eq 'Automatisch') {
      # zuerst die im Reiter Programme angehakten (in Listenreihenfolge), dann bereits installierte
      $gew = @($r.Kandidaten | Where-Object { @($_.Ids | Where-Object { Hat "W:$_" }).Count })
      $kand = @($gew) + @($r.Kandidaten | Where-Object { $gew -notcontains $_ })
    } else { $kand = @($r.Kandidaten | Where-Object { $_.Name -eq $w }) }
    if ($script:Probe) {
      $treffer = @($kand | Where-Object { $k = $_; @($k.Ids | Where-Object { Hat "W:$_" }).Count }) | Select-Object -First 1
      $name = if ($treffer) { $treffer.Name } else { '(erstes installiertes Programm)' }
      Write-Host "  [Probe] $($r.Name) -> $name" -ForegroundColor DarkGray; continue
    }
    $gefunden = $null
    foreach ($k in $kand) {
      $faehig = Finde-Faehigkeiten $k.RegApp
      $exe = if ($k.Exe.Count) { Finde-Exe $k.Exe $k.RegApp $r.Endungen } else { $null }
      if ($faehig -or $exe) { $gefunden = @{ App = $k; Faehig = $faehig; Exe = $exe }; break }
    }
    if (-not $gefunden) {
      $gew0 = @($kand | Where-Object { @($_.Ids | Where-Object { Hat "W:$_" }).Count } | ForEach-Object { $_.Name })
      if ($gew0.Count) { Write-Host "  [!!] $($r.Name): $($gew0[0]) ist angehakt, die Programmdatei wurde aber nicht gefunden" -ForegroundColor Yellow; $script:Fehler++ }
      else { Info "$($r.Name): kein passendes Programm installiert - bleibt wie es ist" }
      continue
    }
    $app = $gefunden.App; $n = 0; $eigen = $null
    foreach ($e in $r.Endungen) {
      $pg = ProgId-Fuer $e $gefunden.Faehig $gefunden.Exe
      if (-not $pg -and $gefunden.Exe) {
        if (-not $eigen) { $eigen = Eigene-ProgId $r $app $gefunden.Exe }
        $pg = $eigen
      }
      if ($pg) { [void]$zeilen.Add(('  <Association Identifier="{0}" ProgId="{1}" ApplicationName="{2}" />' -f $e,
                   [Security.SecurityElement]::Escape($pg), [Security.SecurityElement]::Escape($app.Name))); $n++ }
    }
    if ($n) { Write-Host "  [OK] $($r.Name) -> $($app.Name) ($n Typen)" -ForegroundColor Green }
    else { Write-Host "  [!!] $($r.Name) -> $($app.Name): keine Zuordnung moeglich" -ForegroundColor Yellow; $script:Fehler++ }
  }
  if ($script:Probe) { return }
  $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
  if (-not $zeilen.Count) {
    Remove-ItemProperty -Path $pol -Name 'DefaultAssociationsConfiguration' -ErrorAction SilentlyContinue
    Remove-Item $datei -Force -ErrorAction SilentlyContinue
    return
  }
  Schritt 'Zuordnungen gespeichert und fuer alle Konten aktiviert (wirkt ab dem naechsten Anmelden)' {
    @('<?xml version="1.0" encoding="UTF-8"?>', '<DefaultAssociations>') + @($zeilen) + @('</DefaultAssociations>') |
      Set-Content -Path $datei -Encoding UTF8
    # neue Konten: Vorlage; bestehende Konten: Richtlinie, wird bei jedem Anmelden angewendet
    & dism.exe /Online /Import-DefaultAppAssociations:"$datei" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "DISM-Fehlercode $LASTEXITCODE" }
    Set-Reg $pol 'DefaultAssociationsConfiguration' $datei 'String'
    if ((Get-Reg 'HKLM:\SOFTWARE\Einrichtung' 'StdImportErst') -eq 'fehlt') { Set-Reg 'HKLM:\SOFTWARE\Einrichtung' 'StdImportErst' (Get-Date -Format s) 'String' }
  }
}
function Lege-Link($Name, $Url) {
  $datei = Join-Path "$env:PUBLIC\Desktop" "$Name.url"
  @('[InternetShortcut]', "URL=$Url") | Set-Content -Path $datei -Encoding ASCII
}
function Hersteller-Url {
  switch -Regex ($Hersteller) {
    '^HP|Hewlett' { return 'https://support.hp.com/de-de/drivers' }
    'Lenovo'      { return 'https://pcsupport.lenovo.com/de/de' }
    'Dell'        { return 'https://www.dell.com/support/home/de-de' }
    'ASUS'        { return 'https://www.asus.com/de/support/download-center/' }
    'Acer'        { return 'https://www.acer.com/de-de/support/drivers-and-manuals' }
    'Micro-Star|MSI' { return 'https://de.msi.com/support/download' }
    'Gigabyte'    { return 'https://www.gigabyte.com/de/Support' }
  }
  return $null
}
function Einrichtung-Treiber {
  Titel 'Treiber'
  $gpu = $script:Cfg.GPU
  if ((Hat 'G_Stick') -and $gpu -ne 'Keine') {
    $ordner = Join-Path $Basis 'Treiber'
    $exe = @(Get-ChildItem $ordner -Filter '*.exe' -ErrorAction SilentlyContinue)
    if ($exe.Count) {
      foreach ($x in $exe) {
        if ($gpu -eq 'AMD') { Info 'AMD-Installer: "Nur Treiber" bzw. "Minimal" waehlen, keine Zusatzsoftware.' }
        if ($gpu -eq 'NVIDIA') { Info 'NVIDIA-Installer: "Benutzerdefiniert" -> nur Grafiktreiber (+ PhysX), NVIDIA App optional.' }
        Schritt "Treiber-Installer $($x.Name) gestartet" { Start-Process $x.FullName -Wait }
      }
    } else { Info "Kein Installer im Ordner $ordner gefunden - uebersprungen." }
  }
  if ((Hat 'G_Link') -and $gpu -ne 'Keine') {
    if ($gpu -eq 'AMD') { Schritt 'Desktop-Link: AMD-Treiber' { Lege-Link 'AMD-Treiber herunterladen' 'https://www.amd.com/de/support/download/drivers.html' } }
    if ($gpu -eq 'NVIDIA') { Schritt 'Desktop-Link: NVIDIA-Treiber' { Lege-Link 'NVIDIA-Treiber herunterladen' 'https://www.nvidia.com/de-de/drivers/' } }
    if ($CpuName -match 'AMD') { Schritt 'Desktop-Link: AMD-Chipsatztreiber (bei X3D wichtig fuers Kern-Parken)' {
      Lege-Link 'AMD-Chipsatztreiber herunterladen' 'https://www.amd.com/de/support/download/drivers.html' } }
  }
  if (Hat 'G_Herst') {
    $url = Hersteller-Url
    if ($url) { Schritt "Desktop-Link: Treiberseite $Hersteller" { Lege-Link "Treiber $Hersteller" $url } }
    else { Info "Hersteller '$Hersteller' unbekannt - kein Link angelegt." }
  }
}

function Einrichtung-LocalSend {
  if (-not (Hat 'W:LocalSend.LocalSend')) { return }
  Titel 'LocalSend'
  Schritt 'Firewall: LocalSend (Port 53317) nur fuer Geraete im eigenen Netz geoeffnet' {
    Get-NetFirewallRule -DisplayName 'LocalSend (nur lokales Netz)*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    foreach ($proto in 'TCP', 'UDP') {
      New-NetFirewallRule -DisplayName "LocalSend (nur lokales Netz) Port $proto" -Direction Inbound -Protocol $proto -LocalPort 53317 `
        -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
    }
    # Zusaetzlich eine Regel fuers Programm selbst - verhindert die Firewall-Rueckfrage beim ersten Start
    $exe = Get-ChildItem "$env:ProgramFiles\LocalSend", "${env:ProgramFiles(x86)}\LocalSend" -Filter 'localsend*.exe' -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -notmatch 'unins' } | Select-Object -First 1
    if ($exe) {
      New-NetFirewallRule -DisplayName 'LocalSend (nur lokales Netz) Programm' -Direction Inbound -Program $exe.FullName `
        -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
    }
  }
}

function Finde-Verknuepfung($Muster) {
  $sm = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
  Get-ChildItem $sm -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -like $Muster } | Select-Object -First 1
}
function Einrichtung-Oberflaeche {
  $teile = @('K_TaskPins', 'K_StartPins', 'K_StartKlein', 'K_Desktop') | Where-Object { Hat $_ }
  if (-not $teile) { return }
  Titel 'Taskleiste, Startmenue, Desktop (systemweiter Teil)'
  # Gewuenschter Browser = erster angehakter in dieser Reihenfolge, dessen Verknuepfung existiert
  $browser = $null
  $bListe = @(@('W:Mozilla.Firefox.de', 'Firefox'), @('W:Mozilla.Firefox.ESR', 'Firefox*'), @('W:LibreWolf.LibreWolf', 'LibreWolf'),
              @('W:Brave.Brave', 'Brave'), @('W:Vivaldi.Vivaldi', 'Vivaldi'), @('W:Waterfox.Waterfox', 'Waterfox*'), @('W:Ablaze.Floorp', 'Floorp*'),
              @('W:Zen-Team.Zen-Browser', 'Zen*'), @('W:ImputNet.Helium', 'Helium*'), @('W:MullvadVPN.MullvadBrowser', 'Mullvad Browser*'),
              @('W:Hibbiki.Chromium', 'Chromium*'), @('W:eloston.ungoogled-chromium', 'Chromium*'), @('W:Google.Chrome', 'Google Chrome'))
  foreach ($b in $bListe) { if (-not $browser -and (Hat $b[0])) { $browser = Finde-Verknuepfung $b[1] } }   # zuerst: in diesem Lauf gewaehlt
  foreach ($b in $bListe) { if (-not $browser) { $browser = Finde-Verknuepfung $b[1] } }                   # sonst: bereits installiert
  if (Hat 'K_TaskPins') {
    Schritt "Taskleiste: Explorer$(if ($browser) { ' + ' + $browser.BaseName } else { ' (kein Browser gefunden)' }), Edge/Store/Outlook entfernt" {
      $pins = @('        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" PinGeneration="1"/>')
      if ($browser) { $pins += ('        <taskbar:DesktopApp DesktopApplicationLinkPath="' + $browser.FullName + '" PinGeneration="1"/>') }
      $xml = @('<?xml version="1.0" encoding="utf-8"?>',
        '<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">',
        '  <CustomTaskbarLayoutCollection PinListPlacement="Replace">',
        '    <defaultlayout:TaskbarLayout>',
        '      <taskbar:TaskbarPinList>') + $pins + @(
        '      </taskbar:TaskbarPinList>',
        '    </defaultlayout:TaskbarLayout>',
        '  </CustomTaskbarLayoutCollection>',
        '</LayoutModificationTemplate>')
      $datei = Join-Path $Ziel 'Taskleiste.xml'
      $xml | Set-Content -Path $datei -Encoding UTF8
      Set-Reg "$P\Explorer" 'StartLayoutFile' $datei 'ExpandString'
      Set-Reg "$P\Explorer" 'LockedStartLayout' 1
    }
  }
  if ((Hat 'K_StartPins') -and -not $IstHome) {
    Schritt 'Startmenue: Anheftungen = Explorer, Einstellungen und deine Programme' {
      $eintraege = @('{"desktopAppId":"Microsoft.Windows.Explorer"}',
                     '{"packagedAppId":"windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"}')
      $muster = @()
      if ($browser) { $muster += $browser.BaseName }
      foreach ($m in @(@('W:TheDocumentFoundation.LibreOffice', 'LibreOffice Writer'), @('W:TheDocumentFoundation.LibreOffice', 'LibreOffice Calc'),
                       @('W:ONLYOFFICE.DesktopEditors', 'ONLYOFFICE*'), @('W:Mozilla.Thunderbird.de', 'Thunderbird'),
                       @('W:SumatraPDF.SumatraPDF', 'SumatraPDF'), @('W:TrackerSoftware.PDF-XChangeEditor', 'PDF-XChange Editor'),
                       @('W:IrfanSkiljan.IrfanView', 'IrfanView*'), @('W:KeePassXCTeam.KeePassXC', 'KeePassXC'),
                       @('W:Notepad++.Notepad++', 'Notepad++'), @('W:VideoLAN.VLC', 'VLC media player'),
                       @('W:LocalSend.LocalSend', 'LocalSend'), @('W:Valve.Steam', 'Steam'))) {
        $muster += $m[1]   # nur was tatsaechlich installiert ist, wird gefunden und angeheftet
      }
      foreach ($m in $muster) {
        $l = Finde-Verknuepfung $m
        if ($l) { $eintraege += ('{"desktopAppLink":"' + ($l.FullName -replace '\\', '\\') + '"}') }
      }
      $json = '{"pinnedList":[' + ($eintraege -join ',') + ']}'
      $prov = 'B5292708-1619-419B-9923-E5D9F3925E71'
      $pm = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'
      Set-Reg $pm 'ConfigureStartPins' $json 'String'
      Set-Reg $pm 'ConfigureStartPins_ProviderSet' 1
      Set-Reg $pm 'ConfigureStartPins_WinningProvider' $prov 'String'
      $pv = "HKLM:\SOFTWARE\Microsoft\PolicyManager\providers\$prov\default\Device\Start"
      Set-Reg $pv 'ConfigureStartPins' $json 'String'
      Set-Reg $pv 'ConfigureStartPins_LastWrite' 1
    }
  }
  if (Hat 'K_StartKlein') {
    Schritt 'Startmenue: Bereich "Empfohlen" per Richtlinie aus' { Set-Reg "$P\Explorer" 'HideRecommendedSection' 1 }
  }
  if (Hat 'K_Desktop') {
    Schritt 'Desktop (alle Konten): Verknuepfungen entfernt, Edge legt keine neuen an' {
      Get-ChildItem "$env:PUBLIC\Desktop\*" -Include '*.lnk', '*.url' -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*Treiber*' } | Remove-Item -Force
      Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'CreateDesktopShortcutDefault' 0
    }
  }
}

function Einrichtung-EdgeWeg {
  if (-not (Hat 'D_EdgeWeg')) { return }
  Titel 'Edge entfernen'
  $ersatz = @("$env:ProgramFiles\Mozilla Firefox\firefox.exe", "$env:ProgramFiles\LibreWolf\librewolf.exe",
              "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe", "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") |
            Where-Object { Test-Path $_ }
  # jeder andere als Browser angemeldete Browser zaehlt auch (Vivaldi, Zen, Waterfox ...)
  $ersatz = @($ersatz) + @(Get-ChildItem 'HKLM:\SOFTWARE\Clients\StartMenuInternet', 'HKLM:\SOFTWARE\WOW6432Node\Clients\StartMenuInternet' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -notmatch 'Edge|IEXPLORE' } | ForEach-Object { $_.PSChildName })
  $ersatz = @($ersatz | Where-Object { $_ })
  if (-not $script:Probe -and -not $ersatz) {
    Write-Host '  [!!] Kein anderer Browser installiert - Edge bleibt, sonst haettest du keinen Browser mehr.' -ForegroundColor Yellow
    $script:Fehler++; return
  }
  $msedge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
  if (-not (Test-Path $msedge)) { Write-Host '  [OK] Edge ist nicht installiert' -ForegroundColor Green; return }
  $abg = Get-Reg 'HKLM:\SOFTWARE\Einrichtung' 'EdgeAbgelehnt'
  if (-not $script:Probe -and $abg -ne 'fehlt' -and $abg -eq [string](Get-Item $msedge).VersionInfo.ProductVersion) {
    Info "Edge: Microsoft hat das Entfernen fuer Version $abg schon abgelehnt - neuer Versuch erst nach dem naechsten Edge-Update. Edge ist nicht Standard."
    return
  }
  $o = $Optionen | Where-Object { $_.Id -eq 'D_EdgeWeg' }
  Schritt $o.Text { & $o.Code }
}

# ---------------------------------------------------------------- Pruefung
function Pruef-Alles([switch]$OhneKonten) {
  if (-not (Test-Path $AuswahlDatei)) { Write-Host 'Keine angewendete Auswahl gefunden - zuerst die Einrichtung ausfuehren.' -ForegroundColor Yellow; return }
  $cfg = Get-Content $AuswahlDatei -Raw | ConvertFrom-Json
  $gew = @($cfg.Gewaehlt)
  $script:Ok = 0; $script:Abw = 0
  Titel 'System'
  Info "Edition $Edition, Version $Version, Build $Build.$($cv.UBR), Profil '$($cfg.Profil)' vom $($cfg.Datum)"
  Titel 'Konten'
  Pruefe 'Eingebautes Administrator-Konto deaktiviert' (Get-LocalUser | Where-Object { $_.SID -like '*-500' }).Enabled 'False'
  Pruefe 'Gastkonto deaktiviert' (Get-LocalUser | Where-Object { $_.SID -like '*-501' }).Enabled 'False'
  $u = Get-LocalUser -Name $cfg.Standard -ErrorAction SilentlyContinue
  Pruefe "Alltagskonto '$($cfg.Standard)' vorhanden" ([bool]$u) 'True'
  try {
    $adm = @((Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop).Name)
    Pruefe "'$($cfg.Standard)' ist kein Administrator" ([bool]($adm -match ('\\' + [regex]::Escape($cfg.Standard) + '$'))) 'False'
  } catch { Info 'Admin-Gruppe nicht lesbar' }
  foreach ($w in @($cfg.WeitereKonten)) {
    if (-not $w.Name) { continue }
    Pruefe "Weiteres Konto '$($w.Name)' vorhanden" ([bool](Get-LocalUser -Name $w.Name -ErrorAction SilentlyContinue)) 'True'
    try {
      $adm2 = @((Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop).Name)
      Pruefe "'$($w.Name)' Adminrechte wie gewaehlt" ([bool]($adm2 -match ('\\' + [regex]::Escape($w.Name) + '$'))) ([string][bool]$w.Admin)
    } catch {}
  }
  foreach ($tab in 'Sicherheit', 'Cyber', 'Datenschutz', 'Updates', 'Komfort', 'Grafik') {
    if ($tab -eq 'Grafik' -and $cfg.GPU -eq 'Keine') { continue }
    $liste = @($Optionen | Where-Object { $_.Tab -eq $tab -and ($gew -contains $_.Id) -and ($_.Reg.Count -or $_.Check) })
    if (-not $liste.Count) { continue }
    Titel $(if ($tab -eq 'Cyber') { 'Cybersicherheit' } else { $tab })
    foreach ($o in $liste) {
      foreach ($r in $o.Reg) { Pruefe "$($o.Id): $($r.N)" (Get-Reg $r.P $r.N) $r.W }
      if ($o.Check) { & $o.Check }
    }
  }
  $ob = @()
  if ($gew -contains 'K_TaskPins') { $ob += ,@('Taskleisten-Layout als Richtlinie', ([bool]((Get-Reg "$P\Explorer" 'StartLayoutFile') -ne 'fehlt' -and (Test-Path (Join-Path $Ziel 'Taskleiste.xml'))))) }
  if ($gew -contains 'K_StartPins' -and -not $IstHome) { $ob += ,@('Startmenue-Anheftungen als Richtlinie', ([bool]((Get-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins') -ne 'fehlt'))) }
  if ($gew -contains 'K_StartKlein') { $ob += ,@('Startmenue: Empfohlen ausgeblendet', ((Get-Reg "$P\Explorer" 'HideRecommendedSection') -eq 1)) }
  if ($gew -contains 'K_Desktop') { $ob += ,@('Edge legt keine Desktop-Verknuepfung an', ((Get-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'CreateDesktopShortcutDefault') -eq 0)) }
  if ($gew -contains 'K_Tray' -or $gew -contains 'K_StartListe') {
    $ob += ,@('Infobereich/Startmenue-Liste: Skript und Aufgabe vorhanden (kein Autostart-Eintrag)', ((Test-Path (Join-Path $Ziel 'tray.ps1')) -and [bool](Get-ScheduledTask -TaskName 'Einrichtung-Infobereich' -ErrorAction SilentlyContinue)))
  }
  if (-not (Get-ScheduledTask -TaskName 'Einrichtung-Nachlauf' -ErrorAction SilentlyContinue)) {
    $ob += ,@('Einrichtung fertig: Fortschrittsfenster startet nicht mehr beim Anmelden', (-not (Get-ScheduledTask -TaskName 'Einrichtung-Fortschritt' -ErrorAction SilentlyContinue)))
  }
  if ($ob.Count) {
    Titel 'Taskleiste, Startmenue, Desktop'
    foreach ($e in $ob) { Pruefe $e[0] ([bool]$e[1]) 'True' }
  }
  Titel 'Microsoft-Apps'
  $rest = @()
  foreach ($o in @($Optionen | Where-Object { $_.Tab -eq 'Apps' -and ($gew -contains $_.Id) })) {
    foreach ($pk in $o.Pakete) { if (Get-AppxPackage -AllUsers -Name $pk -ErrorAction SilentlyContinue) { $rest += $pk } } }
  Pruefe 'Entfernte Apps nicht wieder da' $rest.Count 0
  if ($rest.Count) { Info "Wieder vorhanden: $($rest -join ', ')" }
  $geh = @(foreach ($o in (Profil-Ordner)) { Get-ChildItem -Path $o -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { (Get-Content $_.FullName -Raw) -match '"(Pw|Pass[^"]*|Passwort[^"]*|Kennwort[^"]*|Key|Produktkey)"\s*:' } })
  Titel 'Profile'
  Pruefe 'Gespeicherte Profile enthalten keine Passwoerter' $geh.Count 0
  Titel 'Lizenz'
  $lp = $null; try { $lp = Lizenz-Produkt } catch {}
  Pruefe 'Windows aktiviert' ([bool]($lp -and $lp.LicenseStatus -eq 1)) 'True'
  Titel 'Programme'
  $pw = @($Programme | Where-Object { $gew -contains $_.Id } | ForEach-Object { $_.WingetId })
  if ($pw.Count) { Info "Ausgewaehlt: $($pw -join ', ')  - Kontrolle: winget list" }
  $sx = Join-Path $Ziel 'Standardapps.xml'
  if (Test-Path $sx) {
    Titel 'Standard-Apps'
    Pruefe 'Richtlinie fuer Standard-Apps aktiv' (Get-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'DefaultAssociationsConfiguration') $sx
    $zu = @(([xml](Get-Content $sx -Raw)).DefaultAssociations.Association)
    foreach ($g in @($zu | Group-Object ProgId)) {
      Pruefe "$($g.Group[0].ApplicationName): Dateityp $($g.Name) vorhanden ($($g.Count) Endungen)" (Test-Path "HKLM:\SOFTWARE\Classes\$($g.Name)") 'True'
    }
    Info 'Ob die Zuordnung im Konto greift, zeigt Pruefen.cmd im Alltagskonto.'
  }
  if ($gew -contains 'W:LocalSend.LocalSend') {
    Pruefe 'LocalSend-Firewallregeln (nur lokales Netz)' ([bool](@(Get-NetFirewallRule -DisplayName 'LocalSend (nur lokales Netz)*' -ErrorAction SilentlyContinue).Count -ge 2)) 'True'
  }
  if (-not $OhneKonten) { Konten-Pruefen }
  Write-Host ''
  $farbe = if ($script:Abw -eq 0) { 'Green' } else { 'Yellow' }
  Write-Host "Ergebnis: $script:Ok OK, $script:Abw Abweichung(en). Es wurde nichts veraendert." -ForegroundColor $farbe
  try { Set-Reg 'HKLM:\SOFTWARE\Einrichtung' 'LetztePruefung' ("{0}: {1} OK, {2} Abweichung(en)" -f (Get-Date -Format 'dd.MM.yyyy HH:mm'), $script:Ok, $script:Abw) 'String' } catch {}
  if ($OhneKonten) { Info 'Konto-Einstellungen werden beim ersten Anmelden gesetzt und spaeter mitgeprueft.' }
}

function Einrichtung-Lizenz {
  if (-not $script:Pw.ContainsKey('Key')) { return }
  Titel 'Windows-Lizenz'
  if ($script:Probe) { Write-Host '  [Probe] Produktkey eintragen und online aktivieren' -ForegroundColor DarkGray; return }
  $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:Pw['Key']))
  try {
    Schritt 'Produktkey eingetragen (wird nicht gespeichert)' {
      $svc = Get-CimInstance SoftwareLicensingService
      Invoke-CimMethod -InputObject $svc -MethodName InstallProductKey -Arguments @{ ProductKey = $key } | Out-Null
      Invoke-CimMethod -InputObject $svc -MethodName RefreshLicenseStatus | Out-Null
    }
  } finally { $key = $null; $script:Pw.Remove('Key') }
  if (-not (Ist-Online)) { [void](Warte-AufNetz 'die Aktivierung') }
  Schritt 'Windows online aktiviert' { Invoke-CimMethod -InputObject (Lizenz-Produkt) -MethodName Activate | Out-Null }
  Info 'Passt der Key nicht zur Edition (z. B. Pro-Key auf Home): Einstellungen -> System -> Aktivierung -> Product Key aendern.'
}
function Einrichtung-StoreUpdates {
  if (-not (Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsStore' -ErrorAction SilentlyContinue)) { Info 'Microsoft Store ist entfernt - keine Store-Updates'; return }
  Status -Unter -1 -Schritt 'Microsoft-Store-Apps werden aktualisiert ...'
  Schritt 'Store-App-Updates angestossen (kostenlos, ohne Anmeldung; laufen im Hintergrund weiter)' {
    Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' |
      Invoke-CimMethod -MethodName UpdateScanMethod | Out-Null
  }
  Start-Sleep -Seconds 120   # den Downloads etwas Vorsprung lassen
}

# ---------------------------------------------------------------- Automatischer Nachlauf
function Melde($Text) {
  Write-Host $Text -ForegroundColor Cyan
  try { & "$env:SystemRoot\System32\msg.exe" * /TIME:86400 $Text 2>$null } catch {}
}
function Plane-Nachlauf {
  Schritt 'Automatischer Nachlauf geplant: nach dem Neustart Updates, Store, Pruefung' {
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Ziel 'setup.ps1') + '" -Nachlauf'
    $aktion = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $ausl = New-ScheduledTaskTrigger -AtStartup; $ausl.Delay = 'PT1M'
    $wer = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $einst = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    Register-ScheduledTask -TaskName 'Einrichtung-Nachlauf' -Action $aktion -Trigger $ausl -Principal $wer -Settings $einst -Force | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Einrichtung' 'Durchlauf' 0
  }
  Schritt 'Fortschrittsfenster nach jedem Anmelden - nur bis zum Ende, danach wird die Aufgabe entfernt' {
    $arg = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $Ziel 'fortschritt.ps1') + '"'
    $aktion = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arg
    $ausl = New-ScheduledTaskTrigger -AtLogOn; $ausl.EndBoundary = (Get-Date).AddDays(14).ToString('yyyy-MM-ddTHH:mm:ss')
    $wer = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $einst = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Parallel `
               -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -DeleteExpiredTaskAfter (New-TimeSpan -Days 1)
    Register-ScheduledTask -TaskName 'Einrichtung-Fortschritt' -Action $aktion -Trigger $ausl -Principal $wer -Settings $einst -Force | Out-Null
  }
}
function Installiere-Updates([int]$Von = 68, [int]$Bis = 80, [switch]$Windows, [switch]$Optional, [switch]$Treiber) {
  # gibt $true zurueck, wenn ein Neustart noetig ist; installiert Update fuer Update, damit der Fortschritt sichtbar ist
  $sitzung = New-Object -ComObject Microsoft.Update.Session
  $sitzung.ClientApplicationID = 'Windows-Einrichtung'
  $neustart = $false; $fehlUpd = 0
  for ($runde = 1; $runde -le 3; $runde++) {
    Status -Unter -1 -Schritt "Suche nach Updates (Runde $runde) ..."
    Info "Suche nach Updates (Runde $runde) ..."
    $treffer = $sitzung.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
    $liste = New-Object System.Collections.ArrayList
    foreach ($u in $treffer.Updates) {
      $istTreiber = ($u.Type -eq 2)
      if ($istTreiber) {
        if (-not $Treiber -and -not $Windows) { continue }
        if ($u.BrowseOnly -and -not ($Optional -or $Treiber)) { continue }     # optionale Treiber nur, wenn gewaehlt
      } else {
        if (-not $Windows) { continue }
        if ($u.BrowseOnly -and -not $Optional) { continue }                   # optionale Vorschau-Updates nur, wenn gewaehlt
      }
      if ($u.Title -match 'Firmware|BIOS' -or [string]$u.DriverClass -match 'Firmware') {
        Info "Firmware/BIOS bewusst nicht automatisch: $($u.Title) - bei Bedarf am Netzteil unter Windows Update -> Optionale Updates"; continue }
      if ($u.InstallationBehavior.CanRequestUserInput -and -not $istTreiber) { Info "Uebersprungen (braucht Eingaben): $($u.Title)"; continue }
      [void]$liste.Add($u)
    }
    if ($liste.Count -eq 0) { Write-Host '  [OK] Keine weiteren Updates - Windows ist aktuell' -ForegroundColor Green; return $neustart }
    Info "$($liste.Count) Update(s) gefunden"
    $i = 0
    foreach ($u in $liste) {
      $i++
      Status -Gesamt ([int]($Von + ($Bis - $Von) * ($i - 1) / $liste.Count)) -Unter ([int](100 * ($i - 1) / $liste.Count)) -Schritt "Update $i von $($liste.Count): $($u.Title)"
      try {
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        $eins = New-Object -ComObject Microsoft.Update.UpdateColl; [void]$eins.Add($u)
        if (-not $u.IsDownloaded) { $lader = $sitzung.CreateUpdateDownloader(); $lader.Updates = $eins; [void]$lader.Download() }
        $inst = $sitzung.CreateUpdateInstaller(); $inst.ForceQuiet = $true; $inst.Updates = $eins
        $erg = $inst.Install()
        if ($erg.ResultCode -eq 2 -or $erg.ResultCode -eq 3) {
          Write-Host "  [OK] $($u.Title)" -ForegroundColor Green
          if ($erg.RebootRequired) { $neustart = $true }
        } else { Write-Host "  [!!] $($u.Title) - Ergebnis-Code $($erg.ResultCode)" -ForegroundColor Yellow; $fehlUpd++ }
      } catch { Write-Host "  [!!] $($u.Title) - $($_.Exception.Message)" -ForegroundColor Yellow; $fehlUpd++ }
    }
    if ($neustart) {
      if ($fehlUpd) { Info "$fehlUpd Update(s) nicht installiert - werden nach dem Neustart erneut versucht" }
      return $true
    }
  }
  $script:Fehler += $fehlUpd
  return $neustart
}

# ---------------------------------------------------------------- Konten, Reparatur, Pflege
function Konten-Profile {
  foreach ($p in @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.SID -like 'S-1-5-21-*' -and $_.LocalPath })) {
    $name = $null
    try { $name = ((New-Object System.Security.Principal.SecurityIdentifier($p.SID)).Translate([System.Security.Principal.NTAccount]).Value -split '\\')[-1] } catch {}
    if (-not $name -or $name -like 'ADMIN_*' -or $name -like 'defaultuser*' -or $name -like 'WsiAccount*') { continue }
    [pscustomobject]@{ Sid = $p.SID; Name = $name; Pfad = $p.LocalPath; Geladen = (Test-Path "Registry::HKEY_USERS\$($p.SID)") }
  }
}
function Mit-KontoHive($Profil, [scriptblock]$Aktion) {
  # angemeldete Konten direkt, andere: Registry-Datei kurz laden
  if ($Profil.Geladen) { return (& $Aktion "Registry::HKEY_USERS\$($Profil.Sid)") }
  $dat = Join-Path $Profil.Pfad 'NTUSER.DAT'
  if (-not (Test-Path $dat)) { return $null }
  Hive-Laden 'EinrKonto' $dat
  try { return (& $Aktion 'Registry::HKEY_USERS\EinrKonto') } finally { Hive-Entladen 'EinrKonto' }
}
function Konten-Pruefen {
  $kp = Join-Path $Ziel 'konto.ps1'
  if (-not (Test-Path $kp)) { return }
  foreach ($pr in @(Konten-Profile)) {
    try {
      $r = @(Mit-KontoHive $pr { param($w) & $kp -Pruefen -Wurzel $w -Benutzer $pr.Name }) | Where-Object { $_ -and $_.PSObject.Properties['Abw'] } | Select-Object -Last 1
      if ($r) { $script:Ok += [int]$r.Ok; $script:Abw += [int]$r.Abw }
    } catch { Write-Host "  [!!] Konto $($pr.Name) nicht pruefbar: $($_.Exception.Message)" -ForegroundColor Yellow; $script:Abw++ }
  }
}
function Reparatur-Konten {
  Titel 'Reparatur: Einstellungen aller Konten'
  $kp = Join-Path $Ziel 'konto.ps1'
  foreach ($pr in @(Konten-Profile)) {
    try { [void](Mit-KontoHive $pr { param($w) & $kp -Wurzel $w -Benutzer $pr.Name }) }
    catch { Write-Host "  [!!] Konto $($pr.Name): $($_.Exception.Message)" -ForegroundColor Yellow }
  }
}
function Reparatur-System {
  # alles noch einmal anwenden, was Windows-Updates gern zuruecksetzen - ohne einmalige Aktionen
  $ohne = @('S_BitLocker', 'D_EdgeWeg', 'E_Bluetooth', 'G_Stick', 'G_Link', 'G_Herst', 'C_Sandbox')
  if (Hat 'D_EdgeWeg') { Einrichtung-EdgeWeg }
  foreach ($tab in 'Sicherheit', 'Cyber', 'Datenschutz', 'Updates', 'Komfort') { Einrichtung-Optionen $tab $ohne }
  if ($script:Cfg.GPU -and $script:Cfg.GPU -ne 'Keine') { Einrichtung-Optionen 'Grafik' $ohne }
  Einrichtung-Apps 'Reparatur: wieder aufgetauchte Microsoft-Apps entfernen'
  Einrichtung-Oberflaeche
  if ($script:Cfg.StdApps) { Einrichtung-Standardapps }
  Einrichtung-LocalSend
  if ((Hat 'K_Tray') -or (Hat 'K_StartListe')) { Plane-Infobereich }
}
function Pflege-Aufraeumen {
  Titel 'Aufraeumen'
  Status -Unter -1 -Schritt 'Temporaere Dateien und Update-Reste werden entfernt ...'
  Schritt 'Temporaere Dateien (aelter als 2 Tage) entfernt' {
    $grenze = (Get-Date).AddDays(-2)
    $orte = @("$env:SystemRoot\Temp") + @(Konten-Profile | ForEach-Object { Join-Path $_.Pfad 'AppData\Local\Temp' })
    foreach ($o in $orte) {
      Get-ChildItem -Path $o -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $grenze } |
        Remove-Item -Force -ErrorAction SilentlyContinue }
  }
  Schritt 'Cache der Uebermittlungsoptimierung geleert' { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop }
  Status -Schritt 'Update-Reste im Komponentenspeicher werden bereinigt (kann 10 Minuten dauern) ...'
  Schritt 'Update-Reste bereinigt (DISM StartComponentCleanup)' {
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "DISM-Code $LASTEXITCODE" } }
}
function Pflege-Systemdateien {
  Titel 'Systemdateien pruefen und reparieren'
  Status -Unter -1 -Schritt 'DISM: Windows-Abbild pruefen und reparieren (10-20 Minuten) ...'
  Schritt 'Windows-Abbild in Ordnung bzw. repariert (DISM RestoreHealth)' {
    & dism.exe /Online /Cleanup-Image /RestoreHealth /Quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "DISM-Code $LASTEXITCODE (Details: C:\Windows\Logs\DISM\dism.log)" } }
  Status -Schritt 'SFC: Systemdateien pruefen (ca. 10 Minuten) ...'
  Schritt 'Systemdateien geprueft (SFC)' {
    & sfc.exe /scannow | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "SFC-Code $LASTEXITCODE (Details: C:\Windows\Logs\CBS\CBS.log)" } }
}
function Pflege-Virenscan {
  Titel 'Virenscan (Microsoft Defender)'
  Schritt 'Virensignaturen aktualisiert' { Update-MpSignature -ErrorAction Stop }
  Status -Unter -1 -Schritt 'Defender-Schnellscan laeuft (5-15 Minuten) ...'
  $start = Get-Date
  Schritt 'Schnellscan abgeschlossen' { Start-MpScan -ScanType QuickScan -ErrorAction Stop }
  $funde = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $start })
  if ($funde.Count) { Write-Host "  [!!] $($funde.Count) Bedrohung(en) gefunden - Windows-Sicherheit -> Viren- & Bedrohungsschutz oeffnen" -ForegroundColor Yellow }
  else { Write-Host '  [OK] Keine Bedrohungen gefunden' -ForegroundColor Green }
}
function Treiber-Pruefen {
  Titel 'Treiber'
  & pnputil.exe /scan-devices 2>&1 | Out-Null
  $prob = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -in 'Error', 'Degraded' })
  if ($prob.Count) {
    foreach ($d in $prob) { Write-Host "  [!!] Geraet mit Treiberproblem: $($d.FriendlyName) ($($d.Class))" -ForegroundColor Yellow }
    $u = Hersteller-Url; if ($u) { Info "Fehlende Treiber beim Hersteller laden: $u (Zentrale -> Treiberseite)" }
  } else { Write-Host '  [OK] Alle Geraete haben einen funktionierenden Treiber' -ForegroundColor Green }
}
function Programme-Aktualisieren {
  Titel 'Programme aktualisieren (winget)'
  if (-not (Ist-Online) -and -not (Warte-AufNetz 'die Programm-Updates')) { return }
  $wg = Finde-Winget
  if (-not $wg) { Write-Host '  [!!] winget nicht gefunden - App-Installer fehlt?' -ForegroundColor Yellow; return }
  Status -Unter -1 -Schritt 'winget: alle Programme werden aktualisiert ...'
  & $wg source update 2>&1 | Out-Null
  & $wg upgrade --all --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
  $rc = $LASTEXITCODE
  if ($rc -eq 0 -or $rc -eq -1978335189) { Write-Host '  [OK] Programme sind aktuell' -ForegroundColor Green }
  else { Write-Host "  [!!] Nicht alle Programme liessen sich aktualisieren (Code $rc) - oft, weil eins gerade laeuft" -ForegroundColor Yellow }
}

function Pruefen-UndNachbessern([switch]$OhneKonten) {
  # pruefen; bei Abweichungen automatisch nach der gespeicherten Auswahl nachbessern und noch einmal pruefen
  Pruef-Alles -OhneKonten:$OhneKonten
  if ($script:Abw -gt 0) {
    $vorher = $script:Abw
    Write-Host "  [i]  $vorher Abweichung(en) gefunden - werden automatisch nachgebessert (so wie in deiner Auswahl festgelegt)" -ForegroundColor Cyan
    Status -Phase 'Automatische Nachbesserung' -Unter -1
    Reparatur-System
    if (-not $OhneKonten) { Reparatur-Konten }
    Status -Phase 'Kontrollpruefung nach der Nachbesserung' -Unter -1
    Pruef-Alles -OhneKonten:$OhneKonten
    if ($script:Abw -eq 0) { Write-Host "  [OK] Nachbesserung erfolgreich - alle $vorher Abweichung(en) behoben" -ForegroundColor Green }
    else { Write-Host "  [!!] $script:Abw Abweichung(en) liessen sich nicht automatisch beheben - siehe orange Zeilen" -ForegroundColor Yellow }
  }
}
function Ergebnis-Text([string]$Was) {
  $f = [int]$script:Fehler + [int]$script:FehlerVorher
  if ($script:St) { $script:St.Gut = ($script:Abw -eq 0 -and $f -eq 0) }
  if ($script:Abw -eq 0 -and $f -eq 0) { return "Alles perfekt: $Was ohne Fehler. Pruefung: $script:Ok Punkte OK, keine Abweichungen (System und alle Konten)." }
  return "$Was mit Hinweisen: $script:Ok Punkte OK, $script:Abw Abweichung(en), $f Schritt(e) mit Fehler - die orangen Zeilen zeigen, was."
}

# ---------------------------------------------------------------- Wartungsauftrag (laeuft als SYSTEM, auch ueber Neustarts)
$AuftragDatei = Join-Path $Ziel 'auftrag.json'
function Lade-Cfg {
  $j = Get-Content $AuswahlDatei -Raw | ConvertFrom-Json
  $script:Cfg = @{ Gewaehlt = @($j.Gewaehlt); Standard = [string]$j.Standard; StdApps = $j.StdApps; GPU = [string]$j.GPU; Admin = [string]$j.Admin
                   WeitereKonten = @($j.WeitereKonten); ExtraIds = @($j.ExtraIds | Where-Object { $_ }); Profil = [string]$j.Profil; Datum = [string]$j.Datum }
}
function Standard-Schritte {
  $sch = @()
  if (Hat 'U_Updates') { $sch += 'Updates' }
  if (Hat 'U_Optional') { $sch += 'Optional', 'Treiber' }
  if (Hat 'U_Store') { $sch += 'Store' }
  return @($sch + @('Apps', 'Reparieren', 'Pruefen', 'Autostart'))
}
function Schreibe-Auftrag([string[]]$Schritte, [string]$Quelle) {
  [ordered]@{ Schritte = @($Schritte); Quelle = $Quelle; Datum = (Get-Date -Format s) } | ConvertTo-Json | Set-Content -Path $AuftragDatei -Encoding UTF8
  Set-Reg 'HKLM:\SOFTWARE\Einrichtung' 'Durchlauf' 0
  Set-Reg 'HKLM:\SOFTWARE\Einrichtung' 'FehlerSumme' 0
}
function Wartung-Ausfuehren {
  $lo = Join-Path $Ziel 'logs'; New-Item -Path $lo -ItemType Directory -Force | Out-Null
  Start-Transcript -Path (Join-Path $lo ('wartung-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmm'))) -Append | Out-Null
  if (Netz-Freigeben) { Start-Sleep -Seconds 15 }    # Sicherheitsnetz, falls das Netz noch getrennt war
  Ziel-Vorbereiten
  Lade-Cfg
  $auf = $null; try { $auf = Get-Content $AuftragDatei -Raw | ConvertFrom-Json } catch {}
  $S = if ($auf) { @($auf.Schritte) } else { @(Standard-Schritte) }
  $quelle = if ($auf -and $auf.Quelle) { [string]$auf.Quelle } else { 'Einrichtung' }
  Status-Start 'Nachlauf' $script:Cfg.Standard -Fortsetzen
  $script:St.Quelle = $quelle
  $rk = 'HKLM:\SOFTWARE\Einrichtung'
  $n = 0; $v = Get-Reg $rk 'Durchlauf'; if ($v -ne 'fehlt') { $n = [int]$v }
  $n++; Set-Reg $rk 'Durchlauf' $n
  $script:Fehler = 0; $script:FehlerVorher = 0; $fv = Get-Reg $rk 'FehlerSumme'; if ($fv -ne 'fehlt') { $script:FehlerVorher = [int]$fv }
  $von = [Math]::Min(68 + ($n - 1) * 6, 82); $bis = [Math]::Min($von + 6, 88)
  $titel = if ($quelle -eq 'Einrichtung') { "Teil 2 von 2: Updates und Pruefung (Durchgang $n)" } else { "Wartung laeuft (Durchgang $n)" }
  Status -Phase $titel -Gesamt $von -Unter -1 -Schritt 'Pruefe die Internetverbindung ...' -Hinweis $null
  Titel "Automatische Wartung - Durchgang $n ($($S -join ', '))"
  if (@('Updates', 'Treiber', 'Store', 'SFC', 'Scan') | Where-Object { $S -contains $_ }) {
    $w = 0
    while (-not (Ist-Online) -and $w -lt 40) {   # bis 20 Minuten auf Internet warten
      if ($w -eq 2) { Status -Hinweis @{ Art = 'netz'; Text = 'Kein Internet: Bitte WLAN verbinden (Knopf unten) oder Netzwerkkabel einstecken - danach geht es von selbst weiter.' } }
      Start-Sleep -Seconds 30; $w++
    }
    if (-not (Ist-Online)) {
      Write-Host '  [!!] Kein Internet - es geht beim naechsten Start automatisch weiter' -ForegroundColor Yellow
      Status -Phase 'Wartet auf Internet' -Schritt 'Ohne Internet geht es beim naechsten Neustart automatisch weiter.'
      Stop-Transcript | Out-Null; return
    }
    Status -Hinweis $null
  }
  $neustart = $false
  if (($S -contains 'Updates') -or ($S -contains 'Treiber')) {
    if ($n -le 8) {
      Titel 'Windows Update'
      try { $neustart = Installiere-Updates $von $bis -Windows:($S -contains 'Updates') -Optional:($S -contains 'Optional') -Treiber:($S -contains 'Treiber') }
      catch { Write-Host "  [!!] Windows Update: $($_.Exception.Message)" -ForegroundColor Yellow }
    } else { Write-Host '  [!!] Nach 8 Durchgaengen keine weiteren automatischen Update-Neustarts - Rest bitte in Windows Update anstossen' -ForegroundColor Yellow }
  }
  if ($neustart) {
    $angemeldet = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    $sek = if ($angemeldet) { 300 } else { 20 }
    Write-Host '  [i]  Neustart fuer Updates noetig - danach geht es automatisch weiter' -ForegroundColor Gray
    $script:St.Modus = 'Neustart'
    Status -Phase 'Neustart fuer Updates' -Gesamt $bis -Unter -1 -Schritt 'Nach dem Neustart geht es automatisch weiter.' `
      -Hinweis @{ Art = 'neustart'; Text = 'Updates installiert - der PC startet neu und macht danach automatisch weiter. Bitte offene Dateien speichern.'; Bis = (Get-Date).AddSeconds($sek).ToString('s') }
    Set-Reg $rk 'FehlerSumme' ([int]$script:FehlerVorher + [int]$script:Fehler)
    [void](Warte-Anfrage 'neustart' $sek)
    Stop-Transcript | Out-Null
    Restart-Computer -Force
    return
  }
  if ($S -contains 'Treiber')    { Status -Gesamt 89 -Unter -1; Treiber-Pruefen }
  if ($S -contains 'Store')      { Status -Gesamt 90 -Unter -1; Titel 'Microsoft Store'; Einrichtung-StoreUpdates }
  if ($S -contains 'Pflege')     { Status -Gesamt 91 -Unter -1; Pflege-Aufraeumen }
  if ($S -contains 'SFC')        { Status -Gesamt 92 -Unter -1; Pflege-Systemdateien }
  if ($S -contains 'Scan')       { Status -Gesamt 93 -Unter -1; Pflege-Virenscan }
  if ($S -contains 'Apps')       { Status -Gesamt 94 -Unter -1; Einrichtung-Apps 'Microsoft-Apps: Nachkontrolle nach den Updates' }
  if ($S -contains 'Reparieren') { Status -Phase 'Reparatur: alles wieder wie eingerichtet' -Gesamt 95 -Unter -1; Reparatur-System; Reparatur-Konten }
  if ($S -contains 'Pruefen')    { Status -Phase 'Abschlusspruefung (System und alle Konten)' -Gesamt 97 -Unter -1; Pruefen-UndNachbessern }
  Unregister-ScheduledTask -TaskName 'Einrichtung-Nachlauf' -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item $AuftragDatei -Force -ErrorAction SilentlyContinue
  Anmeldehinweis-Entfernen
  Autostart-Abbauen   # das gerade offene Fortschrittsfenster zeigt das Ergebnis noch, beim naechsten Anmelden startet nichts mehr
  Set-Reg $rk 'LetzteWartung' (Get-Date -Format 'dd.MM.yyyy HH:mm') 'String'
  $was = if ($quelle -eq 'Einrichtung') { 'Einrichtung abgeschlossen' } else { 'Wartung abgeschlossen' }
  $erg = if ($S -contains 'Pruefen') { Ergebnis-Text $was } else { "$was." }
  Write-Host "  [i]  $erg" -ForegroundColor Cyan
  Status-Ende ($erg + $(if ($S -contains 'Autostart') { ' Zum Schluss: Autostart pruefen.' } else { '' })) $was -Autostart:($S -contains 'Autostart')
  Stop-Transcript | Out-Null
}
function Wartung-Starten([string[]]$S) {
  # Programme laufen hier im Admin-Fenster (winget), alles andere als Aufgabe im Hintergrund - auch ueber Neustarts
  Ziel-Vorbereiten; Lade-Cfg
  Status-Start 'Wartung' $script:Cfg.Standard
  $script:St.Quelle = 'Wartung'
  Starte-Fortschritt
  Status -Phase 'Wartung laeuft' -Gesamt 2 -Unter -1
  if ($S -contains 'Programme') {
    Status -Gesamt 5; Titel 'Programme: fehlende nachinstallieren'
    Einrichtung-Programme
    Status -Gesamt 50; Programme-Aktualisieren
  }
  $rest = @($S | Where-Object { $_ -ne 'Programme' })
  if ($rest.Count) {
    Status -Gesamt 60 -Schritt 'Uebergabe an die Hintergrund-Wartung ...'
    Schreibe-Auftrag $rest 'Wartung'
    Plane-Nachlauf
    Start-ScheduledTask -TaskName 'Einrichtung-Nachlauf' -ErrorAction SilentlyContinue
    Write-Host '  [i]  Wartung laeuft im Hintergrund weiter (auch ueber Neustarts) - siehe Fortschrittsfenster' -ForegroundColor Gray
  } else {
    Status-Ende 'Programme sind aktuell.' 'Wartung abgeschlossen'
  }
}
function Interaktiv-Ausfuehren([string[]]$S, [string]$Was) {
  # Pruefen und Reparieren ohne Neustart - sofort hier im Admin-Fenster
  Ziel-Vorbereiten; Lade-Cfg
  Status-Start 'Wartung' $script:Cfg.Standard
  $script:St.Quelle = 'Wartung'
  Starte-Fortschritt
  $script:Fehler = 0
  Status -Phase $Was -Gesamt 3 -Unter -1
  if ($S -contains 'Apps')       { Status -Gesamt 10; Einrichtung-Apps 'Microsoft-Apps: wieder aufgetauchte entfernen' }
  if ($S -contains 'Reparieren') { Status -Gesamt 25; Reparatur-System; Status -Gesamt 60; Reparatur-Konten }
  if ($S -contains 'Pruefen')    { Status -Phase "$Was - Pruefung" -Gesamt 75 -Unter -1; if ($S -contains 'Reparieren') { Pruefen-UndNachbessern } else { Pruef-Alles } }
  $script:FehlerVorher = 0
  $erg = if ($S -contains 'Pruefen') { Ergebnis-Text "$Was abgeschlossen" } else { 'Fertig.' }
  Write-Host "  [i]  $erg" -ForegroundColor Cyan
  Status-Ende $erg "$Was abgeschlossen"
}

# ---------------------------------------------------------------- Zentrale (Startfenster)
$WartungsSchritte = @(
  @('Updates',    'Windows-Updates installieren (mit allen noetigen Neustarts)', $true),
  @('Optional',   'Optionale Updates mitnehmen (Vorschau-Updates)', $true),
  @('Treiber',    'Treiber-Updates ueber Windows Update + Geraete mit Treiberproblemen melden', $true),
  @('Store',      'Microsoft-Store-Apps aktualisieren', $true),
  @('Programme',  'Programme: fehlende nachinstallieren und alle aktualisieren (winget)', $true),
  @('Pflege',     'Aufraeumen: temporaere Dateien, Update-Reste, Uebermittlungs-Cache', $true),
  @('SFC',        'Systemdateien pruefen und reparieren (DISM + SFC, 20-40 Minuten)', $false),
  @('Scan',       'Virenscan: Signaturen aktualisieren + Defender-Schnellscan', $true),
  @('Apps',       'Entfernte Microsoft-Apps wieder entfernen (falls Updates sie zurueckbringen)', $true),
  @('Reparieren', 'Reparieren: Einstellungen fuer System und ALLE Konten wiederherstellen', $true),
  @('Pruefen',    'Abschlusspruefung: System und alle Konten', $true),
  @('Autostart',  'Zum Schluss: Autostart pruefen (das Fortschrittsfenster fragt)', $true))
function Netzwerk-Reparieren {
  # haengende Schnelleinstellungen/WLAN-Liste neu starten, WLAN-Adapter neu starten, DNS-Cache leeren
  $sid = (Get-Process -Id $PID).SessionId
  Get-Process ShellExperienceHost, ShellHost -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sid } | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802\.11' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN' } |
    Restart-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue
  & ipconfig.exe /flushdns | Out-Null
  Start-Sleep -Seconds 6
  try { Start-Process 'ms-availablenetworks:' } catch {}
  [void][System.Windows.Forms.MessageBox]::Show('WLAN-Adapter und Schnelleinstellungen wurden neu gestartet. Die WLAN-Liste ist unten rechts geoeffnet.', 'Netzwerk reparieren', 'OK', 'Information')
}
function Zentrale-Status {
  $z = @("Windows: $Edition $Version (Build $Build.$($cv.UBR))   |   $Hersteller   |   $(if ($Laptop) { 'Notebook' } else { 'Desktop' })")
  $lz = 'unbekannt'; try { $lp = Lizenz-Produkt; $lz = if ($lp -and $lp.LicenseStatus -eq 1) { 'aktiviert' } else { 'NICHT aktiviert' } } catch {}
  $z += "Windows-Lizenz: $lz"
  try {
    $ms = Get-MpComputerStatus -ErrorAction Stop
    $z += "Virenschutz (Defender): Echtzeitschutz $(if ($ms.RealTimeProtectionEnabled) { 'an' } else { 'AUS' }), Signaturen vom $($ms.AntivirusSignatureLastUpdated.ToString('dd.MM.yyyy HH:mm'))"
  } catch { $z += 'Virenschutz: Status nicht lesbar (anderer Virenscanner aktiv?)' }
  try { $bv = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop; $z += "BitLocker C:: $(if ([string]$bv.ProtectionStatus -eq 'On') { 'an' } else { 'aus' })" } catch { $z += 'BitLocker: nicht verfuegbar' }
  try { $d = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop; $z += ('Speicher C:: {0:N1} GB frei von {1:N1} GB' -f ($d.Free / 1GB), (($d.Used + $d.Free) / 1GB)) } catch {}
  $a = $null; try { $a = Get-Content $AuswahlDatei -Raw | ConvertFrom-Json } catch {}
  $stdName = if ($script:Vorschau) { 'Alltag' } elseif ($a) { $a.Standard } else { '' }
  $z += "Eingerichtet: $(if ($a) { "$($a.Datum), Profil $($a.Profil), Alltagskonto '$stdName'" } else { 'noch nicht' })"
  $e = Get-Reg 'HKLM:\SOFTWARE\Einrichtung' 'LetztePruefung'; $z += "Letzte Pruefung: $(if ($e -ne 'fehlt') { $e } else { 'noch keine' })"
  $w = Get-Reg 'HKLM:\SOFTWARE\Einrichtung' 'LetzteWartung'; $z += "Letzte Wartung: $(if ($w -ne 'fehlt') { $w } else { 'noch keine' })"
  if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $z += 'ACHTUNG: Neustart fuer Updates steht aus' }
  if (Get-ScheduledTask -TaskName 'Einrichtung-Nachlauf' -ErrorAction SilentlyContinue) { $z += 'Automatik ist geplant/aktiv (Updates/Wartung) - Stand im Fortschrittsfenster' }
  return ($z -join "`r`n")
}
function Zeige-Zentrale {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [System.Windows.Forms.Application]::EnableVisualStyles()
  $script:ZAktion = $null; $script:ZSchritte = @(); $script:ZTitel = ''
  $f = New-Object System.Windows.Forms.Form
  $f.Text = 'Windows-Einrichtung - Zentrale'
  $f.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
  $f.StartPosition = 'CenterScreen'
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $f.Size = New-Object System.Drawing.Size([Math]::Min(1060, $wa.Width - 20), [Math]::Min(720, $wa.Height - 20))
  $f.MinimumSize = New-Object System.Drawing.Size(760, 520)
  $script:ZForm = $f

  # rechts: Status + Werkzeuge
  $rechts = New-Object System.Windows.Forms.Panel; $rechts.Dock = 'Right'; $rechts.Width = [Math]::Min(430, [int]($f.Width * 0.42)); $rechts.Padding = New-Object System.Windows.Forms.Padding(4, 8, 8, 4)
  $gStat = New-Object System.Windows.Forms.GroupBox; $gStat.Text = 'Status'; $gStat.Dock = 'Top'; $gStat.Height = 270
  $script:ZStatus = New-Object System.Windows.Forms.Label; $script:ZStatus.Dock = 'Fill'; $script:ZStatus.Padding = New-Object System.Windows.Forms.Padding(4)
  $script:ZStatus.Text = 'Status wird gelesen ...'
  $gStat.Controls.Add($script:ZStatus)
  $gWerk = New-Object System.Windows.Forms.GroupBox; $gWerk.Text = 'Werkzeuge'; $gWerk.Dock = 'Fill'
  $fw = New-Object System.Windows.Forms.FlowLayoutPanel; $fw.Dock = 'Fill'; $fw.FlowDirection = 'TopDown'; $fw.WrapContents = $false; $fw.AutoScroll = $true
  $gWerk.Controls.Add($fw)
  function WKnopf($Text, [scriptblock]$Klick) { $b = New-Object System.Windows.Forms.Button; $b.Text = $Text; $b.Width = 380; $b.Height = 30; $b.TextAlign = 'MiddleLeft'; $b.Add_Click($Klick); [void]$fw.Controls.Add($b) }
  WKnopf 'Fortschrittsfenster anzeigen' { Starte-Fortschritt }
  WKnopf 'Autostart pruefen (was beim Anmelden startet)' { Starte-Fortschritt -NurAutostart }
  WKnopf 'Geraete-Manager (Treiber ansehen)' { Start-Process devmgmt.msc }
  $hu = Hersteller-Url
  if ($hu) { WKnopf "Treiberseite des Herstellers ($Hersteller)" { Start-Process (Hersteller-Url) } }
  WKnopf 'Windows-Sicherheit (Defender, Firewall)' { Start-Process 'windowsdefender:' }
  WKnopf 'Windows Update (Einstellungen)' { Start-Process 'ms-settings:windowsupdate' }
  WKnopf 'WLAN / Netzwerk reparieren (bei haengender WLAN-Liste)' { Netzwerk-Reparieren }
  WKnopf 'Protokolle oeffnen' { Start-Process explorer.exe (Join-Path $Ziel 'logs') }
  WKnopf 'Status aktualisieren' { $script:ZStatus.Text = Zentrale-Status }
  $rechts.Controls.Add($gWerk); $rechts.Controls.Add($gStat)

  # links: Einrichten + Wartung
  $links = New-Object System.Windows.Forms.Panel; $links.Dock = 'Fill'; $links.Padding = New-Object System.Windows.Forms.Padding(8, 8, 4, 4)
  $gEin = New-Object System.Windows.Forms.GroupBox; $gEin.Text = 'Einrichten / Aendern'; $gEin.Dock = 'Top'; $gEin.Height = 110
  $le = New-Object System.Windows.Forms.Label; $le.Dock = 'Top'; $le.Height = 40
  $le.Text = 'Konten (auch weitere), Sicherheit, Cybersicherheit, Updates, Microsoft-Apps, Komfort, Programme, Standard-Apps, Grafik - mit Probelauf.'
  $bEin = New-Object System.Windows.Forms.Button; $bEin.Text = 'Auswahloberflaeche oeffnen ...'; $bEin.Height = 36; $bEin.Dock = 'Top'
  $bEin.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
  $gEin.Controls.Add($bEin); $gEin.Controls.Add($le)
  $gW = New-Object System.Windows.Forms.GroupBox; $gW.Text = 'Wartung, Pflege, Pruefung'; $gW.Dock = 'Fill'
  $lw = New-Object System.Windows.Forms.Label; $lw.Dock = 'Top'; $lw.Height = 40
  $lw.Text = 'Haken setzen und "Wartung starten". Laeuft im Hintergrund weiter, auch ueber Neustarts - das Fortschrittsfenster zeigt den Stand.'
  $script:ZListe = New-Object System.Windows.Forms.CheckedListBox; $script:ZListe.Dock = 'Fill'; $script:ZListe.CheckOnClick = $true; $script:ZListe.IntegralHeight = $false
  foreach ($w in $WartungsSchritte) { $i = $script:ZListe.Items.Add($w[1]); $script:ZListe.SetItemChecked($i, [bool]$w[2]) }
  $fb = New-Object System.Windows.Forms.FlowLayoutPanel; $fb.Dock = 'Bottom'; $fb.AutoSize = $true; $fb.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 2)
  $bWart = New-Object System.Windows.Forms.Button; $bWart.Text = 'Wartung starten'; $bWart.Height = 34; $bWart.AutoSize = $true
  $bWart.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
  $bRep = New-Object System.Windows.Forms.Button; $bRep.Text = 'Nach Windows-Updates: Reparieren + Pruefen'; $bRep.Height = 34; $bRep.AutoSize = $true
  $bPr = New-Object System.Windows.Forms.Button; $bPr.Text = 'Nur pruefen'; $bPr.Height = 34; $bPr.AutoSize = $true
  $fb.Controls.AddRange(@($bWart, $bRep, $bPr))
  $gW.Controls.Add($script:ZListe); $gW.Controls.Add($fb); $gW.Controls.Add($lw)
  $links.Controls.Add($gW); $links.Controls.Add($gEin)

  $unten = New-Object System.Windows.Forms.FlowLayoutPanel; $unten.Dock = 'Bottom'; $unten.Height = 46; $unten.FlowDirection = 'RightToLeft'
  $unten.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
  $bZu = New-Object System.Windows.Forms.Button; $bZu.Text = 'Schliessen'; $bZu.Width = 120; $bZu.Height = 32
  $unten.Controls.Add($bZu)
  $f.Controls.Add($links); $f.Controls.Add($rechts); $f.Controls.Add($unten)

  $bEin.Add_Click({ $script:ZAktion = 'einrichten'; $script:ZForm.Close() })
  $bZu.Add_Click({ $script:ZForm.Close() })
  $bWart.Add_Click({
    $sch = @(); for ($i = 0; $i -lt $script:ZListe.Items.Count; $i++) { if ($script:ZListe.GetItemChecked($i)) { $sch += $WartungsSchritte[$i][0] } }
    if (-not $sch.Count) { return }
    if (-not (Test-Path $AuswahlDatei)) { [void][System.Windows.Forms.MessageBox]::Show('Noch nicht eingerichtet - zuerst "Auswahloberflaeche oeffnen".', 'Windows-Zentrale', 'OK', 'Information'); return }
    if (Get-ScheduledTask -TaskName 'Einrichtung-Nachlauf' -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' }) {
      [void][System.Windows.Forms.MessageBox]::Show('Es laeuft gerade schon eine Wartung - Stand im Fortschrittsfenster.', 'Windows-Zentrale', 'OK', 'Information'); return }
    $script:ZAktion = 'wartung'; $script:ZSchritte = $sch; $script:ZForm.Close()
  })
  $bRep.Add_Click({
    if (-not (Test-Path $AuswahlDatei)) { return }
    $script:ZAktion = 'sofort'; $script:ZSchritte = @('Apps', 'Reparieren', 'Pruefen'); $script:ZTitel = 'Reparieren und Pruefen'; $script:ZForm.Close()
  })
  $bPr.Add_Click({
    if (-not (Test-Path $AuswahlDatei)) { return }
    $script:ZAktion = 'sofort'; $script:ZSchritte = @('Pruefen'); $script:ZTitel = 'Pruefung'; $script:ZForm.Close()
  })
  $f.Add_Shown({ $script:ZForm.Activate(); $script:ZForm.Refresh(); $script:ZStatus.Text = Zentrale-Status })
  if ($script:VBilder) { $f.Add_Shown({ Bild-Speichern $script:ZForm (Join-Path $script:VBilder '30-zentrale.png'); $script:ZAktion = $null; $script:ZForm.Close() }) }
  [void]$f.ShowDialog()
  return $script:ZAktion
}

# ---------------------------------------------------------------- Ablauf
function Vorschau-Fortschritt {
  # Beispiel-Stand fuer das Fortschrittsfenster (Datei im TEMP-Ordner, nichts am System)
  $script:StatusDatei = Join-Path $env:TEMP 'einrichtung-vorschau-status.json'; $StatusDatei = $script:StatusDatei
  $fp = Join-Path $Basis 'fortschritt.ps1'
  if (-not (Test-Path $fp)) { return }
  Set-Variable -Name StatusDatei -Value $script:StatusDatei -Scope Script
  Set-Variable -Name AnfrageOrdner -Value (Join-Path $env:TEMP 'einrichtung-vorschau-anfrage') -Scope Script
  Status-Start 'Setup' 'Alltag'
  $script:St.Quelle = 'Einrichtung'
  Status -Phase 'Teil 1 von 2: Einstellungen und Programme' -Gesamt 34 -Unter 40 -Schritt 'Programm 3 von 7: PDF-XChange Editor'
  foreach ($z in @(@('T', 'Vorbereitung'), @('OK', 'Wiederherstellungspunkt erstellt'), @('T', 'Konten'),
                   @('OK', "Alltagskonto 'Alltag' angelegt (ohne Adminrechte)"), @('OK', 'Eingebautes Administrator-Konto deaktiviert'),
                   @('T', 'Sicherheit'), @('OK', 'Adminabfrage nur mit Passwort, auf dem sicheren Desktop'), @('OK', 'Firewall in allen Profilen an'),
                   @('T', 'Cybersicherheit'), @('OK', 'Angriffsflaechen-Reduzierung (Defender-ASR, 15 Regeln)'), @('OK', 'Kernisolierung: Speicherintegritaet (HVCI), LSA-Schutz'),
                   @('T', 'Datenschutz'), @('OK', 'Diagnosedaten auf Minimum, Telemetrie-Dienste aus'), @('OK', 'Copilot, Recall und KI-Datenanalyse aus'),
                   @('T', 'Microsoft-Apps entfernen'), @('OK', 'Bing News, Wetter, Bing-Suche'), @('OK', 'Clipchamp (Videoeditor)'),
                   @('T', 'Programme installieren (winget)'), @('OK', 'Mozilla.Firefox.de'), @('OK', 'TheDocumentFoundation.LibreOffice'))) {
    Status-Zeile $z[0] $z[1]
  }
  Status-Schreiben
  $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $fp + '"'),
         '-StatusPfad', ('"' + $script:StatusDatei + '"'), '-Bild', ('"' + (Join-Path $script:VBilder '40-fortschritt.png') + '"'))
  $p.WaitForExit(30000) | Out-Null
  # zweites Bild: fertig
  $script:St.Fertig = $true; $script:St.Modus = 'Fertig'; $script:St.Gut = $true
  $script:St.Ergebnis = 'Alles perfekt: Einrichtung abgeschlossen - 330 Punkte OK, keine Abweichungen, keine Fehler.'
  Status-Zeile 'T' 'Abschlusspruefung (System und alle Konten)'; Status-Zeile 'OK' 'Alle Konten geprueft - keine Abweichungen'
  Status -Phase 'Einrichtung abgeschlossen' -Gesamt 100 -Unter 100 -Schritt $script:St.Ergebnis
  $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $fp + '"'),
         '-StatusPfad', ('"' + $script:StatusDatei + '"'), '-Bild', ('"' + (Join-Path $script:VBilder '41-fortschritt-fertig.png') + '"'))
  $p.WaitForExit(30000) | Out-Null
  $script:StatusAn = $false
  Remove-Item $script:StatusDatei -Force -ErrorAction SilentlyContinue
}
if ($Vorschau) {
  # Nur ansehen: keine Aenderung am System, keine Adminrechte noetig
  $ErrorActionPreference = 'SilentlyContinue'
  Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
  if ($script:VBilder) { Bild-Vorbereiten; New-Item -ItemType Directory -Path $script:VBilder -Force | Out-Null }
  [void](Zeige-Oberflaeche)
  if ($script:VBilder) {
    [void](Zeige-Zentrale)
    Vorschau-Fortschritt
    Write-Host "Bilder gespeichert in: $script:VBilder" -ForegroundColor Green
  }
  return
}
if ($Pruefen) { Pruef-Alles; return }
if ($Nachlauf) { Wartung-Ausfuehren; return }

$logOrdner = Join-Path $Ziel 'logs'
New-Item -Path $logOrdner -ItemType Directory -Force | Out-Null
$log = Join-Path $logOrdner ("setup-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
Start-Transcript -Path $log -Append | Out-Null

function Erststart-Aufraeumen {
  Titel 'Erstinstallation abschliessen'
  Schritt 'Automatische Anmeldung entfernt' {
    Set-ItemProperty -Path $Winlogon -Name 'AutoAdminLogon' -Value '0'
    foreach ($n in 'DefaultPassword', 'AutoLogonCount') { Remove-ItemProperty -Path $Winlogon -Name $n -ErrorAction SilentlyContinue }
  }
  Schritt 'Installationsdateien mit dem vorlaeufigen Passwort von C: geloescht' {
    Get-ChildItem "$env:SystemRoot\Panther" -Filter 'unattend*.xml' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\System32\Sysprep\unattend.xml" -Force -ErrorAction SilentlyContinue
  }
}

Konsole-Minimieren
if (-not $Erststart -and -not $Einrichten) {
  try { Autostart-Abbauen } catch {}
  # Zentrale: alles aus einem Programm. Pruefen/Reparieren/Wartung kehren danach hierher zurueck.
  while ($true) {
    $wahl = Zeige-Zentrale
    if ($wahl -eq 'einrichten') { break }
    if ($wahl -eq 'wartung') { Wartung-Starten $script:ZSchritte; continue }
    if ($wahl -eq 'sofort') { Interaktiv-Ausfuehren $script:ZSchritte $script:ZTitel; continue }
    Stop-Transcript | Out-Null
    return
  }
}
if ($Erststart) { Info 'Erststart erkannt: Windows wurde mit autounattend.xml installiert.' }
if ($Erststart) { Netz-Trennen }   # steckt noch ein Kabel: Netz erst freigeben, wenn es gebraucht wird
$fertig = $false
try {
  do {
    if (-not (Zeige-Oberflaeche)) {
      Write-Host 'Abgebrochen - nichts veraendert.'
      if ($Erststart) { Hinweisfenster 'ACHTUNG: Das Admin-Konto hat noch das vorlaeufige Passwort aus der Installation. Start.cmd vom Stick bald erneut ausfuehren!' 'Warning' }
      return
    }
    $script:Probe = [bool]$script:Cfg.Probe
    $script:Fehler = 0
    $script:VorherGewaehlt = @(); try { if (Test-Path $AuswahlDatei) { $script:VorherGewaehlt = @((Get-Content $AuswahlDatei -Raw | ConvertFrom-Json).Gewaehlt) } } catch {}
    if ($script:Cfg.NetzTrennen) { Netz-Trennen } else { [void](Netz-Freigeben) }
    Ziel-Vorbereiten
    Status-Start $(if ($script:Probe) { 'Probe' } else { 'Setup' }) $script:Cfg.Standard
    Starte-Fortschritt
    Konsole-Minimieren
    Startmenue-Schliessen
    Status -Phase $(if ($script:Probe) { 'Probelauf - es wird nichts veraendert' } else { 'Teil 1 von 2: Einstellungen und Programme' }) -Gesamt 1 -Unter -1
    if ($script:Probe) { Write-Host '*** PROBELAUF - es wird nichts veraendert ***' -ForegroundColor Magenta }
    Info "Profil: $($script:Cfg.Profil), GPU: $($script:Cfg.GPU), $($script:Cfg.Gewaehlt.Count) Punkte ausgewaehlt"

    Titel 'Vorbereitung'
    Schritt 'Wiederherstellungspunkt erstellt' {
      Enable-ComputerRestore -Drive "$env:SystemDrive\"
      Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
      Checkpoint-Computer -Description 'Vor Einrichtungsskript' -RestorePointType MODIFY_SETTINGS
    }
    Status -Gesamt 4;  Einrichtung-Konten
    Status -Gesamt 8;  Einrichtung-Optionen 'Sicherheit'
    Status -Gesamt 10; Einrichtung-Optionen 'Cyber'; Rueckbau-Cyber
    Status -Gesamt 12; Einrichtung-Optionen 'Datenschutz'
    Status -Gesamt 13; Einrichtung-Optionen 'Updates'
    if ($script:Cfg.GPU -ne 'Keine') { Status -Gesamt 14; Einrichtung-Optionen 'Grafik' }
    Status -Gesamt 17; Einrichtung-Optionen 'Komfort'
    Status -Gesamt 22; Einrichtung-Apps
    Status -Gesamt 26; Einrichtung-Kontoeinstellungen
    Status -Gesamt 29; Einrichtung-Treiber
    Status -Gesamt 30; Einrichtung-Programme
    Status -Gesamt 56 -Unter -1; Einrichtung-LocalSend
    Status -Gesamt 57; Einrichtung-Lizenz
    Status -Gesamt 58; Einrichtung-Standardapps
    Status -Gesamt 59; Einrichtung-EdgeWeg
    Status -Gesamt 60; Einrichtung-Oberflaeche
    if (Hat 'E_Leistung') {
      Titel 'Energiemodus'
      $netz = $true
      try { Add-Type -AssemblyName System.Windows.Forms; $netz = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -ne 'Offline' } catch {}
      if ($netz) {
        # Windows merkt sich den Energiemodus getrennt fuer Netzteil und Akku - gesetzt wird der fuer die aktuelle Stromquelle
        Schritt 'Energiemodus am Netzteil: "Beste Leistung" (Akku bleibt "Ausbalanciert")' { powercfg /overlaysetactive ded574b5-45a0-4f42-8737-46345c09c238 }
      } else {
        Write-Host '  [!!] Energiemodus nicht gesetzt: Laptop laeuft gerade auf Akku. Netzteil anstecken und Start.cmd erneut ausfuehren.' -ForegroundColor Yellow; $script:Fehler++
      }
    }
    Status -Gesamt 62; Einrichtung-Apps 'Microsoft-Apps: zweiter Durchgang (falls Updates etwas nachinstalliert haben)'
    if ($Erststart) { Erststart-Aufraeumen }

    $nochmal = $false
    if ($script:Probe) {
      Status-Ende 'Es wurde nichts veraendert. Die Liste zeigt, was beim echten Lauf passieren wuerde.' 'Probelauf beendet'
      $nochmal = Frage ("Probelauf beendet - im Fortschrittsfenster steht, was passieren wuerde.`r`n`r`nOberflaeche erneut oeffnen, um jetzt echt einzurichten?")
      if (-not $nochmal) { return }
    }
  } while ($nochmal)

  Status -Phase 'Teil 1 von 2: Pruefung' -Gesamt 64 -Unter -1
  Pruefen-UndNachbessern -OhneKonten
  $script:Pw = $null
  Write-Host ''
  Write-Host "Fertig. $script:Fehler Schritt(e) mit Fehler. Protokoll: $log" -ForegroundColor $(if ($script:Fehler) { 'Yellow' } else { 'Green' })
  if ($script:Cfg.Nachlauf) { Schreibe-Auftrag (Standard-Schritte) 'Einrichtung'; Plane-Nachlauf }
  $fertig = $true
} finally {
  # Netz nie getrennt zuruecklassen - auch nicht bei Abbruch oder Fehler
  try { [void](Netz-Freigeben) } catch {}
  if (-not $fertig) { try { Stop-Transcript | Out-Null } catch {} }
}
try { Copy-Item $log $Basis -Force -ErrorAction Stop } catch {}
if ($script:Cfg.Nachlauf -and (Get-ScheduledTask -TaskName 'Einrichtung-Nachlauf' -ErrorAction SilentlyContinue)) {
  Anmeldehinweis-Setzen $script:Cfg.Standard
  Write-Host '  [i]  Anmeldebildschirm zeigt bis zum Ende, mit welchem Konto du dich anmelden sollst' -ForegroundColor Gray
  $script:St.Modus = 'Neustart'
  Status -Phase 'Neustart - danach geht es automatisch weiter' -Gesamt 66 -Unter -1 `
    -Schritt "Nach dem Neustart wieder mit 'Verwaltung' anmelden - dort laufen Updates und Pruefung bis zum Ende. Danach ins Alltagskonto '$($script:Cfg.Standard)'." `
    -Hinweis @{ Art = 'neustart'; Text = "Teil 1 ist fertig. Der PC startet neu.`r`nDanach wieder mit 'Verwaltung' anmelden und warten, bis 'Einrichtung abgeschlossen' kommt - erst dann ins Alltagskonto."; Bis = (Get-Date).AddSeconds(60).ToString('s') }
  Stop-Transcript | Out-Null
  [void](Warte-Anfrage 'neustart' 60)
  Restart-Computer -Force
} else {
  Status-Ende "Fertig: $script:Fehler Schritt(e) mit Fehler. Windows Update bitte selbst ausfuehren." -Autostart
  Stop-Transcript | Out-Null
  if (Frage 'Einrichtung fertig. Jetzt neu starten?') { Restart-Computer -Force }
}
