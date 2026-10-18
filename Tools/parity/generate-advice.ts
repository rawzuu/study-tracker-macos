/**
 * Kontrolní data pro „Co teď?“ a ranní plán: výsledky SKUTEČNÉHO kódu webu (`src/lib/recommend.ts`,
 * `src/lib/dayplan.ts`) v pražském čase. Swift testy (Packages/StudyKit/Tests/EngineTests) musí dát stejný výsledek.
 *
 *   WEB_DIR=…/study-tracker npm run generate
 *
 * Opakování na Macu není, data proto nemají témata a opakování po přednášce je vypnuté (`lectureRecap: false`)
 * – web pak počítá jen se signály, které má i Mac. Rozvrh zůstává jako obsazený čas.
 *
 * Každá část má vlastní seed – přidání nové části nezmění data těch dřívějších.
 * Vstupy jsou syntetické – skutečná data uživatele sem nikdy nepatří.
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
const R = await load('src/lib/recommend.ts');
const DP = await load('src/lib/dayplan.ts');
const ST = await load('src/lib/stats.ts');
const { emptyData } = await load('src/data/schema.ts');
const { MIN, DAY } = T as { MIN: number; DAY: number };

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

/** Běžné dny i dny, kdy se něco pokazí nejspíš: změny času, přelom měsíce a roku, přestupný den. */
const DAYS = [
  [2026, 2, 29], [2026, 9, 25], [2026, 9, 26], [2026, 11, 31], [2027, 0, 1], [2028, 1, 29],
  [2026, 9, 14], [2026, 9, 18], [2026, 4, 12], [2026, 6, 1], [2026, 10, 2], [2027, 2, 15],
].map(([y, m, d]) => new Date(y, m, d).getTime());

const NAMES = ['Matematika', 'Fyzika', 'Chemie', 'Anatomie', 'Dějepis', 'Angličtina', 'Biologie'];
const TOPICS = ['Derivace', 'Integrály', 'Limity', 'Řady', 'Kinematika', 'Optika', '  Vlny  '];
const MODES = ['pomodoro', 'pomodoro-long', 'ultradian', 'stopwatch', 'manual', 'flowtime', '52-17'];
const TITLES = ['', 'Kapitola 3', 'Opakování: Derivace, Limity +1', 'Nové téma: Řady', 'Pokračovat: Integrály', 'Příprava na zkoušku: Zápočet', 'Nová látka', 'Blok podle plánu', 'Podle plánu: Optika, Vlny'];
const SERIES = ['Anatomie – přednáška', 'Fyzika – cvičení', 'Chemie'];

// ---------- „Co teď?“ a ranní plán na náhodných datech ----------
function advice() {
  const { int, pick, chance } = random(0xadb1ce);
  const stamp = { createdAt: 1, updatedAt: 1 };

  return Array.from({ length: 18 }, (_, n) => {
    const base = DAYS[n % DAYS.length];
    const nows = Array.from({ length: 8 }, () => T.atMinutes(T.addDays(base, pick([0, 0, 0, 0, 1, -1])), int(0, 1439)) + int(0, 59_999));

    const ids = Array.from({ length: int(1, 6) }, (_, i) => `s${i}`);
    const subjects: Record<string, unknown>[] = ids.map((id, i) => ({
      id,
      name: NAMES[i],
      color: '#7b8cde',
      weeklyGoalMin: pick([0, 0, 60, 120, 180, 300, 480, 600]),
      archived: chance(0.12),
      ...stamp,
      ...(chance(0.05) ? { deletedAt: 5 } : {}),
    }));
    if (chance(0.3)) subjects.push({ id: 'anki', name: 'Anki', color: '#888888', weeklyGoalMin: pick([0, 120]), archived: false, ...stamp });
    const anyId = [...ids, 'gone'];

    const sessions = Array.from({ length: pick([0, 3, 12, 60, 140, 220]) }, (_, i) => {
      const anki = chance(0.1);
      let start = T.atMinutes(T.addDays(base, chance(0.3) ? -int(0, 3) : -int(0, 70)), int(5 * 12, 23 * 12 + 11) * 5) + int(0, 59) * 1000;
      if (chance(0.15)) start = pick(nows) - int(0, 240) * MIN; // nedávno → prokládání a únava
      const durationSec = pick([5 * 60, 25 * 60, 25 * 60, 50 * 60, 50 * 60, 90 * 60, int(2, 180) * 60 + int(0, 59)]);
      const s: Record<string, unknown> = {
        id: `x${i}`,
        mode: anki ? 'anki' : pick(MODES),
        interruptions: 0,
        subjectId: anki ? pick([...anyId, 'anki']) : pick(anyId),
        topic: anki ? 'Balíček' : chance(0.6) ? pick(TOPICS) : '',
        start,
        end: start + durationSec * 1000 + (chance(0.3) ? int(1, 40) * MIN : 0),
        durationSec,
        note: anki && chance(0.8) ? `Anki · ${int(1, 300)} karet` : '',
        ...stamp,
      };
      if (!anki && chance(0.65)) s.focus = int(1, 5);
      else if (chance(0.05)) s.focus = 0;
      if (chance(0.03)) s.deletedAt = pick([0, 5]);
      return s;
    });

    const exams = Array.from({ length: int(0, 3) }, (_, i) => ({
      id: `e${i}`,
      subjectId: pick(anyId),
      name: pick(['Zápočet', 'Zkouška', 'Test']),
      date: T.dayKey(T.addDays(base, int(-3, 45))),
      time: '',
      note: '',
      ...stamp,
      ...(chance(0.05) ? { deletedAt: 5 } : {}),
    }));

    const planBlocks = Array.from({ length: pick([0, 2, 5, 10]) }, (_, i) => {
      const near = chance(0.4);
      const start = near
        ? Math.round((pick(nows) + int(-60, 60) * MIN) / (15 * MIN)) * 15 * MIN
        : T.atMinutes(T.addDays(base, pick([0, 0, 0, -1, -2, -3, 1])), int(6 * 4, 22 * 4) * 15);
      return {
        id: `b${i}`,
        subjectId: pick(anyId),
        title: pick(TITLES),
        start,
        durationMin: pick([15, 25, 30, 45, 50, 60, 90, 120]),
        done: chance(0.3),
        note: '',
        ...stamp,
        ...(chance(0.05) ? { deletedAt: 5 } : {}),
      };
    });

    const timetables: Record<string, unknown>[] = [];
    if (chance(0.5)) {
      const events = [-1, 0, 1].flatMap((d) =>
        Array.from({ length: int(1, 4) }, () => {
          const series = pick(SERIES);
          const start = T.atMinutes(T.addDays(base, d), pick([8 * 60, 9 * 60 + 15, 10 * 60 + 50, 12 * 60 + 30, 14 * 60 + 10, 16 * 60]));
          return { key: `${series}@${start}`, series, title: series, location: '', start, end: start + pick([45, 90, 100]) * MIN };
        }),
      );
      timetables.push({
        id: 'tt',
        name: 'Rozvrh',
        importedAt: 1,
        events,
        hiddenSeries: chance(0.3) ? [pick(SERIES)] : [],
        skipped: chance(0.3) ? [pick(events).key] : [],
        ...stamp,
      });
    }

    const anki: Record<string, unknown>[] = [];
    if (chance(0.5)) {
      anki.push({
        id: 'snapshot',
        at: chance(0.7) ? T.atMinutes(base, int(0, 1439)) : T.atMinutes(T.addDays(base, -1), int(0, 1439)),
        decks: Array.from({ length: int(1, 3) }, (_, i) => ({ name: `Balíček ${i}`, newCount: int(0, 30), learnCount: int(0, 20), reviewCount: pick([0, int(0, 40), int(0, 300)]), total: 500 })),
        reviewedToday: pick([0, 5, int(10, 200)]),
        msToday: pick([0, int(1, 3_600_000)]),
        ...stamp,
        ...(chance(0.1) ? { deletedAt: 5 } : {}),
      });
    }

    const data = {
      ...emptyData(),
      subjects,
      sessions,
      exams,
      planBlocks,
      timetables,
      anki,
      settings: {
        ...emptyData().settings,
        dailyGoalMin: pick([0, 60, 120, 180, 240, 360]),
        defaultMode: pick(['pomodoro', 'pomodoro-long', 'stopwatch']),
        planDayStart: pick(['08:00', '08:00', '07:30', '06:00', '09:15', '', '7']),
        planDayEnd: pick(['22:00', '22:00', '20:00', '23:30', '18:00', '24:00']),
        lectureRecap: false,
      },
    };

    const item = (i: Record<string, unknown> & { carry?: { id: string } }) => ({
      key: i.key, subjectId: i.subjectId, title: i.title, minutes: i.minutes, start: i.start, activity: i.activity, reasons: i.reasons, include: i.include, carry: i.carry?.id ?? null,
    });

    const cases = nows.map((now) => {
      const recs = R.recommend({ data, now }).map((r: Record<string, unknown>) => ({
        key: r.key, subjectId: r.subjectId, activity: r.activity, title: r.title, topic: r.topic, minutes: r.minutes, modeId: r.modeId,
        score: r.score, signals: r.signals, reasons: r.reasons, planBlockId: r.planBlockId ?? null,
      }));
      const extra = pick([0, 0, 1, 2]);
      const items = DP.proposeDay(data, now, extra);
      // Úpravy v okně ranního plánu: odebrat, změnit délku, odškrtnout → znovu rozmístit (`reflow`)
      const edit = {
        drop: items.length > 1 && chance(0.5) ? pick(items as { key: string }[]).key : null,
        resize: items.length && chance(0.6) ? { key: pick(items as { key: string }[]).key, minutes: pick([15, 25, 30, 45, 50, 60, 75, 90, 120]) } : null,
        uncheck: items.length && chance(0.3) ? pick(items as { key: string }[]).key : null,
      };
      const edited = items
        .filter((i: { key: string }) => i.key !== edit.drop)
        .map((i: { key: string }) => ({ ...i, ...(edit.resize?.key === i.key ? { minutes: edit.resize.minutes } : {}), ...(edit.uncheck === i.key ? { include: false } : {}), start: 0 }));
      const sessionsAlive = data.sessions.filter((s) => !s.deletedAt) as never[];
      return {
        now,
        recs,
        note: R.contextNote(data, now),
        share: R.weekShare(sessionsAlive, now),
        lowFocus: R.lowFocusNow(sessionsAlive, now),
        peak: ST.focusWindow(sessionsAlive.filter((s: { start: number; mode: string }) => s.start > now - 60 * DAY && s.mode !== 'anki')),
        bounds: DP.dayBounds(data, now),
        extra,
        items: items.map(item),
        edit,
        reflow: DP.place(data, edited, now).map(item),
      };
    });
    return { data, cases };
  });
}

// ---------- volné místo dne a pauzy ----------
function slots() {
  const { int, pick } = random(0x51075);
  const day = DAYS[0];
  const findSlot = Array.from({ length: 300 }, () => {
    const busy = Array.from({ length: int(0, 8) }, () => {
      const a = T.atMinutes(day, int(6 * 12, 22 * 12) * 5);
      return [a, a + pick([5, 15, 45, 60, 90, 180]) * MIN] as [number, number];
    }).sort((a, b) => a[0] - b[0]);
    const from = T.atMinutes(day, int(6 * 4, 20 * 4) * 15);
    const to = T.atMinutes(day, pick([18, 20, 22, 24]) * 60);
    const minutes = pick([15, 25, 50, 90, 120]);
    return { busy, from, to, minutes, slot: DP.findSlot(busy, from, to, minutes) };
  });
  const breaks = [0, 5, 10, 12, 13, 15, 25, 30, 37, 38, 45, 50, 62, 63, 75, 90, 100, 120, 180].map((m) => [m, DP.breakAfter(m)]);
  return { findSlot, breaks };
}

write('advice.json', { datasets: advice(), ...slots() });
