/**
 * Kontrolní data pro úspěchy: SKUTEČNÝ kód webu (`evaluate`, `toPersist`, `describe`
 * ze `src/features/achievements/achievements.ts`) v pražském čase s pevným „teď“.
 * Swift testy (Packages/StudyKit/Tests/EngineTests/AchievementsParityTests) musí dát stejný výsledek.
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
const A = await load('src/features/achievements/achievements.ts');
const { emptyData } = await load('src/data/schema.ts');

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

const MODES = ['pomodoro', 'pomodoro-long', '52-17', 'ultradian', 'flowtime', 'stopwatch', 'manual', 'anki', 'custom-1'];

function cases() {
  const { int, pick, chance } = random(0xac41e);
  const out: unknown[] = [];
  for (let n = 0; n < 40; n++) {
    const now = new Date(2026, int(0, 11), int(1, 28), int(7, 23), int(0, 59)).getTime();
    const data = emptyData();
    data.subjects = ['Anatomie', 'Fyziologie', 'Biochemie', 'Latina', 'Chemie'].slice(0, int(1, 5)).map((name, i) => ({
      id: `s${i}`, name, color: '#7d9cc0', weeklyGoalMin: chance(0.7) ? pick([30, 60, 120, 180]) : 0, archived: chance(0.1), createdAt: 1, updatedAt: 1,
    }));
    const span = pick([20, 60, 200, 420]);
    const density = pick([0.3, 0.6, 0.9]);
    const sessions: Record<string, unknown>[] = [];
    let k = 0;
    for (let d = span; d >= 0; d--) {
      // pauza delší než 14 dní (Návrat) a celé měsíce bez výpadku
      if (span > 100 && d > span / 2 && d < span / 2 + 18) continue;
      if (!chance(density)) continue;
      const day = T.addDays(T.startOfDay(now), -d);
      for (let j = 0, c = int(1, 4); j < c; j++) {
        const hour = pick([3, 5, 6, 8, 10, 13, 16, 19, 21, 22, 23]);
        const start = day + hour * 3_600_000 + int(0, 59) * 60_000;
        if (start > now) continue;
        const mode = pick(MODES);
        const min = mode === 'anki' ? int(2, 30) : pick([10, 25, 30, 45, 50, 55, 90, 100, 130, 200]);
        sessions.push({
          id: `x${n}-${k++}`, subjectId: pick(data.subjects).id, topic: '', start, end: start + min * 60_000, durationSec: min * 60,
          mode, ...(chance(0.5) && mode !== 'anki' ? { focus: int(1, 5) } : {}), interruptions: chance(0.3) ? int(1, 2) : 0, note: '',
          ...(chance(0.2) ? { recall: chance(0.5) ? 'srdce má 4 oddíly' : '  ' } : {}),
          createdAt: 1, updatedAt: 1, ...(chance(0.02) ? { deletedAt: 3 } : {}),
        });
      }
    }
    // svátky a půlnoc
    for (const [m, dd] of [[0, 1], [2, 14], [11, 24]]) {
      if (!chance(0.3)) continue;
      const start = new Date(new Date(now).getFullYear() - 1, m, dd, 10).getTime();
      sessions.push({ id: `h${n}-${m}`, subjectId: 's0', topic: '', start, end: start + 1_800_000, durationSec: 1800, mode: 'pomodoro', interruptions: 0, note: '', createdAt: 1, updatedAt: 1 });
    }
    if (chance(0.4)) {
      const start = T.addDays(T.startOfDay(now), -int(1, 30)) + 23 * 3_600_000 + 30 * 60_000;
      sessions.push({ id: `m${n}`, subjectId: 's0', topic: '', start, end: start + 3_600_000, durationSec: 3600, mode: 'flowtime', interruptions: 0, note: '', createdAt: 1, updatedAt: 1 });
    }
    data.sessions = sessions;
    data.exams = chance(0.6) ? [{ id: 'e1', subjectId: 's0', name: 'Zápočet', date: T.dayKey(T.addDays(now, -int(-10, 30))), time: '', note: '', createdAt: now - int(1, 90) * 86_400_000, updatedAt: 1 }] : [];
    data.planBlocks = Array.from({ length: int(0, 30) }, (_, j) => ({
      id: `b${n}-${j}`, subjectId: 's0', title: '', start: T.addDays(T.startOfDay(now), -int(0, 100)) + 9 * 3_600_000, durationMin: 50, done: chance(0.7),
      ...(chance(0.3) && data.exams.length ? { examId: 'e1' } : {}), createdAt: now - int(1, 200) * 86_400_000, updatedAt: 1,
    }));
    data.topics = Array.from({ length: int(0, 8) }, (_, j) => ({
      id: `t${n}-${j}`, subjectId: 's0', name: `Téma ${j}`, stage: 1, reviews: int(0, 80), mastered: chance(0.3), note: '',
      ...(chance(0.7) ? { fsrs: { s: int(0, 400) + 0.5, d: 5, state: 2 } } : {}), createdAt: 1, updatedAt: now - int(1, 300) * 86_400_000,
    }));
    data.reflections = Array.from({ length: int(0, 6) }, (_, j) => ({
      id: `r${n}-${j}`, weekStart: '2026-01-05', rating: 3, wentWell: '', blocked: '', focusNext: '', createdAt: now - int(1, 200) * 86_400_000, updatedAt: 1,
    }));
    data.anki = chance(0.4) ? [{ id: 'snapshot', at: now, decks: [], reviewedToday: 0, msToday: 0, createdAt: now - int(1, 50) * 86_400_000, updatedAt: 1 }] : [];
    data.achievements = chance(0.5)
      ? [{ id: 'hours.3', at: now - 86_400_000, createdAt: 1, updatedAt: 1 }, { id: 'streak.2', at: 5, createdAt: 1, updatedAt: 1 }, { id: 'first-exam', at: 7, createdAt: 1, updatedAt: 1 },
        { id: 'flow.1', at: 9, createdAt: 1, updatedAt: 1, deletedAt: 10 }]
      : [];
    data.settings = {
      ...data.settings, dailyGoalMin: pick([0, 30, 60, 120]), streakRestDays: int(0, 2), streakMinMin: pick([0, 15]),
      hiddenPages: chance(0.2) ? ['reflexe'] : [],
    };

    const res = A.evaluate(data, now);
    const realNow = Date.now;
    Date.now = () => now;
    const persist = A.toPersist(data, res, now);
    Date.now = realNow;
    out.push({
      now, data,
      families: res.families.map((r: { family: { id: string }; value: number; tier: number; tiers: { unlocked: boolean; at: number | null }[]; next: number | null; progress: number }) => ({
        id: r.family.id, value: r.value, tier: r.tier, tiers: r.tiers.map((t) => [t.unlocked, t.at]), next: r.next, progress: r.progress,
      })),
      singles: res.singles.map((s: { single: { id: string }; unlocked: boolean; at: number | null }) => [s.single.id, s.unlocked, s.at]),
      unlockedIds: res.unlockedIds, total: res.total, unlocked: res.unlocked, persist,
    });
  }
  return out;
}

const all = [...A.FAMILIES.flatMap((f: { id: string; thresholds: number[] }) => f.thresholds.map((_, i) => `${f.id}.${i + 1}`)), ...A.SINGLES.map((s: { id: string }) => s.id)];
const describe = all.map((id: string) => ({ id, ...A.describe(id) }));

writeFileSync(join(OUT, 'achievements.json'), JSON.stringify({ cases: cases(), describe }) + '\n');
console.log(`achievements.json: 40 případů, ${describe.length} úspěchů`);
