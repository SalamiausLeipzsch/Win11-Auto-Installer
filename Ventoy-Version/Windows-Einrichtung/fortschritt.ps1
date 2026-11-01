# fortschritt.ps1 - Fortschrittsfenster der Windows-Einrichtung
# Zeigt den Stand aus C:\ProgramData\Einrichtung\status.json (geschrieben von setup.ps1).
# Startet automatisch: waehrend der Einrichtung durch setup.ps1, nach Neustarts beim Anmelden (Aufgabe
# "Einrichtung-Fortschritt", wird am Ende der Einrichtung entfernt). Aendert selbst nichts am System -
# ausser den Autostart-Eintraegen, die du am Ende ausdruecklich auswaehlst.
#   -NurAutostart : nur die Autostart-Pruefung (aus der Zentrale)
#   -StatusPfad / -Bild : (nur fuer setup.ps1 -Vorschau -Bilder) Beispiel-Stand anzeigen, Bildschirmfoto speichern, schliessen
param([switch]$NurAutostart, [string]$StatusPfad, [string]$Bild)
$ErrorActionPreference = 'SilentlyContinue'
$FehlerDatei = Join-Path $env:TEMP 'einrichtung-fortschritt-fehler.txt'
function Fehler-Merken($Text) { try { Add-Content -Path $FehlerDatei -Value ('{0}  {1}' -f (Get-Date -Format s), $Text) -Encoding UTF8 } catch {} }
$Ziel        = Join-Path $env:ProgramData 'Einrichtung'
$StatusDatei = if ($StatusPfad) { $StatusPfad } else { Join-Path $Ziel 'status.json' }
$Anfrage     = if ($StatusPfad) { $env:TEMP } else { Join-Path $Ziel 'anfrage' }

# nur ein Fenster pro Sitzung (die Sperre wird erst gesetzt, wenn das Fenster wirklich sichtbar ist)
$SperrName = if ($Bild) { 'Local\EinrichtungVorschau' } elseif ($NurAutostart) { 'Local\EinrichtungAutostart' } else { 'Local\EinrichtungFortschritt' }
try { $m = $null; if ([System.Threading.Mutex]::TryOpenExisting($SperrName, [ref]$m)) { $m.Dispose(); return } } catch { return }
if ($Bild) {
  Add-Type -Namespace EinrB -Name Bild -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(System.IntPtr h, int a, out RECT r, int s);
public struct RECT { public int L; public int T; public int R; public int B; }
'@
  try { [void][EinrB.Bild]::SetProcessDPIAware() } catch {}
}

try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# Fehler in Knopf-/Zeitgeber-Ereignissen nicht als Fehlerfenster zeigen, sondern in eine Datei schreiben
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($q, $ev) Fehler-Merken $ev.Exception.ToString() })
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Boot     = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$script:Lauf     = ''
$script:LetzteNr = 0
$script:Fertig   = $false
$script:AutoOffen = $false
$script:AutoErledigt = $false
$script:SchliessenUm = $null
$Ich = $env:USERNAME

function Lies-Status {
  try { return (Get-Content -Path $StatusDatei -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}
function Sende-Anfrage($Name) {
  try { Set-Content -Path (Join-Path $Anfrage "$Name.txt") -Value (Get-Date -Format s) -ErrorAction Stop; return $true } catch { return $false }
}
function Zeit-Text([int]$Sek) { if ($Sek -lt 0) { $Sek = 0 }; return ('{0}:{1:00}' -f [int][Math]::Floor($Sek / 60), ($Sek % 60)) }

# ---------------------------------------------------------------- Fenster
$f = New-Object System.Windows.Forms.Form
$f.Text = 'Windows-Einrichtung - Fortschritt'
$f.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$f.TopMost = $true
$f.MaximizeBox = $false
$f.StartPosition = 'Manual'
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$f.Size = New-Object System.Drawing.Size([Math]::Min(760, $wa.Width - 20), [Math]::Min(580, $wa.Height - 20))
$f.Location = New-Object System.Drawing.Point(($wa.Left + [int](($wa.Width - $f.Width) / 2)), ($wa.Top + [int](($wa.Height - $f.Height) / 2)))

# Kopf: Phase, Schritt, Balken
$kopf = New-Object System.Windows.Forms.TableLayoutPanel
$kopf.Dock = 'Top'; $kopf.AutoSize = $true; $kopf.ColumnCount = 1; $kopf.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 4)
[void]$kopf.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$lblPhase = New-Object System.Windows.Forms.Label; $lblPhase.AutoSize = $true
$lblPhase.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$lblPhase.Text = 'Warte auf die Einrichtung ...'
$lblSchritt = New-Object System.Windows.Forms.Label; $lblSchritt.AutoSize = $true; $lblSchritt.MaximumSize = New-Object System.Drawing.Size(($f.Width - 50), 0)
$lblGesamt = New-Object System.Windows.Forms.Label; $lblGesamt.AutoSize = $true; $lblGesamt.ForeColor = [System.Drawing.Color]::DimGray
$lblGesamt.Text = 'Gesamtfortschritt'
$pbGesamt = New-Object System.Windows.Forms.ProgressBar; $pbGesamt.Dock = 'Fill'; $pbGesamt.Height = 22; $pbGesamt.Maximum = 100
$lblUnter = New-Object System.Windows.Forms.Label; $lblUnter.AutoSize = $true; $lblUnter.ForeColor = [System.Drawing.Color]::DimGray
$lblUnter.Text = 'Aktueller Schritt'
$pbUnter = New-Object System.Windows.Forms.ProgressBar; $pbUnter.Dock = 'Fill'; $pbUnter.Height = 14; $pbUnter.Maximum = 100
$pbUnter.Style = 'Marquee'; $pbUnter.MarqueeAnimationSpeed = 30
foreach ($c in @($lblPhase, $lblSchritt, $lblGesamt, $pbGesamt, $lblUnter, $pbUnter)) { [void]$kopf.Controls.Add($c) }

# Hinweisleiste (gelb) mit Knoepfen
$hinweis = New-Object System.Windows.Forms.TableLayoutPanel
$hinweis.Dock = 'Top'; $hinweis.AutoSize = $true; $hinweis.ColumnCount = 1; $hinweis.Visible = $false
$hinweis.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 196); $hinweis.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 6)
$lblHinweis = New-Object System.Windows.Forms.Label; $lblHinweis.AutoSize = $true; $lblHinweis.MaximumSize = New-Object System.Drawing.Size(($f.Width - 50), 0)
$lblHinweis.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$knoepfe = New-Object System.Windows.Forms.FlowLayoutPanel; $knoepfe.AutoSize = $true; $knoepfe.WrapContents = $true
function Knopf($Text) { $b = New-Object System.Windows.Forms.Button; $b.Text = $Text; $b.AutoSize = $true; $b.Height = 30; $b.Visible = $false; [void]$knoepfe.Controls.Add($b); return $b }
$bWlan     = Knopf 'WLAN-Liste öffnen'
$bOhne     = Knopf 'Ohne Internet weiter (Programme später)'
$bNeustart = Knopf 'Jetzt neu starten'
$bWechsel  = Knopf 'Konto wechseln (dieses Konto bleibt angemeldet)'
$bAbmelden = Knopf 'Jetzt abmelden - weiter zum Alltagskonto'
[void]$hinweis.Controls.Add($lblHinweis); [void]$hinweis.Controls.Add($knoepfe)

# Protokoll
$liste = New-Object System.Windows.Forms.ListView
$liste.Dock = 'Fill'; $liste.View = 'Details'; $liste.HeaderStyle = 'None'; $liste.FullRowSelect = $true
[void]$liste.Columns.Add('Zeit', 70); [void]$liste.Columns.Add('Meldung', 640)

# Autostart-Pruefung (am Ende)
$auto = New-Object System.Windows.Forms.Panel; $auto.Dock = 'Fill'; $auto.Visible = $false
$lblAuto = New-Object System.Windows.Forms.Label; $lblAuto.Dock = 'Top'; $lblAuto.Height = 78; $lblAuto.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 0)
$lblAuto.Text = "Letzter Schritt: Was soll beim Anmelden automatisch starten?`r`nHaken = bleibt im Autostart. Vorgeschlagen sind nur Sicherheit (Defender/Virenschutz), Grafik-, Audio- und Touchpad-Treiber. " +
                "Alles ohne Haken wird abgeschaltet (nicht gelöscht - jederzeit wieder einschaltbar im Task-Manager unter 'Autostart'). " +
                "Einträge 'für alle Konten' brauchen die Adminabfrage (.\Verwaltung)."
$clbAuto = New-Object System.Windows.Forms.CheckedListBox; $clbAuto.Dock = 'Fill'; $clbAuto.CheckOnClick = $true; $clbAuto.IntegralHeight = $false
$clbAuto.Tag = New-Object System.Collections.ArrayList
$autoKnoepfe = New-Object System.Windows.Forms.FlowLayoutPanel; $autoKnoepfe.Dock = 'Bottom'; $autoKnoepfe.Height = 42
$autoKnoepfe.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 0)
$bAutoOk = New-Object System.Windows.Forms.Button; $bAutoOk.Text = 'Übernehmen'; $bAutoOk.AutoSize = $true; $bAutoOk.Height = 30
$bAutoSpaeter = New-Object System.Windows.Forms.Button; $bAutoSpaeter.Text = 'Später fragen'; $bAutoSpaeter.AutoSize = $true; $bAutoSpaeter.Height = 30
[void]$autoKnoepfe.Controls.Add($bAutoOk); [void]$autoKnoepfe.Controls.Add($bAutoSpaeter)
$auto.Controls.Add($clbAuto); $auto.Controls.Add($autoKnoepfe); $auto.Controls.Add($lblAuto)

# Fuss
$fuss = New-Object System.Windows.Forms.FlowLayoutPanel; $fuss.Dock = 'Bottom'; $fuss.Height = 32
$fuss.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 0)
$cbVorn = New-Object System.Windows.Forms.CheckBox; $cbVorn.Text = 'Immer im Vordergrund'; $cbVorn.Checked = $true; $cbVorn.AutoSize = $true
$lblFuss = New-Object System.Windows.Forms.Label; $lblFuss.AutoSize = $true; $lblFuss.ForeColor = [System.Drawing.Color]::DimGray
$lblFuss.Margin = New-Object System.Windows.Forms.Padding(16, 4, 0, 0); $lblFuss.Text = "Protokolle: $Ziel\logs"
[void]$fuss.Controls.Add($cbVorn); [void]$fuss.Controls.Add($lblFuss)

# Reihenfolge: zuletzt hinzugefuegt = ganz oben angedockt
$f.Controls.Add($liste); $f.Controls.Add($auto); $f.Controls.Add($fuss); $f.Controls.Add($hinweis); $f.Controls.Add($kopf)

# ---------------------------------------------------------------- Autostart
$AP = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$Wichtig = 'SecurityHealth|Defender|Antivir|Avast|\bAVG\b|Avira|Bitdefender|Kaspersky|\bESET\b|egui|Norton|McAfee|Malwarebytes|Sophos|G DATA|' +
           '\bAMD|Radeon|NVIDIA|Intel|igfx|IAStor|Realtek|RtkAud|Synaptics|\bELAN|\bETD|Dolby|Waves|MaxxAudio|Conexant|Hotkey'
function Ist-An($Pfad, $Name) {
  $v = (Get-ItemProperty -Path $Pfad -Name $Name -ErrorAction SilentlyContinue).$Name
  if ($v -is [byte[]] -and $v.Length) { return (($v[0] -band 1) -eq 0) }
  return $true
}
function Autostart-Eintraege {
  $l = New-Object System.Collections.ArrayList
  $quellen = @(
    @('Konto', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', "HKCU:\$AP\Run"),
    @('Alle', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', "HKLM:\$AP\Run"),
    @('Alle', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', "HKLM:\$AP\Run32"))
  foreach ($q in $quellen) {
    $k = Get-Item -Path $q[1] -ErrorAction SilentlyContinue
    if (-not $k) { continue }
    foreach ($n in $k.GetValueNames()) {
      if (-not $n) { continue }
      [void]$l.Add([pscustomobject]@{ Bereich = $q[0]; Name = $n; Befehl = [string]$k.GetValue($n); Appr = $q[2]; An = (Ist-An $q[2] $n) })
    }
  }
  foreach ($o in @(@('Konto', [Environment]::GetFolderPath('Startup'), "HKCU:\$AP\StartupFolder"),
                   @('Alle', [Environment]::GetFolderPath('CommonStartup'), "HKLM:\$AP\StartupFolder"))) {
    if (-not $o[1]) { continue }
    Get-ChildItem -Path $o[1] -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
      [void]$l.Add([pscustomobject]@{ Bereich = $o[0]; Name = $_.Name; Befehl = $_.FullName; Appr = $o[2]; An = (Ist-An $o[2] $_.Name) })
    }
  }
  return $l
}
function Zeige-Autostart {
  $script:AutoOffen = $true
  $clbAuto.Items.Clear(); $clbAuto.Tag.Clear()
  $maschineFertig = (Get-ItemProperty 'HKLM:\SOFTWARE\Einrichtung' -Name AutostartMaschine -ErrorAction SilentlyContinue).AutostartMaschine -eq 1
  foreach ($e in (Autostart-Eintraege)) {
    if ($e.Befehl -match 'powershell|pwsh') { $soll = $false }                       # PowerShell im Autostart: abschalten
    elseif ($e.Bereich -eq 'Alle' -and $maschineFertig) { $soll = $e.An }            # schon in einem anderen Konto entschieden
    else { $soll = $e.An -and ("$($e.Name) $($e.Befehl)" -match $Wichtig) }
    $wo = if ($e.Bereich -eq 'Alle') { 'für alle Konten' } else { 'nur dieses Konto' }
    $befehl = $e.Befehl; if ($befehl.Length -gt 70) { $befehl = $befehl.Substring(0, 67) + '...' }
    $i = $clbAuto.Items.Add("$($e.Name)   [$wo]   $befehl")
    [void]$clbAuto.Tag.Add($e)
    $clbAuto.SetItemChecked($i, [bool]$soll)
  }
  if (-not $clbAuto.Items.Count) {
    Setze-Geprueft; $script:AutoErledigt = $true; $script:AutoOffen = $false
    Neue-Zeile 'ok' 'Autostart: keine Einträge vorhanden - nichts zu tun.'
    return
  }
  $liste.Visible = $false; $auto.Visible = $true
}
function Setze-Geprueft {
  if (-not (Test-Path 'HKCU:\Software\Einrichtung')) { New-Item -Path 'HKCU:\Software\Einrichtung' -Force | Out-Null }
  New-ItemProperty -Path 'HKCU:\Software\Einrichtung' -Name 'AutostartGeprueft' -Value 1 -PropertyType DWord -Force | Out-Null
}
function Setze-Appr($Pfad, $Name, [bool]$An) {
  if (-not (Test-Path $Pfad)) { New-Item -Path $Pfad -Force | Out-Null }
  $wert = [byte[]](@($(if ($An) { 2 } else { 3 })) + @(0) * 11)
  New-ItemProperty -Path $Pfad -Name $Name -Value $wert -PropertyType Binary -Force | Out-Null
}
$bAutoOk.Add_Click({
  $maschine = New-Object System.Collections.ArrayList
  $aus = 0
  for ($i = 0; $i -lt $clbAuto.Items.Count; $i++) {
    $e = $clbAuto.Tag[$i]; $an = $clbAuto.GetItemChecked($i)
    if (-not $an) { $aus++ }
    if ($e.Bereich -eq 'Konto') {
      try { Setze-Appr $e.Appr $e.Name $an } catch { Neue-Zeile 'warn' "Autostart $($e.Name): $($_.Exception.Message)" }
      # alte PowerShell-Hilfe der Einrichtung ganz entfernen (ersetzt durch eine Aufgabe ohne Autostart-Eintrag)
      if ($e.Name -eq 'EinrichtungTray' -and -not $an) { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'EinrichtungTray' -ErrorAction SilentlyContinue }
    } else { [void]$maschine.Add(@{ Appr = $e.Appr; Name = $e.Name; An = $an }) }
  }
  $ok = $true
  if ($maschine.Count) {
    $tmp = Join-Path $env:TEMP 'einrichtung-autostart.json'
    ConvertTo-Json -InputObject @($maschine) -Depth 3 | Set-Content -Path $tmp -Encoding UTF8
    try {
      $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $Ziel 'autostart.ps1') + '"'), '-Datei', ('"' + $tmp + '"'))
      $ok = ($p.ExitCode -eq 0)
    } catch { $ok = $false }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
  if ($ok) {
    Setze-Geprueft; $script:AutoErledigt = $true
    Neue-Zeile 'ok' "Autostart übernommen: $aus Eintrag/Einträge abgeschaltet. Änderbar im Task-Manager -> Autostart."
  } else {
    Neue-Zeile 'warn' 'Autostart für alle Konten nicht geändert (Adminabfrage abgebrochen). Beim nächsten Anmelden wird erneut gefragt.'
  }
  $auto.Visible = $false; $liste.Visible = $true; $script:AutoOffen = $false
  $lblSchritt.Text = 'Fertig. Dieses Fenster schließt sich gleich von selbst.'
  Schliesse-Bald 10
})
$bAutoSpaeter.Add_Click({
  $auto.Visible = $false; $liste.Visible = $true; $script:AutoOffen = $false; $script:AutoErledigt = $true
  Neue-Zeile 'info' 'Autostart-Prüfung verschoben - kommt beim nächsten Anmelden wieder.'
  Schliesse-Bald 10
})
# Nach dem Ende von selbst schliessen (Countdown unten im Fenster)
function Schliesse-Bald([int]$Sek) { if (-not $script:SchliessenUm) { $script:SchliessenUm = (Get-Date).AddSeconds($Sek) } }
$zuTimer = New-Object System.Windows.Forms.Timer; $zuTimer.Interval = 1000
$zuTimer.Add_Tick({
  try {
    if (-not $script:SchliessenUm) { return }
    $rest = [int][Math]::Ceiling(($script:SchliessenUm - (Get-Date)).TotalSeconds)
    if ($rest -le 0) { $zuTimer.Stop(); $script:Fertig = $true; $f.Close(); return }
    $lblFuss.Text = "Fertig - dieses Fenster schließt sich in $rest Sekunden."
  } catch { Fehler-Merken $_.Exception.ToString() }
})
$zuTimer.Start()

# ---------------------------------------------------------------- Knoepfe
$bWlan.Add_Click({ try { Start-Process 'ms-availablenetworks:' } catch {} })
$bOhne.Add_Click({ if (Sende-Anfrage 'ohne-netz') { $bOhne.Enabled = $false; $bOhne.Text = 'Wird übersprungen ...' } })
$bNeustart.Add_Click({
  $bNeustart.Enabled = $false; $bNeustart.Text = 'Neustart wird ausgelöst ...'
  if (-not (Sende-Anfrage 'neustart')) { & shutdown.exe /r /t 0 }
})
$bWechsel.Add_Click({
  # Benutzer wechseln: dieses Konto bleibt angemeldet, der Anmeldebildschirm erscheint
  $ts = Join-Path $env:SystemRoot 'System32\tsdiscon.exe'
  if (Test-Path $ts) { Start-Process $ts } else { & rundll32.exe user32.dll, LockWorkStation }
})
$cbVorn.Add_CheckedChanged({ $f.TopMost = $cbVorn.Checked })
$bAbmelden.Add_Click({ $script:Fertig = $true; $script:Abmelden = $true; $f.Close() })
$f.Add_FormClosing({
  param($sender, $e)
  if (-not $script:Fertig -and $e.CloseReason -eq 'UserClosing') {
    $e.Cancel = $true; $f.WindowState = 'Minimized'
  }
})

# ---------------------------------------------------------------- Aktualisieren
function Neue-Zeile($Art, $Text, $Zeit = (Get-Date -Format 'HH:mm:ss')) {
  $it = New-Object System.Windows.Forms.ListViewItem($Zeit)
  [void]$it.SubItems.Add([string]$Text)
  switch ($Art) {
    'ok'    { $it.ForeColor = [System.Drawing.Color]::ForestGreen }
    'warn'  { $it.ForeColor = [System.Drawing.Color]::DarkOrange }
    'titel' { $it.ForeColor = [System.Drawing.Color]::SteelBlue; $it.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold) }
    default { $it.ForeColor = [System.Drawing.Color]::DimGray }
  }
  [void]$liste.Items.Add($it)
  while ($liste.Items.Count -gt 600) { $liste.Items.RemoveAt(0) }
  $it.EnsureVisible()
}
function Zeige-Knoepfe([string[]]$Welche) {
  foreach ($b in @($bWlan, $bOhne, $bNeustart, $bWechsel, $bAbmelden)) { $b.Visible = $false }
  foreach ($w in $Welche) { (Get-Variable -Name $w -ValueOnly).Visible = $true }
}
function Aktualisiere {
  $s = Lies-Status
  if (-not $s) { return }
  if ($s.Lauf -ne $script:Lauf) {
    $liste.Items.Clear(); $script:LetzteNr = 0; $script:Lauf = $s.Lauf
    $script:Fertig = $false; $script:AutoErledigt = $false; $script:SchliessenUm = $null
    $lblPhase.ForeColor = [System.Drawing.SystemColors]::ControlText; $lblFuss.Text = "Protokolle: $Ziel\logs"
  }
  foreach ($z in @($s.Zeilen)) {
    if ($z -and [int]$z.N -gt $script:LetzteNr) { Neue-Zeile $z.A $z.T $z.Z; $script:LetzteNr = [int]$z.N }
  }
  $zeit = $null; try { $zeit = [datetime]$s.Zeit } catch {}
  $phase = [string]$s.Phase; $schritt = [string]$s.Schritt
  $gesamt = [int]$s.Gesamt; $unter = [int]$s.Unter
  $wartetAufStart = ($s.Modus -eq 'Neustart' -and $zeit -and $zeit -lt $script:Boot)
  if ($wartetAufStart) {
    $phase = 'Neustart erledigt - es geht gleich automatisch weiter'
    $schritt = 'Die Updates starten etwa 2 Minuten nach dem Hochfahren im Hintergrund. Du musst nichts tun.'
    $unter = -1
  } elseif (-not $s.Fertig -and $zeit -and ((Get-Date) - $zeit).TotalMinutes -gt 15) {
    $schritt = "$schritt`r`n(Letzte Rückmeldung vor $([int]((Get-Date) - $zeit).TotalMinutes) Min. - große Updates brauchen manchmal so lange.)"
  }
  $lblPhase.Text = $phase
  $lblSchritt.Text = $schritt
  $pbGesamt.Value = [Math]::Max(0, [Math]::Min(100, $gesamt))
  $lblGesamt.Text = "Gesamtfortschritt: $gesamt %"
  if ($unter -lt 0) { if ($pbUnter.Style -ne 'Marquee') { $pbUnter.Style = 'Marquee' }; $lblUnter.Text = 'Aktueller Schritt: läuft ...' }
  else { if ($pbUnter.Style -ne 'Continuous') { $pbUnter.Style = 'Continuous' }; $pbUnter.Value = [Math]::Min(100, $unter); $lblUnter.Text = "Aktueller Schritt: $unter %" }

  # Hinweise und Knoepfe
  $art = [string]$s.Hinweis.Art
  $text = [string]$s.Hinweis.Text
  $zeigen = @()
  if (-not $wartetAufStart -and $art -eq 'netz') {
    $zeigen = @('bWlan'); if ($s.Modus -ne 'Nachlauf') { $zeigen += 'bOhne' }
  } elseif (-not $wartetAufStart -and $art -eq 'neustart') {
    $bis = $null; try { $bis = [datetime]$s.Hinweis.Bis } catch {}
    if ($bis) { $text = "$text`r`nNeustart in $(Zeit-Text ([int]($bis - (Get-Date)).TotalSeconds))" }
    $zeigen = @('bNeustart')
  } elseif (-not $s.Fertig -and ($s.Modus -eq 'Nachlauf' -or $wartetAufStart) -and $s.Standard -and $Ich -ne $s.Standard -and ([string]$s.Quelle -ne 'Wartung')) {
    $art = 'warten'
    $text = "Bitte in diesem Konto bleiben, bis 'Einrichtung abgeschlossen' erscheint - erst dann ins Alltagskonto '$($s.Standard)'."
    $zeigen = @()
  } elseif ($s.Fertig -and $s.Standard -and $Ich -ne $s.Standard -and ([string]$s.Quelle -eq 'Einrichtung') -and -not $script:AutoOffen) {
    $art = 'fertig'
    $text = "Fertig. Jetzt abmelden und mit dem Alltagskonto '$($s.Standard)' anmelden - dort werden deine persönlichen Einstellungen gesetzt."
    $zeigen = @('bAbmelden')
  } else { $art = '' }
  if ($art) { $lblHinweis.Text = $text; Zeige-Knoepfe $zeigen; $hinweis.Visible = $true } else { $hinweis.Visible = $false }

  # Ende
  if ($s.Fertig) {
    # schon in diesem Konto gesehen und Autostart erledigt? Dann gar nicht mehr stoeren
    $gesehen = (Get-ItemProperty 'HKCU:\Software\Einrichtung' -Name 'GesehenLauf' -ErrorAction SilentlyContinue).GesehenLauf
    $geprueft0 = (Get-ItemProperty 'HKCU:\Software\Einrichtung' -Name AutostartGeprueft -ErrorAction SilentlyContinue).AutostartGeprueft -eq 1
    if ($gesehen -eq $s.Lauf -and (-not $s.Autostart -or $geprueft0) -and -not $script:Fertig) { $script:Leise = $true; $script:Fertig = $true; $f.Close(); return }
    $script:Fertig = $true
    $script:Ergebnis = [string]$s.Ergebnis; $script:ErgebnisLauf = [string]$s.Lauf
    $script:ErgebnisWechsel = if ($s.Standard -and $Ich -ne $s.Standard -and [string]$s.Quelle -eq 'Einrichtung') { [string]$s.Standard } else { $null }
    if ($s.Gut -eq $true) { $lblPhase.ForeColor = [System.Drawing.Color]::ForestGreen } elseif ($s.Gut -eq $false) { $lblPhase.ForeColor = [System.Drawing.Color]::DarkOrange }
    $lblPhase.Text = if ($phase) { $phase } else { 'Einrichtung abgeschlossen' }
    $pbGesamt.Value = 100; $pbUnter.Style = 'Continuous'; $pbUnter.Value = 100; $lblUnter.Text = 'Aktueller Schritt: fertig'
    if ($s.Autostart -and -not $script:AutoOffen -and -not $script:AutoErledigt) {
      $geprueft = (Get-ItemProperty 'HKCU:\Software\Einrichtung' -Name AutostartGeprueft -ErrorAction SilentlyContinue).AutostartGeprueft -eq 1
      if ($geprueft) { $script:AutoErledigt = $true } else { Zeige-Autostart }
    }
    if (($script:AutoErledigt -or -not $s.Autostart) -and -not $script:AutoOffen) {
      $lblSchritt.Text = "$schritt`r`nDieses Fenster schließt sich gleich von selbst."
      Schliesse-Bald 60
    }
  }
}

$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000
$timer.Add_Tick({ try { Aktualisiere } catch { Fehler-Merken $_.Exception.ToString() } })
$f.Add_Shown({
  try { $neu = $false; $script:Sperre = New-Object System.Threading.Mutex($true, $SperrName, [ref]$neu) } catch {}
  if ($NurAutostart) {
    $f.Text = 'Windows-Einrichtung - Autostart pruefen'
    $lblPhase.Text = 'Autostart pruefen'; $lblSchritt.Text = 'Was soll beim Anmelden automatisch starten?'
    $pbGesamt.Visible = $false; $pbUnter.Visible = $false; $lblGesamt.Visible = $false; $lblUnter.Visible = $false
    $script:Fertig = $true
    try { Zeige-Autostart } catch { Fehler-Merken $_.Exception.ToString() }
    return
  }
  # nach der Skalierung in die Bildschirmmitte setzen
  $wa = [System.Windows.Forms.Screen]::FromControl($f).WorkingArea
  if ($f.Height -gt $wa.Height) { $f.Height = $wa.Height - 10 }
  if ($f.Width -gt $wa.Width) { $f.Width = $wa.Width - 10 }
  $f.Location = New-Object System.Drawing.Point(($wa.Left + [int](($wa.Width - $f.Width) / 2)), ($wa.Top + [int](($wa.Height - $f.Height) / 2)))
  # Startmenue, das Windows beim ersten Anmelden oeffnet, schliessen (eigener Prozess dieses Kontos)
  if (-not $Bild) { try { $sid = (Get-Process -Id $PID).SessionId
        Get-Process StartMenuExperienceHost, SearchHost -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sid } | Stop-Process -Force -ErrorAction SilentlyContinue } catch {} }
  $f.Activate()
  $liste.Columns[1].Width = $liste.ClientSize.Width - $liste.Columns[0].Width - 4
  try { Aktualisiere } catch {}
  $timer.Start()
  if ($Bild) {
    $script:BildTimer = New-Object System.Windows.Forms.Timer; $script:BildTimer.Interval = 2500
    $script:BildTimer.Add_Tick({
      $script:BildTimer.Stop()
      try {
        $f.TopMost = $true; $f.Activate(); [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 400
        $r = New-Object EinrB.Bild+RECT
        $x = $f.Left; $y = $f.Top; $w = $f.Width; $h = $f.Height
        if ([EinrB.Bild]::DwmGetWindowAttribute($f.Handle, 9, [ref]$r, 16) -eq 0) { $x = $r.L; $y = $r.T; $w = $r.R - $r.L; $h = $r.B - $r.T }
        $bmp = New-Object System.Drawing.Bitmap($w, $h); $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h))); $g.Dispose()
        $bmp.Save($Bild, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
      } catch { Fehler-Merken $_.Exception.ToString() }
      $script:Leise = $true; $f.Close()
    })
    $script:BildTimer.Start()
  }
})
$f.Add_Resize({ if ($liste.Columns.Count -gt 1) { $liste.Columns[1].Width = [Math]::Max(200, $liste.ClientSize.Width - $liste.Columns[0].Width - 4) } })
[void]$f.ShowDialog()
$timer.Stop()
# Abschlussmeldung: einmal pro Konto und Durchlauf, bleibt stehen bis OK
if (-not $NurAutostart -and -not $script:Leise -and $script:Ergebnis) {
  try {
    if (-not (Test-Path 'HKCU:\Software\Einrichtung')) { New-Item -Path 'HKCU:\Software\Einrichtung' -Force | Out-Null }
    New-ItemProperty -Path 'HKCU:\Software\Einrichtung' -Name 'GesehenLauf' -Value $script:ErgebnisLauf -PropertyType String -Force | Out-Null
  } catch {}
  $sym = if ($script:Ergebnis -like 'Alles perfekt*') { 'Information' } else { 'Warning' }
  $o = New-Object System.Windows.Forms.Form; $o.TopMost = $true; $o.ShowInTaskbar = $false; $o.Opacity = 0; $o.StartPosition = 'CenterScreen'; $o.Show()
  if ($script:ErgebnisWechsel -and -not $script:Abmelden) {
    $a = [System.Windows.Forms.MessageBox]::Show($o, "$($script:Ergebnis)`r`n`r`nJetzt abmelden und mit dem Alltagskonto '$($script:ErgebnisWechsel)' anmelden?`r`n`r`nProtokolle: $Ziel\logs", 'Windows-Einrichtung - Ergebnis', 'YesNo', $sym)
    if ($a -eq 'Yes') { $script:Abmelden = $true }
  } else {
    [void][System.Windows.Forms.MessageBox]::Show($o, "$($script:Ergebnis)`r`n`r`nProtokolle: $Ziel\logs", 'Windows-Einrichtung - Ergebnis', 'OK', $sym)
  }
  $o.Dispose()
}
if ($script:Abmelden) { & shutdown.exe /l }
} catch {
  # Fenster konnte nicht aufgebaut werden: Fehler merken und sichtbar melden
  Fehler-Merken $_.Exception.ToString()
  try { [void][System.Windows.Forms.MessageBox]::Show("Das Fortschrittsfenster konnte nicht starten:`r`n$($_.Exception.Message)`r`n`r`nDetails: $FehlerDatei`r`nDie Einrichtung laeuft trotzdem weiter.", 'Windows-Einrichtung', 'OK', 'Warning') } catch {}
}
