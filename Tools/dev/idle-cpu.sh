#!/bin/sh
# Spustí vývojové sestavení skrytě s ukázkovými daty v paměti (-uiTesting, nic skutečného) a změří
# CPU a paměť v klidu. V klidu má být CPU ≈ 0 % – jinak se něco točí ve smyčce.
set -eu
cd "$(dirname "$0")/../.."
APP="$PWD/build/DerivedData/Build/Products/Debug/StudyTracker.app"
[ -d "$APP" ] || { echo "Nejdřív sestav Debug (xcodebuild … -configuration Debug -derivedDataPath build/DerivedData)."; exit 1; }
open -g -j -n "$APP" --args -uiTesting
PID=""
for _ in $(seq 1 100); do
    PID=$(pgrep -f "Debug/StudyTracker.app/Contents/MacOS/StudyTracker" | head -1 || true)
    [ -n "$PID" ] && break
done
[ -n "$PID" ] || { echo "Aplikace se nespustila."; exit 1; }
# první 3 vzorky = start, dál klid
top -l 12 -pid "$PID" -stats cpu,mem -s 1 | awk -v pid="$PID" '$0 ~ /^ *[0-9.]+ +[0-9]/ { n++; if (n > 3) { cpu += $1; mem = $2; k++ } } END { printf "CPU v klidu: %.1f %% · paměť: %s\n", cpu / k, mem }'
kill "$PID"
Tools/dev/unregister-dev.sh >/dev/null
