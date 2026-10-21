#!/bin/sh
# Připraví instalaci sestavené verze (Release) ve Stažených souborech: složka „Study Tracker <verze>“
# se StudyTracker.zip a Nainstalovat.command. Aplikace je jen v ZIPu – rozbalenou kopii by si macOS
# zaregistroval (widgety navíc v galerii, jiná ikona v Docku).
set -eu
cd "$(dirname "$0")/.."
APP="build/DerivedData/Build/Products/Release/StudyTracker.app"
[ -d "$APP" ] || { echo "Chybí sestavená verze ($APP)."; exit 1; }
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DEST="$HOME/Downloads/Study Tracker $VERSION"
rm -rf "$DEST"
mkdir -p "$DEST"
ditto -c -k --keepParent "$APP" "$DEST/StudyTracker.zip"
cp Tools/Nainstalovat.command "$DEST/"
chmod +x "$DEST/Nainstalovat.command"
# Ani sestavení v build/ nemá zůstat zaregistrované.
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LS" -u "$PWD/$APP" 2>/dev/null || true
pluginkit -r "$PWD/$APP/Contents/PlugIns/StudyTrackerWidgets.appex" 2>/dev/null || true
Tools/dev/unregister-dev.sh >/dev/null 2>&1 || true
echo "$DEST"
