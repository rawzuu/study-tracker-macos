#!/bin/sh
# Nainstaluje Study Tracker z této složky do /Applications. Nic se nemaže: předchozí verze se uloží
# jako ZIP do zálohy v ~/Library/Application Support/Study Tracker – zálohy aplikace. Data (kontejner
# aplikace a GitHub) se výměnou aplikace nemění.
#
# Aplikace je ve složce i v záloze jen jako ZIP: macOS si každou rozbalenou kopii aplikace, kterou
# najde (Stažené soubory, zálohy), zaregistruje i s jejími widgety – v galerii widgetů pak byly
# staré widgety vedle nových a Dock mohl ukázat špatnou ikonu.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ZIP="$HERE/StudyTracker.zip"
APP="/Applications/StudyTracker.app"
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BACKUPS="$HOME/Library/Application Support/Study Tracker – zálohy aplikace"
[ -f "$ZIP" ] || { echo "Ve složce chybí StudyTracker.zip."; exit 1; }
if pgrep -x StudyTracker >/dev/null; then
    echo "Study Tracker běží – ukonči ho (⌘Q) a spusť instalaci znovu."
    exit 1
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ZIP" "$WORK"
NEW="$WORK/StudyTracker.app"
codesign --verify --deep --strict "$NEW"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$NEW/Contents/Info.plist")
# Starší zálohy uložené jako rozbalená aplikace převést na ZIP (obsah zůstane stejný).
if [ -d "$BACKUPS" ]; then
    find "$BACKUPS" -maxdepth 2 -name "StudyTracker.app" -type d | while read -r old; do
        dir="$(dirname "$old")"
        "$LS" -u "$old" 2>/dev/null || true
        ditto -c -k --keepParent "$old" "$dir/StudyTracker.zip" && rm -rf "$old"
    done
fi
if [ -d "$APP" ]; then
    OLD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
    BACKUP="$BACKUPS/$(date +%Y-%m-%d-%H%M%S)"
    mkdir -p "$BACKUP"
    ditto -c -k --keepParent "$APP" "$BACKUP/StudyTracker.zip"
    "$LS" -u "$APP" 2>/dev/null || true
    rm -rf "$APP"
    echo "Předchozí verze $OLD je v záloze: $BACKUP/StudyTracker.zip"
fi
ditto "$NEW" "$APP"
codesign --verify --deep --strict "$APP"
"$LS" -u "$NEW" 2>/dev/null || true
pluginkit -r "$NEW/Contents/PlugIns/StudyTrackerWidgets.appex" 2>/dev/null || true
"$LS" -f "$APP"
# Proces widgetů ze staré verze běží dál i po výměně aplikace a macOS jeho výstup odmítá
# („Bundle version did not match“) – widgety pak zůstanou prázdné. Ukončit; systém spustí nový.
pkill -x StudyTrackerWidgets 2>/dev/null || true
open "$APP"
echo "Nainstalováno: Study Tracker ${VERSION}. Složku „Study Tracker ${VERSION}“ ve Stažených souborech můžeš smazat."
