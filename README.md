# Study Tracker pro macOS

Nativní aplikace pro macOS k webové aplikaci [Study Tracker](https://github.com/rawzuu/study-tracker). Používá **stejná data** – co zapíšeš na Macu, uvidíš na mobilu a naopak.

Stav: **v0.9.0 – Anki přímo na Macu a milník M5: Statistiky, Měsíční report s kalibrací, Reflexe a Úspěchy.** Mac synchronizuje data s GitHubem oběma směry, ukazuje Dnes (den jako seznam bloků s volnými chvílemi a návrhy), Historii (s ručním zápisem a úpravami) a Předměty, má časovač (Pomodoro, Flowtime, stopky, vlastní režimy) se šumem, zvonky a notifikacemi a Kalendář: týden a měsíc, bloky plánu s přetahováním, zkoušky, rozvrh z .ics a export do Apple Kalendáře. Na stránce Dnes radí „Co teď?“ (jaký předmět) a ranní plán navrhne bloky na dnešek, zítřek, do neděle nebo na příští týden. Navíc oproti webu: plán přímo v Apple Kalendáři a obsazený čas z ostatních kalendářů, horní lišta, oznámení s tlačítky, akce pro Zkratky a widgety; rozvržení využije celou šířku velkého monitoru. Anki čte Mac přímo přes AnkiConnect (karty na dnešek, čas z Anki jako sezení se stejnými id jako na webu). Opakování (FSRS) na Macu záměrně není – viz [docs/PLAN.md](docs/PLAN.md). Plán a seznam funkcí: [docs/PLAN.md](docs/PLAN.md), postup v [issues](https://github.com/rawzuu/study-tracker-macos/issues).

## Architektura

```
App/                    vstupní bod, okna, horní lišta, navigace, akce pro Zkratky (SwiftUI, App Intents)
Widgets/                rozšíření widgetů – jen registrace widgetů a akce tlačítek (WidgetKit)
UITests/                UI testy hlavních toků (XCUITest)
Packages/StudyKit/      Swift Package s moduly aplikace
  Sources/Core/         datový model sdílený s webem – bez závislostí
    JSON/               JSON se zachováním pořadí klíčů, zápis shodný s JSON.stringify
    Model/              typované pohledy na záznamy (Session, Topic, Settings…)
    Data/               schéma, migrace, slučování (merge), stabilní zápis (serialize)
  Sources/Engine/       výpočty bez UI: kalendář v místním čase, souhrny, série, české formáty,
                        časovač, rozložení kalendáře, čtení a zápis .ics, rozvrh, koš
  Sources/Networking/   GitHub Contents API a AnkiConnect (URLSession), chyby a hlášky jako na webu
  Sources/Persistence/  lokální kopie dat (GRDB/SQLite, WAL, zálohy) a token v Klíčence
  Sources/Sync/         SyncEngine (actor): stáhnout → sloučit → nahrát se sha, režim jen čtení
  Sources/AppModel/     AppStore (@Observable), AppEnvironment (DI), připojení zálohy, časovač,
                        Apple Kalendář, hlášky s „Vrátit“
  Sources/DesignSystem/ barvy a prvky vzhledu „Seznam“
  Sources/Features/     obrazovky (SwiftUI) a jejich stavy (čisté funkce s testy)
  Sources/WidgetData/   souhrn pro widgety a příkazy z jejich tlačítek (jen Foundation)
  Sources/WidgetUI/     vzhled a časová osa widgetů (bez dat, sítě a databáze – malá paměť)
  Tests/                testy každého modulu, */Fixtures = kontrolní data z webu
Tools/parity/           generátor kontrolních dat ze skutečného kódu webové aplikace
Config/                 xcconfig (podpis)
project.yml             definice projektu pro XcodeGen
```

Závislosti jdou jedním směrem: `Core` → `Engine` · `Networking` · `Persistence` → `Sync` → `AppModel` → `Features` (+ `DesignSystem`) → aplikace. 

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

`Tools/parity/generate.ts` prožene syntetické vstupy (pevný seed) skutečným kódem webové aplikace a výsledky uloží do `Packages/StudyKit/Tests/CoreTests/Fixtures`. Swift testy musí dát bajtově stejný výstup. `generate-engine.ts` stejně ověří kalendář, formáty a souhrny (`src/lib/time.ts`, `stats.ts`) v pražském čase – včetně dnů změny času, kdy 2:30 buď neexistuje, nebo je dvakrát – do `EngineTests/Fixtures`. `generate-planner.ts` ověří kalendář (rozložení položek, dělení přes půlnoc, odškrtnutí, obnovení z koše), čtení .ics (pásma, opakování, výjimky, přesuny), rozvrh a export .ics včetně otisku odebíraného kalendáře. `generate-advice.ts` ověří „Co teď?“ (skóre, signály, důvody, délku bloku) a ranní plán (návrh, rozmístění, nové rozmístění po úpravách) na náhodných datech bez témat – tak, jak je počítá Mac bez opakování. `generate-anki.ts` ověří čas z Anki (`runAnkiSync` s podvrženou Anki) `generate-report.ts` měsíční report, postřehy, týdenní souhrn a návrhy kalibrace (`periodStats`, `highlights`, `calibrate`) a `generate-achievements.ts` všech 119 úspěchů (`evaluate`, `toPersist`, `describe`). Funkce, které web nemá exportované (jsou uvnitř komponent), se vyjmou ze zdrojového kódu komponenty a spustí beze změny. Verze webu, proti které se testuje, je v `Tools/parity/WEB_REF`; CI každý týden zkouší i aktuální web, aby se hned ukázalo, když změní formát dat.

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

Spotřeba v klidu (vývojové sestavení s ukázkovými daty v paměti, spuštěné skrytě): `Tools/dev/idle-cpu.sh` – CPU má být ≈ 0 %.

Instalace sestavené verze do /Applications (předchozí verze se uloží jako ZIP do zálohy, nic se nemaže). `Tools/package-release.sh` připraví složku pro uživatele ve Stažených souborech: `StudyTracker.zip` + `Nainstalovat.command`. Aplikace je všude jen v ZIPu – rozbalenou kopii (Stažené soubory, zálohy) by si macOS zaregistroval i s widgety a galerie by ukazovala staré widgety vedle nových:

```bash
xcodebuild build -project StudyTracker.xcodeproj -scheme StudyTracker -configuration Release -derivedDataPath build/DerivedData
Tools/install-release.sh
```

Obnovení kontrolních dat (po změně webu):

```bash
git clone https://github.com/rawzuu/study-tracker ../study-tracker-web && npm ci --prefix ../study-tracker-web
npm ci --prefix Tools/parity
WEB_DIR=$PWD/../study-tracker-web npm run generate --prefix Tools/parity
```

## Zkratky, Spotlight a Siri

Aplikace má vlastní akce v aplikaci Zkratky (App Intents): **Začít učení** (předmět, téma, režim – bez předmětu podle „Co teď?“, během pauzy pokračuje dalším blokem), **Pozastavit**, **Pokračovat**, **Hotovo – uložit blok**, **Ukončit učení**, **Co se mám teď učit?** a **Dnešní učení** (vrací minuty). Akce běží v aplikaci se stejným stavem jako okno; když aplikace neběží, systém ji spustí a akce počká na načtení dat. Logika je v `StudyActions` (AppModel) s testy.

Režim Soustředění: ve Zkratkách stačí spojit „Nastavit režim Soustředění“ a „Začít učení“ (a obráceně „Ukončit učení“ s vypnutím). Siri česky neumí – anglické věty („Start studying in Study Tracker“) fungují se Siri v angličtině.

### Odkaz

Stejně jako odkaz na webu – třeba jako akce „Otevřít URL“ ve Zkratkách:

```
studytracker://casovac?start=1                       poslední použitý předmět
studytracker://casovac?start=1&predmet=Matematika    předmět podle názvu (stačí začátek, bez diakritiky)
studytracker://casovac?start=1&predmet=mat&tema=Derivace
```

Běžící blok odkaz nikdy nepřeruší; mezi bloky nejdřív ukončí čekající sérii.

## Připojení dat

V aplikaci **Nastavení → Synchronizace s GitHubem**: vytvoř fine-grained token jen pro Mac (repo `study-tracker-data`, *Contents: Read and write*) a vlož ho. GitHub jméno se zjistí z tokenu, token se uloží do Klíčenky macOS.

## Kalendář a rozvrh

- **Rozvrh:** Kalendář → Rozvrh → vyber export .ics ze školního systému. Nová verze rozvrhu ukáže před uložením, co se změní; proběhlé hodiny, skryté předměty a odpadlé termíny zůstanou.
- **Export:** Kalendář → Do kalendáře uloží soubor .ics (stálá UID – opakovaný import aktualizuje stejné události).
- **Odebíraný kalendář** (gist) je od v0.8.0 jen na webu – Mac ho nahradil přímým zápisem do Apple Kalendáře. Nastavení v datech Mac nemění, takže web ho dál aktualizuje, pokud je zapnutý.
- **Apple Kalendář přímo (jen Mac):** Nastavení → Apple Kalendář. Mac zapisuje bloky (od dvou týdnů zpět) a zkoušky do vlastního kalendáře „Studijní plán“ – v iCloudu jsou hned v iPhonu, iPadu i hodinkách, bez čekání na obnovu odebíraného kalendáře. Kalendář je jen kopie `data.json`: po každé změně dat se srovná, úpravy v Kalendáři se přepíšou podle dat a ostatních kalendářů se zápis nikdy nedotkne (každá změna se ověřuje). Událost odkazuje zpátky do aplikace (`studytracker://planovac?blok=…`). Další Mac najde stejný kalendář podle názvu – převezme ho ale jen tehdy, když v něm jsou výhradně události Study Trackeru (cizí kalendář se stejným názvem nikdy nepřepíše). Když máš v Kalendáři i odebíraný plán z gistu, zruš jeho odběr, ať bloky nevidíš dvakrát.
- **Obsazený čas:** události z vybraných kalendářů (ve výchozím stavu vlastní kalendáře, ne odebírané ani narozeniny; bez celodenních, volných a odmítnutých) ranní plán obchází a Kalendář je ukazuje v barvě jejich kalendáře. Události ve stejném čase jako hodina z importovaného rozvrhu se neukazují – výuku ukáže rozvrh (dá se v něm označit, že odpadla, a pak se čas uvolní).

## Anki

Nastavení má stejné volby jako web (motiv, denní cíl, chování časovače, volitelné funkce, vlastní režimy časovače) – jsou synchronizované, změna na Macu platí i na webu. **Záloha** uloží data do souboru (JSON, bajtově stejný jako `data.json` na GitHubu) nebo sezení do CSV pro Excel/Numbers; import zálohu sloučí s aktuálními daty a nic nesmaže. **Koš** ukáže smazané položky za 30 dní a vrátí je jedním kliknutím. Koš a CSV jsou ověřené kontrolními daty z kódu webu (`Tools/parity/generate-backup.ts`).

**Jen na tomto Macu** (UserDefaults, web je nemá):
- **Automatická pauza** – po nastavené době bez myši a klávesnice (výchozí 10 min, jde vypnout) nebo hned při zamčení či uspání se běžící blok učení pozastaví zpětně k poslední aktivitě. Po návratu oznámení nabídne „Pokračovat“, nebo „Pokračovat a započítat i pauzu“ (učení z knihy). Kontroluje se jen během bloku (`AwayMonitor`, nečinnost z `CGEventSource`).
- **Zkratky při bloku** – volitelně spustí zkratku ze Zkratek na začátku a na konci bloku (třeba zapnout a vypnout Nerušit); pozastavení se nepočítá (`BlockAutomation`, `shortcuts://run-shortcut`).
- **Klávesové zkratky odkudkoli** – spustit / pozastavit blok (výchozí ⌃⌥P) a otevřít okno; nahrávají se v Nastavení (`HotKeyCenter`, Carbon `RegisterEventHotKey` – bez oprávnění Zpřístupnění, i v sandboxu).
- **Pondělní souhrn** – v pondělí od 8:00 jedno oznámení: čas proti týdennímu cíli, nejlepší den, změna proti týdnu předtím a blížící se zkouška (`WeeklySummary`); kliknutí otevře Statistiky.

Nastavení → Anki: jednou do desktopové Anki doplněk AnkiConnect (kód 2055492159), pak zapnout „Načítat z Anki na tomto Macu“ (platí jen pro tento Mac, sdílené nastavení `anki.enabled` webu se nemění). Mac se každé 2 minuty a po návratu do aplikace zeptá Anki na `127.0.0.1:8765` (výjimka ATS jen pro místní adresy), zapíše dnešní stav balíčků (`anki` → `snapshot`) a opakování jako sezení `anki-<balíček>-<začátek>` – stejně jako web v2.6.7 (`runAnkiSync`), ověřeno kontrolními daty z jeho kódu (`Tools/parity/generate-anki.ts`). Přiřazení balíčků k předmětům, počítání času a délka historie jsou sdílené s webem. Testy a UI testy používají Anki v paměti, nikdy skutečnou Anki.

## Oznámení s tlačítky

Na konci bloku přijde oznámení s tlačítky v „Možnostech“: hodnocení soustředění 1–5 (zavře i okno s hodnocením), „Bez pauzy – další blok“, „Ukončit sérii“ a – když se pauza nespouští sama – „Začít pauzu“. Na konci pauzy „Začít další blok“. Všechno bez přepnutí do aplikace; když oznámení aplikaci spustí, akce počká na načtení dat.

## Widgety

Na plochu a do Centra oznámení: **Dnešek** (malý, střední), **Časovač** (malý, střední – živý odpočet, pauza, hotovo, v klidu „Co teď?“ se spuštěním), **Plán** (střední, velký – i zítřek a zkouška), **Zkoušky** (malý, střední) a **Přehled** (velký a extra velký – pro velký monitor).

- Aplikace zapisuje do sdíleného kontejneru (app group) malý souhrn – jen odvozený výřez z dat, zdrojem pravdy zůstává `data.json`. Zapisuje a překresluje widgety jen při skutečné změně (WidgetKit má denní limit překreslení).
- Widget si stav dopočítá sám: odpočet běží živě (systémový časovač, žádné překreslování), během bloku se kruh posune každou minutu, na začátku a konci bloků a o půlnoci se přepne sám – i když aplikace neběží.
- Tlačítka: když aplikace běží, pošlou příkaz rovnou (soubor v kontejneru + Darwin oznámení), widget hned ukáže očekávaný stav a do vteřiny skutečný; když neběží, aplikaci otevřou odkazem a příkaz provedou po načtení dat.
- Vzhled Seznam ve světlém i tmavém režimu a v tlumeném režimu plochy (vibrant). Náhledy: `ST_SNAPSHOT_DIR=… swift test --filter WidgetSnapshots`.
- Vývojové sestavení má vlastní kontejner a vlastní widgety („Study Tracker (vývoj)“); po lokálním buildu ho odregistruj (`Tools/dev/unregister-dev.sh`), ať se v galerii widgetů neplete.

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
