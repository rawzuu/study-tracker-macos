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

mkdirSync(OUT, { recursive: true });
planner();
console.log(`Kontrolní data kalendáře → ${OUT}`);
