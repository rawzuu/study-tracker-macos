/**
 * Kontrolní data pro kalendář, zkoušky a rozvrh: výsledky SKUTEČNÉHO kódu webu v pražském čase.
 * Swift testy (Packages/StudyKit/Tests/EngineTests) musí dát stejný výsledek.
 *
 *   WEB_DIR=…/study-tracker npm run generate
 *
 * Část logiky je na webu uvnitř komponent (rozložení kalendáře, předvyplnění zápisu z bloku) a není
 * exportovaná. Takové funkce se vyjmou ze zdrojového kódu komponenty (`extract`) a spustí beze změny,
 * takže kontrolní data pořád počítá kód webu, ne jeho přepis.
 *
 * Každá část má vlastní seed – přidání nové části nezmění data těch dřívějších.
 * Vstupy jsou syntetické – skutečná data uživatele sem nikdy nepatří.
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { transformSync } from 'esbuild';

const here = import.meta.dirname;
const WEB = resolve(process.env.WEB_DIR ?? join(here, '../../../study-tracker-web'));
const OUT = resolve(process.env.ENGINE_OUT_DIR ?? join(here, '../../Packages/StudyKit/Tests/EngineTests/Fixtures'));

if (Intl.DateTimeFormat().resolvedOptions().timeZone !== 'Europe/Prague') {
  throw new Error('Spusť s TZ=Europe/Prague (npm run generate to dělá samo).');
}

const load = (p: string) => import(pathToFileURL(join(WEB, p)).href);
const T = await load('src/lib/time.ts');
const M = await load('src/features/planner/match.ts');
const TR = await load('src/lib/trash.ts');
const IC = await load('src/lib/ical.ts');
const TT = await load('src/lib/timetable.ts');
const ICS = await load('src/features/planner/ics.ts');
const FEED = await load('src/features/planner/calendarFeed.ts');
const { emptyData } = await load('src/data/schema.ts');
const { MIN, HOUR, DAY } = T as { MIN: number; HOUR: number; DAY: number };

/**
 * Neexportovaná funkce `name` ze souboru webu: soubor se převede na JavaScript (bez typů),
 * vyjme se text funkce a spustí se se zadanými závislostmi.
 */
function extract<F>(file: string, name: string, scope: Record<string, unknown>): F {
  const js = transformSync(readFileSync(join(WEB, file), 'utf8'), { loader: 'tsx', jsx: 'preserve' }).code;
  const start = js.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`${file}: funkce ${name} nenalezena`);
  // konec parametrů (mohou obsahovat výchozí hodnoty se závorkami), pak tělo po odpovídající závorku
  let i = js.indexOf('(', start);
  for (let depth = 0; ; i++) {
    if (js[i] === '(') depth++;
    else if (js[i] === ')' && --depth === 0) break;
  }
  let j = js.indexOf('{', i);
  for (let depth = 0, quote = ''; ; j++) {
    const ch = js[j];
    if (quote) {
      if (ch === '\\') j++;
      else if (ch === quote) quote = '';
    } else if (ch === "'" || ch === '"') quote = ch;
    else if (ch === '{') depth++;
    else if (ch === '}' && --depth === 0) break;
  }
  const source = js.slice(start, j + 1);
  return new Function(...Object.keys(scope), `${source}\nreturn ${name};`)(...Object.values(scope)) as F;
}

/** Deterministická náhoda (mulberry32) – každá část svůj seed. */
function random(seed: number) {
  const rnd = () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return {
    rnd,
    int: (lo: number, hi: number) => lo + Math.floor(rnd() * (hi - lo + 1)),
    pick: <T>(xs: readonly T[]): T => xs[Math.floor(rnd() * xs.length)],
    chance: (p: number) => rnd() < p,
  };
}

function write(name: string, value: unknown) {
  writeFileSync(join(OUT, name), JSON.stringify(value) + '\n');
}

/** Dny, na kterých se nejčastěji něco pokazí: změny času, přelom měsíce a roku, přestupný den. */
const DAYS = [
  [2026, 2, 28], [2026, 2, 29], [2026, 2, 30], [2026, 9, 24], [2026, 9, 25], [2026, 9, 26],
  [2026, 11, 31], [2027, 0, 1], [2028, 1, 29], [2026, 4, 12], [2026, 6, 1],
].map(([y, m, d]) => new Date(y, m, d).getTime());

// ---------- 1. kalendář: rozložení dne, dělení přes půlnoc, odškrtnutí, zápis z bloku, obnovení ----------
function planner() {
  const { int, pick, chance } = random(0x9a11e7);
  type Item = { kind: string; id: string; subjectId: string; start: number; end: number; title: string; span?: [number, number] };
  const layoutDay = extract<(items: Item[]) => Map<string, { lane: number; lanes: number }>>('src/features/planner/PlannerPage.tsx', 'layoutDay', { MIN });
  const splitAtMidnight = extract<(it: Item) => Item[]>('src/features/planner/PlannerPage.tsx', 'splitAtMidnight', { addDays: T.addDays, startOfDay: T.startOfDay });
  const fromBlock = extract<(b: unknown, now: number) => { start: number; minutes: number }>('src/features/sessions/HistoryPage.tsx', 'fromBlock', {});
  const kinds = ['plan', 'done', 'live', 'lecture'];

  // Překrývající se položky jednoho dne – i se shodnými začátky (pořadí řazení rozhoduje o sloupcích).
  const layout = Array.from({ length: 400 }, (_, n) => {
    const day = pick(DAYS);
    const slots = [int(6, 20) * 60, int(6, 20) * 60];
    const items: Item[] = Array.from({ length: int(1, n < 20 ? 3 : 12) }, (_, i) => {
      const start = T.atMinutes(day, chance(0.4) ? pick(slots) : int(6 * 12, 22 * 12) * 5);
      const dur = pick([0, 5, 10, 15, 19, 20, 21, 30, 45, 50, 60, 90, 120, 240]);
      return { kind: pick(kinds), id: `i${i}`, subjectId: '', start, end: start + dur * MIN, title: '' };
    });
    const lanes = layoutDay(items);
    return { items, lanes: items.map((it) => [it.id, lanes.get(it.id)!.lane, lanes.get(it.id)!.lanes]) };
  });

  // Položky kolem půlnoci – i ve dnech změny času (den má 23 nebo 25 hodin).
  const split = Array.from({ length: 300 }, (_, i) => {
    const day = pick(DAYS);
    const start = T.atMinutes(day, int(18 * 12, 24 * 12 - 1) * 5) + (chance(0.1) ? int(1, 59_999) : 0);
    const end = start + pick([1, 30, 60, 120, 300, 26 * 60]) * MIN + (chance(0.2) ? int(-30, 30) * MIN : 0);
    const it: Item = { kind: pick(kinds), id: `x${i}`, subjectId: 's', start, end, title: 't' };
    return { item: it, parts: splitAtMidnight(it).map((p) => ({ id: p.id, start: p.start, end: p.end, span: p.span ?? null })) };
  });

  // Odškrtnutí bloků podle sezení: shodný předmět a dostatečný překryv.
  const match = Array.from({ length: 300 }, () => {
    const base = pick(DAYS) + 8 * HOUR;
    const blocks = Array.from({ length: int(1, 6) }, (_, i) => {
      const b: Record<string, unknown> = {
        id: `b${i}`,
        subjectId: pick(['a', 'b']),
        title: '',
        start: base + int(0, 40) * 15 * MIN,
        durationMin: pick([5, 10, 20, 25, 29, 30, 31, 45, 60, 90]),
        done: chance(0.2),
        note: '',
        createdAt: 1,
        updatedAt: 1,
      };
      if (chance(0.15)) b.deletedAt = pick([0, 5]);
      return b;
    });
    const sessions = Array.from({ length: int(0, 4) }, (_, i) => {
      const start = base + int(-8, 160) * 5 * MIN;
      const s: Record<string, unknown> = { id: `s${i}`, subjectId: pick(['a', 'b']), start, end: start + int(1, 30) * 5 * MIN };
      if (chance(0.1)) s.deletedAt = 7;
      return s;
    });
    const span = { subjectId: pick(['a', 'b']), start: base + int(-8, 160) * 5 * MIN, minutes: int(1, 30) * 5 };
    const end = span.start + span.minutes * MIN;
    return {
      blocks,
      sessions,
      span: { subjectId: span.subjectId, start: span.start, end },
      matched: M.matchPlanBlocks(blocks, span.subjectId, span.start, end).map((b: { id: string }) => b.id),
      hasSession: blocks.map((b) => M.blockHasSession(sessions, b)),
    };
  });

  // Předvyplnění zápisu z bloku („Hotovo“): blok v budoucnu, právě probíhající i dávno skončený.
  const prefill = Array.from({ length: 200 }, () => {
    const start = pick(DAYS) + int(0, 23 * 12) * 5 * MIN;
    const block = { start, durationMin: pick([5, 25, 45, 50, 90, 240]) };
    const now = start + int(-120, 400) * MIN + int(0, 59_999);
    return { block, now, ...fromBlock(block, now) };
  });

  // Obnovení z koše: zkouška vrátí bloky smazané se stejnou chvílí (±5 s), předmět své plány, zkoušky a témata.
  const restore = Array.from({ length: 100 }, (_, n) => {
    const d = emptyData();
    const at = 1_760_000_000_000 + int(0, 10 ** 6) * 1000;
    const del = () => (chance(0.5) ? at + pick([0, 1, -4999, 4999, 5000, -6000, 60_000]) : chance(0.3) ? 0 : undefined);
    const ent = (id: string, extra: Record<string, unknown>) => {
      const e: Record<string, unknown> = { id, ...extra, createdAt: 1, updatedAt: 2 };
      const x = del();
      if (x !== undefined) e.deletedAt = x;
      return e;
    };
    d.subjects = ['a', 'b'].map((id) => ent(id, { name: id.toUpperCase(), color: '#7d9cc0', weeklyGoalMin: 0, archived: false }));
    d.exams = ['e1', 'e2'].map((id) => ent(id, { subjectId: pick(['a', 'b']), name: id, date: '2026-11-02', time: '', note: '' }));
    d.planBlocks = Array.from({ length: int(0, 6) }, (_, i) => {
      const b = ent(`p${i}`, { subjectId: pick(['a', 'b']), title: '', start: at, durationMin: 45, done: chance(0.3), note: '' });
      if (chance(0.6)) b.examId = pick(['e1', 'e2']);
      return b;
    });
    d.topics = Array.from({ length: int(0, 3) }, (_, i) => ent(`t${i}`, { subjectId: pick(['a', 'b']), name: `T${i}`, stage: -1, lastStudiedAt: null, nextReviewAt: null, reviews: 0, mastered: false, note: '' }));
    d.sessions = [ent('s0', { subjectId: 'a', topic: '', start: at, end: at + HOUR, durationSec: 3600, mode: 'manual', interruptions: 0, note: '' })];
    const key = n < 10 ? 'sessions' : pick(['exams', 'exams', 'subjects', 'subjects', 'planBlocks', 'topics']);
    const list = d[key] as { id: string }[];
    const id = list.length ? pick(list).id : 'chybi';
    const now = at + 3_600_000;
    const out = TR.restoreEntity(d, key, id, now);
    // výstup jen dotčených kolekcí (nastavení se nemění) – zápis jako JSON.stringify, tedy i pořadí klíčů
    const touched = Object.fromEntries(['subjects', 'sessions', 'planBlocks', 'exams', 'topics'].map((k) => [k, out[k]]));
    return { input: JSON.stringify(d), key, id, now, output: JSON.stringify(touched) };
  });

  write('planner.json', { layout, split, match, prefill, restore });
}

// ---------- 2. rozvrh .ics: čtení (parseIcs) ----------
/** Ručně psané kalendáře na ošemetné případy: pásma, změny času, výjimky, přesuny, zalomené řádky… */
const ICS_CASES: string[] = [
  'BEGIN:VEVENT\nSUMMARY:Bez kalendáře\nEND:VEVENT',
  '',
  [
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'X-WR-CALNAME:Rozvrh\\, LS 2026', 'X-WR-TIMEZONE:Europe/Prague',
    'BEGIN:VTIMEZONE', 'TZID:Europe/Prague', 'BEGIN:STANDARD', 'DTSTART:19701025T030000', 'TZOFFSETFROM:+0200', 'TZOFFSETTO:+0100', 'END:STANDARD', 'END:VTIMEZONE',
    'BEGIN:VEVENT', 'UID:anat-pr', 'SUMMARY:Anatomie – přednáška', 'LOCATION:Posluchárna A\\, 2. patro', 'DTSTART;TZID=Europe/Prague:20260921T091500',
    'DTEND;TZID=Europe/Prague:20260921T104500', 'RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261216', 'EXDATE;TZID=Europe/Prague:20261028T091500,20261102T091500',
    'BEGIN:VALARM', 'TRIGGER:-PT10M', 'SUMMARY:Alarm se nepočítá', 'END:VALARM', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:anat-pr', 'RECURRENCE-ID;TZID=Europe/Prague:20261007T091500', 'SUMMARY:Anatomie – přednáška (přesunuto)',
    'DTSTART;TZID=Europe/Prague:20261008T130000', 'DTEND;TZID=Europe/Prague:20261008T143000', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:anat-pr', 'RECURRENCE-ID;TZID=Europe/Prague:20261014T091500', 'STATUS:CANCELLED', 'DTSTART;TZID=Europe/Prague:20261014T091500', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:zapoc', 'SUMMARY:Zápočtový týden', 'DTSTART;VALUE=DATE:20261214', 'DTEND;VALUE=DATE:20261219', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:zrus', 'SUMMARY:Zrušeno', 'STATUS:cancelled', 'DTSTART:20261001T100000', 'DTEND:20261001T110000', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:dlouhy', 'SUMMARY:Seminář s dlouhým názvem, který se v exportu zalomí na víc řádků a musí se zase', ' spojit dohromady', 'DTSTART:20261002T',
    '\t080000', 'DURATION:PT1H30M', 'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n'),
  // UTC, denní opakování s intervalem a počtem, výjimky v UTC
  ['BEGIN:VCALENDAR', 'BEGIN:VEVENT', 'UID:d', 'SUMMARY:Ranní', 'DTSTART:20261023T060000Z', 'DTEND:20261023T070000Z',
    'RRULE:FREQ=DAILY;INTERVAL=2;COUNT=6', 'EXDATE:20261027T060000Z', 'EXDATE;VALUE=DATE:20261029', 'END:VEVENT', 'END:VCALENDAR'].join('\n'),
  // místní čas bez pásma ve dnech změny času (2:30 neexistuje / je dvakrát)
  ['BEGIN:VCALENDAR', 'BEGIN:VEVENT', 'SUMMARY:Noční jaro', 'DTSTART:20260322T023000', 'DTEND:20260322T033000', 'RRULE:FREQ=WEEKLY;COUNT=3', 'END:VEVENT',
    'BEGIN:VEVENT', 'SUMMARY:Noční podzim', 'DTSTART:20261018T023000', 'DURATION:PT2H', 'RRULE:FREQ=WEEKLY;COUNT=3', 'END:VEVENT',
    'BEGIN:VEVENT', 'SUMMARY:Praha jaro', 'DTSTART;TZID=Europe/Prague:20260322T023000', 'DTEND;TZID=Europe/Prague:20260322T033000', 'RRULE:FREQ=WEEKLY;COUNT=3', 'END:VEVENT',
    'BEGIN:VEVENT', 'SUMMARY:Praha podzim', 'DTSTART;TZID=Europe/Prague:20261018T023000', 'DTEND;TZID=Europe/Prague:20261018T033000', 'RRULE:FREQ=WEEKLY;COUNT=3', 'END:VEVENT',
    'END:VCALENDAR'].join('\n'),
  // různá pásma, i neznámá a psaná malými písmeny
  ['BEGIN:VCALENDAR',
    ...['America/New_York', 'Asia/Kolkata', 'Australia/Lord_Howe', 'Europe/London', 'UTC', 'Etc/GMT-2', 'Mars/Olympus', 'europe/prague', 'Central Europe Standard Time', '"Europe/Prague"']
      .flatMap((tz, i) => ['BEGIN:VEVENT', `UID:tz${i}`, `SUMMARY:Pásmo ${tz}`, `DTSTART;TZID=${tz}:20261026T083000`, `DTEND;TZID=${tz}:20261026T100000`,
        'RRULE:FREQ=WEEKLY;BYDAY=MO,TH;COUNT=4', 'END:VEVENT']),
    'END:VCALENDAR'].join('\n'),
  // řazení a duplicity: stejný začátek, různé názvy (i lišící se jen mezerami)
  ['BEGIN:VCALENDAR',
    ...['Anatomie – cvičení B', 'anatomie – cvičení A', 'Ánatomie', 'Zoologie', '  Matematika   I  ', 'Matematika I', 'Matematika I', '10. seminář', '9. seminář', 'Čeština', 'Cvičení', 'Chemie']
      .flatMap((t, i) => ['BEGIN:VEVENT', `UID:s${i}`, `SUMMARY:${t}`, 'DTSTART:20261020T100000', 'DTEND:20261020T113000', 'END:VEVENT']),
    'BEGIN:VEVENT', 'DTSTART:20261020T100000', 'DTEND:20261020T110000', 'LOCATION:Bez názvu \\n\\N\\;\\\\x', 'END:VEVENT',
    'END:VCALENDAR'].join('\n'),
  // podivná pravidla opakování a délky
  ['BEGIN:VCALENDAR',
    ...[
      'FREQ=MONTHLY;COUNT=3', 'FREQ=WEEKLY;BYDAY=1MO,-1FR,XX;COUNT=4', 'FREQ=WEEKLY;INTERVAL=0;COUNT=3', 'FREQ=WEEKLY;INTERVAL=abc;COUNT=3',
      'FREQ=WEEKLY;INTERVAL=2.5;COUNT=3', 'FREQ=DAILY;INTERVAL=1.5;COUNT=4', 'FREQ=WEEKLY;COUNT=abc', 'FREQ=WEEKLY;COUNT=0', 'FREQ=WEEKLY;COUNT=2.5',
      'FREQ=WEEKLY;COUNT=0x3', 'FREQ=WEEKLY;COUNT= 2 ', 'FREQ=WEEKLY;UNTIL=20261124T225959Z', 'FREQ=WEEKLY', 'FREQ=DAILY;UNTIL=20290101',
      'freq=weekly;count=2', 'FREQ=WEEKLY;BYDAY=;COUNT=2', 'FREQ=WEEKLY;BYDAY=su,mo;COUNT=3', 'FREQ=DAILY;COUNT=1e1',
    ].flatMap((r, i) => ['BEGIN:VEVENT', `UID:r${i}`, `SUMMARY:Pravidlo ${i}`, 'DTSTART:20261021T120000', 'DTEND:20261021T130000', `RRULE:${r}`, 'END:VEVENT']),
    ...['PT90M', 'P1DT2H', 'P1W', 'PT0M', 'P', 'PT45M30S', 'P2D', 'PT1H'].flatMap((d, i) => ['BEGIN:VEVENT', `UID:d${i}`, `SUMMARY:Délka ${d}`, 'DTSTART:20261022T090000', `DURATION:${d}`, 'END:VEVENT']),
    'BEGIN:VEVENT', 'SUMMARY:Konec před začátkem', 'DTSTART:20261022T090000', 'DTEND:20261022T080000', 'END:VEVENT',
    'BEGIN:VEVENT', 'SUMMARY:Bez konce', 'DTSTART:20261022T090000', 'END:VEVENT',
    'BEGIN:VEVENT', 'SUMMARY:Datum jako čas', 'DTSTART;VALUE=DATE:20261022T090000', 'DTEND:20261022T100000', 'END:VEVENT',
    'BEGIN:VEVENT', 'SUMMARY:Špatné datum', 'DTSTART:2026-10-22T09:00', 'DTEND:20261022T100000', 'END:VEVENT',
    'BEGIN:VEVENT', 'SUMMARY;X-P="a:b";LANGUAGE=cs:Parametr s dvojtečkou', 'DTSTART:20261022T090000', 'DTEND:20261022T091500', 'END:VEVENT',
    'END:VCALENDAR'].join('\r'),
  // přesunutý termín bez hlavní akce, dvakrát exportovaná akce
  ['BEGIN:VCALENDAR', 'BEGIN:VEVENT', 'UID:sirotek', 'RECURRENCE-ID:20261105T100000', 'SUMMARY:Jen přesun', 'DTSTART:20261106T100000', 'DTEND:20261106T110000', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:dvakrat', 'SUMMARY:Dvakrát', 'DTSTART:20261105T100000', 'DTEND:20261105T110000', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:dvakrat', 'SUMMARY:Dvakrát', 'DTSTART:20261105T100000', 'DTEND:20261105T110000', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:m', 'SUMMARY:S přesunem v UTC', 'DTSTART;TZID=Europe/Prague:20261102T100000', 'DTEND;TZID=Europe/Prague:20261102T110000', 'RRULE:FREQ=WEEKLY;COUNT=3', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:m', 'RECURRENCE-ID:20261109T090000Z', 'SUMMARY:Přesun (UTC)', 'DTSTART:20261110T120000Z', 'END:VEVENT',
    'END:VCALENDAR'].join('\n'),
];

function ical() {
  const { int, pick, chance } = random(0x1ca15);
  const zones = ['', '', 'Europe/Prague', 'Europe/Prague', 'Z', 'America/New_York', 'Europe/London'];
  const titles = ['Anatomie – přednáška', 'Anatomie – cvičení', 'Fyziologie', 'Biochemie I', 'Latina', 'Histologie – praktikum', 'Tělesná výchova'];
  const pad = (n: number) => String(n).padStart(2, '0');
  const stamp = (t: Date, h: number, m: number) => `${t.getFullYear()}${pad(t.getMonth() + 1)}${pad(t.getDate())}T${pad(h)}${pad(m)}00`;
  const dt = (name: string, zone: string, value: string) => (zone === 'Z' ? `${name}:${value}Z` : zone ? `${name};TZID=${zone}:${value}` : `${name}:${value}`);
  const texts = [...ICS_CASES];
  for (let n = 0; n < 120; n++) {
    const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0'];
    if (chance(0.5)) lines.push(`X-WR-CALNAME:Rozvrh ${n}`);
    for (let k = int(1, 7); k > 0; k--) {
      const zone = pick(zones);
      const first = new Date(pick([2026, 2027]), pick([1, 8, 9]), int(1, 28));
      const h = int(7, 18);
      const m = pick([0, 15, 30, 45]);
      const minutes = pick([45, 90, 100, 135]);
      const uid = `u${n}-${k}`;
      const title = pick(titles);
      lines.push('BEGIN:VEVENT', `UID:${uid}`, `SUMMARY:${title}`, dt('DTSTART', zone, stamp(first, h, m)));
      if (chance(0.7)) {
        const end = new Date(first.getTime() + minutes * MIN);
        lines.push(dt('DTEND', zone, stamp(end, end.getHours(), end.getMinutes())));
      } else lines.push(`DURATION:PT${minutes}M`);
      if (chance(0.5)) lines.push(`LOCATION:Učebna ${int(1, 400)}`);
      const weekly = chance(0.8);
      if (weekly) {
        const days = ['MO', 'TU', 'WE', 'TH', 'FR'].filter(() => chance(0.3));
        const parts = [`FREQ=${chance(0.9) ? 'WEEKLY' : 'DAILY'}`];
        if (days.length && chance(0.6)) parts.push(`BYDAY=${days.join(',')}`);
        if (chance(0.2)) parts.push(`INTERVAL=${int(2, 3)}`);
        if (chance(0.4)) parts.push(`COUNT=${int(1, 16)}`);
        else if (chance(0.7)) {
          const until = new Date(first.getTime() + int(20, 150) * DAY);
          parts.push(chance(0.5) ? `UNTIL=${stamp(until, 0, 0).slice(0, 8)}` : `UNTIL=${stamp(until, 22, 59)}Z`);
        }
        lines.push(`RRULE:${parts.join(';')}`);
        for (let e = int(0, 2); e > 0; e--) {
          const ex = new Date(first.getTime() + int(0, 10) * 7 * DAY);
          lines.push(dt('EXDATE', zone, stamp(ex, h, m)));
        }
      }
      if (chance(0.1)) lines.push('STATUS:CANCELLED');
      lines.push('END:VEVENT');
      if (weekly && chance(0.4)) {
        // přesunutý nebo zrušený termín řady
        const occ = new Date(first.getTime() + int(0, 6) * 7 * DAY);
        const to = new Date(occ.getTime() + int(-2, 2) * DAY + int(-3, 3) * HOUR);
        lines.push('BEGIN:VEVENT', `UID:${uid}`, dt('RECURRENCE-ID', zone, stamp(occ, h, m)), `SUMMARY:${title}${chance(0.5) ? ' (náhrada)' : ''}`);
        if (chance(0.3)) lines.push('STATUS:CANCELLED');
        lines.push(dt('DTSTART', zone, stamp(to, to.getHours(), to.getMinutes())));
        if (chance(0.6)) lines.push(`DURATION:PT${pick([60, 90])}M`);
        lines.push('END:VEVENT');
      }
    }
    lines.push('END:VCALENDAR');
    texts.push(lines.join(pick(['\r\n', '\n'])));
  }
  const out = texts.map((text) => {
    try {
      const r = IC.parseIcs(text);
      return { text, name: r.name, skippedAllDay: r.skippedAllDay, events: r.events };
    } catch (e) {
      return { text, error: (e as Error).message };
    }
  });
  write('ical.json', out);
}

// ---------- 3. rozvrh: hodiny v týdnu, náhled změn, nová verze, přehled řad ----------
function timetables() {
  const { int, pick, chance } = random(0x77ab1e);
  const series = ['Anatomie – přednáška', 'Anatomie – cvičení', 'Fyziologie', 'Biochemie I', 'Latina', 'Žurnalistika', 'chemie', 'Čeština'];
  const base = new Date(2026, 8, 21).getTime();
  const event = (s: string, start: number, minutes: number) => ({ key: `${s}|${start}`, series: s, title: s, location: '', start, end: start + minutes * MIN });
  const semester = () => {
    const list: ReturnType<typeof event>[] = [];
    for (let k = int(1, 6); k > 0; k--) {
      const s = pick(series);
      const first = T.addDays(base, int(0, 6));
      const minutes = pick([45, 90, 100]);
      const at = T.atMinutes(first, int(7 * 4, 18 * 4) * 15);
      for (let w = 0; w < int(2, 14); w++) list.push(event(s, T.addDays(at, w * 7), minutes));
    }
    return list.sort((a, b) => a.start - b.start);
  };
  const out = Array.from({ length: 60 }, () => {
    const old = semester();
    // nová verze: část termínů zůstane, část zmizí, přibudou nové
    const next = [...old.filter(() => chance(0.8)), ...semester().filter(() => chance(0.3))].sort((a, b) => a.start - b.start);
    const all = [...new Set(old.map((e) => e.series))];
    const tt = {
      id: 'tt', name: 'Rozvrh', importedAt: 1, events: old,
      hiddenSeries: all.filter(() => chance(0.3)).concat(chance(0.2) ? ['Neexistuje'] : []),
      skipped: old.filter(() => chance(0.1)).map((e) => e.key).concat(chance(0.2) ? ['x|1'] : []),
      createdAt: 1, updatedAt: 1,
    };
    const now = T.addDays(base, int(-5, 100)) + int(0, 86_399) * 1000;
    const from = T.startOfWeek(T.addDays(base, int(0, 100)));
    const to = T.addDays(from, 7);
    const data = { timetables: chance(0.1) ? [{ ...tt, deletedAt: 5 }] : [tt, { ...tt, id: 'tt2', events: old.slice(0, 2), hiddenSeries: [], skipped: [] }] };
    return {
      tt, next, now, from, to,
      lectures: TT.lecturesIn(data, from, to).map((l: { timetableId: string; key: string }) => `${l.timetableId}:${l.key}`),
      deleted: !!data.timetables[0].deletedAt,
      diff: TT.diffTimetable(old, next, now),
      replaced: JSON.stringify(TT.replaceEvents(tt, next, now)),
      series: TT.seriesOf(tt, now),
    };
  });
  write('timetables.json', out);
}

// ---------- 4. export do kalendáře (.ics) a odebíraný kalendář ----------
function icsExport() {
  const { int, pick, chance } = random(0xe4a0e);
  const realNow = Date.now;
  const subjects = [
    { id: 'a', name: 'Anatomie' }, { id: 'b', name: 'Biochemie; II' }, { id: 'c', name: 'Latina, řeč' }, { id: 'd', name: 'Back\\slash' },
    { id: 'e', name: 'Fyzika 🚀 a 👩‍🔬' }, { id: 'f', name: 'Velmi dlouhý název předmětu, který se do jednoho řádku kalendáře rozhodně nevejde' },
    { id: 'a', name: 'Anatomie (novější záznam se stejným id)' }, { id: 'z', name: 'Smazaný', deletedAt: 5 },
  ].map((x) => ({ color: '#7d9cc0', weeklyGoalMin: 0, archived: false, createdAt: 1, updatedAt: 1, ...x }));
  const titles = ['', 'Kapitola 5', 'Derivace, limity; řady', 'Řádek\nnový', 'Řádek\r\nWindows', 'Č'.repeat(40), 'Opakování: Ledviny, Srdce (−3 d)', 'emoji 📚📚📚 '.repeat(5)];
  const notes = ['', 'Zkus si nejdřív vybavit z hlavy (retrieval practice), až pak se podívej do materiálů.', 'a\\b', 'x'.repeat(200)];
  const base = new Date(2026, 9, 17).getTime();
  const block = (i: number) => {
    const b: Record<string, unknown> = {
      id: `b${i}-${int(0, 1e6)}`, subjectId: pick(['a', 'b', 'c', 'd', 'e', 'f', 'z', 'x']), title: pick(titles),
      start: T.atMinutes(T.addDays(base, int(-30, 60)), int(0, 287) * 5), durationMin: pick([5, 25, 45, 50, 90, 240]),
      done: chance(0.3), note: pick(notes), createdAt: 1, updatedAt: 1,
    };
    if (chance(0.1)) b.deletedAt = 7;
    return b;
  };
  const exam = (i: number) => {
    const e: Record<string, unknown> = {
      id: `e${i}`, subjectId: pick(['a', 'b', 'e', 'x']), name: pick(['Zápočet', 'Zkouška, ústní', 'Test; písemka', 'Kolokvium']),
      date: T.dayKey(T.addDays(base, int(-30, 60))), time: pick(['', '', '08:30', '23:30', '00:00', '02:30']), note: pick(notes), createdAt: 1, updatedAt: 1,
    };
    if (chance(0.1)) e.deletedAt = 7;
    return e;
  };
  // Dny změny času pro zkoušky s časem a bez něj
  const dstExams = ['2026-03-29', '2026-10-25'].flatMap((date, i) => [
    { ...exam(100 + i), date, time: '02:30', deletedAt: undefined },
    { ...exam(200 + i), date, time: '', deletedAt: undefined },
  ]);
  const build = Array.from({ length: 80 }, (_, n) => {
    const now = base + int(0, 86_399) * 1000 + n * 13;
    Date.now = () => now;
    const blocks = Array.from({ length: int(0, 8) }, (_, i) => block(i)).filter((b) => !b.deletedAt);
    const exams = [...Array.from({ length: int(0, 3) }, (_, i) => exam(i)).filter((e) => !e.deletedAt), ...(n < 4 ? dstExams : [])];
    const opts = { blocks, exams, subjects, alarmMin: pick([null, 5, 10, 15, 30]), feed: chance(0.5) };
    const ics = ICS.buildIcs(opts);
    Date.now = realNow;
    return { ...opts, now, ics };
  });
  const feed = Array.from({ length: 40 }, () => {
    const now = base + int(-5, 40) * DAY + int(0, 86_399) * 1000;
    Date.now = () => now;
    const data = { planBlocks: Array.from({ length: int(0, 12) }, (_, i) => block(i)), exams: Array.from({ length: int(0, 4) }, (_, i) => exam(i)), subjects };
    const f = { includeExams: chance(0.6), alarmMin: pick([null, 10]) };
    const ics = FEED.buildFeed(data, f);
    Date.now = realNow;
    return { data, ...f, now, ics, hash: FEED.feedHash(ics) };
  });
  write('ics.json', { build, feed });
}

mkdirSync(OUT, { recursive: true });
planner();
ical();
timetables();
icsExport();
console.log(`Kontrolní data kalendáře → ${OUT}`);
