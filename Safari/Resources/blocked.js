// Blokovací stránka: odpočet do konce, co je zablokované, kolikátý je to dnes pokus a věta k učení.
// Odemyká se na obrazovce Strážce. Když blokování přestane platit (konec bloku, odemknutí),
// vrátí se sama na původní adresu.
const QUOTES = [
  "Za deset minut ti tohle chybět nebude. Učení ano.",
  "Rozptýlení počká. Zkouška ne.",
  "Teď je čas na učení. Na tohle dojde potom – bez výčitek.",
  "Každý odolaný pokus je malá výhra.",
  "Soustředění je dovednost. Právě ji trénuješ.",
  "Dokonči blok. Pak si to užiješ.",
  "Malý krok teď ušetří velký stres před zkouškou.",
  "Mozek chce odměnu hned. Ty víš, co chceš doopravdy.",
];

function clock(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const pad = (n) => (n < 10 ? "0" + n : "" + n);
  return h > 0 ? `${h}:${pad(m)}:${pad(sec)}` : `${m}:${pad(sec)}`;
}

function render(r) {
  document.getElementById("title").textContent = r.name;
  const parts = [];
  if (r.lists && r.lists.length) parts.push(r.lists.join(", "));
  if (r.until) {
    const d = new Date(r.until);
    const time = `${d.getHours()}:${d.getMinutes() < 10 ? "0" : ""}${d.getMinutes()}`;
    const tomorrow = new Date();
    tomorrow.setDate(tomorrow.getDate() + 1);
    if (d.toDateString() === new Date().toDateString()) parts.push(`do ${time}`);
    else if (d.toDateString() === tomorrow.toDateString()) parts.push(`zítra do ${time}`);
    else parts.push(`do ${d.getDate()}. ${d.getMonth() + 1}. ${time}`);
  } else {
    parts.push("do konce bloku");
  }
  if (r.locked) parts.push("přísný zámek");
  document.getElementById("detail").textContent = parts.join(" · ");
  const count = document.getElementById("count");
  count.textContent = `Dnes už ${Math.max(1, r.attempts)}. pokus`;
  count.classList.toggle("many", r.attempts >= 5);
  count.hidden = false;
  document.getElementById("quote").textContent = QUOTES[(r.attempts + r.name.length) % QUOTES.length];
  document.getElementById("unlock").hidden = !r.canUnlock;
  if (r.locked) {
    const note = document.getElementById("note");
    note.textContent = "Přísný zámek – do konce bloku nejde zrušit.";
    note.hidden = false;
  }
  const box = document.getElementById("clock");
  if (r.until) {
    box.hidden = false;
    document.querySelector(".glyph").style.display = "none";
    const tick = () => (document.getElementById("left").textContent = clock(r.until - Date.now()));
    tick();
    setInterval(tick, 1000);
  }
}

(async () => {
  const param = new URLSearchParams(location.search).get("u");
  const url = param || (await browser.runtime.sendMessage({ type: "origin" }));
  const r = url ? await browser.runtime.sendMessage({ type: "attempt", url }) : null;
  if (url && r && r.blocked === false) {
    location.replace(url);
    return;
  }
  if (r && r.blocked) render(r);
  // Konec bloku nebo odemknutí: zpátky na stránku.
  if (url) {
    setInterval(async () => {
      const now = await browser.runtime.sendMessage({ type: "check", url });
      if (now && now.blocked === false) location.replace(url);
    }, 3000);
  }
  document.getElementById("unlock").addEventListener("click", async () => {
    await browser.runtime.sendMessage({ type: "unlock", url });
    const note = document.getElementById("note");
    note.textContent = "Odemykání se otevřelo na obrazovce Study Trackeru.";
    note.hidden = false;
  });
  document.getElementById("back").addEventListener("click", () => (history.length > 1 ? history.back() : browser.runtime.sendMessage({ type: "close" })));
  document.getElementById("close").addEventListener("click", () => browser.runtime.sendMessage({ type: "close" }));
})();
