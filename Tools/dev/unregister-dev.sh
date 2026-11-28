#!/bin/sh
# Odregistruje sestavení ve složce build/ (Debug i Release) z LaunchServices a jejich widgety
# a rozšíření Safari z pluginkitu – po lokálním buildu se jinak „Study Tracker (vývoj)“ objeví v galerii widgetů,
# odkazy studytracker:// by mohly otevírat kopii z build/ místo nainstalované a widgety by běžely z build/.
#
# Sestavení patří do build/DerivedData.noindex: složku s příponou .noindex Spotlight neprochází, takže si
# macOS kopie z ní sám znovu nezaregistruje (stalo se po aktualizaci systému se složkou bez přípony).
set -e
cd "$(dirname "$0")/../.."
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for app in build/*/Build/Products/*/StudyTracker.app; do
    [ -d "$app" ] || continue
    pluginkit -r "$PWD/$app/Contents/PlugIns/StudyTrackerWidgets.appex" 2>/dev/null || true
    pluginkit -r "$PWD/$app/Contents/PlugIns/StudyTrackerSafari.appex" 2>/dev/null || true
    "$LS" -u "$PWD/$app/Contents/Library/LoginItems/StudyTrackerGuard.app" 2>/dev/null || true
    "$LS" -u "$PWD/$app" 2>/dev/null || true
    echo "odregistrováno: $app"
done
# Samostatné produkty vedle aplikace (Strážce před vložením do aplikace, spouštěč UI testů).
for app in build/*/Build/Products/*/StudyTrackerGuard.app build/*/Build/Products/*/StudyTrackerUITests-Runner.app; do
    [ -d "$app" ] || continue
    "$LS" -u "$PWD/$app" 2>/dev/null || true
done
