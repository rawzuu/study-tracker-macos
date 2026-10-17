/**
 * Kontrolní data pro paritní testy: stejné vstupy proženeme SKUTEČNÝM kódem webové aplikace
 * a Swift testy (Packages/StudyKit/Tests/CoreTests) musí dát bajtově stejný výsledek.
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
const OUT = resolve(process.env.OUT_DIR ?? join(here, '../../Packages/StudyKit/Tests/CoreTests/Fixtures'));

// Web řadí záznamy se shodným createdAt podle jazyka prohlížeče (localeCompare) – generujeme česky.
if (!new Intl.Collator().resolvedOptions().locale.startsWith('cs')) {
  throw new Error('Spusť s LC_ALL=cs_CZ.UTF-8 (npm run generate to dělá samo).');
}

const load = (p: string) => import(pathToFileURL(join(WEB, p)).href);
const { mergeData, serialize, hasNewer } = await load('src/data/merge.ts');
const { migrate } = await load('src/data/migrations.ts');
const webVersion = JSON.parse(readFileSync(join(WEB, 'package.json'), 'utf8')).version as string;

// ---------- deterministická náhoda ----------
let seed = 0x5eed1234;
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
/** Fisher–Yates – na rozdíl od sort(() => rnd() − 0,5) nezávisí na verzi Node. */
function shuffle<T>(xs: T[]): T[] {
  for (let i = xs.length - 1; i > 0; i--) {
    const j = Math.floor(rnd() * (i + 1));
    [xs[i], xs[j]] = [xs[j], xs[i]];
  }
  return xs;
}

function write(name: string, value: unknown, compact = false) {
  writeFileSync(join(OUT, name), JSON.stringify(value, null, compact ? undefined : 1) + '\n');
}

function bitsOf(x: number): string {
  const v = new DataView(new ArrayBuffer(8));
  v.setFloat64(0, x);
  return v.getBigUint64(0).toString(16).padStart(16, '0');
}

// ---------- 1. čísla: Number::toString ----------
function numbers() {
  const fixed = [
    0, -0, 1, -1, 0.1, 0.2, 0.1 + 0.2, 0.5, 1.5, 0.6, 0.35, 0.9, 1e21, 1e-7, 1e-6, 1.5e-7, 9.99e-7, 123e-20,
    123456789012345680000, 2 ** 53, 2 ** 53 + 2, 2 ** 63, 2 ** 64, -(2 ** 53), 5e-324, Number.MAX_VALUE, Number.MIN_VALUE,
    1759823400000, 1.7598234e12, 100, 1e16, 1e20, 1.234e21, 0.000001, 0.0000001, 33.333333333333336, 4.35, 2.675,
    Number.EPSILON, 1 / 3, 2 / 3, 1e300 * 10, 299792458, 6.02214076e23, 1.602176634e-19,
  ];
  const xs = [...fixed];
  const buf = new DataView(new ArrayBuffer(8));
  for (let i = 0; i < 1500; i++) {
    // náhodné bity pokryjí všechny řády včetně subnormálních čísel
    buf.setUint32(0, Math.floor(rnd() * 2 ** 32));
    buf.setUint32(4, Math.floor(rnd() * 2 ** 32));
    const x = buf.getFloat64(0);
    if (Number.isFinite(x)) xs.push(x);
  }
  // Desetinná čísla skládáme z textu: převod textu na číslo je přesný v každé verzi Node,
  // kdežto `10 ** -n` se mezi verzemi V8 liší v posledním bitu.
  const digits = (n: number) => String(int(1, 9)) + Array.from({ length: n }, () => int(0, 9)).join('');
  for (let i = 0; i < 800; i++) {
    xs.push(Number(`${chance(0.2) ? '-' : ''}${digits(int(0, 16))}e${int(-30, 25)}`));
    xs.push(Number(`${digits(int(0, 6))}e-${int(0, 3)}`));
  }
  write('numbers.json', xs.map((x) => ({ bits: bitsOf(x), js: JSON.stringify(x) })));
}

// ---------- 2. řetězce: escapování ----------
function randomString(): string {
  const parts = [
    () => String.fromCharCode(int(0, 31)),
    () => pick(['"', '\\', '/', '\u007f', ' ', ' ', '﻿', ' ']),
    () => pick(['Žluťoučký kůň', 'příliš', 'ĚŠČŘŽÝÁÍÉ', 'naïve', '日本語', 'ß']),
    () => pick(['😀', '👩‍💻', '🇨🇿', '𝄞']),
    () => String.fromCharCode(int(32, 126)),
    () => String.fromCodePoint(int(0x80, 0xd7ff)),
  ];
  let s = '';
  const n = int(0, 24);
  for (let i = 0; i < n; i++) s += pick(parts)();
  return s;
}

function strings() {
  const out: { codePoints: number[]; js: string }[] = [];
  for (let i = 0; i < 400; i++) {
    const s = randomString();
    out.push({ codePoints: [...s].map((c) => c.codePointAt(0)!), js: JSON.stringify(s) });
  }
  write('strings.json', out);
}

// ---------- 3. dokumenty: čtení + zápis (pořadí klíčů, mezery, escape sekvence) ----------
const ws = () => pick(['', '', ' ', '\n', '\t', ' \r\n  ']);

function sourceNumber(): string {
  return pick([
    () => String(int(-1000, 1000)),
    () => (rnd() * 1000).toFixed(int(0, 6)),
    () => `${int(1, 9)}${pick(['e', 'E'])}${pick(['', '+', '-'])}${int(0, 30)}`,
    () => '-0',
    () => '0.0e0',
    () => '123456789012345678901234567890',
    () => '1.50',
    () => String(1759823400000 + int(0, 10 ** 9)),
  ])();
}

function sourceString(): string {
  // část znaků zapíšeme escape sekvencemi, které JS.stringify nepoužívá (\/, é, náhradní páry)
  let out = '"';
  for (const ch of randomString()) {
    const cp = ch.codePointAt(0)!;
    if (ch === '"' || ch === '\\') out += '\\' + ch;
    else if (cp < 0x20) out += '\\u' + cp.toString(16).padStart(4, '0');
    else if (ch === '/' && chance(0.5)) out += '\\/';
    else if (cp > 0xffff && chance(0.5)) {
      const h = Math.floor((cp - 0x10000) / 0x400) + 0xd800;
      const l = ((cp - 0x10000) % 0x400) + 0xdc00;
      out += `\\u${h.toString(16)}\\u${l.toString(16).toUpperCase()}`;
    } else if (cp > 0x7f && chance(0.3)) out += '\\u' + cp.toString(16).padStart(4, '0');
    else out += ch;
  }
  return out + '"';
}

function sourceValue(depth: number): string {
  const kinds = depth > 3 ? ['n', 's', 'b', 'z'] : ['n', 's', 'b', 'z', 'a', 'o', 'o'];
  switch (pick(kinds)) {
    case 'n':
      return sourceNumber();
    case 's':
      return sourceString();
    case 'b':
      return pick(['true', 'false']);
    case 'z':
      return 'null';
    case 'a': {
      const n = int(0, 4);
      return '[' + ws() + Array.from({ length: n }, () => sourceValue(depth + 1)).join(ws() + ',' + ws()) + ws() + ']';
    }
    default: {
      const n = int(0, 6);
      const keys = Array.from({ length: n }, () =>
        pick(['id', 'name', 'b', 'a', '10', '2', '0', '01', '-1', '4294967294', '4294967295', '1.5', 'Ž', '', 'name']),
      );
      return '{' + ws() + keys.map((k) => `${JSON.stringify(k)}${ws()}:${ws()}${sourceValue(depth + 1)}`).join(ws() + ',' + ws()) + ws() + '}';
    }
  }
}

function documents() {
  const out: { text: string; compact: string; pretty: string }[] = [];
  for (let i = 0; i < 250; i++) {
    const text = ws() + sourceValue(0) + ws();
    const v = JSON.parse(text);
    out.push({ text, compact: JSON.stringify(v), pretty: JSON.stringify(v, null, 1) });
  }
  write('documents.json', out);
}

// ---------- 4. migrace a slučování ----------
const T0 = 1_759_800_000_000;
const ID_POOL = [
  ...Array.from({ length: 6 }, (_, i) => `00000000-0000-4000-8000-00000000000${i}`),
  'anki', 'snapshot', 'anki-chemie-1', 'anki-hudba-1', 'anki-Hudba-1', 'anki-žalm-1', 'anki zalm-1', 'anki-algoritmizace-1759800000000',
  'hours.3', 'exam-ready', 'Zkouška', 'zkouska',
];

function maybe<T>(p: number, v: () => T): T | undefined {
  return chance(p) ? v() : undefined;
}

function clean(o: Record<string, unknown>) {
  for (const k of Object.keys(o)) if (o[k] === undefined) delete o[k];
  return o;
}

function entityFields(col: string): Record<string, unknown> {
  const t = T0 + int(0, 30) * 86_400_000 + int(0, 86_399) * 1000;
  switch (col) {
    case 'subjects':
      return { name: pick(['Matematika', 'Němčina', 'Anki', 'Právo']), color: pick(['#7d9cc0', '#8fae8b']), weeklyGoalMin: pick([0, 120, 300]), archived: chance(0.2) };
    case 'sessions':
      return clean({
        subjectId: pick(ID_POOL), topic: pick(['', 'Derivace', 'Integrály']), start: t, end: t + 1_500_000, durationSec: pick([1500, 1499.5, 60, 3000]),
        mode: pick(['pomodoro', 'manual', 'anki', 'flowtime']), focus: maybe(0.7, () => int(1, 5)), interruptions: int(0, 3), note: pick(['', 'pozn. "uvozovky"\n']),
        topicId: maybe(0.3, () => pick(ID_POOL)), recall: maybe(0.3, () => randomString()),
      });
    case 'topics':
      return clean({
        subjectId: pick(ID_POOL), name: 'Téma', stage: int(-1, 6), reviews: int(0, 9), mastered: chance(0.1), note: '',
        lastStudiedAt: maybe(0.6, () => t), nextReviewAt: maybe(0.6, () => t + 86_400_000),
        fsrs: maybe(0.6, () => ({ s: rnd() * 40, d: 1 + rnd() * 9, state: int(0, 3), reps: int(0, 9), lapses: int(0, 3), scheduledDays: int(0, 60), lastReview: t, due: t + 86_400_000 * int(1, 30) })),
        log: maybe(0.4, () => [{ at: t, rating: int(1, 4) }, { at: t + 1, rating: 3, auto: true }]),
      });
    case 'planBlocks':
      return clean({ subjectId: pick(ID_POOL), title: 'Blok', start: t, durationMin: pick([25, 50, 90]), done: chance(0.5), note: '', examId: maybe(0.2, () => pick(ID_POOL)) });
    case 'exams':
      return { subjectId: pick(ID_POOL), name: 'Zkouška', date: '2026-11-20', time: pick(['', '09:00']), note: '' };
    case 'presets':
      return { name: 'Vlastní', workMin: 45, shortBreakMin: 7.5, longBreakMin: 20, roundsBeforeLong: 3 };
    case 'reflections':
      return { weekStart: '2026-10-05', rating: int(1, 5), wentWell: 'x', blocked: '', focusNext: '' };
    case 'anki':
      return { at: t, decks: [{ name: 'matematika', newCount: 3, learnCount: 1, reviewCount: 20, total: 400 }], reviewedToday: int(0, 200), msToday: int(0, 3_600_000) };
    case 'timetables':
      return { name: 'Rozvrh', importedAt: t, events: [{ key: 'a|1', series: 'a', title: 'Přednáška', location: 'A1', start: t, end: t + 5_400_000 }], hiddenSeries: [], skipped: [], seriesSubjects: { a: pick(ID_POOL), '10': 'x' } };
    default:
      return { at: t };
  }
}

const COLS = ['subjects', 'sessions', 'planBlocks', 'exams', 'presets', 'topics', 'reflections', 'anki', 'timetables', 'achievements'];

function entity(col: string, id: string, createdAt: number): Record<string, unknown> {
  const fields = entityFields(col);
  const base: Record<string, unknown> = chance(0.5)
    ? { id, ...fields, createdAt, updatedAt: createdAt + int(0, 5) * 1000 }
    : { createdAt, id, updatedAt: createdAt + int(0, 5) * 1000, ...fields };
  if (chance(0.15)) base.deletedAt = (base.updatedAt as number) + 1;
  if (chance(0.1)) base.futureField = { nested: [1, 'dva', null], '3': true };
  if (chance(0.03)) delete base.updatedAt;
  return base;
}

function settings(): Record<string, unknown> | undefined {
  const r = rnd();
  if (r < 0.15) return undefined;
  if (r < 0.2) return {};
  const s: Record<string, unknown> = { updatedAt: T0 + int(0, 10) * 1000 };
  if (chance(0.5)) s.theme = pick(['dark', 'light', 'system', 'sepia']);
  if (chance(0.5)) s.dailyGoalMin = pick([90, 120, 180]);
  if (chance(0.3)) s.anki = { enabled: true, countTime: true, deckSubjects: { matematika: 'x', '2024': 'y' }, importDays: 60 };
  if (chance(0.3)) s.futureSetting = pick([true, 'x', { a: 1 }]);
  if (chance(0.2)) s.calendarFeed = { gistId: 'g', owner: 'o', includeExams: true, alarmMin: null };
  if (chance(0.5)) {
    // klíče v jiném pořadí než výchozí nastavení
    const keys = shuffle(Object.keys(s));
    return Object.fromEntries(keys.map((k) => [k, s[k]]));
  }
  return s;
}

/** Dvojice dokumentů se společnými i rozdílnými záznamy (jako dvě zařízení). */
function docPair(): [Record<string, unknown>, Record<string, unknown>] {
  const a: Record<string, unknown> = {};
  const b: Record<string, unknown> = {};
  if (chance(0.8)) a.schemaVersion = 1;
  if (chance(0.8)) b.schemaVersion = 1;
  for (const col of COLS) {
    for (const d of [a, b]) {
      if (chance(0.1)) continue; // kolekce chybí (starší verze)
      if (chance(0.03)) {
        d[col] = null;
        continue;
      }
      d[col] = [];
    }
    const n = int(0, 4);
    for (let i = 0; i < n; i++) {
      const id = pick(ID_POOL);
      const createdAt = T0 + pick([0, 0, 1000, int(0, 10 ** 6)]);
      const e = entity(col, id, createdAt);
      const where = rnd();
      const targets = where < 0.35 ? [a] : where < 0.7 ? [b] : [a, b];
      for (const d of targets) {
        if (!Array.isArray(d[col])) continue;
        const copy = structuredClone(e);
        if (targets.length === 2 && chance(0.6) && copy.updatedAt !== undefined) {
          copy.updatedAt = (copy.updatedAt as number) + int(-2, 2) * 1000;
          copy.note = 'upraveno';
        }
        (d[col] as unknown[]).push(copy);
      }
    }
  }
  const sa = settings();
  const sb = settings();
  if (sa) a.settings = sa;
  if (sb) b.settings = sb;
  // neznámá pole z budoucích verzí: stejná na obou stranách, nebo jen na jedné
  if (chance(0.3)) {
    const v = pick([{ x: 1 }, [1, 2], 'text', [{ id: 'z', updatedAt: T0, v: 1 }]]);
    if (chance(0.5)) a.futureTop = v;
    if (chance(0.5)) b.futureTop = structuredClone(v);
  }
  if (chance(0.2)) a.onlyLocal = { a: [true] };
  if (chance(0.2)) b.onlyRemote = 7.5;
  return chance(0.5) ? [a, b] : [b, a];
}

function merges() {
  const out: unknown[] = [];
  for (let i = 0; i < 100; i++) {
    const [a, b] = docPair();
    const la = migrate(structuredClone(a));
    const rb = migrate(structuredClone(b));
    out.push({
      local: JSON.stringify(a),
      remote: JSON.stringify(b),
      // normalizace se ověřuje jen u části případů (jinak by soubor zbytečně bobtnal)
      normalizedLocal: i < 25 ? serialize(la) : null,
      normalizedRemote: i < 25 ? serialize(rb) : null,
      merged: serialize(mergeData(la, rb)),
      mergedReversed: serialize(mergeData(rb, la)),
      hasNewerLocalRemote: hasNewer(la, rb),
      hasNewerRemoteLocal: hasNewer(rb, la),
    });
  }
  write('merges.json', out, true);

  const errors = [
    { text: '{"schemaVersion":2}', error: 'tooNew' },
    { text: '{"schemaVersion":7,"subjects":[]}', error: 'tooNew' },
    { text: '{"schemaVersion":0}', error: 'missingMigration' },
  ];
  for (const e of errors) {
    try {
      migrate(JSON.parse(e.text));
      throw new Error(`Web neodmítl ${e.text}`);
    } catch (err) {
      if (String(err).includes('neodmítl')) throw err;
    }
  }
  write('migrate-errors.json', errors);
  write('empty.json', { serialized: serialize(migrate({})) });
}

mkdirSync(OUT, { recursive: true });
numbers();
strings();
documents();
merges();
write('meta.json', { webVersion, note: 'Vygenerováno z kódu webové aplikace (Tools/parity/generate.ts). Neupravovat ručně.' });
console.log(`Kontrolní data z webu v${webVersion} → ${OUT}`);
