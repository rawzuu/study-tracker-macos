#!/bin/sh
# Nainstaluje sestavenou verzi (Release) do /Applications stejně jako instalace pro uživatele:
# připraví složku ve Stažených souborech (Tools/package-release.sh) a spustí její Nainstalovat.command.
# Předchozí verze se uloží jako ZIP do ~/Library/Application Support/Study Tracker – zálohy aplikace.
set -eu
cd "$(dirname "$0")/.."
DEST=$(Tools/package-release.sh)
"$DEST/Nainstalovat.command"
