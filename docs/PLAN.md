# Plán nativní verze pro macOS

Schváleno 17. 10. 2026. Cíl: plnohodnotná nativní aplikace se **stejnými funkcemi a stejnými daty** jako webová aplikace [study-tracker](https://github.com/rawzuu/study-tracker) (v době plánu v2.6.7). Webová aplikace se nemění a dál slouží na mobilu.

## Rozhodnutí

| | Rozhodnutí |
|---|---|
| Repo | veřejné (`rawzuu/study-tracker-macos`), bez jakýchkoli uživatelských dat |
| Vzhled | nativní Mac (boční panel, toolbar, okno Nastavení, menu, zkratky) s paletou a písmem webového vzhledu „Deník“ |
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
| Časovač | 6 režimů + vlastní, série s pauzami, auto-start, ukončení čekající série, soustředění, vyrušení, vybavení, více témat → FSRS | časové značky; notifikace naplánované na konec bloku; téma jen jako text sezení (bez FSRS) |
| Šum, zvonky, upozornění | hnědý/růžový/bílý šum, zvonky, notifikace | AVAudioEngine, UserNotifications |
| Odkaz pro Zkratky | `#/casovac?start=1&predmet=…&tema=…` | `studytracker://casovac?…` |
| Kalendář | týden/měsíc, odučeno vs. plán, živý blok, filtry, přetahování a změna délky po 5 min, Hotovo zapíše čas, auto-odškrtnutí | SwiftUI Canvas |
| Zkoušky a rozvrh | rozložené opakování ke zkoušce, import rozvrhu .ics (náhled změn, skryté řady, odpadlé termíny, opakování po přednášce) | zkoušky a rozvrh 1:1, bez generovaných bloků opakování |
| Export kalendáře | .ics, odebíraný kalendář přes gist | stejné API |
| Opakování | FSRS-6, 4 hodnocení, historie opakování, hlídání zkoušky | **vynecháno** |
| Co teď? a ranní plán | skóre z 6 signálů, simulace, prokládání, nejlepší okno soustředění | port bez signálu opakování |
| Statistiky | heatmapy, trend, den × hodina, soustředění, série | Swift Charts |
| Report, reflexe | postřehy, návrhy úprav (kalibrace), tisk/PDF, týdenní reflexe | systémový tisk do PDF |
| Úspěchy | 119 úspěchů, stabilní id, medaile, trvalé záznamy | stejná id |
| Historie, předměty | úpravy, ruční zápis, CSV, barvy, cíle, archivace, mazání i s plány | SwiftUI |
| Nastavení | vše vč. vypínatelných funkcí, skrytých stránek, zálohy (token → login) | token v Klíčence |
| Data | koš 30 dní, JSON export/import se sloučením | stejná logika |
| Anki | AnkiConnect, panel, odhad času, čas do statistik, mapování balíčků | bez omezení Safari |
| Onboarding | průvodce pro nové uživatele | SwiftUI |

Jinak než na webu: PWA, service worker, CSP a synchronizace mezi záložkami nahrazuje App Sandbox (síť jen `api.github.com` a `127.0.0.1:8765`). Běžící časovač je – stejně jako na webu – jen na daném zařízení.

## Milníky

Každý milník končí releasem. Před každou změnou, která poprvé zapisuje data, záloha datového repa tagem.

| # | Obsah | Výsledek |
|---|---|---|
| M0 | repo, XcodeGen, balíčky, CI, Core (JSON, modely, merge, serialize), paritní testy | build + zelené testy |
| M1 | Klíčenka, GRDB, SyncEngine **jen čtení**, Přehled/Historie/Předměty jen pro čtení | data na Macu; po kontrole záloha `zaloha-pred-macos` a zapnutí zápisu |
| M2 | Časovač, Přehled, šum, zvonky, notifikace, URL odkaz | každodenní používání |
| M3 | Kalendář, zkoušky, rozvrh .ics, export a odebíraný kalendář | |
| M4 | Co teď?, ranní plán (bez opakování) | |
| M5 | Statistiky, report a kalibrace, reflexe, úspěchy | |
| M6 | Nastavení, koš, export/import, Anki, onboarding | parita |
| M7 | profilování v Instruments, optimalizace, výkonnostní testy | v1.0.0 |

Cíle výkonu: studený start < 0,4 s, paměť v klidu < 60 MB, CPU v klidu ≈ 0 %.
