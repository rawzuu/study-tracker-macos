#!/bin/sh
# Spustí vývojové sestavení s ukázkovými daty v paměti (-uiTesting, nic skutečného) a změří CPU
# a paměť. Bez argumentu skrytě a v klidu: CPU má být ≈ 0 % – jinak se něco točí ve smyčce.
# S argumentem (stránka: prehled, casovac, planovac…) běží ukázkový blok a okno se zobrazí
# na pozadí (bez aktivace), aby se opravdu vykreslovalo – měří se zátěž s běžícím časovačem.
set -eu
cd "$(dirname "$0")/../.."
APP="$PWD/build/DerivedData/Build/Products/Debug/StudyTracker.app"
[ -d "$APP" ] || { echo "Nejdřív sestav Debug (xcodebuild … -configuration Debug -derivedDataPath build/DerivedData)."; exit 1; }
PATTERN="Debug/StudyTracker.app/Contents/MacOS/StudyTracker"
BEFORE=$(pgrep -f "$PATTERN" || true)
# Vždy po sobě ukončit všechny kopie spuštěné tímto skriptem (jinak zůstanou ikony v liště).
cleanup() {
    for p in $(pgrep -f "$PATTERN" || true); do
        echo "$BEFORE" | grep -qx "$p" || kill "$p" 2>/dev/null || true
    done
    Tools/dev/unregister-dev.sh >/dev/null 2>&1 || true
}
trap cleanup EXIT
if [ $# -gt 0 ]; then
    open -g -n "$APP" --args -uiTesting -measureTimer "$1"
    LABEL="CPU s běžícím blokem ($1)"
else
    open -g -j -n "$APP" --args -uiTesting
    LABEL="CPU v klidu"
fi
PID=""
for _ in $(seq 1 100); do
    PID=$(pgrep -f "$PATTERN" | grep -vxF "$BEFORE" | head -1 || true)
    [ -n "$PID" ] && break
    sleep 0.1
done
[ -n "$PID" ] || { echo "Aplikace se nespustila."; exit 1; }
# první 3 vzorky = start, dál ustálený stav
top -l 15 -pid "$PID" -stats cpu,mem -s 1 | awk -v label="$LABEL" '$0 ~ /^ *[0-9.]+ +[0-9]/ { n++; if (n > 3) { cpu += $1; mem = $2; k++ } } END { printf "%s: %.1f %% · paměť: %s\n", label, cpu / k, mem }'
footprint "$PID" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]* [KMG]B\).*/footprint: \1/p'
