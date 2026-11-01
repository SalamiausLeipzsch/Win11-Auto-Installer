# konto.ps1 - Einstellungen fuer das angemeldete Konto (ohne Adminrechte)
# Laeuft automatisch einmal beim naechsten Anmelden jedes Kontos (von setup.ps1 eingerichtet).
#   -Pruefen  : prueft die Einstellungen dieses Kontos, aendert nichts
#   -Wurzel   : (nur von setup.ps1 als Admin/SYSTEM) arbeitet auf der Registry eines ANDEREN Kontos,
#               z. B. 'Registry::HKEY_USERS\S-1-5-21-...'. Dann nur Registry-Werte; Rueckgabe: Zaehler.
#   -Benutzer : Kontoname zu -Wurzel
param([switch]$Pruefen, [string]$Wurzel, [string]$Benutzer)

$Ziel = Join-Path $env:ProgramData 'Einrichtung'
$AuswahlDatei = Join-Path $Ziel 'auswahl.json'
if (-not (Test-Path $AuswahlDatei)) { Write-Host 'Keine Auswahl gefunden - zuerst Start.cmd ausfuehren.' -ForegroundColor Yellow; return }
$cfg = Get-Content $AuswahlDatei -Raw | ConvertFrom-Json
$an  = @($cfg.Komfort)
$Name = if ($Benutzer) { $Benutzer } else { $env:USERNAME }
$vor  = if ($Wurzel) { "$Name - " } else { '' }       # Zeilen-Praefix, wenn mehrere Konten nacheinander laufen
function KPfad($Pfad) { if ($Wurzel) { return ($Pfad -replace '^HKCU:', $Wurzel) } return $Pfad }
# Hat sich dieses Konto seit der aktuellen Einrichtung schon einmal angemeldet? (sonst greifen Anmelde-Dinge noch nicht)
$angemeldet = $true
if ($Wurzel) { $angemeldet = ((Get-ItemProperty (KPfad 'HKCU:\Software\Einrichtung') -Name 'Angewendet' -ErrorAction SilentlyContinue).Angewendet -eq $cfg.Datum) }

$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
function RegWert($P, $N, $W, $T = 'DWord') { @{ P = (KPfad $P); N = $N; W = $W; T = $T } }

$Werte = @{
  K_Werbung = @(
    @('ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled',
      'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled', 'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled',
      'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled', 'SubscribedContentEnabled',
      'SubscribedContent-310093Enabled', 'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled',
      'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
      'SubscribedContent-353696Enabled') | ForEach-Object { RegWert $cdm $_ 0 }
    (RegWert $adv 'Start_IrisRecommendations' 0), (RegWert $adv 'Start_AccountNotifications' 0), (RegWert $adv 'Start_TrackProgs' 0),
    (RegWert $adv 'ShowSyncProviderNotifications' 0),
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0))
  K_Daten = @(
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0),
    (RegWert 'HKCU:\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1),
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0),
    (RegWert 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0),
    (RegWert 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0),
    (RegWert 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1),
    (RegWert 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1),
    (RegWert 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0),
    (RegWert 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0),
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0),
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDeviceSearchHistoryEnabled' 0),
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsMSACloudSearchEnabled' 0),
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsAADCloudSearchEnabled' 0),
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'),
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'ShowGlobalPrompts' 0))
  K_Dunkel = @(
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0),
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0))
  K_Task      = @((RegWert "$adv\TaskbarDeveloperSettings" 'TaskbarEndTask' 1))
  K_Endungen  = @((RegWert $adv 'HideFileExt' 0))
  K_Taskleiste = @((RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1), (RegWert $adv 'ShowTaskViewButton' 0))
  K_Einrasten = @((RegWert 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'))
  K_Maus = @(
    (RegWert 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'), (RegWert 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'),
    (RegWert 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'))
  K_Animation = @(
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0),
    (RegWert 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'), (RegWert $adv 'TaskbarAnimations' 0))
  K_Aufnahme   = @((RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled' 0))
  K_GameBarAus = @((RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0), (RegWert 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0))
  K_Spielmodus = @((RegWert 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1))
  K_TaskLinks  = @((RegWert $adv 'TaskbarAl' 0))
  K_StartKlein = @((RegWert $adv 'Start_TrackDocs' 0), (RegWert $adv 'Start_IrisRecommendations' 0), (RegWert $adv 'Start_TrackProgs' 0))
  K_ExplorerNav = @(
    (RegWert 'HKCU:\Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}' 'System.IsPinnedToNameSpaceTree' 0),
    (RegWert 'HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}' 'System.IsPinnedToNameSpaceTree' 0),
    (RegWert $adv 'LaunchTo' 1))
  K_ExplorerAnsicht = @(
    (RegWert $adv 'Hidden' 1), (RegWert $adv 'HideMergeConflicts' 0),
    (RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' 'FullPath' 1))
  K_SysDateienAlle = @((RegWert $adv 'ShowSuperHidden' 1))
  K_StartListe = @((RegWert 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' 'AllAppsViewMode' 2), (RegWert 'HKCU:\Software\Einrichtung' 'StartListe' 1))
}
# Admin-Konto erkennen (fuer "Systemdateien nur im Admin-Konto")
$istAdminKonto = $false
try { $istAdminKonto = [bool](Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Where-Object { $_.Name -match ('\\' + [regex]::Escape(($Name -replace '^ADMIN_', '')) + '$') }) }
catch { if ($cfg.Admin) { $istAdminKonto = ($Name -eq $cfg.Admin) -or ($Name -eq ('ADMIN_' + $cfg.Admin)) } }
if ($istAdminKonto -and ($an -contains 'K_SysDateienAdmin')) { $Werte['K_SysDateienAdmin'] = @((RegWert $adv 'ShowSuperHidden' 1)) }
$KontextKey = KPfad 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'

# ---------------------------------------------------------------- Pruefen
if ($Pruefen) {
  $ok = 0; $abw = 0
  Write-Host "== Konto $Name (Auswahl vom $($cfg.Datum)) ==" -ForegroundColor Cyan
  if (-not $angemeldet) { Write-Host "  [i]  $Name hat sich seit der Einrichtung noch nicht angemeldet - Anmelde-Dinge (Infobereich, Standard-Apps) erst danach" -ForegroundColor Gray }
  foreach ($id in $an) {
    if ($id -eq 'K_Kontext') {
      if (Test-Path $KontextKey) { Write-Host "  [OK] ${vor}K_Kontext" -ForegroundColor Green; $ok++ } else { Write-Host "  [!!] ${vor}K_Kontext fehlt" -ForegroundColor Yellow; $abw++ }
      continue
    }
    if ($id -eq 'K_Tray') {
      $alt = (Get-ItemProperty (KPfad 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') -Name 'EinrichtungTray' -ErrorAction SilentlyContinue).EinrichtungTray
      $lauf = (Get-ItemProperty (KPfad 'HKCU:\Software\Einrichtung') -Name 'TrayLauf' -ErrorAction SilentlyContinue).TrayLauf
      if ($alt) { Write-Host "  [!!] ${vor}K_Tray: alter PowerShell-Autostart-Eintrag noch da" -ForegroundColor Yellow; $abw++ }
      elseif ($lauf) { Write-Host "  [OK] ${vor}K_Tray (Aufgabe laeuft, zuletzt $lauf; kein Autostart-Eintrag)" -ForegroundColor Green; $ok++ }
      elseif (-not $angemeldet) { Write-Host "  [i]  ${vor}K_Tray: greift beim naechsten Anmelden" -ForegroundColor Gray }
      else { Write-Host "  [!!] ${vor}K_Tray: Aufgabe 'Einrichtung-Infobereich' ist noch nicht gelaufen - einmal ab- und anmelden" -ForegroundColor Yellow; $abw++ }
      continue
    }
    foreach ($r in @($Werte[$id])) {
      if (-not $r) { continue }
      $ist = (Get-ItemProperty -Path $r.P -Name $r.N -ErrorAction SilentlyContinue).($r.N); if ($null -eq $ist) { $ist = 'fehlt' }
      if ("$ist" -eq "$($r.W)") { Write-Host "  [OK] ${vor}${id}: $($r.N)" -ForegroundColor Green; $ok++ }
      else { Write-Host "  [!!] ${vor}${id}: $($r.N)   (ist: '$ist' / soll: '$($r.W)')" -ForegroundColor Yellow; $abw++ }
    }
  }
  # Standard-Apps: greifen nach dem Anmelden (Richtlinie)
  $sx = Join-Path $Ziel 'Standardapps.xml'
  if (Test-Path $sx) {
    $stdAbw = 0; $istErst = $null
    # Konten, die es schon vor dem ersten Standard-Apps-Import gab (z. B. Verwaltung), bekommen die Vorgaben von Windows nicht
    $altesKonto = $false
    try {
      $erst = (Get-ItemProperty 'HKLM:\SOFTWARE\Einrichtung' -Name 'StdImportErst' -ErrorAction SilentlyContinue).StdImportErst
      $erstZeit = if ($erst) { [datetime]$erst } else { (Get-Item $sx).CreationTime }
      $profil = if ($Wurzel) {
        $sidK = (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue).SID.Value
        if ($sidK) { (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sidK" -ErrorAction SilentlyContinue).ProfileImagePath }
      } else { $env:USERPROFILE }
      if ($profil -and (Test-Path $profil)) { $altesKonto = ((Get-Item $profil -Force).CreationTime -lt $erstZeit.AddMinutes(-1)) }
    } catch {}
    foreach ($g in @(@(([xml](Get-Content $sx -Raw)).DefaultAssociations.Association) | Group-Object ApplicationName)) {
      $falsch = @()
      foreach ($a in $g.Group) {
        $e = $a.Identifier
        $basisPfad = KPfad $(if ($e.StartsWith('.')) { "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$e" } else { "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$e" })
        $ist = $null
        foreach ($u in 'UserChoiceLatest\ProgId', 'UserChoiceLatest', 'UserChoice') {
          $v = (Get-ItemProperty "$basisPfad\$u" -Name ProgId -ErrorAction SilentlyContinue).ProgId
          if ($v) { $ist = $v; break }
        }
        if ($ist -ne $a.ProgId) { $falsch += $e; if (-not $istErst) { $istErst = "$e = $(if ($ist) { $ist } else { 'Windows-Vorgabe' })" } }
      }
      if ($falsch.Count -and $altesKonto) { Write-Host "  [i]  ${vor}Standard-App $($g.Name): Konto gab es schon vor der Einrichtung - Windows uebernimmt die Vorgaben nur fuer neue Konten. Bei Bedarf einmal: Einstellungen > Apps > Standard-Apps." -ForegroundColor Gray }
      elseif ($falsch.Count -and -not $angemeldet) { Write-Host "  [i]  ${vor}Standard-App $($g.Name): wird beim naechsten Anmelden gesetzt" -ForegroundColor Gray }
      elseif ($falsch.Count) { Write-Host "  [!!] ${vor}Standard-App $($g.Name): nicht zugeordnet fuer $($falsch -join ' ') (z. B. $istErst)" -ForegroundColor Yellow; $abw++; $stdAbw++ }
      else { Write-Host "  [OK] ${vor}Standard-App $($g.Name) ($($g.Count) Typen)" -ForegroundColor Green; $ok++ }
    }
    if ($stdAbw) { Write-Host '  Tipp: Standard-Apps werden beim Anmelden gesetzt - einmal ab- und wieder anmelden, dann erneut pruefen.' -ForegroundColor Gray }
  }
  if ($Wurzel) { return [pscustomobject]@{ Ok = $ok; Abw = $abw } }
  $farbe = if ($abw -eq 0) { 'Green' } else { 'Yellow' }
  Write-Host "Konto: $ok OK, $abw Abweichung(en)." -ForegroundColor $farbe
  if ($abw) { Write-Host '  Tipp: Zentrale -> "Pruefen & Reparieren" stellt alles fuer alle Konten wieder her.' -ForegroundColor Gray }
  return
}

# ---------------------------------------------------------------- Anwenden
if ($Wurzel) {
  # Reparatur durch setup.ps1: nur Registry-Werte dieses Kontos zuruecksetzen (Rest passiert beim Anmelden)
  $fehler = 0
  foreach ($id in $an) {
    try {
      if ($id -eq 'K_Kontext') { if (-not (Test-Path $KontextKey)) { New-Item -Path $KontextKey -Value '' -Force | Out-Null } }
      else {
        foreach ($r in @($Werte[$id])) {
          if (-not $r) { continue }
          if (-not (Test-Path $r.P)) { New-Item -Path $r.P -Force | Out-Null }
          New-ItemProperty -Path $r.P -Name $r.N -Value $r.W -PropertyType $r.T -Force | Out-Null
        }
      }
    } catch { Write-Host "  [!!] ${vor}${id} - $($_.Exception.Message)" -ForegroundColor Yellow; $fehler++ }
  }
  Remove-ItemProperty -Path (KPfad 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') -Name 'EinrichtungTray' -ErrorAction SilentlyContinue
  if ($cfg.OneDriveWeg) { Remove-ItemProperty -Path (KPfad 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') -Name 'OneDriveSetup' -ErrorAction SilentlyContinue }
  $ek = KPfad 'HKCU:\Software\Einrichtung'
  if (-not (Test-Path $ek)) { New-Item -Path $ek -Force | Out-Null }
  New-ItemProperty -Path $ek -Name 'Repariert' -Value (Get-Date -Format s) -PropertyType String -Force | Out-Null
  if (-not $fehler) { Write-Host "  [OK] ${Name}: Konto-Einstellungen wiederhergestellt ($($an.Count) Punkte)" -ForegroundColor Green }
  return [pscustomobject]@{ Fehler = $fehler }
}
$log = Join-Path $env:LOCALAPPDATA 'Einrichtung-Konto.log'
Start-Transcript -Path $log -Append | Out-Null
Write-Host "Konto $env:USERNAME - $(Get-Date)"
foreach ($id in $an) {
  try {
    if ($id -eq 'K_Kontext') {
      New-Item -Path $KontextKey -Value '' -Force | Out-Null
    } else {
      foreach ($r in @($Werte[$id])) {
        if (-not $r) { continue }
        if (-not (Test-Path $r.P)) { New-Item -Path $r.P -Force | Out-Null }
        New-ItemProperty -Path $r.P -Name $r.N -Value $r.W -PropertyType $r.T -Force | Out-Null
      }
    }
    Write-Host "[OK] $id"
  } catch { Write-Host "[!!] $id - $($_.Exception.Message)" }
}

if ($cfg.OneDriveWeg) {
  Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  foreach ($od in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDriveSetup.exe") {
    if (Test-Path $od) { Start-Process $od '/uninstall' -Wait -ErrorAction SilentlyContinue; Write-Host '[OK] OneDrive entfernt'; break }
  }
  Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDriveSetup' -ErrorAction SilentlyContinue
}

# Alte Fassung startete den Infobereich-Helfer als PowerShell-Eintrag im Autostart - entfernen.
# Heute erledigt das die Aufgabe "Einrichtung-Infobereich" (nur kurz beim Anmelden, kein Autostart-Eintrag).
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'EinrichtungTray' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name 'EinrichtungTray' -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*\Einrichtung\tray.ps1*' -and $_.ProcessId -ne $PID } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if (($an -contains 'K_Tray') -or ($an -contains 'K_StartListe')) {
  $tp = Join-Path $Ziel 'tray.ps1'
  if (Test-Path $tp) { & $tp }   # sofort einmal, danach uebernimmt die Aufgabe
  Write-Host '[OK] K_Tray/K_StartListe sofort angewendet'
}

# Programme, die nur pro Konto installiert werden koennen - in allen Alltagskonten (ohne Adminrechte)
$progs = @($cfg.KontoProgramme | Where-Object { $_ })
$alltag = @($cfg.Standard) + @($cfg.WeitereKonten | Where-Object { $_ -and -not $_.Admin } | ForEach-Object { $_.Name })
if ($progs.Count -and ($alltag -contains $env:USERNAME)) {
  # Beim allerersten Anmelden registriert Windows winget erst nach ein paar Minuten
  $wg = $null
  for ($i = 0; $i -lt 30 -and -not $wg; $i++) {
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wg) { Start-Sleep -Seconds 10 }
  }
  if ($wg) {
    foreach ($id in $progs) {
      # Store-Apps (msstore:...) ueber die Store-Quelle, alles andere nur fuer dieses Konto
      $zusatz = if ($id -like 'msstore:*') { @('--source', 'msstore') } else { @('--scope', 'user') }
      & $wg.Source install --id ($id -replace '^msstore:', '') --exact --silent @zusatz --accept-package-agreements --accept-source-agreements
      Write-Host "winget $id -> Code $LASTEXITCODE"
    }
  } else { Write-Host '[!!] winget nicht verfuegbar - Programme spaeter selbst installieren.' }
}

# Nach den Installationen: Desktop, Taskleiste und Startmenue dieses Kontos neu aufbauen
if ($an -contains 'K_Desktop') {
  $desk = [Environment]::GetFolderPath('Desktop')
  Get-ChildItem "$desk\*" -Include '*.lnk', '*.url' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*Treiber*' } |
    Remove-Item -Force -ErrorAction SilentlyContinue
  Write-Host '[OK] K_Desktop'
}
if ($an -contains 'K_TaskPins') {
  # Persoenliche Anheftungen loeschen - Windows baut die Taskleiste dann aus dem Layout (Explorer + Browser) neu auf
  Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\*" -Force -ErrorAction SilentlyContinue
  Write-Host '[OK] K_TaskPins'
}
if ($an -contains 'K_StartPins') {
  $ls = "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState"
  Remove-Item "$ls\start2.bin", "$ls\start.bin" -Force -ErrorAction SilentlyContinue
  Get-Process StartMenuExperienceHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Write-Host '[OK] K_StartPins'
}

# Achtung: New-Item -Force auf einen vorhandenen Schluessel loescht dessen Werte (z. B. die Markierung StartListe) - daher nur anlegen, wenn er fehlt
if (-not (Test-Path 'HKCU:\Software\Einrichtung')) { New-Item -Path 'HKCU:\Software\Einrichtung' -Force | Out-Null }
New-ItemProperty -Path 'HKCU:\Software\Einrichtung' -Name 'Angewendet' -Value $cfg.Datum -PropertyType String -Force | Out-Null
Stop-Transcript | Out-Null
# Explorer neu starten, damit Kontextmenue, Taskleiste und Dunkelmodus sofort greifen
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
# Ist die Einrichtung schon fertig (keine Fortschritts-Aufgabe mehr), fragt dieses Konto EINMAL nach dem Autostart -
# ohne dauerhaften Autostart-Eintrag (dieses Skript kommt aus RunOnce und laeuft nur einmal)
try {
  $st = $null; try { $st = Get-Content (Join-Path $Ziel 'status.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
  $geprueft = (Get-ItemProperty 'HKCU:\Software\Einrichtung' -Name AutostartGeprueft -ErrorAction SilentlyContinue).AutostartGeprueft -eq 1
  $fp = Join-Path $Ziel 'fortschritt.ps1'
  if (-not $geprueft -and (Test-Path $fp) -and (-not $st -or $st.Fertig)) {
    Start-Sleep -Seconds 8
    Start-Process -FilePath 'conhost.exe' -ArgumentList ('--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "' + $fp + '" -NurAutostart')
  }
} catch {}
