/**
 * Kontrolní data pro koš a export sezení do CSV: SKUTEČNÝ kód webu (`trashItems` ze `src/lib/trash.ts`,
 * `sessionsToCsv` ze `src/lib/csv.ts`) v pražském čase s pevným „teď“.
 * Swift testy (Packages/StudyKit/Tests/EngineTests/BackupParityTests) musí dát stejný výsledek.
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
const Trash = await load('src/lib/trash.ts');
const Csv = await load('src/lib/csv.ts');
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

const DAY = 86_400_000;
const texts = ['', 'Lebka', 'Srdce; chlopně', 'Citát "Hippokrates"', '=SUM(A1)', '+420', '-minus', '@zmínka', 'Řádek\nnový', 'Win\r\nřádek', '\tTab', 'žluťoučký kůň'];

function cases() {
  const { int, pick, chance, rnd } = random(0xb4c0);
  const out: unknown[] = [];
  for (let n = 0; n < 40; n++) {
    const now = new Date(2026, int(0, 11), int(1, 28), int(6, 23), int(0, 59)).getTime();
    const data = emptyData();
    const deleted = () => (chance(0.35) ? (chance(0.8) ? now - int(0, 40) * DAY - int(0, DAY) : 0) : undefined);
    const stamp = (e: Record<string, unknown>) => {
      const d = deleted();
      return { ...e, createdAt: 1, updatedAt: 2, ...(d !== undefined ? { deletedAt: d } : {}) };
    };
    data.subjects = ['Anatomie', 'Fyziologie', 'Latina'].slice(0, int(1, 3)).map((name, i) => stamp({ id: `s${i}`, name, color: '#7d9cc0', weeklyGoalMin: 0, archived: false }));
    if (chance(0.3)) data.subjects.push({ ...data.subjects[0], name: 'Duplicitní', updatedAt: 3 });
    const subjectId = () => (chance(0.9) ? `s${int(0, 3)}` : 'zmizely');
    data.presets = Array.from({ length: int(0, 3) }, (_, i) => stamp({ id: `p${i}`, name: `Režim ${i}`, workMin: pick([25, 40, 7.5, 0.5]), shortBreakMin: pick([5, 8, 2.5]), longBreakMin: 15, roundsBeforeLong: 3 }));
    const modes = ['pomodoro', 'flowtime', 'manual', 'plan', 'anki', 'stopwatch', 'p0', 'p1', 'neznamy'];
    data.sessions = Array.from({ length: int(0, 14) }, (_, i) => {
      const start = now - int(0, 60) * DAY - int(0, DAY);
      const dur = pick([0, 59, 60, 90, 150, 1500, 3000, 3333, 7201, int(1, 9000)]);
      const s: Record<string, unknown> = { id: `x${i}`, subjectId: subjectId(), topic: pick(texts), start, end: start + dur * 1000, durationSec: dur, mode: pick(modes), note: pick(texts) };
      if (chance(0.7)) s.interruptions = int(0, 4);
      if (chance(0.5)) s.focus = int(1, 5);
      if (chance(0.3)) s.recall = pick(texts);
      return stamp(s);
    });
    data.topics = Array.from({ length: int(0, 4) }, (_, i) => stamp({ id: `t${i}`, subjectId: subjectId(), name: `Téma ${i}`, stage: 0, reviews: 0, mastered: false, note: '' }));
    data.exams = Array.from({ length: int(0, 3) }, (_, i) => stamp({ id: `e${i}`, subjectId: subjectId(), name: `Zkouška ${i}`, date: `2026-${String(int(1, 12)).padStart(2, '0')}-${String(int(1, 28)).padStart(2, '0')}` }));
    data.planBlocks = Array.from({ length: int(0, 5) }, (_, i) => {
      const b: Record<string, unknown> = { id: `b${i}`, subjectId: subjectId(), title: pick(['', 'Opakování: Lebka', 'Kapitola 3']), start: now + int(-20, 20) * DAY, durationMin: pick([30, 45, 37.5, 90]), done: false };
      if (chance(0.3)) b.examId = `e${int(0, 2)}`;
      return stamp(b);
    });
    data.timetables = Array.from({ length: int(0, 2) }, (_, i) => stamp({ id: `tt${i}`, name: `Rozvrh ${i}`, events: Array.from({ length: int(0, 5) }, (_, j) => ({ key: `k${j}`, title: 'Hodina', start: now, end: now + 3600_000 })), hiddenSeries: [] }));
    data.reflections = Array.from({ length: int(0, 2) }, (_, i) => stamp({ id: `r${i}`, weekStart: `2026-10-${String(int(1, 28)).padStart(2, '0')}`, rating: 3, wentWell: '', blocked: '', focusNext: '' }));
    void rnd;
    out.push({ now, data, trash: Trash.trashItems(data, now), csv: Csv.sessionsToCsv(data.sessions, data.subjects, data.presets) });
  }
  return out;
}

writeFileSync(join(OUT, 'backup.json'), JSON.stringify({ cases: cases() }) + '\n');
console.log('backup.json: 40 případů');
