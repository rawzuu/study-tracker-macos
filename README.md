# Study Tracker pro macOS

Nativní aplikace pro macOS k webové aplikaci [Study Tracker](https://github.com/rawzuu/study-tracker). Používá **stejná data** – co zapíšeš na Macu, uvidíš na mobilu a naopak.

Stav: **M0 – kostra a datové jádro.** Plán a seznam funkcí: [docs/PLAN.md](docs/PLAN.md), postup v [issues](https://github.com/rawzuu/study-tracker-macos/issues).

## Architektura

```
App/                    vstupní bod, okna, navigace (SwiftUI)
UITests/                UI testy hlavních toků (XCUITest)
Packages/StudyKit/      Swift Package s moduly aplikace
  Sources/Core/         datový model sdílený s webem – bez závislostí
    JSON/               JSON se zachováním pořadí klíčů, zápis shodný s JSON.stringify
    Model/              typované pohledy na záznamy (Session, Topic, Settings…)
    Data/               schéma, migrace, slučování (merge), stabilní zápis (serialize)
  Tests/CoreTests/      unit a paritní testy, Fixtures/ = kontrolní data z webu
Tools/parity/           generátor kontrolních dat ze skutečného kódu webové aplikace
Config/                 xcconfig (podpis)
project.yml             definice projektu pro XcodeGen
```

Další moduly přibývají s milníky: `Engine` (algoritmy – FSRS-6, Co teď?, ranní plán, statistiky, úspěchy), `Networking` (GitHub, AnkiConnect), `Persistence` (GRDB, Klíčenka), `Sync` (actor pro synchronizaci), `DesignSystem` a jednotlivé `Features`.

**Tok dat:** View → `@Observable @MainActor` ViewModel → `AppStore` (drží neměnný `AppDocument`) → actory `Persistence` a `Sync` → GitHub Contents API → `data.json` v soukromém repu. Závislosti se předávají jako protokoly, testy je nahrazují falešnými implementacemi.

### Proč vlastní JSON místo Codable

Webová aplikace do dat průběžně přidává nová pole a kolekce. Pevné `Codable` typy by je při zápisu zahodily a přepsaly by tak data novější verze webu. Proto:

- `AppDocument` drží celý `data.json` jako `JSONValue` a typy (`Session`, `Topic`…) jsou jen **pohledy**, které čtou a zapisují přímo do původního objektu. Neznámá pole zůstanou beze změny a na svém místě.
- `JSONObject` řadí klíče jako JavaScript a `serialized()` zapisuje bajtově stejně jako `JSON.stringify` (čísla podle `Number::toString`, stejné escapování). Web tak po synchronizaci z Macu nemá důvod soubor přepisovat.
- Slučování je oproti webu dopředně kompatibilní: neznámé kolekce (pole záznamů s `id` a `updatedAt`) slučuje po záznamech a neznámá pole bere ze vzdálené strany.
- Data s vyšší `schemaVersion`, než aplikace zná, se jen čtou.

### Paritní testy

`Tools/parity/generate.ts` prožene syntetické vstupy (pevný seed) skutečným kódem webové aplikace a výsledky uloží do `Packages/StudyKit/Tests/CoreTests/Fixtures`. Swift testy musí dát bajtově stejný výstup. Verze webu, proti které se testuje, je v `Tools/parity/WEB_REF`; CI každý týden zkouší i aktuální web, aby se hned ukázalo, když změní formát dat.

## Sestavení

Potřeba: macOS 15+, Xcode 26+ (Swift 6.2+), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/rawzuu/study-tracker-macos && cd study-tracker-macos
echo "DEVELOPMENT_TEAM = <Team ID>" > Config/Local.xcconfig   # podpis vlastním certifikátem
xcodegen generate
open StudyTracker.xcodeproj
```

Testy:

```bash
swift test --package-path Packages/StudyKit                       # jádro (Swift Testing)
xcodebuild test -project StudyTracker.xcodeproj -scheme StudyTracker -destination 'platform=macOS'
```

Obnovení kontrolních dat (po změně webu):

```bash
git clone https://github.com/rawzuu/study-tracker ../study-tracker-web && npm ci --prefix ../study-tracker-web
npm ci --prefix Tools/parity
WEB_DIR=$PWD/../study-tracker-web npm run generate --prefix Tools/parity
```

## Bezpečnost dat

- Testy nikdy nesahají na skutečné datové repo ani na skutečnou Anki (port 8765); kontrolní data jsou syntetická.
- Kontrola na skutečných datech běží jen lokálně (`ST_REAL_DATA`, `ST_REAL_EXPECTED`), data do repa nepatří.
- Token bude uložený v Klíčence. Před prvním zápisem z Macu se datové repo zálohuje tagem.

## Technologie

Swift 6 (strict concurrency), SwiftUI, Observation, async/await a actory, Swift Testing + XCTest/XCUITest. Jediná plánovaná závislost: GRDB. Bez webového obalu (Electron/WebView), jen Apple Silicon.
