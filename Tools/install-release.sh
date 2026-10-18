#!/bin/sh
# Nainstaluje sestavenou verzi (Release) do /Applications. Nic se nemaže: předchozí verze se přesune
# do zálohy v ~/Library/Application Support/Study Tracker – zálohy aplikace. Data jsou v kontejneru
# aplikace (a na GitHubu) a výměna aplikace se jich nedotkne.
set -eu
cd "$(dirname "$0")/.."
NEW="build/DerivedData/Build/Products/Release/StudyTracker.app"
APP="/Applications/StudyTracker.app"
[ -d "$NEW" ] || { echo "Chybí sestavená verze ($NEW)."; exit 1; }
codesign --verify --deep --strict "$NEW"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$NEW/Contents/Info.plist")
if pgrep -x StudyTracker >/dev/null; then
    echo "Study Tracker běží – ukonči ho (⌘Q) a spusť skript znovu."
    exit 1
fi
BACKUP="$HOME/Library/Application Support/Study Tracker – zálohy aplikace/$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$BACKUP"
if [ -d "$APP" ]; then
    OLD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
    mv "$APP" "$BACKUP/"
    echo "Předchozí verze $OLD je v záloze: $BACKUP"
fi
ditto "$NEW" "$APP"
codesign --verify --deep --strict "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
Tools/dev/unregister-dev.sh >/dev/null
open "$APP"
echo "Nainstalováno: Study Tracker $VERSION"
