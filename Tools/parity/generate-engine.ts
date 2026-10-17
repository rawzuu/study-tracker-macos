/**
 * Kontrolní data pro Engine: kalendář, formáty a souhrny učení spočítané SKUTEČNÝM kódem webu
 * (`src/lib/time.ts`, `src/lib/stats.ts`) v pražském čase. Swift testy (Packages/StudyKit/Tests/EngineTests)
 * musí dát stejný výsledek.
 *
 *   WEB_DIR=…/study-tracker npm run generate
 *
 * Vstupy jsou syntetické (pevný seed) – skutečná data uživatele sem nikdy nepatří.
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const here = import.meta.dirname;
const WEB = resolve(process.env.WEB_DIR ?? join(here, '../../../study-tracker-web'));
const OUT = resolve(process.env.ENGINE_OUT_DIR ?? join(here, '../../Packages/StudyKit/Tests/EngineTests/Fixtures'));

// Web počítá v místním čase prohlížeče – kontrolní data jsou pro Prahu (dvě změny času ročně).
if (Intl.DateTimeFormat().resolvedOptions().timeZone !== 'Europe/Prague') {
  throw new Error('Spusť s TZ=Europe/Prague (npm run generate to dělá samo).');
}

const load = (p: string) => import(pathToFileURL(join(WEB, p)).href);
const T = await load('src/lib/time.ts');
const S = await load('src/lib/stats.ts');
const TT = await load('src/lib/timetable.ts');
const webVersion = JSON.parse(readFileSync(join(WEB, 'package.json'), 'utf8')).version as string;

// ---------- deterministická náhoda (stejný generátor jako generate.ts, jiný seed) ----------
let seed = 0x7173e11a;
function rnd(): number {
  seed |= 0;
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const int = (lo: number, hi: number) => lo + Math.floor(rnd() * (hi - lo + 1));
const pick = <T>(xs: readonly T[]): T => xs[Math.floor(rnd() * xs.length)];
const chance = (p: number) => rnd() < p;

function write(name: string, value: unknown, compact = false) {
  writeFileSync(join(OUT, name), JSON.stringify(value, null, compact ? undefined : 1) + '\n');
}

const { MIN, HOUR, DAY } = T as { MIN: number; HOUR: number; DAY: number };

// ---------- 1. kalendář ----------
/** Všechny tvary data, které web používá (`fmtDate` / `toLocaleDateString`). */
const DATE_STYLES: Record<string, Intl.DateTimeFormatOptions> = {
  weekdayDayMonth: { weekday: 'long', day: 'numeric', month: 'long' },
  shortWeekdayDayNumericMonth: { weekday: 'short', day: 'numeric', month: 'numeric' },
  dayNumericMonth: { day: 'numeric', month: 'numeric' },
  dayNumericMonthYear: { day: 'numeric', month: 'numeric', year: 'numeric' },
  dayNumericMonthShortYear: { day: 'numeric', month: 'numeric', year: '2-digit' },
  dayMonth: { day: 'numeric', month: 'long' },
  shortWeekdayDayMonth: { weekday: 'short', day: 'numeric', month: 'long' },
  weekdayDayNumericMonth: { weekday: 'long', day: 'numeric', month: 'numeric' },
  monthShortYear: { month: 'short', year: '2-digit' },
  monthYear: { month: 'long', year: 'numeric' },
};

/** Okamžiky: kolem změn času, přestupných dnů, přelomů roku (53. týden) a náhodně 2019–2031. */
function instants(): number[] {
  const out: number[] = [];
  const days: [number, number, number][] = [
    [2026, 2, 28], [2026, 2, 29], [2026, 2, 30], [2026, 9, 24], [2026, 9, 25], [2026, 9, 26],
    [2025, 2, 30], [2025, 9, 26], [2024, 1, 28], [2024, 1, 29], [2024, 2, 1],
    [2020, 11, 28], [2020, 11, 31], [2021, 0, 1], [2021, 0, 3], [2021, 0, 4],
    [2026, 11, 28], [2026, 11, 31], [2027, 0, 1], [2027, 0, 3], [2027, 0, 4], [2025, 11, 29], [2026, 0, 1],
  ];
  for (const [y, m, d] of days) for (const [h, mi] of [[0, 0], [1, 59], [2, 30], [3, 0], [12, 0], [23, 59]]) out.push(new Date(y, m, d, h, mi).getTime());
  // přesně kolem okamžiku změny času (UTC 01:00), po čtvrthodinách
  for (const change of [Date.UTC(2026, 2, 29, 1), Date.UTC(2026, 9, 25, 1), Date.UTC(2025, 9, 26, 1)]) {
    for (let k = -8; k <= 8; k++) out.push(change + k * 15 * MIN);
  }
  for (let i = 0; i < 400; i++) out.push(Date.UTC(2019, 0, 1) + Math.floor(rnd() * 12 * 365 * DAY));
  return out;
}

const MINUTES = [0, 1, 59, 60, 90, 120, 150, 179, 180, 600, 1439, 1440, 1500];

function calendar() {
  const out = instants().map((t) => {
    const sod = T.startOfDay(t);
    const now = t + int(-3, 3) * DAY + int(-12, 12) * HOUR;
    const realNow = Date.now;
    Date.now = () => now; // fmtDayLabel porovnává s Date.now()
    const label = T.fmtDayLabel(t);
    Date.now = realNow;
    return {
      t,
      dayKey: T.dayKey(t),
      startOfDay: sod,
      parsed: T.parseDayKey(T.dayKey(t)).getTime(),
      addDays: [1, -1, 7, -7, 31, -400].map((n) => [n, T.addDays(t, n)]),
      minutesOfDay: T.minutesOfDay(t),
      atMinutes: MINUTES.map((m) => [m, T.atMinutes(sod, m)]),
      startOfWeek: T.startOfWeek(t),
      startOfMonth: T.startOfMonth(t),
      weekday: T.weekdayIdx(t),
      isoWeek: T.isoWeek(t),
      time: T.fmtTime(t),
      dates: Object.fromEntries(Object.entries(DATE_STYLES).map(([k, o]) => [k, T.fmtDate(t, o)])),
      now,
      dayLabel: label,
      capitalized: T.capitalize(label),
    };
  });
  write('calendar.json', out, true);
}

// ---------- 2. čísla a délky ----------
function formats() {
  const durations = [0, 0.4, 0.5, 0.6, 1, 29.5, 30, 59, 59.5, 60, 61, 3599, 3599.5, 3600, 3660, 5400, 8100.5, 36000, 359999, -5, -0.5];
  for (let i = 0; i < 300; i++) durations.push(chance(0.3) ? int(0, 300) : chance(0.2) ? int(0, 10 ** 6) / 2 : int(0, 200_000));
  const decimals = [0, 0.05, 0.15, 0.25, 0.35, 1.005, 2.05, 2.675, 3.25, 3.35, 4, 4.45, 4.55, 9.95, 99.95, 999.95, 1234.56, 10_000.05];
  for (let i = 0; i < 300; i++) decimals.push(chance(0.5) ? int(0, 50_000) / 100 : chance(0.5) ? int(0, 5000) / 1000 : rnd() * 5);
  const hours = [0, 1, 179, 180, 3600, 5940, 12600, 3600 * 1000 + 180, 1e7];
  for (let i = 0; i < 300; i++) hours.push(chance(0.7) ? int(0, 400_000) : int(0, 10 ** 7));
  const clocks = [0, 1, 499, 500, 501, 59_499, 59_500, 61_000, 3_599_499, 3_599_500, 3_725_000, 36_000_000, -1000];
  for (let i = 0; i < 200; i++) clocks.push(int(0, 15_000_000));
  const counts = [0, 7, 999, 1000, 1234, 10_000, 99_999, 123_456, 1_234_567, 12_345_678];
  for (let i = 0; i < 100; i++) counts.push(int(0, 10 ** int(1, 8)));

  write('formats.json', {
    durations: durations.map((sec) => ({ sec, text: T.fmtDuration(sec) })),
    decimals: decimals.flatMap((n) => [0, 1, 2].map((digits) => ({ n, digits, text: T.fmtDec(n, digits) }))),
    hours: hours.map((sec) => ({ sec, text: T.fmtHours(sec) })),
    clocks: clocks.map((ms) => ({ ms, text: T.fmtClock(ms) })),
    // `toLocaleString('cs-CZ')` u počtů (karty Anki, report)
    counts: counts.map((n) => ({ n, text: n.toLocaleString('cs-CZ') })),
    plurals: Array.from({ length: 32 }, (_, i) => i - 1).map((n) => ({ n, text: T.plural(n, 'den', 'dny', 'dní') })),
  });
}

// ---------- 3. souhrny učení ----------
function stats() {
  const bases = [new Date(2026, 2, 16).getTime(), new Date(2026, 9, 12).getTime(), new Date(2026, 11, 21).getTime(), new Date(2024, 1, 19).getTime()];
  const out: unknown[] = [];
  for (let i = 0; i < 150; i++) {
    const base = i < 100 ? pick(bases) : T.startOfDay(Date.UTC(2020, 0, 1) + Math.floor(rnd() * 8 * 365 * DAY));
    const learnDay = rnd() * 0.6 + 0.3; // jak často se v daný den učí
    const sessions: Record<string, unknown>[] = [];
    for (let d = 0; d < 24; d++) {
      if (!chance(learnDay)) continue;
      const day = T.addDays(base, d);
      for (let k = int(1, 3); k > 0; k--) {
        const start = day + int(0, 86_399) * 1000;
        const durationSec = chance(0.08) ? 0 : pick([int(60, 1200), int(1200, 3600), int(3600, 9000)]);
        const s: Record<string, unknown> = {
          id: `s${i}-${sessions.length}`,
          subjectId: pick(['a', 'b', 'c']),
          start,
          end: start + durationSec * 1000 + int(0, 30) * MIN,
          durationSec,
        };
        if (chance(0.6)) s.focus = int(0, 5);
        sessions.push(s);
      }
    }
    // pořadí jako v datech: novější i starší záznamy přeházené
    for (let a = sessions.length - 1; a > 0; a--) {
      const b = Math.floor(rnd() * (a + 1));
      [sessions[a], sessions[b]] = [sessions[b], sessions[a]];
    }
    const rules = { restDays: int(0, 2), minMin: pick([0, 0, 15, 30, 60]) };
    const now = T.addDays(base, int(-1, 28)) + int(0, 86_399) * 1000;
    const from = T.addDays(base, int(0, 12));
    const to = T.addDays(from, int(1, 10));
    const entries = (m: Map<string, number>) => Object.fromEntries([...m.entries()].sort(([a], [b]) => (a < b ? -1 : 1)));
    out.push({
      sessions,
      rules,
      now,
      from,
      to,
      inRange: S.inRange(sessions, from, to).map((s: { id: string }) => s.id),
      totalSec: S.totalSec(sessions),
      byDay: entries(S.byDay(sessions)),
      bySubject: entries(S.bySubject(sessions)),
      streakDays: [...S.streakDays(sessions, rules.minMin)].sort(),
      streaks: S.streaks(sessions, rules, now),
      avgFocus: S.avgFocus(sessions),
    });
  }
  write('stats.json', out, true);
}

// ---------- 4. normalizace názvů (`norm` – hledání předmětu podle názvu v odkazu) ----------
function names() {
  const parts = ['Matematika', 'Anatomie', 'Fyziologie', 'Žluťoučký kůň', 'ĚŠČŘŽÝÁÍÉ', 'Biochemie II', 'Právo – úvod', 'naïve', 'İstanbul', 'Straße',
    '日本語', '😀', '  ', '-', '/', '_', '12', 'Ö', 'Ångström', 'ﬁ', 'Ǆ', 'e\u0301', 'Ḱ', 'Ⅻ', '½', 'Ⓐ', 'ǅ'];
  const out: { s: string; norm: string }[] = [];
  for (let i = 0; i < 300; i++) {
    let s = '';
    for (let k = int(1, 4); k > 0; k--) s += pick(parts) + pick(['', ' ', '  ', '.', ', ', '\t']);
    if (chance(0.3)) s = s.toUpperCase();
    out.push({ s, norm: TT.norm(s) });
  }
  write('names.json', out);
}

mkdirSync(OUT, { recursive: true });
calendar();
formats();
stats();
names();
write('meta.json', { webVersion, timeZone: 'Europe/Prague', note: 'Vygenerováno z kódu webové aplikace (Tools/parity/generate-engine.ts). Neupravovat ručně.' });
console.log(`Kontrolní data Engine z webu v${webVersion} → ${OUT}`);
