# AInauten Voice

Native Diktier-App für macOS. Apple Silicon, macOS 14+. Audio bleibt lokal; Parakeet v3 (FluidAudio) und Qwen3-4B Q4_K_M (eingebettetes llama.cpp). Optionale OpenAI-kompatible Textglättung ist standardmäßig aus.

## Installieren

Das DMG enthält AInauten Voice, eine Applications-Verknüpfung sowie **00 - ZUERST LESEN.html** und eine Textfassung. Die HTML-Anleitung ist eigenständig und offline lesbar. App nach Applications ziehen und von dort öffnen. Der Assistent führt durch Modelle, Wispr-Import, Sprache, Mikrofon/Bedienungshilfen, Probediktat und Wechsel.

Release-Pakete sind mit der festen lokalen Identität signiert und nutzen Hardened Runtime. Ad-hoc-Signaturen sind ausschließlich für ausdrücklich angeforderte Testbuilds erlaubt. Apple Developer ID und Notarisierung sind noch nicht Bestandteil dieser Lieferung. Falls macOS den ersten Start blockiert: **Fertig (Done)** wählen, dann **Systemeinstellungen → Datenschutz & Sicherheit → Dennoch öffnen (Open Anyway)** und den Start bestätigen. Die genaue Anleitung mit Hinweisen zu abweichenden Warnungen liegt im DMG und [online](https://voice.ainauten.com/installation.html). Ein Neu-Build kann eine erneute macOS-Freigabe verlangen. Auf macOS 14 wurde das Paket noch nicht praktisch getestet.

`scripts/package.py` und `scripts/package_dmg.py` verwenden dieselbe Anleitung aus `Resources/InstallerGuide`. Mit `python3 scripts/package_dmg.py --app /Pfad/zu/AInauten\ Voice.app` lässt sich ein bestehendes signiertes App-Bundle unverändert neu verpacken, ohne interne Beta-Funktionen in die öffentliche Version zu übernehmen.

Vor dem DMG-Bau werden die Bibliothekspfade des arm64-Laufzeitprogramms und seiner Abhängigkeiten geprüft. Eine gültige Codesignatur allein reicht dafür nicht: Ein Bundle mit nicht auffindbarer `llama.framework` wird vor der Installer-Erstellung abgewiesen. Für interne Oberflächenprüfungen ebenfalls ein vollständig gepacktes Debug-Bundle mit `@executable_path/../Frameworks` verwenden; das unveränderte SwiftPM-Programm allein genügt nicht. `python3 scripts/app_bundle.py /Pfad/zu/App.app` prüft das Bundle ohne Start, `python3 scripts/check-app-bundle.py` testet fehlende Pfade, fehlende Abhängigkeiten und das Verschieben der App mit isolierten Fixtures.

## Diktieren mit Strg+Z

Beim Halten-Kürzel Strg+Z genügt es, die Kombination einmal zu drücken und anschließend nur Strg festzuhalten. Z darf losgelassen werden; das Diktat endet beim Loslassen von Strg. Für den Freihändig-Modus die vollständige Kombination zweimal kurz drücken und loslassen.

## Entwickeln

Command Line Tools mit Swift 6.2+ oder passendes Xcode, Python 3 nur für den Paketbau. Für die normale Agent-Installation nutze die geprüfte Download-Beta gemäß [Installationsanleitung](../docs/agent-installation.md). Der Paketbau des optionalen Forschungs-Installers setzt derzeit zusätzlich uv 0.12.5 aus Homebrew voraus; `scripts/package.py` prüft den festen Paketpfad. Endnutzer benötigen keine Entwicklungswerkzeuge und keinen separaten Server.

```sh
python3 scripts/bootstrap.py
swift package resolve
swift build
swift test                  # mit vollständigem Xcode/XCTest
python3 scripts/portable-checks.py  # dieselben Contract-Cases auf CLT-only Macs
python3 scripts/check-download-transport.py  # echte Downloads kleiner Loopback-Fixtures
python3 scripts/check-cloud-transport.py  # optionale Text-Cloud gegen lokalen Mockserver
python3 scripts/check-paragraph-quality.py  # vorhandenes lokales Qwen-Modell, Textfälle ohne Mikrofon/ASR
python3 scripts/check-textedit-delivery.py --include-fullscreen  # eigene TextEdit-Dokumente, bestehende AX-Freigabe
python3 scripts/package.py --development --install
swift run -c release VoiceWisprProbe format-cases docs/fixtures/formatting-contracts.json
python3 scripts/human-fixtures.py  # öffentliche CC-BY-4.0-Sprachaufnahmen
swift run -c release VoiceWisprProbe suite artifacts/fixtures/fleurs/manifest.json 3 --styles=original,cleaned,email,chat
swift run -c release VoiceWisprProbe feed-pacing-check  # Timerprüfung ohne Modelle/Mikrofon
swift run -c release VoiceWisprProbe speech-config-check --dual-decode  # tatsächlich verwendete Konfiguration, ohne Modell-Laden
python3 scripts/check-probe-config.py  # Default und kombinierte akustische Testoptionen
python3 scripts/human-fixtures.py --balanced  # nutzt ausschließlich den geprüften öffentlichen Cache
python3 scripts/build-continuous-audio-fixture.py --manifest artifacts/fixtures/fleurs/balanced/manifest.json  # bereitet exakt 20 Minuten PCM vor, ohne Modelle
mkdir -p artifacts/receipts
swift run -c release VoiceWisprProbe suite artifacts/fixtures/fleurs/balanced/manifest.json 3 --styles=original,cleaned --long --stream > artifacts/receipts/human-suite.jsonl
python3 scripts/check-human-suite.py --manifest artifacts/fixtures/fleurs/balanced/manifest.json --results artifacts/receipts/human-suite.jsonl --output artifacts/receipts/human-suite-check.json
```

`--balanced` erzeugt pro Sprache vier kurze, drei einminütige und drei 180/240/300 Sekunden lange Fälle aus den vorhandenen vollständigen Quellsätzen. Die Auswahl hängt nur von Dauer und fester Quellreihenfolge ab. Prüfsummen, Referenzen und PCM-Zeitachsen werden erhalten; es gibt keine zusätzliche Anfangs- oder Endstille. Längere Fälle enthalten verschiedene beziehungsweise wiederholte Sprecher und sind ausdrücklich zusammengesetzte Belastungstests. Drei Wiederholungen in Original und Optimiert ergeben 180 Echtzeitläufe. Diese prüfen die Modellverarbeitung; Mikrofon, Kürzel, Einfügen und persönliche Diktatqualität bleiben eigene Abnahmekriterien. Abweichende vorhandene Fixtures werden nicht überschrieben.

`check-human-suite.py` prüft die vollständige Ergebnismenge, unveränderte Quellreferenzen, feste Namen/Begriffe, Zahlenwerte und Verneinungen. Die Referenzen für alle 40 Quellen stehen in `docs/fixtures/fleurs-reference-checks.json`. Explizite Zahlwort- und Einheitenvarianten gelten nur für diese zusätzliche Prüfung; die strikte WER bleibt unverändert. Fehlende/falsche Orte, Jahre oder Einheiten können damit trotz niedriger WER durchfallen. `--allow-partial` erzeugt einen ausdrücklich ausstehenden Zwischenstand, `--self-test` prüft Gegenbeispiele ohne Modelle. Rückfälle, fehlende Ergebnisse und erste langsame Läufe bleiben sichtbar. Semantische Zusätze, der Geltungsbereich einer Verneinung und das tatsächliche OS-Einfügen benötigen weiter eigene Prüfungen; auch ein vollständiger grüner Durchlauf dieses Werkzeugs ist keine vollständige Produktabnahme.

`bootstrap.py` prüft die festgelegte llama-XCFramework-Prüfsumme. `Package.resolved` bindet FluidAudio an den geprüften Commit. Modelle sind über ein mitgeliefertes Datei-/SHA256-Verzeichnis gebunden. Die lokale SwiftPM-Mirrorkonfiguration in `.swiftpm` ist nicht Teil des Quellcodes; sie vermeidet auf dem Referenzgerät einen unnötig großen vollständigen Upstream-Clone.

Die lokalen Optimierungsfälle sind ausdrücklich synthetische Texte. Die öffentliche FLEURS-Auswahl verwendet einen festen Datenstand; Quell-/PCM-Prüfsummen und CC-BY-4.0-Provenance liegen bei den ignorierten Fixtures. Zehn gemischte Fälle sind zusammengesetzte Lesetexte verschiedener Sprecher, keine spontanen Sprachwechsel. `--settings-dictionary` liest das lokale Wörterbuch ohne Schlüsselbundzugriff und unterdrückt alle Inhaltsfelder im Probe-Receipt. `format-cases` protokolliert nur solche deklarierten Fixtures; die App speichert keine Inhalte in Diagnoseprotokollen. Der optionale lokale Textverlauf ist davon getrennt. Die lokale Glättung ist auf die Wortfolge des aktuellen Abschnitts beschränkt. Bei Diktaten über zehn Minuten prüft der abschließende Abgleich 60-Sekunden-Blöcke mit acht Sekunden akustischem Kontext. Details und weiterhin offene praktische Abnahme stehen im Prüfbericht.

Bei `SwiftUIMacros.StateMacro`-Fehlern in neuen Command Line Tools ist die passende SwiftUI-Macro-Laufzeit erforderlich. Auf dem Referenzsystem wurde der Release-Build mit `swift build --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -c release --jobs 4` geprüft. Nutze nur ein bereits vorhandenes, kompatibles SDK oder vollständiges passendes Xcode; ändere keine globale Toolchain-Konfiguration für eine Nutzerinstallation. Dieser Build-Befehl allein erstellt noch kein installierbares App-Bundle.

Die Prüfskripte `portable-checks.py`, `check-paragraph-quality.py` und `check-textedit-delivery.py` nehmen ebenfalls `--sdk /Pfad/zum/kompatiblen.sdk` an. Sie verwenden dieses SDK sowohl beim Paketbau als auch beim Kompilieren der jeweiligen Prüfung. Die Absatzprüfung liest das vorhandene lokale Wörterbuch, verändert keine Einstellungen und prüft ausschließlich deklarierte Textfälle; sie ersetzt keinen Spracherkennungstest.

Die Absatzprüfung protokolliert auch fehlgeschlagene Formatierungsversuche mit ihrer gemessenen Dauer. Die Kontrolle unveränderter Einstellungen bleibt im optimierten Prüfprogramm aktiv; ein fehlgeschlagener Fall bleibt ein Fehler.

## Aus dem Projektordner starten

Die laufende AInauten Voice über ihr App-Menü beenden, dann im Ordner `native` auf **Start Local.command** doppelklicken. Der Starter öffnet den zuletzt vorbereiteten lokalen Build und verhindert den Start, solange eine andere AInauten-Version läuft. Die App im Programme-Ordner bleibt erhalten. Im Terminal geht derselbe Start mit `./native/Start\ Local.command` aus dem Repository.

Einmalig und nach Quellcodeänderungen den lokalen Build im Ordner `native` vorbereiten:

```sh
python3 scripts/package.py --development --local \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --build-system native \
  --uv '/Applications/AInauten Voice.app/Contents/Resources/LipReading/uv'
```

Dieser Befehl verwendet das auf dem Entwicklungsgerät vorhandene kompatible SDK und den bereits installierten uv 0.12.5. Für lokale Builds wird bevorzugt die feste Testsignatur aus `.local/local-signing-identity` verwendet; andernfalls gilt die vorhandene Release-Signatur aus `.local/signing-identity`. Beide Dateien enthalten ausschließlich den öffentlichen Zertifikatsfingerabdruck; der private Schlüssel bleibt im macOS-Schlüsselbund. Die Testsignatur wird für Release-Pakete nicht automatisch verwendet.

Beim Wechsel von einer Ad-hoc-Signatur oder einer anderen Signieridentität müssen Mikrofon und Bedienungshilfen erneut bewusst freigegeben werden. Weitere lokale Builds mit derselben Testsignatur und unveränderter Bundle-ID können diese Freigaben weiterverwenden. Vorhandene Freigaben sind erst nach einem praktischen Mikrofon-/Bedienungshilfentest bestätigt. Ohne verfügbare feste Signatur bricht der Build ab. `--adhoc` ist nur eine ausdrückliche Ausnahme für Testbuilds und kann erneute Freigaben bei jedem Neubau verursachen.

Lokale Builds werden zuerst in einem temporären Ordner signiert und geprüft und ersetzen anschließend das Bundle am festen Ablageort. Der Pfad steht in `.local/local-app-path`; unterstützt sind `/Applications/AInauten Voice Dev.app`, `~/Applications/AInauten Voice Dev.app` als ausgeschriebener absoluter Pfad und der Projektpfad `.local/AInauten Voice.app`. Ohne diese Datei gilt der Projektpfad. Der Starter verwendet weiterhin `.local/AInauten Voice.app`, bei einem externen Ablageort als Verknüpfung. Eine laufende Testversion wird nicht ersetzt. Erfolgreiche lokale Builds erzeugen keine neuen Artefakt-Ordner; ältere vorhandene Builds bleiben erhalten.

Der lokale Build hat keinen Updatekanal, sodass ein öffentliches Update ihn nicht ersetzt. Modelle, Wörterbuch, Einstellungen und Schlüsselbunddienste werden weiterverwendet.

Vor der ersten Umstellung eines Schema-1-Verlaufs sichert der Starter Verlauf und Einstellungen unter `.local/backups/before-history-v2/`. Die installierte Version 0.1.4 kann den neuen Schema-2-Verlauf nicht lesen. Für eine Rückkehr zur alten Version zunächst beide Apps beenden und die gesicherte Datenbank wiederherstellen; seitdem hinzugekommene Diktate vorher aus der lokalen App exportieren. Sicherung und Builds sind privat und werden von Git ignoriert.

## Sicherheit und Zustellung

Einfügung nur in unveränderte, lesbare AX-Ziele. Bestätigung verlangt kompletten Text-/Cursor-Readback, keine bloße Tastensimulation. Bei Zweifel vollständiges Ergebnisfenster; keine automatische Wiederholung. Zwischenablage wird byteweise gesichert, bei unlesbaren/über 64 MB großen Inhalten nicht verändert; ein neuer Benutzer-Copy gewinnt. macOS stellt keine atomare Fokus-und-Paste-Operation bereit. Verzögerte Einfügeziele können nach dem 1,5-Sekunden-Fenster unklar bleiben.

Einstellungen und Wörterbuch: `~/Library/Application Support/Voice Wispr/settings.json`, atomar, versioniertes Exportformat. API-Schlüssel ausschließlich Keychain. Audio und die fünf letzten Resultate für den Schnellzugriff bleiben im Speicher. Bei eingeschaltetem Verlauf werden Diktattexte zusätzlich lokal in history.sqlite gespeichert; das lässt sich in der App abschalten. SDK-Transkript-Diagnosen und llama-Logs sind deaktiviert. Die App liest den fokussierten Text ausschließlich für lokale Zustellungsprüfung; er wird weder an ein Sprachmodell noch an Cloud gesendet.

Neue Sprachdiktate zeigen in Übersicht und Verlauf die Verarbeitungsdauer ab Aufnahmeende bis zum fertigen Text, ohne die anschließende Einfügung. Die Detailansicht trennt Modellvorbereitung, Erkennung einschließlich Abgleich und Textoptimierung. Zeiten während der Aufnahme zählen nicht zur Wartezeit; gleichzeitig laufende Schritte können sich überlappen. Modellaufrufe werden auch während der Aufnahme gezählt. Der Optimierungsstatus unterscheidet ausgeführte Modellaufrufe, automatisch übersprungene Optimierung, Original-Stil, bewusst angeforderten Originaltext und einen Rückfall bei Problemen. Ältere Einträge und Ergebnisse ohne Messung bleiben als nicht gemessen erkennbar. Schema 2 ergänzt nur optionale Messdaten; Schema-1-Verläufe werden ohne Änderung ihrer Texte und Markierungen übernommen.

Die lokale Qwen-Optimierung arbeitet weiter während der Aufnahme. Beim folgenden Abschnitt wird nur der letzte Satz des bereits bearbeiteten Textes erneut geöffnet; ältere Sätze bleiben im geprüften Cache. Die Satzgrenzen stammen aus dem bearbeiteten Text und sind eine Heuristik, keine garantierte Prüfung grammatischer Vollständigkeit. Der abschließende Erkennungsabgleich, Wortlautprüfung, Wörterbuch, Originaltext und sichtbare Rückfälle bleiben erhalten. Cloud-Optimierung nutzt weiterhin das bisherige Fenster von bis zu zwei vorherigen Sätzen.

Die Probe vergleicht diese Variante auf derselben gekennzeichneten Audio-Fixture mit `suite ... --stream --preserve-completed-sentences`; ohne den Schalter gilt das bisherige Fenster. Die Receipts enthalten zusätzlich die Verarbeitungsmessung einschließlich tatsächlicher Modellaufrufe. Synthetische Aufnahmen belegen den Vergleich auf diesem Beispiel, keine allgemeine Diktatqualität.

## Stand und Nachweise

Siehe `docs/implementation-status.md` und `docs/verification-report.md`. Build-, Contract- und UI-Prüfungen sind getrennt von realem Mikrofon-/Modell-/App-Einfügenachweis. Keine behaupteten Leistungswerte ohne Messung.

Drittlizenzen und Modellkarten: `Resources/Licenses/`.

Die Echtzeit-Probe liefert 100ms-Blöcke erst nach ihrem Aufnahmeende; die letzte Teilsekunde wird nicht aufgerundet. Die Stop-Uhr beginnt am logischen Ende der Aufnahmedauer und enthält verspätete Audiozustellung. `feed-pacing-check` prüft genau diese Fristen und einen absichtlich verzögerten letzten Block ohne Modelle. Frühere Sekundenblock-Feeds lieferten Audio zu früh: Ihre Zeiten sind keine Latenzabnahme. Der Checker weist sie standardmäßig ab; `--legacy-quality-only` erlaubt ausschließlich ihre Inhaltsdiagnose. Die Pipeline wird vor den Messungen mit der vollständigen ersten Fixture gewärmt, ohne diese aus den drei Wiederholungen auszuschließen.

`--dual-decode` ist eine diagnostische Option für den akustischen Variantenvergleich und bleibt standardmäßig aus. Der Suite-Lauf und `speech-config-check` verwenden dieselbe Konfiguration; `dualDecodeArbitration` wird im Suite-Start protokolliert. Frühere Suite-Versionen ignorierten diesen Schalter. Erst ein gemessener Vergleich auf denselben vollständigen Audiofällen kann eine Änderung der App rechtfertigen. Der Konfigurationstest allein belegt keine bessere Erkennung oder Latenz.

`--trace-stages` ergänzt ausschließlich für öffentliche FLEURS-Fixtures ohne `--settings-dictionary` lokale Zeitmessungen für ASR und Formatierung. Die Ausgabe enthält Aufruf-IDs, Zeiten, Längen und Prüfsummen; auch die regulären Case-Zeilen unterdrücken dann Text-, Zahlen- und Verneinungsinhalte sowie rohe Fehlermeldungen. Ohne den Schalter bleibt die bisherige Suite-Ausgabe erhalten. `capture-end` markiert die tatsächlich abgeschlossene Audiozustellung im Prüfprogramm, keine physische Mikrofonmessung. Überlappende Zeiten enthalten auch Wartezeit und dürfen nicht als CPU-Zeiten addiert werden. Die Option verändert weder App-Verhalten noch Modell- oder Formatierungsregeln und ist keine End-to-End-Abnahme.


### Fenster im Ruhezustand prüfen

`python3 scripts/check-window-visibility.py --stage foreground --output-dir artifacts/receipts/window-foreground` beobachtet drei Sekunden lang alle vom WindowServer gemeldeten Fenster der bereits laufenden App unter `/Applications/AInauten Voice.app`. Die Einstellungen müssen zuvor im Vordergrund geöffnet sein. Für `--stage background` muss eine andere App im Vordergrund sein, während das Einstellungsfenster auf demselben Bildschirm sichtbar bleibt. Für `--stage closed` müssen die Einstellungen geschlossen und eine andere App aktiv sein. Verwende je Zustand einen eigenen Ausgabeordner.

Der Prüfer aktiviert oder startet keine App und liest keine Diktate, Zwischenablage oder Einstellungen. Er benötigt keine Modelle und fordert keine Berechtigungen an. Rohdaten und auch fehlgeschlagene Vorbereitungen bleiben erhalten. Ein positives Ergebnis betrifft nur den beobachteten Zustand; es belegt keinen abgeschlossenen Diktiervorgang, keine weiteren Spaces oder Displays und keine Latenzabnahme.

## Sicherheitsänderungen für den nächsten Kandidaten

Der veröffentlichte Build 0.1.10 (14) ist weiterhin lokal signiert und nicht notarisiert. Neue öffentliche Pakete benötigen jetzt eine bestehende Apple Developer ID Application sowie `--notary-profile`; lokale Tests benötigen ausdrücklich `--development`. Automatische Zwischenablage-Nutzung ist im aktuellen Quellcode standardmäßig aus und erfordert Opt-in. Details und noch offene Apple-Einrichtung: [Sicherheitsnachprüfung](docs/security-followup-2026-10-06.md).
