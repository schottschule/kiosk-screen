# Ubuntu-Kiosk-Setup

Dieses Repo enthält ein Installationsskript für Ubuntu-Kiosk-Bildschirme. Das Skript wird als normaler Benutzer `vplan` gestartet, fragt die benötigten Werte interaktiv ab und richtet danach den Benutzer `kiosk`, Chrome im Kiosk-Modus, Autologin, Autostart, Medienfreigaben und optional einen täglichen Ausschalt-Timer ein.

## Zielzustand

- Ubuntu Desktop ist installiert.
- Der Admin-/Einrichtungsbenutzer heißt `vplan`.
- Der Kiosk-Benutzer heißt `kiosk`.
- Chrome startet nach dem Login des Benutzers `kiosk` automatisch im Kiosk-Modus.
- Die aufgerufene URL wird aus `Basis-URL#TOKEN` zusammengesetzt.

## Direkter Aufruf auf Ubuntu

Als Benutzer `vplan` im Terminal ausführen:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/schottschule/kiosk-screen/main/install-kiosk.sh)
```

Falls `curl` noch fehlt:

```bash
sudo apt update && sudo apt install -y curl
```

## Was das Skript abfragt

- Basis-URL ohne Token, zum Beispiel `https://example.com/app`
- Token
- tägliche Abschaltzeit im Format `HH:MM`

Aus URL und Token wird intern automatisch `https://example.com/app#DEIN_TOKEN`.

Wenn die Abschaltzeit leer gelassen wird, wird kein täglicher Ausschalt-Timer eingerichtet.

## Was das Skript automatisch erledigt

- installiert Google Chrome aus dem offiziellen Google-APT-Repository
- legt den Benutzer `kiosk` an, falls er noch nicht existiert
- setzt GDM-Autologin auf den Benutzer `kiosk`
- erzeugt `/home/kiosk/bin/kiosk.sh`
- legt den Chrome-Autostart für den Benutzer `kiosk` an
- legt zusätzlich ein Desktop-Icon für den manuellen Start an
- setzt Chrome-Policies für Kamera- und Mikrofon-Freigaben auf die konfigurierte Origin
- setzt für den Benutzer `kiosk` die GNOME-Einstellungen für Bildschirm-Timeout, Suspend und Sperre
- richtet optional einen systemd-Timer zum täglichen Ausschalten ein
- verzögert den Chrome-Start beim Login und wartet in `kiosk.sh` zusätzlich auf Netzwerk und Erreichbarkeit der Ziel-URL

## Empfohlener Ablauf

1. Ubuntu Desktop installieren.
2. Beim ersten Login als Benutzer `vplan` anmelden.
3. Im Terminal das Installationsskript per `curl`-Aufruf starten.
4. Nach dem Setup das System neu starten.
5. Prüfen, ob automatisch der Benutzer `kiosk` eingeloggt wird und Chrome im Kiosk-Modus startet.

## Manuell prüfen

Das Skript setzt die üblichen GNOME-Einstellungen automatisch. Je nach Ubuntu-Version, Display Manager oder OEM-Anpassung sollte Folgendes trotzdem einmal in der GUI kontrolliert werden:

- `Einstellungen -> System -> Benutzer -> Automatische Anmeldung`: Benutzer `kiosk` muss aktiv sein.
- `Einstellungen -> Energie -> Bildschirm aus`: auf `Nie`.
- `Einstellungen -> Energie -> Automatisches Bereitschaft`: auf `Aus`.
- `Einstellungen -> Datenschutz & Sicherheit -> Bildschirmsperre -> Automatische Bildschirmsperre`: auf `Aus`.

Falls auf dem Gerät zusätzliche Hersteller-Tools für Stromsparmodi aktiv sind, müssen diese separat deaktiviert werden. Das Skript deckt nur die Standard-GNOME- und systemd-Konfiguration ab.

## Robuster Start

Wenn die Seite nach einem Kaltstart ohne CSS erscheint, ist der wahrscheinlichste Grund ein Rennen zwischen GNOME-Autostart, Netzwerk und dem Erreichen deiner Web-App. Deshalb erzeugt das Setup jetzt eine robustere `/home/kiosk/bin/kiosk.sh`:

- GNOME wartet per `X-GNOME-Autostart-Delay=10` erst kurz vor dem Start.
- `kiosk.sh` wartet zusätzlich auf Netzwerk und prüft mit `curl`, ob die Origin erreichbar ist.
- Der Start wird in `$HOME/.cache/kiosk-start.log` protokolliert.

Die Wartezeiten kannst du auf dem Gerät direkt in `/home/kiosk/bin/kiosk.sh` anpassen:

- `STARTUP_DELAY_SECONDS=10`
- `NETWORK_WAIT_SECONDS=60`
- `NETWORK_RETRY_INTERVAL=2`

## Nachträgliche Änderungen

Das Installationsskript in diesem Repo heißt:

- `install-kiosk.sh`

Auf dem Zielsystem liegt die eigentliche Kiosk-Startdatei hier:

- `/home/kiosk/bin/kiosk.sh`

Wenn sich URL oder Token ändern, kann das Setup-Skript einfach erneut ausgeführt werden. Die Konfiguration wird dabei aktualisiert.

## Hinweise

- Das Skript erwartet Ubuntu Desktop mit GDM. Wenn ein anderes Login-System verwendet wird, muss Autologin eventuell manuell gesetzt werden.
- Für die tägliche Abschaltzeit verwendet der Timer die lokale Systemzeit des Ubuntu-Geräts.
- Nach dem ersten vollständigen Durchlauf ist ein Neustart sinnvoller als nur Aus- und Einloggen.
