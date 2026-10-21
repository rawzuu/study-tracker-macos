#!/bin/sh
# Nainstaluje Study Tracker z této složky do /Applications. Nic se nemaže: předchozí verze se přesune
# do zálohy v ~/Library/Application Support/Study Tracker – zálohy aplikace. Data (kontejner aplikace
# a GitHub) se výměnou aplikace nemění.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
NEW="$HERE/StudyTracker.app"
APP="/Applications/StudyTracker.app"
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
codesign --verify --deep --strict "$NEW"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$NEW/Contents/Info.plist")
if pgrep -x StudyTracker >/dev/null; then
    echo "Study Tracker běží – ukonči ho (⌘Q) a spusť instalaci znovu."
    exit 1
fi
BACKUP="$HOME/Library/Application Support/Study Tracker – zálohy aplikace/$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$BACKUP"
if [ -d "$APP" ]; then
    OLD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
    mv "$APP" "$BACKUP/"
    "$LS" -u "$BACKUP/StudyTracker.app" 2>/dev/null || true
    echo "Předchozí verze $OLD je v záloze: $BACKUP"
fi
ditto "$NEW" "$APP"
codesign --verify --deep --strict "$APP"
# Jen kopie v /Applications – ať se widgety a odkazy nepletou s kopií ve Stažených souborech.
"$LS" -u "$NEW" 2>/dev/null || true
pluginkit -r "$NEW/Contents/PlugIns/StudyTrackerWidgets.appex" 2>/dev/null || true
"$LS" -f "$APP"
# Proces widgetů ze staré verze běží dál i po výměně aplikace a macOS jeho výstup odmítá
# („Bundle version did not match“) – widgety pak zůstanou prázdné. Ukončit; systém spustí nový.
pkill -x StudyTrackerWidgets 2>/dev/null || true
open "$APP"
echo "Nainstalováno: Study Tracker ${VERSION}. Složku „Study Tracker ${VERSION}“ ve Stažených souborech můžeš smazat."
