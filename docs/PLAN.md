# Plán nativní verze pro macOS

Schváleno 17. 10. 2026. Cíl: plnohodnotná nativní aplikace se **stejnými funkcemi a stejnými daty** jako webová aplikace [study-tracker](https://github.com/rawzuu/study-tracker) (v době plánu v2.6.7). Webová aplikace se nemění a dál slouží na mobilu.

## Rozhodnutí

| | Rozhodnutí |
|---|---|
| Repo | veřejné (`rawzuu/study-tracker-macos`), bez jakýchkoli uživatelských dat |
| Vzhled | nativní Mac (boční panel, toolbar, okno Nastavení, menu, zkratky); od v0.7.0 vlastní vzhled „Seznam“ (jako Things 3: den jako seznam, systémové písmo, modrý akcent, barvu nesou předměty; kalendář jako Notion Calendar; volné chvíle s návrhem bloku) – schváleno 19. 10. 2026 |
| Distribuce | zatím jen pro autora – podpis certifikátem Apple Development, bez notarizace |
| Úložiště | GRDB (ne SwiftData) – zachová původní JSON každého záznamu |
| Nativní novinky | menu bar, Apple Kalendář (EventKit), Zkratky/Siri, widgety – **až po paritě a po schválení** |
| Opakování | **na Macu není** (rozhodnutí 17. 10. 2026): žádná stránka Opakování, žádné „K zopakování“, žádné FSRS, Co teď? ani ranní plán nenavrhují opakování a Mac negeneruje bloky opakování ke zkoušce ani po přednášce. Data témat zůstávají v `data.json` beze změny pro web. |

## Backend a data

Server neexistuje. Data jsou jeden soubor `data.json` v soukromém repu `study-tracker-data`, přístup přes GitHub Contents API a fine-grained token (na každém zařízení vlastní). Synchronizace: stáhnout (+`sha`) → normalizovat → sloučit po záznamech (novější `updatedAt` vyhrává, mazání je měkké `deletedAt`, nastavení jako celek) → nahrát s `sha`, při konfliktu 409/422 znovu (max. 4×).

Rizika, která řeší architektura:

1. **Neznámá pole** z novějších verzí webu se nesmí ztratit → každý záznam se drží jako původní JSON, typy jsou jen pohled (`JSONLens`).
2. **Nové kolekce** z budoucích verzí webu → každé pole záznamů s `id` + `updatedAt` se slučuje po záznamech.
3. **Pořadí klíčů** – web podle textového porovnání pozná, jestli má zapisovat → vlastní JSON se zachováním pořadí a zápisem shodným s `JSON.stringify` (ověřeno paritními testy i na skutečných datech).
4. **Novější `schemaVersion`** → aplikace data jen čte, nikdy nezapisuje.
5. **Anki** – sezení mají deterministická id (`anki-<balíček>-<start>`), takže web i Mac vytvoří stejné záznamy. **FSRS** – rozptyl intervalů v ts-fsrs je deterministický, port lze ověřit přesně.

## Parita funkcí

| Oblast | Web (v2.6.7) | Mac |
|---|---|---|
| Přehled | měřidlo dneška, Co teď?, týden po předmětech s cíli, ranní výzva, Anki panel, varování k tokenu | SwiftUI |
| Časovač | 6 režimů + vlastní, série s pauzami, auto-start, ukončení čekající série, soustředění, vyrušení, vybavení, více témat → FSRS | časové značky, žádný tikající časovač (jedno probuzení na konec fáze, překreslení 1× za s jen při běhu); stav přežije restart i uspání; šum a zvonky přes AVAudioEngine (engine běží jen, když hraje); notifikace naplánované dopředu na konec fáze; odkaz `studytracker://casovac?start=1…`; téma jen jako text sezení (bez FSRS) |
| Šum, zvonky, upozornění | hnědý/růžový/bílý šum, zvonky, notifikace | AVAudioEngine, UserNotifications |
| Odkaz pro Zkratky | `#/casovac?start=1&predmet=…&tema=…` | `studytracker://casovac?…` |
| Kalendář | týden/měsíc, odučeno vs. plán, živý blok, filtry, přetahování a změna délky po 5 min, Hotovo zapíše čas, auto-odškrtnutí | SwiftUI (vlastní `Layout` pro sloupce dne); rozložení ověřené kontrolními daty z kódu webu; běžící blok bez animace pruhů (nepřekresluje okno) |
| Zkoušky a rozvrh | rozložené opakování ke zkoušce, import rozvrhu .ics (náhled změn, skryté řady, odpadlé termíny, opakování po přednášce) | zkoušky a rozvrh 1:1, bez generovaných bloků opakování a bez přiřazení řady k předmětu (slouží jen opakování po přednášce; v datech zůstává) |
| Export kalendáře | .ics, odebíraný kalendář přes gist | .ics; odebíraný kalendář od v0.8.0 nahradil přímý zápis do Apple Kalendáře (gist dál aktualizuje web) |
| Opakování | FSRS-6, 4 hodnocení, historie opakování, hlídání zkoušky | **vynecháno** |
| Co teď? a ranní plán | skóre z 6 signálů, simulace, prokládání, nejlepší okno soustředění | port bez signálu opakování a bez opakování po přednášce; témata se nečtou; výsledky shodné s webem (kontrolní data), předpočítané údaje sdílí simulace ranního plánu. Navíc (schváleno 19. 10. 2026): plán na zítřek, do neděle a na příští týden; „Co teď?“ ukazuje předmět, ne „Pokračovat: téma“ |
| Statistiky | heatmapy, trend, den × hodina, soustředění, série | Swift Charts |
| Report, reflexe | postřehy, návrhy úprav (kalibrace), tisk/PDF, týdenní reflexe | systémový tisk do PDF |
| Úspěchy | 119 úspěchů, stabilní id, medaile, trvalé záznamy | stejná id a výpočet (kontrolní data), trvalé záznamy; místo medailí řádky s úrovněmi |
| Historie, předměty | úpravy, ruční zápis, CSV, barvy, cíle, archivace, mazání i s plány | SwiftUI |
| Nastavení | vše vč. vypínatelných funkcí, skrytých stránek, zálohy (token → login) | token v Klíčence |
| Data | koš 30 dní, JSON export/import se sloučením | stejná logika |
| Anki | AnkiConnect, panel, odhad času, čas do statistik, mapování balíčků | v0.9.0 (předsunuto z M6, schváleno 20. 10. 2026): AnkiConnect přímo z Macu bez omezení Safari, souhrn na stránce Dnes, zapnutí jen pro tento Mac; zápis shodný s webem (kontrolní data) |
| Onboarding | průvodce pro nové uživatele | SwiftUI |

Jinak než na webu: PWA, service worker, CSP a synchronizace mezi záložkami nahrazuje App Sandbox (síť jen `api.github.com` a `127.0.0.1:8765`). Běžící časovač je – stejně jako na webu – jen na daném zařízení.

## Milníky

Každý milník končí releasem. Před každou změnou, která poprvé zapisuje data, záloha datového repa tagem.

| # | Obsah | Výsledek |
|---|---|---|
| M0 | repo, XcodeGen, balíčky, CI, Core (JSON, modely, merge, serialize), paritní testy | build + zelené testy |
| M1 | Klíčenka, GRDB, SyncEngine **jen čtení**, Přehled/Historie/Předměty jen pro čtení | data na Macu; po kontrole záloha `zaloha-pred-macos` a zapnutí zápisu |
| M2 ✓ | Časovač, Přehled, šum, zvonky, notifikace, URL odkaz | každodenní používání (v0.3.0) |
| M3 ✓ | Kalendář, zkoušky, rozvrh .ics, export a odebíraný kalendář | v0.4.0 |
| M4 ✓ | Co teď?, ranní plán (bez opakování) | v0.5.0 |
| M4+ ✓ | Integrace s macOS (schváleno 18. 10. 2026): velký monitor, Apple Kalendář (EventKit), horní lišta, oznámení s akcemi, Zkratky a Siri, widgety | v0.6.0, #27–#32 |
| M5 ✓ | Statistiky, report a kalibrace, reflexe, úspěchy (úspěchy jako seznam místo kovových medailí – bez žluté, vzhled „Seznam“) | v0.9.0 |
| M6 (část) ✓ | Nastavení jako na webu (cíle, časovač, funkce, vlastní režimy), koš, export JSON/CSV a import se sloučením (Anki už v v0.9.0); zbývá onboarding | v0.10.0 |
| M6+ ✓ | Jen Mac (schváleno 21. 10. 2026): automatická pauza po nečinnosti, zkratky při bloku, klávesové zkratky odkudkoli, pondělní souhrn | v0.11.0 |
| M8 | Soustředění (schváleno 28. 10. 2026): blokování aplikací a webů v Safari, čas u obrazovky, přísnost a pojistky proti obcházení, statistiky – viz níže | F1–F6 v v0.12.0, opravy v0.12.1, F7–F8 v0.13.0 |
| M7 | profilování v Instruments, optimalizace, výkonnostní testy | v1.0.0 |

Cíle výkonu: studený start < 0,4 s, paměť v klidu < 60 MB, CPU v klidu ≈ 0 %.

## M8 Soustředění

Blokování aplikací a webů a měření času u obrazovky, jen na tomto Macu (v `data.json` nic, web beze změny).

Ověřeno 28. 10. 2026 (pokus mimo repo, macOS 27, bezplatný Personal Team):
- Screen Time API (FamilyControls, ManagedSettings, DeviceActivity) je v SDK macOS 27 `@available(macOS, unavailable)` – pro aplikace na Macu není.
- Systémový síťový filtr (Network Extension) vyžaduje placený Apple Developer Program – nepoužívá se.
- Sandboxovaná aplikace nesmí registrovat pomocníka bez sandboxu („SMAppService target executable must be sandboxed because the app is sandboxed“). Řešení: Strážce (aplikace bez sandboxu uvnitř balíčku) se zaregistruje sám (`SMAppService.agent` z vlastního balíčku) – funguje, stav hned `enabled`, launchd ho po pádu znovu spustí (KeepAlive).
- Sdílený kontejner (app group) čtou i zapisují obě strany bez dotazu systému; Strážce vidí aplikaci v popředí, nečinnost, umí jinou aplikaci schovat i ukončit.
- Apple Events k Safari (adresa záložky) chtějí jednorázový souhlas uživatele (Automatizace).

| Krok | Obsah |
|---|---|
| F1 ✓ | ověření (výše) |
| F2 ✓ | modul `Focus` (nastavení, seznamy, plány, přísnost, závazky, porovnání webů, měření) a `FocusStore` (databáze ve sdíleném kontejneru), testy |
| F3 ✓ | Strážce: blokování aplikací, blokovací obrazovka, měření času; první stránka Soustředění; navíc denní limit, výjimky v seznamu, slova v adrese, „Jen učení“ |
| F4 ✓ | Safari: rozšíření (declarativeNetRequest + kontrola při navigaci) a pojistka přes adresu záložky |
| F5 ✓ | odemykání na blokovací obrazovce (i ze Safari): odklad, opsání textu (bez vložení), týdenní limit, po restartu Macu, heslo, jen v daném čase, přísný zámek; obrazovka s odpočtem, počtem pokusů a větou k učení |
| F6 ✓ | stránka Soustředění: editory seznamů (aplikace z Aplikací i spuštěné, weby, výjimky, slova), plánů (blok učení, časová okna, Studijní plán, denní limit) a přísnosti, ruční zámek, zamčené úpravy během přísného zámku, statistiky (čas po dnech, nejvíc času, pokusy po dnech a hodinách, porušení) |
| F7 ✓ | napojení na časovač (co se blokuje pod časovačem), pondělní souhrn (čas u obrazovky, pokusy), horní lištu (stav a rychlý zámek 25 min – 4 h, i přísně) |
| F8 ✓ | blíž Cold Turkey: týdenní rozvrh jako mřížka (malování tahem, přehled v Plánech), jiné prohlížeče blokované s weby, posunutí hodin Macu neukončí přísný zámek (závazky se prodlouží, zapíše se porušení), zavírání zablokovaných záložek Safari i na pozadí, hromadné vložení a načtení webů ze souboru |
