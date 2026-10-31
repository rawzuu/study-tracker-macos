#!/bin/bash
# Zkouška skutečného Strážce (ne náhražek z unit testů): sestavený Strážce se spustí jako u launchd,
# dostane nastavení z Tools/ci/guard-e2e a musí opravdu schovat TextEdit, ukázat blokovací obrazovku,
# zapsat pokus, zmrazit Mac (Finder zakrytý, ne schovaný) a po zrušení všechno pustit.
# JEN na CI – na skutečném Macu by blokoval aplikace.
set -euo pipefail
[ "${CI:-}" = "true" ] || { echo "Jen na CI: Strážce by blokoval aplikace na tomto Macu."; exit 1; }
cd "$(dirname "$0")/../.."

APP=${1:-build/dd/Build/Products/Debug/StudyTracker.app}
GUARD="$APP/Contents/Library/LoginItems/StudyTrackerGuard.app"
PLIST="$GUARD/Contents/Info.plist"
LABEL=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$PLIST")
GROUP=$(/usr/libexec/PlistBuddy -c "Print STAppGroup" "$PLIST")
DIR="$HOME/Library/Group Containers/$GROUP/Focus"
LOG=build/guard-e2e.log
PROBE=build/guard-probe
TEXTEDIT=com.apple.TextEdit
echo "Strážce: $LABEL · kontejner: $GROUP"

swiftc -O Tools/ci/guard-probe.swift -o "$PROBE"
mkdir -p "$DIR"
rm -f "$DIR"/state.json "$DIR"/focus.sqlite*

GPID=""
cleanup() {
    [ -n "$GPID" ] && kill "$GPID" 2>/dev/null || true
    pkill -x TextEdit 2>/dev/null || true
}
trap cleanup EXIT

fail() {
    echo "CHYBA: $1"
    echo "--- stav: $("$PROBE" "$TEXTEDIT" "${GPID:-0}")"
    echo "--- zpráva Strážce:"; cat "$DIR/state.json" 2>/dev/null || echo "(žádná)"
    echo "--- log Strážce:"; cat "$LOG" 2>/dev/null || true
    /usr/bin/log show --last 3m --style compact --predicate 'subsystem == "cz.rawzuu.studytracker"' 2>/dev/null | tail -30 || true
    exit 1
}

# Čeká (nejvýš 15 s), až výpis pomocníka obsahuje všechna slova, např. "hidden=1 guardWindows=[1-9]".
expect() {
    local app=$1 what=$2; shift 2
    local out=""
    for _ in $(seq 1 30); do
        out=$("$PROBE" "$app" "${GPID:-0}")
        local ok=1
        for pattern in "$@"; do echo "$out" | grep -Eq "$pattern" || ok=0; done
        [ $ok = 1 ] && { echo "✓ $what ($out)"; return 0; }
        sleep 0.5
    done
    fail "$what – čekáno: $* · je: $out"
}

use() {
    cp "Tools/ci/guard-e2e/$1.json" "$DIR/config.json"
    notifyutil -p "$GROUP.focus-config"
}

attempts() { sqlite3 "$DIR/focus.sqlite" "select count(*) from event where kind = 'attempt'" 2>/dev/null || echo 0; }

# TextEdit běží dřív, než začne zámek.
echo "zkouška" > build/guard-e2e.txt
open -a TextEdit build/guard-e2e.txt
expect "$TEXTEDIT" "TextEdit běží" "running=1" "hidden=0"

# 1) Ruční zámek na TextEdit: Strážce ho po startu schová.
use block
XPC_SERVICE_NAME="$LABEL" "$GUARD/Contents/MacOS/StudyTrackerGuard" > "$LOG" 2>&1 &
GPID=$!
for _ in $(seq 1 30); do [ -f "$DIR/state.json" ] && break; sleep 0.5; done
[ -f "$DIR/state.json" ] || fail "Strážce nezapsal zprávu (kontejner $DIR)"
kill -0 "$GPID" 2>/dev/null || fail "Strážce skončil"
echo "✓ Strážce běží a píše zprávu"
expect "$TEXTEDIT" "běžící zakázaná aplikace je schovaná" "hidden=1"

# 2) Pokus o otevření: zase schovaná, blokovací obrazovka, zapsaný pokus.
open -a TextEdit
expect "$TEXTEDIT" "otevření zablokováno, blokovací obrazovka" "hidden=1" "guardWindows=[1-9]"
sleep 3
expect "$TEXTEDIT" "obrazovka zůstala (neproblikla)" "hidden=1" "guardWindows=[1-9]"
for _ in $(seq 1 20); do [ "$(attempts)" -ge 1 ] && break; sleep 0.5; done
[ "$(attempts)" -ge 1 ] || fail "pokus se nezapsal do databáze"
echo "✓ pokus zapsán ($(attempts)×)"

# 3) Zmrazení: TextEdit schovaný, Finder se neschovává, jen ho zakryje obrazovka.
use freeze
open -a TextEdit
expect "$TEXTEDIT" "zmrazení: TextEdit schovaný, obrazovka zmrazení" "hidden=1" "guardWindows=[1-9]"
open -a Finder
expect com.apple.finder "zmrazení: Finder neschovaný, ale zakrytý" "hidden=0" "guardWindows=[1-9]"

# 4) Konec zmrazení: obrazovka zmizí a TextEdit jde otevřít.
use free
expect "$TEXTEDIT" "po zrušení obrazovka zmizela" "guardWindows=0"
open -a TextEdit
expect "$TEXTEDIT" "po zrušení TextEdit jde otevřít" "hidden=0" "front=$TEXTEDIT"
kill -0 "$GPID" 2>/dev/null || fail "Strážce během zkoušky spadl"
echo "Strážce funguje."
