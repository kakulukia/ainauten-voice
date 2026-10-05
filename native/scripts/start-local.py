#!/usr/bin/env python3
"""Launch the prepared local app after preserving the pre-migration history."""

import datetime
import pathlib
import shutil
import sqlite3
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
app = root / ".local/AInauten Voice.app"
if not app.is_dir():
    raise SystemExit(
        "Lokale App fehlt. Zuerst den lokalen Build laut native/README.md erstellen."
    )
running = subprocess.run(["pgrep", "-x", "VoiceWispr"], capture_output=True)
if running.returncode == 0:
    raise SystemExit(
        "Bitte AInauten Voice zuerst über das App-Menü beenden und dann erneut starten. Es läuft bereits eine Version."
    )
if running.returncode != 1:
    raise SystemExit(
        "Laufende App konnte nicht geprüft werden. Der lokale Start wurde abgebrochen."
    )

support = pathlib.Path.home() / "Library/Application Support/Voice Wispr"
history = support / "history.sqlite"
backup = root / ".local/backups/before-history-v2"
if history.exists():
    with sqlite3.connect(history.as_uri() + "?mode=ro", uri=True) as source:
        if (
            source.execute("PRAGMA user_version").fetchone()[0] == 1
            and not backup.exists()
        ):
            staging = backup.with_name(
                "before-history-v2-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            )
            staging.mkdir(parents=True, mode=0o700)
            with sqlite3.connect(staging / "history.sqlite") as target:
                source.backup(target)
            settings = support / "settings.json"
            if settings.exists():
                shutil.copy2(settings, staging / "settings.json")
            staging.rename(backup)
            print("Verlauf und Einstellungen vor der Umstellung gesichert:", backup)

subprocess.run(["open", "-a", str(app.resolve())], check=True)
print("Start der lokalen AInauten Voice angefordert:", app.resolve())
