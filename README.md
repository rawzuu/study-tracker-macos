# Study Tracker pro macOS

Nativní aplikace pro macOS k webové aplikaci [Study Tracker](https://github.com/rawzuu/study-tracker). Používá **stejná data** – co zapíšeš na Macu, uvidíš na mobilu a naopak.

Stav: **v0.5.0 – M4 hotový.** Mac synchronizuje data s GitHubem oběma směry, ukazuje Přehled, Historii (s ručním zápisem a úpravami) a Předměty, má časovač (Pomodoro, Flowtime, stopky, vlastní režimy) se šumem, zvonky a notifikacemi a Kalendář: týden a měsíc, bloky plánu s přetahováním, zkoušky, rozvrh z .ics, export do Apple Kalendáře a odebíraný kalendář. Na Přehledu radí „Co teď?“ a ráno navrhne plán dne. Opakování (FSRS) na Macu záměrně není – viz [docs/PLAN.md](docs/PLAN.md). Plán a seznam funkcí: [docs/PLAN.md](docs/PLAN.md), postup v [issues](https://github.com/rawzuu/study-tracker-macos/issues).

## Architektura

```
App/                    vstupní bod, okna, navigace (SwiftUI)
UITests/                UI testy hlavních toků (XCUITest)
Packages/StudyKit/      Swift Package s moduly aplikace
  Sources/Core/         datový model sdílený s webem – bez závislostí
    JSON/               JSON se zachováním pořadí klíčů, zápis shodný s JSON.stringify
    Model/              typované pohledy na záznamy (Session, Topic, Settings…)
    Data/               schéma, migrace, slučování (merge), stabilní zápis (serialize)
  Sources/Engine/       výpočty bez UI: kalendář v místním čase, souhrny, série, české formáty,
                        časovač, rozložení kalendáře, čtení a zápis .ics, rozvrh, koš
  Sources/Networking/   GitHub Contents API a gisty (URLSession), chyby a hlášky jako na webu
  Sources/Persistence/  lokální kopie dat (GRDB/SQLite, WAL, zálohy) a token v Klíčence
  Sources/Sync/         SyncEngine (actor): stáhnout → sloučit → nahrát se sha, režim jen čtení
  Sources/AppModel/     AppStore (@Observable), AppEnvironment (DI), připojení zálohy, časovač,
                        odebíraný kalendář, hlášky s „Vrátit“
  Sources/DesignSystem/ barvy a prvky vzhledu „Deník“
  Sources/Features/     obrazovky (SwiftUI) a jejich stavy (čisté funkce s testy)
  Tests/                testy každého modulu, */Fixtures = kontrolní data z webu
Tools/parity/           generátor kontrolních dat ze skutečného kódu webové aplikace
Config/                 xcconfig (podpis)
project.yml             definice projektu pro XcodeGen
```

Závislosti jdou jedním směrem: `Core` → `Engine` · `Networking` · `Persistence` → `Sync` → `AppModel` → `Features` (+ `DesignSystem`) → aplikace. V dalších milnících přibudou do `Engine` algoritmy (Co teď?, ranní plán, statistiky, úspěchy) a do `Networking` AnkiConnect.

**Tok dat:** View ← stav obrazovky (čistá funkce z `AppDocument`) ← `AppStore` (`@Observable @MainActor`, drží neměnný `AppDocument`) ⇄ `SyncEngine` (actor) → `LocalStore` (SQLite na Macu) a GitHub Contents API → `data.json` v soukromém repu. Závislosti se předávají přes `AppEnvironment` a protokoly (`RemoteDataFile`, `SecretStore`, `BackupService`), testy je nahrazují podvrženými implementacemi.

### Synchronizace

Stejný postup jako `syncNow()` na webu: stáhnout se `sha` → normalizovat → sloučit po záznamech (novější `updatedAt` vyhrává) → nahrát se `sha`, při konfliktu 409/422 znovu (nejvýš 4×). Spouští se po startu, při aktivaci okna, každých 5 minut jen při aktivní aplikaci, 3 s po změně, po návratu sítě a před ukončením. Commity z Macu mají zprávu `Sync dat (Mac) · …`.

- **Jen čtení:** přepínač v Nastavení – Mac pak nic nezapisuje a úpravy jsou vypnuté.
- **Jiné repo:** při připojení jiného repa se data na Macu nesloučí do nového – uloží se do zálohy na Macu a začne se od dat nového repa.
- Data z novější verze schématu ani nečitelný soubor se nikdy nepřepíšou.
- Čerstvá instalace převezme data z GitHubu celá (výchozí nastavení Macu nepřebije nastavení z jiného zařízení).
- Lokální změny se při chybě neztratí – zůstanou v SQLite a odešlou se příště.

### Proč vlastní JSON místo Codable

Webová aplikace do dat průběžně přidává nová pole a kolekce. Pevné `Codable` typy by je při zápisu zahodily a přepsaly by tak data novější verze webu. Proto:

- `AppDocument` drží celý `data.json` jako `JSONValue` a typy (`Session`, `Topic`…) jsou jen **pohledy**, které čtou a zapisují přímo do původního objektu. Neznámá pole zůstanou beze změny a na svém místě.
- `JSONObject` řadí klíče jako JavaScript a `serialized()` zapisuje bajtově stejně jako `JSON.stringify` (čísla podle `Number::toString`, stejné escapování). Web tak po synchronizaci z Macu nemá důvod soubor přepisovat.
- Slučování je oproti webu dopředně kompatibilní: neznámé kolekce (pole záznamů s `id` a `updatedAt`) slučuje po záznamech a neznámá pole bere ze vzdálené strany.
- Data s vyšší `schemaVersion`, než aplikace zná, se jen čtou.

### Paritní testy

`Tools/parity/generate.ts` prožene syntetické vstupy (pevný seed) skutečným kódem webové aplikace a výsledky uloží do `Packages/StudyKit/Tests/CoreTests/Fixtures`. Swift testy musí dát bajtově stejný výstup. `generate-engine.ts` stejně ověří kalendář, formáty a souhrny (`src/lib/time.ts`, `stats.ts`) v pražském čase – včetně dnů změny času, kdy 2:30 buď neexistuje, nebo je dvakrát – do `EngineTests/Fixtures`. `generate-planner.ts` ověří kalendář (rozložení položek, dělení přes půlnoc, odškrtnutí, obnovení z koše), čtení .ics (pásma, opakování, výjimky, přesuny), rozvrh a export .ics včetně otisku odebíraného kalendáře. `generate-advice.ts` ověří „Co teď?“ (skóre, signály, důvody, délku bloku) a ranní plán (návrh, rozmístění, nové rozmístění po úpravách) na náhodných datech bez témat – tak, jak je počítá Mac bez opakování. Funkce, které web nemá exportované (jsou uvnitř komponent), se vyjmou ze zdrojového kódu komponenty a spustí beze změny. Verze webu, proti které se testuje, je v `Tools/parity/WEB_REF`; CI každý týden zkouší i aktuální web, aby se hned ukázalo, když změní formát dat.

## Sestavení

Potřeba: macOS 15+, Xcode 26+ (Swift 6.2+), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/rawzuu/study-tracker-macos && cd study-tracker-macos
echo "DEVELOPMENT_TEAM = <Team ID>" > Config/Local.xcconfig   # podpis vlastním certifikátem
xcodegen generate
open StudyTracker.xcodeproj
```

Vývojové sestavení (Debug – Xcode ⌘R, UI testy) má identifikátor `cz.rawzuu.studytracker.dev` a jméno „Study Tracker (vývoj)“: vlastní data, nastavení i položku v Klíčence. Nikdy tak nesáhne na data nainstalované aplikace (Release, `cz.rawzuu.studytracker`) a může běžet vedle ní.

Testy:

```bash
swift test --package-path Packages/StudyKit                       # moduly (Swift Testing)
ST_KEYCHAIN_TESTS=1 swift test --package-path Packages/StudyKit   # + test skutečné Klíčenky
xcodebuild test -project StudyTracker.xcodeproj -scheme StudyTracker -destination 'platform=macOS'
TEST_RUNNER_ST_NO_SCREENSHOTS=1 xcodebuild test …                 # bez snímků (např. při vypnutém displeji)
ST_SNAPSHOT_DIR=/tmp/nahledy swift test --package-path Packages/StudyKit --filter Náhledy   # náhledy obrazovek do PNG
```

Obnovení kontrolních dat (po změně webu):

```bash
git clone https://github.com/rawzuu/study-tracker ../study-tracker-web && npm ci --prefix ../study-tracker-web
npm ci --prefix Tools/parity
WEB_DIR=$PWD/../study-tracker-web npm run generate --prefix Tools/parity
```

## Spuštění bloku ze Zkratek

Stejně jako odkaz na webu – třeba jako akce „Otevřít URL“ ve Zkratkách, přes Siri nebo Spotlight:

```
studytracker://casovac?start=1                       poslední použitý předmět
studytracker://casovac?start=1&predmet=Matematika    předmět podle názvu (stačí začátek, bez diakritiky)
studytracker://casovac?start=1&predmet=mat&tema=Derivace
```

Běžící blok odkaz nikdy nepřeruší; mezi bloky nejdřív ukončí čekající sérii.

## Připojení dat

V aplikaci **Nastavení → Synchronizace s GitHubem**: vytvoř fine-grained token jen pro Mac (repo `study-tracker-data`, *Contents: Read and write*) a vlož ho. GitHub jméno se zjistí z tokenu, token se uloží do Klíčenky macOS. Pro odebíraný kalendář potřebuje token navíc *Account permissions → Gists: Read and write*.

## Kalendář a rozvrh

- **Rozvrh:** Kalendář → Rozvrh → vyber export .ics ze školního systému. Nová verze rozvrhu ukáže před uložením, co se změní; proběhlé hodiny, skryté předměty a odpadlé termíny zůstanou.
- **Export:** Kalendář → Do kalendáře uloží soubor .ics (stálá UID – opakovaný import aktualizuje stejné události).
- **Odebíraný kalendář:** Nastavení → Odebíraný kalendář publikuje plán do tajného gistu; Apple Kalendář si ho sám stahuje. Mac i web ho po změně plánu aktualizují (se stejným obsahem, takže se navzájem nepřepisují zbytečně).
- **Apple Kalendář přímo (jen Mac):** Nastavení → Apple Kalendář. Mac zapisuje bloky (od dvou týdnů zpět) a zkoušky do vlastního kalendáře „Studijní plán“ – v iCloudu jsou hned v iPhonu, iPadu i hodinkách, bez čekání na obnovu odebíraného kalendáře. Kalendář je jen kopie `data.json`: po každé změně dat se srovná, úpravy v Kalendáři se přepíšou podle dat a ostatních kalendářů se zápis nikdy nedotkne (každá změna se ověřuje). Událost odkazuje zpátky do aplikace (`studytracker://planovac?blok=…`). Další Mac najde stejný kalendář podle názvu. Odebíraný kalendář z gistu může zůstat jako záloha – v Kalendáři si ho jen skryj, ať bloky nevidíš dvakrát.
- **Obsazený čas:** události z vybraných kalendářů (ve výchozím stavu vlastní kalendáře, ne odebírané ani narozeniny; bez celodenních, volných a odmítnutých) ranní plán obchází a Kalendář je ukazuje šedě šrafované.

## Oznámení s tlačítky

Na konci bloku přijde oznámení s tlačítky v „Možnostech“: hodnocení soustředění 1–5 (zavře i okno s hodnocením), „Bez pauzy – další blok“, „Ukončit sérii“ a – když se pauza nespouští sama – „Začít pauzu“. Na konci pauzy „Začít další blok“. Všechno bez přepnutí do aplikace; když oznámení aplikaci spustí, akce počká na načtení dat.

## Horní lišta

Ikona v horní liště ukazuje odpočet běžícího bloku (překresluje se jen tehdy, když časovač běží – v klidu nestojí žádné CPU). Okénko z lišty: dnešní čas a cíl, běžící blok s ovládáním (pozastavit, hotovo, ukončit), v klidu „Co teď?“ se spuštěním jedním kliknutím a nejbližší blok z plánu. Vypíná se v Nastavení → Horní lišta (jen pro tento Mac).

## Co teď? a ranní plán

- **Co teď?** na Přehledu doporučí, čemu se věnovat, a řekne proč: blízká zkouška, zaostávání za týdenním cílem (podle toho, kdy v týdnu se obvykle učíš), dny bez učení, blok naplánovaný na teď a prostřídání předmětů. Délka bloku vychází z toho, v jaké délce se ti v tuhle denní dobu nejlépe soustředí. „Proč“ ukáže signály všech předmětů. Na stránce Časovač je totéž doporučení s „Použít“.
- **Ranní plán** (Přehled ráno, „Naplánovat“ u dnešního plánu, Kalendář → Naplánovat den) navrhne bloky na zbytek dne až do denního cíle: přesune nedokončené bloky z posledních dvou dnů, náročnou látku dá do doby, kdy se ti nejlépe soustředí, předměty prostřídá, nechá pauzy a vyhne se výuce z rozvrhu. Návrh jde upravit (začátek, délka, odebrat, „Další blok“) a uložit do kalendáře.
- Opakování (FSRS) na Macu není, proto Mac témata k opakování nenavrhuje a nečte; ostatní výpočty jsou shodné s webem (ověřeno kontrolními daty).

## Výkon

Výpočty, které běží často, mají měření v testech (`AdvicePerformanceTests`, release, 3 200 sezení za 2 roky): „Co teď?“ ~2–3 ms, ranní plán ~3,5 ms. Sezení se z dat čtou jednou do kompaktní kopie, hodina a den v týdnu se počítají z posunu časového pásma (přesně i při změně času) a doporučení na Přehledu se přepočítají jen po změně dat nebo jednou za 5 minut.

## Bezpečnost dat

- Testy nikdy nesahají na skutečné datové repo ani na skutečnou Anki (port 8765); kontrolní data jsou syntetická.
- Kontrola na skutečných datech běží jen lokálně (`ST_REAL_DATA`, `ST_REAL_EXPECTED`), data do repa nepatří.
- Token je v Klíčence (jen pro tuto aplikaci, bez iCloudu) a nikdy se neobjeví ve výpisu ani v logu. Před prvním zápisem z Macu se datové repo zálohuje tagem.
- Aplikace běží v sandboxu, ze sítě smí jen odchozí spojení a ze souborů jen ty, které uživatel sám vybere (import a export .ics). UI testy (`-uiTesting`) běží s ukázkovými daty v paměti – nesahají na skutečná data, Klíčenku ani síť.

## Technologie

Swift 6 (strict concurrency), SwiftUI, Observation, async/await a actory, Swift Testing + XCTest/XCUITest. Jediná závislost: GRDB 7.11.1 (přesně připnutá). Bez webového obalu (Electron/WebView), jen Apple Silicon.
