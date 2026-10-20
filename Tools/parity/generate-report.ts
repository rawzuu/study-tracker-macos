/**
 * Kontrolní data pro měsíční report, kalibraci a týdenní reflexi: SKUTEČNÝ kód webu
 * (`periodStats`, `highlights`, `pct` ze `src/lib/report.ts` a `calibrate`, `enoughData`
 * ze `src/lib/calibrate.ts`) v pražském čase s pevným „teď“.
 * Swift testy (Packages/StudyKit/Tests/EngineTests/ReportParityTests) musí dát stejný výsledek.
 *
 *   WEB_DIR=…/study-tracker npm run generate
 *
 * Vstupy jsou syntetické (vlastní seed) – skutečná data uživatele sem nikdy nepatří.
 */
import { writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const here = import.meta.dirname;
const WEB = resolve(process.env.WEB_DIR ?? join(here, '../../../study-tracker-web'));
const OUT = resolve(process.env.ENGINE_OUT_DIR ?? join(here, '../../Packages/StudyKit/Tests/EngineTests/Fixtures'));

if (Intl.DateTimeFormat().resolvedOptions().timeZone !== 'Europe/Prague') {
  throw new Error('Spusť s TZ=Europe/Prague (npm run generate to dělá samo).');
}

const load = (p: string) => import(pathToFileURL(join(WEB, p)).href);
const T = await load('src/lib/time.ts');
const R = await load('src/lib/report.ts');
const C = await load('src/lib/calibrate.ts');
const { emptyData, alive } = await load('src/data/schema.ts');

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

/** Pevné „teď“ pro kód webu (periodStats a calibrate se ptají `Date.now()`). */
function at<T>(now: number, f: () => T): T {
  const real = Date.now;
  Date.now = () => now;
  try {
    return f();
  } finally {
    Date.now = real;
  }
}

const entries = (m: Map<string, number>) => [...m.entries()];

function stats(p: Record<string, unknown>) {
  return {
    ...p,
    longestSession: (p.longestSession as { id: string } | null)?.id ?? null,
    perSubject: entries(p.perSubject as Map<string, number>),
    perDay: entries(p.perDay as Map<string, number>),
  };
}

function cases() {
  const { int, pick, chance } = random(0x2e9071);
  const out: unknown[] = [];
  for (let n = 0; n < 48; n++) {
    const now = new Date(2026, int(0, 11), int(1, 28), int(7, 23), int(0, 59)).getTime();
    const data = emptyData();
    const subjects = ['Anatomie', 'Fyziologie', 'Biochemie', 'Latina'].slice(0, int(2, 4)).map((name, i) => ({
      id: `s${i}`, name, color: '#7d9cc0', weeklyGoalMin: chance(0.75) ? pick([60, 90, 120, 180, 240, 300, 420]) : 0,
      archived: chance(0.1), createdAt: 1, updatedAt: 1,
    }));
    data.subjects = subjects;
    // Učení za posledních ~100 dní: někdo pravidelně, někdo nárazově, někdo ráno, někdo v noci.
    const style = pick(['regular', 'burst', 'morning', 'night', 'sparse']);
    const sessions: Record<string, unknown>[] = [];
    let k = 0;
    for (let d = 100; d >= 0; d--) {
      const day = T.addDays(T.startOfDay(now), -d);
      const p = style === 'regular' ? 0.75 : style === 'burst' ? (d % 14 < 3 ? 0.95 : 0.1) : style === 'sparse' ? 0.25 : 0.6;
      if (!chance(p)) continue;
      for (let j = 0, count = int(1, 4); j < count; j++) {
        const hour = style === 'morning' ? int(6, 11) : style === 'night' ? pick([20, 21, 22, 23, 0, 1]) : int(7, 22);
        const start = day + hour * 3_600_000 + int(0, 59) * 60_000 + (hour < 4 ? 86_400_000 : 0);
        if (start > now) continue;
        const anki = chance(0.12);
        const min = anki ? int(3, 25) : pick([15, 25, 30, 45, 50, 60, 75, 90, 120]);
        const durationSec = min * 60 - (chance(0.3) ? int(0, 300) : 0);
        sessions.push({
          id: `x${n}-${k++}`, subjectId: pick(subjects).id, topic: chance(0.5) ? pick(['Lebka', 'srdce', 'Srdce', 'Ledviny', 'Enzymy', '']) : '',
          start, end: start + min * 60_000 + (chance(0.3) ? int(1, 20) * 60_000 : 0), durationSec,
          mode: anki ? 'anki' : pick(['pomodoro', 'pomodoro-long', 'flowtime', 'manual']),
          ...(chance(0.6) && !anki ? { focus: int(1, 5) } : {}), interruptions: chance(0.3) ? int(1, 3) : 0, note: '',
          createdAt: 1, updatedAt: 1, ...(chance(0.03) ? { deletedAt: 5 } : {}),
        });
      }
    }
    data.sessions = sessions;
    const blocks: Record<string, unknown>[] = [];
    for (let j = 0, count = int(0, 40); j < count; j++) {
      const start = T.addDays(T.startOfDay(now), -int(0, 70)) + int(6, 22) * 3_600_000;
      blocks.push({ id: `b${n}-${j}`, subjectId: pick(subjects).id, title: '', start, durationMin: pick([25, 50, 90]), done: chance(0.6), createdAt: 1, updatedAt: 1, ...(chance(0.05) ? { deletedAt: 5 } : {}) });
    }
    data.planBlocks = blocks;
    data.settings = {
      ...data.settings, dailyGoalMin: pick([0, 30, 60, 90, 120, 180, 240, 300]), planDayStart: pick(['06:00', '07:30', '08:00', '09:00']),
      planDayEnd: pick(['20:00', '22:00', '23:30']), streakRestDays: int(0, 2), streakMinMin: pick([0, 0, 15, 30]),
    };

    // Report za tento a minulý měsíc (jako ReportPage) a týden (jako reflexe)
    const d = new Date(now);
    const month = pick([0, -1, -2]);
    const ref = new Date(d.getFullYear(), d.getMonth() + month, 1);
    const y = ref.getFullYear(), m = ref.getMonth();
    const { from, to } = R.monthRange(y, m);
    const prevRange = R.monthRange(m === 0 ? y - 1 : y, m === 0 ? 11 : m - 1);
    const rules = { restDays: data.settings.streakRestDays, minMin: data.settings.streakMinMin };
    const all = alive(data.sessions);
    const report = at(now, () => {
      const cur = R.periodStats(all, data.planBlocks, from, to, rules);
      const prev = R.periodStats(all, data.planBlocks, prevRange.from, prevRange.to, rules);
      return { cur: stats(cur), prev: stats(prev), highlights: R.highlights(cur, prev, data.subjects) };
    });
    const weekFrom = T.addDays(T.startOfWeek(now), -7 * int(0, 2));
    const week = at(now, () => stats(R.periodStats(all, data.planBlocks, weekFrom, T.addDays(weekFrom, 7), rules)));

    const end = Math.min(to, now);
    const calibration = at(now, () => ({ suggestions: C.calibrate(data, end), enough: C.enoughData(data, end) }));
    out.push({ now, data, y, m, report, weekFrom, week, end, calibration });
  }
  return out;
}

const pct = [[0, 0], [10, 0], [0, 10], [15, 10], [5, 10], [7, 3], [1, 3], [2, 3]].map(([cur, prev]) => ({ cur, prev, pct: R.pct(cur, prev) }));
const quantiles = (() => {
  const { int, rnd } = random(0x9a17);
  return Array.from({ length: 40 }, () => {
    const values = Array.from({ length: int(1, 12) }, () => int(0, 300));
    const weights = values.map(() => rnd());
    const q = [0.1, 0.3, 0.5, 0.9][int(0, 3)];
    return { values, weights, q, result: C.weightedQuantile(values, weights, q) };
  });
})();

writeFileSync(join(OUT, 'report.json'), JSON.stringify({ cases: cases(), pct, quantiles }) + '\n');
console.log('report.json: 48 případů');
