#!/bin/sh
# Odregistruje vývojové sestavení (Debug, cz.rawzuu.studytracker.dev) z LaunchServices a jeho widgety
# z pluginkitu – po lokálním buildu se jinak „Study Tracker (vývoj)“ objeví v galerii widgetů a odkazy
# studytracker:// by mohly otevírat vývojovou aplikaci místo nainstalované.
set -e
cd "$(dirname "$0")/../.."
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for app in build/*/Build/Products/*/StudyTracker.app; do
    [ -d "$app" ] || continue
    pluginkit -r "$PWD/$app/Contents/PlugIns/StudyTrackerWidgets.appex" 2>/dev/null || true
    "$LS" -u "$PWD/$app" 2>/dev/null || true
    echo "odregistrováno: $app"
done
