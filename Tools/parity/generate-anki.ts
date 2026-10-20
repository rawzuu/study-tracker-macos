/**
 * Kontrolní data pro čas z Anki: SKUTEČNÝ kód webu (`clusterReviews` z `src/lib/anki.ts` a `runAnkiSync`
 * z `src/features/anki/useAnkiSync.ts`, vyjmutá ze zdrojového kódu a spuštěná beze změny, jen s podvrženou
 * Anki místo `fetchAnki`) – co web zapíše do dat (stav balíčků, předmět Anki, sezení, smazání).
 * Swift testy (Packages/StudyKit/Tests/EngineTests/AnkiParityTests) musí dát stejný výsledek.
 *
 *   WEB_DIR=…/study-tracker npm run generate
 *
 * Vstupy jsou syntetické (vlastní seed) – skutečná data uživatele ani skutečná Anki sem nikdy nepatří.
 */
import { readFileSync, writeFileSync } from 'node:fs';
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
const A = await load('src/lib/anki.ts');
const { MIN } = T as { MIN: number };

/** Neexportovaná funkce `name` ze souboru webu (stejně jako v generate-planner.ts). */
function extract<F>(file: string, name: string, scope: Record<string, unknown>): F {
  const js = transformSync(readFileSync(join(WEB, file), 'utf8'), { loader: 'tsx', jsx: 'preserve' }).code;
  const start = js.search(new RegExp(`(async )?function ${name}\\(`));
  if (start < 0) throw new Error(`${file}: funkce ${name} nenalezena`);
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
    } else if (ch === "'" || ch === '"' || ch === '`') quote = ch;
    else if (ch === '{') depth++;
    else if (ch === '}' && --depth === 0) break;
  }
  const source = js.slice(start, j + 1);
  return new Function(...Object.keys(scope), `${source}\nreturn ${name};`)(...Object.values(scope)) as F;
}

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

type Op = { op: string; key: string; value: unknown };

// Podvržená Anki: `fetchAnki` vrátí připravený výsledek a zapamatuje si, od kdy se ptal.
let answer: { decks: unknown[]; reviewedToday: number; reviews: { deck: string; time: number; durationMs: number }[]; reviewsFetched: boolean };
let asked: { since: number } | null = null;
const fetchAnki = async (since: number) => {
  asked = { since };
  return answer;
};
const run = extract<(store: unknown, data: unknown, full: boolean) => Promise<void>>('src/features/anki/useAnkiSync.ts', 'runAnkiSync', {
  fetchAnki,
  clusterReviews: A.clusterReviews,
  AnkiError: A.AnkiError,
  startOfDay: T.startOfDay,
  addDays: T.addDays,
  ANKI_SUBJECT_ID: 'anki',
  setStatus: () => {},
  lastSeen: null,
});

const DECKS = ['Anatomie', 'Fyziologie::Srdce', 'Biochemie', 'Latina – slovíčka', 'Ústní 2. kolo', 'Default'];
const top = (n: string) => n.split('::')[0];

async function cases() {
  const { int, pick, chance } = random(0xa4c1);
  const out: unknown[] = [];
  for (let n = 0; n < 160; n++) {
    const now = new Date(2026, int(0, 11), int(1, 28), int(6, 23), int(0, 59), int(0, 59)).getTime();
    const today = T.startOfDay(now);
    const importDays = pick([7, 30, 60]);
    const full = chance(0.25);
    const hasSessions = chance(0.7);
    const days = full || !hasSessions ? importDays : 2;
    const since = T.addDays(today, -(days - 1));
    const from = T.addDays(since, -1);

    // Opakování od začátku dotazu (den před oknem) – i bloky přes hranici okna.
    const reviews: { deck: string; time: number; durationMs: number }[] = [];
    const reviewsFetched = chance(0.85);
    if (reviewsFetched) {
      for (let k = 0, count = int(0, 4); k < count; k++) {
        const deck = top(pick(DECKS));
        let t = int(from + MIN, Math.max(from + MIN, now - 30 * MIN));
        for (let r = 0, cards = int(1, 40); r < cards && t < now; r++) {
          const durationMs = int(1500, 45_000);
          reviews.push({ deck, time: t, durationMs });
          t += durationMs + (chance(0.08) ? int(11 * MIN, 50 * MIN) : int(500, 4 * MIN));
        }
      }
      reviews.sort((a, b) => a.time - b.time);
    }
    const deckStats = [...new Set(DECKS.map(top))].filter(() => chance(0.7)).map((name) => ({
      name, newCount: int(0, 20), learnCount: int(0, 10), reviewCount: int(0, 120), total: int(1, 900),
    }));
    const reviewedToday = int(0, 300);
    answer = { decks: deckStats, reviewedToday, reviews, reviewsFetched };

    // Data: předměty, přiřazení balíčků, předchozí stav a dřívější sezení z Anki
    const subjects: Record<string, unknown>[] = [{ id: 's1', name: 'Anatomie', color: '#c98a5b', weeklyGoalMin: 300, archived: false }];
    const ankiSubject = pick(['none', 'alive', 'deleted']);
    if (ankiSubject !== 'none') {
      subjects.push({ id: 'anki', name: 'Anki', color: '#9ca3af', weeklyGoalMin: 0, archived: false, ...(ankiSubject === 'deleted' ? { deletedAt: 5 } : {}) });
    }
    const deckSubjects: Record<string, string> = {};
    for (const d of new Set(DECKS.map(top))) if (chance(0.4)) deckSubjects[d] = pick(['s1', '', 's1']);
    const prevMs = reviews.filter((r) => r.time >= today).reduce((a, r) => a + r.durationMs, 0);
    const anki = chance(0.3)
      ? []
      : [{
          id: 'snapshot', at: now - int(1, 600) * 60_000, createdAt: 1, updatedAt: 2,
          decks: chance(0.5) ? deckStats : deckStats.slice(1),
          reviewedToday: chance(0.7) ? reviewedToday : reviewedToday + 1,
          msToday: chance(0.5) ? prevMs + int(-20_000, 20_000) : int(0, 9_000_000),
        }];

    const blocks = (A.clusterReviews(reviews) as { deck: string; start: number; end: number; durationMs: number; count: number }[])
      .filter((b) => b.durationMs >= 30_000);
    const idOf = (b: { deck: string; start: number }) => `anki-${b.deck.replace(/[^\p{L}\p{N}]+/gu, '_')}-${b.start}`;
    const sessions: Record<string, unknown>[] = [];
    if (hasSessions) {
      // starší sezení mimo okno (zůstanou), aby `hasAnkiSessions` platilo
      const old = T.addDays(from, -3);
      sessions.push({ id: `anki-Old-${old}`, subjectId: 'anki', topic: 'Old', start: old, end: old + 60_000, durationSec: 60, mode: 'anki', interruptions: 0, note: '3 karet', createdAt: 1, updatedAt: 1 });
      for (const b of blocks) {
        if (!chance(0.6)) continue;
        const same = chance(0.6);
        const subjectId = deckSubjects[b.deck] || 'anki';
        sessions.push({
          id: idOf(b), subjectId: same || chance(0.5) ? subjectId : 'jiny', topic: b.deck, start: b.start,
          end: Math.max(b.end, b.start + b.durationMs) + (same ? 0 : 60_000), durationSec: Math.round(b.durationMs / 1000),
          mode: 'anki', interruptions: 0, note: `${b.count} karet`, createdAt: 1, updatedAt: 1, ...(chance(0.1) ? { deletedAt: 9 } : {}),
        });
      }
      // sezení v okně, které po přepočtu neexistuje (smaže se), a už smazané (zůstane)
      for (let k = 0, extra = int(0, 2); k < extra; k++) {
        const start = int(since + MIN, now - MIN);
        sessions.push({ id: `anki-Gone-${start}`, subjectId: 'anki', topic: 'Gone', start, end: start + 90_000, durationSec: 90, mode: 'anki', interruptions: 0, note: '5 karet', createdAt: 1, updatedAt: 1, ...(chance(0.3) ? { deletedAt: 7 } : {}) });
      }
    }
    // obyčejné sezení se nikdy nesmaže
    sessions.push({ id: 'manual', subjectId: 's1', topic: 'Lebka', start: now - 2 * 3_600_000, end: now - 3_600_000, durationSec: 3600, mode: 'pomodoro', interruptions: 0, note: '', createdAt: 1, updatedAt: 1 });

    const data = {
      subjects, sessions, anki,
      settings: { anki: { enabled: true, countTime: chance(0.85), deckSubjects, importDays } },
    };
    const ops: Op[] = [];
    const store = {
      upsert: (key: string, value: unknown) => ops.push({ op: 'upsert', key, value }),
      upsertMany: (key: string, value: unknown) => ops.push({ op: 'upsertMany', key, value }),
      remove: (key: string, value: unknown) => ops.push({ op: 'remove', key, value }),
    };
    const realNow = Date.now;
    Date.now = () => now;
    try {
      asked = null;
      await run(store, data, full);
    } finally {
      Date.now = realNow;
    }
    if (!asked) throw new Error(`#${n}: run se Anki nezeptal`);
    out.push({ now, full, data, answer, since: asked.since, ops });
  }
  return out;
}

/** Názvy balíčků → id sezení (regulární výraz `[^\p{L}\p{N}]+` s příznakem `u`). */
function ids() {
  const names = ['Anatomie', 'Fyziologie srdce', 'Latina – slovíčka', 'Ústní 2. kolo', '日本語 N5', 'a::b', '  mezery  ', 'Ⅻ kapitola', 'é́', '½ testu', ''];
  return names.map((deck) => ({ deck, id: `anki-${deck.replace(/[^\p{L}\p{N}]+/gu, '_')}-1` }));
}

writeFileSync(join(OUT, 'anki.json'), JSON.stringify({ cases: await cases(), ids: ids() }) + '\n');
console.log('anki.json: 160 případů');
