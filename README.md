# Win11-Auto-Installer

> 🇬🇧 **English version below** – [jump to English](#english)

Windows 11 automatisch neu aufsetzen: vom USB-Stick installieren, ein Fenster mit Haken ausfüllen, „Start" drücken. Den Rest macht das Paket allein, auch über mehrere Neustarts hinweg: Konten, Sicherheit, Datenschutz, Programme, Updates, Treiber und eine Abschlussprüfung.

Geschrieben für Office-Laptops und Gaming-PCs mit **Windows 11 Pro/Home 24H2 bis 26H2**, in PowerShell 5.1 und WinForms. Es ist nichts zusätzlich zu installieren. Oberfläche und Anleitungen sind auf Deutsch.

> **Ohne Gewähr.** Das Paket ändert tiefgreifend Systemeinstellungen. Zuerst die **Vorschau** oder den **Probelauf** nutzen und vor einer Neuinstallation die Daten sichern.

---

## Bilder

| | |
|---|---|
| ![Konten](bilder/10-oberflaeche-konten.png) | ![Cybersicherheit](bilder/13-oberflaeche-cybersicherheit.png) |
| **Konten:** Alltagskonto ohne Adminrechte, Verwaltungskonto, weitere Konten; alle Passwörter vergibst du selbst | **Cybersicherheit:** Defender-ASR, Kernisolierung, Anmeldeschutz, SMB-Signierung … |
| ![Programme](bilder/17-oberflaeche-programme.png) | ![Standard-Apps](bilder/18-oberflaeche-standard-apps.png) |
| **Programme:** rund 250 Programme in Kategorien, Installation über winget | **Standard-Apps:** das gewählte Ersatzprogramm öffnet PDF, Videos, Archive … |
| ![Fortschritt](bilder/40-fortschritt.png) | ![Zentrale](bilder/30-zentrale.png) |
| **Fortschrittsfenster:** Gesamt- und Schrittbalken, jede Zeile mit OK oder !! | **Windows-Zentrale:** Prüfen, Reparieren, Updates, Treiber, Programme, Pflege |

Alle Bilder liegen im Ordner [`bilder/`](bilder/).

---

## Was es macht

**Installation (autounattend.xml)**
- Windows installiert sich mit lokalem Konto, ohne Microsoft-Konto und ohne Fragen nach Region, Netzwerk oder Datenschutz
- Die Festplatte wählst du bei der Installation selbst, es wird nichts ungefragt gelöscht
- Ein Netzwerkkabel bleibt getrennt, bis Programme wirklich Internet brauchen

**Auswahloberfläche (ein Fenster, mehrere Reiter, Profile „Office" und „Gaming")**
- **Konten:**
  - Alltagskonto ohne Adminrechte
  - Admin-Konto „Verwaltung" nur für Adminabfragen
  - weitere Konten nach Wunsch
  - das eingebaute Administrator-Konto wird abgeschaltet
- **Sicherheit:** Adminabfrage mit Passwort, Kontosperre, kein Remotedesktop, LLMNR und NetBIOS aus, Firewall, SMB1 und PowerShell 2.0 aus, Funktionsupdates auf deiner Version festhalten
- **Cybersicherheit:**
  - Defender-Angriffsflächenreduzierung (15 Regeln) und Cloud-Schutz
  - Speicherintegrität (HVCI) und LSA-Schutz
  - nur NTLMv2, SMB-Signierung, AutoRun aus, SmartScreen, Bildschirmsperre
  - Sicherheitsprotokoll und gehärtete Browser (uBlock Origin, HTTPS-only)
  - optional „[Streng]": DNS über Quad9 mit Verschlüsselung, USB-Programmsperre u. a.
- **Datenschutz:**
  - Telemetrie auf Minimum
  - Copilot, Recall und KI-Datenanalyse aus
  - keine Websuche im Startmenü, keine Werbe-ID, Widgets und OneDrive weg, Standort aus
  - Edge zähmen oder entfernen
- **Microsoft-Apps entfernen:** Bing, Clipchamp, Teams, Outlook (neu), Xbox und mehr; sie kommen auch nach Updates nicht zurück
- **Komfort:** dunkler Modus, volles Kontextmenü, Dateiendungen sichtbar, Startmenü als Liste, Energieplan je nach Netzteil oder Akku, WLAN ohne Energiesparen
- **Programme:** rund 250 Programme in Kategorien, darunter Browser, Office/PDF, Medien, Sicherheit, Backup, Fernzugriff, Netzwerk, Entwicklung und Gaming. Alles kommt über winget aus offiziellen Quellen; die Liste lässt sich in `programme.csv` erweitern
- **Standard-Apps:** Wer einen Ersatz anhakt (z. B. Firefox statt Edge, VLC, 7-Zip, LibreOffice), bekommt ihn für alle Konten als Standard
- **Grafik:** Einstellungen für NVIDIA und AMD, wenn eine solche Karte erkannt wird
- **Profile:** Die Auswahl lässt sich für das nächste Gerät speichern. Passwörter und Produktschlüssel werden dabei **nie** gespeichert, das prüft die Abschlussprüfung

**Danach vollautomatisch, auch über Neustarts**
- **Windows Update:** alle Updates einschließlich optionaler Updates und Treiber, Update für Update sichtbar. Firmware und BIOS bewusst nicht
- **Store und Nachkontrolle:** Store-App-Updates ohne Microsoft-Konto; zurückgekommene Microsoft-Apps werden wieder entfernt
- **Abschlussprüfung:** prüft System und **alle Konten** (über 300 Punkte). Abweichungen bessert die Einrichtung automatisch nach deiner Auswahl nach und prüft danach erneut
- **Fortschrittsfenster:** zeigt jederzeit den Stand; am Ende kommt die Frage, was im Autostart bleiben soll
- **Nach dem Ende:** Es bleibt kein Einrichtungs-Autostart und kein dauerhaft laufendes PowerShell zurück

**Windows-Zentrale (Startmenü), für später**
- Nur prüfen, sowie „Reparieren + Prüfen" nach großen Windows-Updates
- Wartung im Hintergrund: Updates, Treiber, Store, Programme, Aufräumen, Systemdateien, Virenscan
- Autostart prüfen und „WLAN / Netzwerk reparieren"

---

## Schnellstart

Es gibt zwei gleichwertige Varianten. Ausführliche Schritt-für-Schritt-Anleitungen für Laien liegen jeweils dabei.

| Variante | Für wen | Anleitung |
|---|---|---|
| **Rufus-Version** | normaler Installations-Stick | [`Rufus-Version/ANLEITUNG-Rufus.txt`](Rufus-Version/ANLEITUNG-Rufus.txt) |
| **Ventoy-Version** | Ventoy-Stick mit mehreren ISOs | [`Ventoy-Version/ANLEITUNG-Ventoy.txt`](Ventoy-Version/ANLEITUNG-Ventoy.txt) |

1. Oben auf **Code → Download ZIP** klicken und entpacken.
2. Den Ordner deiner Variante auf den Stick kopieren:
   - **Rufus:** `Windows-Einrichtung` und `autounattend.xml` ins Hauptverzeichnis des Sticks
   - **Ventoy:** `Windows-Einrichtung` und den Ordner `ventoy`
3. Vom Stick booten und Windows installieren. Nach dem ersten Anmelden öffnet sich die Auswahloberfläche von selbst.
4. Haken setzen, alle Passwörter selbst festlegen und **Start** drücken. Danach nach jedem Neustart wieder mit **Verwaltung** anmelden, bis „Einrichtung abgeschlossen" erscheint. Erst dann ins Alltagskonto wechseln.

**Bereits installiertes Windows:** Ohne Neuinstallation `Windows-Einrichtung\Start.cmd` starten. Es holt sich selbst die Adminrechte.

### Erst einmal nur ansehen

`Windows-Einrichtung\Vorschau.cmd` öffnet die Oberfläche **ohne Adminrechte**, und es wird **nichts verändert**. „Start" ist dort abgeschaltet.
Mit `Vorschau.cmd -Bilder "%USERPROFILE%\Desktop\Bilder"` entstehen Bildschirmfotos aller Reiter, so wie die Bilder oben.

Für einen Testlauf auf einem eingerichteten PC hat die Oberfläche zusätzlich den Haken **„Probelauf"**. Dann zeigt das Fortschrittsfenster jeden Schritt, ohne etwas zu ändern.

---

## Sicherheitshinweise

- **Passwörter:**
  - Du vergibst sie selbst in der Oberfläche.
  - Sie werden weder gespeichert noch protokolliert, auch nicht in Profilen.
- **`autounattend.xml`:**
  - Sie enthält ein **vorläufiges** Installations-Passwort (`Einrichtung-2026`).
  - Die Oberfläche zwingt dich, es beim ersten Start zu ersetzen.
  - Die Installationsdateien mit diesem Passwort werden danach von der Festplatte gelöscht.
- **BitLocker:** Der Wiederherstellungsschlüssel landet als Textdatei auf dem Stick. Den Stick nicht beim Laptop aufbewahren.
- **Edge entfernen:** Microsoft erlaubt das nur im EWR. Lehnt Windows es ab, bleibt Edge installiert, ist aber nicht Standard.
- **Protokolle:** liegen unter `C:\ProgramData\Einrichtung\logs`.

## Aufbau

```
Rufus-Version/
  autounattend.xml            Antwortdatei für die Installation
  ANLEITUNG-Rufus.txt
  Windows-Einrichtung/        (in beiden Varianten identisch)
    Start.cmd                 Einrichtung / Zentrale (holt Adminrechte)
    Vorschau.cmd              nur ansehen, ändert nichts
    Pruefen.cmd               Prüfung aller Konten
    setup.ps1                 Oberfläche, Einrichtung, Wartung, Prüfung
    konto.ps1                 Einstellungen pro Konto (beim ersten Anmelden)
    fortschritt.ps1           Fortschrittsfenster + Autostart-Prüfung
    autostart.ps1             Autostart-Einträge für alle Konten
    programme.csv             Programmliste (erweiterbar)
    Treiber/                  optional: eigene Treiber (z. B. WLAN)
Ventoy-Version/
  ventoy/ventoy.json, ventoy/script/office.xml, office-pro.xml
  ANLEITUNG-Ventoy.txt
  Windows-Einrichtung/
bilder/                       Bildschirmfotos
```

## Lizenz

[MIT](LICENSE) © 2026 Salami_aus_Leipzsch. Nutzung auf eigene Verantwortung. Kein offizielles Microsoft-Produkt. Windows, Edge und weitere Namen sind Marken ihrer Inhaber.

---

## English

**Win11-Auto-Installer** sets up Windows 11 automatically. You install from a USB stick, tick boxes in one window and press **Start**. The package then does the rest on its own, across several restarts: accounts, security, privacy, programs, updates, drivers and a final check.

Built for office laptops and gaming PCs running **Windows 11 Pro/Home 24H2 to 26H2**. It uses PowerShell 5.1 and WinForms, so there is nothing extra to install. **The user interface and the step-by-step guides are in German.**

> **No warranty.** This package makes deep changes to system settings. Use the **preview** or the **dry run** first, and back up your data before reinstalling.

### Screenshots

See the table at the top or the [`bilder/`](bilder/) folder. File names are German: *oberflaeche* = setup window, *fortschritt* = progress window, *zentrale* = maintenance center.

### What it does

**Installation (autounattend.xml)**
- Windows installs with a local account. There is no Microsoft account and no questions about region, network or privacy
- You pick the disk yourself during installation, so nothing is wiped without asking
- A network cable stays disconnected until programs actually need internet

**Setup window (one window with tabs and the profiles "Office" and "Gaming")**
- **Accounts:**
  - everyday account without admin rights
  - admin account "Verwaltung" used only for elevation prompts
  - optional extra accounts
  - the built-in Administrator account is disabled
- **Security:** UAC with password, account lockout, no Remote Desktop, LLMNR and NetBIOS off, firewall, SMB1 and PowerShell 2.0 removed, feature updates pinned to your version
- **Cyber security:**
  - Defender attack surface reduction (15 rules) and cloud protection
  - memory integrity (HVCI) and LSA protection
  - NTLMv2 only, SMB signing, AutoRun off, SmartScreen, screen lock
  - security auditing and hardened browsers (uBlock Origin, HTTPS-only)
  - optional "[Streng]" (strict) items: Quad9 DNS with encryption, blocking programs on USB drives, and more
- **Privacy:**
  - minimal telemetry
  - Copilot, Recall and AI data analysis off
  - no web search in Start, no advertising ID, Widgets and OneDrive removed, location off
  - Edge tamed or removed
- **Remove Microsoft apps:** Bing, Clipchamp, Teams, new Outlook, Xbox and more. They stay removed after updates
- **Comfort:** dark mode, classic context menu, visible file extensions, Start menu as a list, power plan by AC or battery, Wi-Fi without power saving
- **Programs:** about 250 programs in categories, including browsers, office/PDF, media, security, backup, remote access, networking, development and gaming. Everything comes from official sources via winget, and you can extend the list in `programme.csv`
- **Default apps:** the replacement you select (e.g. Firefox instead of Edge, VLC, 7-Zip, LibreOffice) becomes the default for all accounts
- **Graphics:** NVIDIA and AMD settings when such a card is detected
- **Profiles:** you can save your selection for the next device. Passwords and product keys are **never** saved, and the final check verifies this

**Then fully automatic, across restarts**
- **Windows Update:** all updates including optional updates and drivers, installed one by one and visible. Firmware and BIOS are deliberately excluded
- **Store and clean-up:** Store app updates without a Microsoft account, and Microsoft apps that came back are removed again
- **Final check:** checks the system and **all accounts** (300+ items). It fixes deviations automatically according to your selection, then checks again
- **Progress window:** always shows the current status, and at the end asks what should stay in autostart
- **When it's done:** no setup autostart and no permanently running PowerShell are left behind

**"Windows-Zentrale" (maintenance center in the Start menu), for later**
- Check only, or repair and check after big Windows updates
- Background maintenance: updates, drivers, Store, programs, clean-up, system files, virus scan
- Autostart review and "repair Wi-Fi / network"

### Quick start

| Variant | For | Guide (German) |
|---|---|---|
| **Rufus-Version** | a regular install stick | [`Rufus-Version/ANLEITUNG-Rufus.txt`](Rufus-Version/ANLEITUNG-Rufus.txt) |
| **Ventoy-Version** | a Ventoy stick with several ISOs | [`Ventoy-Version/ANLEITUNG-Ventoy.txt`](Ventoy-Version/ANLEITUNG-Ventoy.txt) |

1. Click **Code → Download ZIP** and extract it.
2. Copy your variant to the stick:
   - **Rufus:** `Windows-Einrichtung` and `autounattend.xml` into the root of the stick
   - **Ventoy:** `Windows-Einrichtung` and the `ventoy` folder
3. Boot from the stick and install Windows. After the first sign-in, the setup window opens by itself.
4. Tick your choices, set all passwords yourself and press **Start**. After each restart, sign in as **Verwaltung** again until "Einrichtung abgeschlossen" (setup finished) appears. Only then switch to the everyday account.

**Windows already installed:** run `Windows-Einrichtung\Start.cmd` without reinstalling. It requests admin rights itself.

**Just look:** `Windows-Einrichtung\Vorschau.cmd` opens the window **without admin rights and changes nothing**, because "Start" is disabled there. To save screenshots of every tab, run it with `-Bilder "<folder>"`.

### Security notes

- **Passwords:**
  - You set them yourself in the setup window.
  - They are never stored or logged, not even in profiles.
- **`autounattend.xml`:**
  - It contains a **temporary** install password (`Einrichtung-2026`).
  - The setup window forces you to replace it on first start.
  - The install files containing it are deleted from the disk afterwards.
- **BitLocker:** the recovery key is saved as a text file on the stick. Don't keep the stick with the laptop.
- **Removing Edge:** Microsoft only allows this in the EEA. If Windows refuses, Edge stays installed but is not the default.
- **Logs:** stored in `C:\ProgramData\Einrichtung\logs`.

### License

[MIT](LICENSE) © 2026 Salami_aus_Leipzsch. Use at your own risk. This is not an official Microsoft product. Windows, Edge and other names are trademarks of their respective owners.
