// Blokovací stránka: co je zablokované, do kdy a kolikátý je to dnes pokus. Když už blokování neplatí
// (blok skončil, odemknutí), vrátí se na původní adresu.
(async () => {
  const param = new URLSearchParams(location.search).get("u");
  const url = param || (await browser.runtime.sendMessage({ type: "origin" }));
  const r = url ? await browser.runtime.sendMessage({ type: "attempt", url }) : null;
  if (url && r && r.blocked === false) {
    location.replace(url);
    return;
  }
  if (r && r.blocked) {
    document.getElementById("title").textContent = `${r.name} je teď zablokovaný`;
    const parts = [];
    if (r.lists && r.lists.length) parts.push(r.lists.join(", "));
    if (r.until) {
      const d = new Date(r.until);
      const today = d.toDateString() === new Date().toDateString();
      parts.push("do " + d.toLocaleString("cs-CZ", today ? { hour: "numeric", minute: "2-digit" } : { day: "numeric", month: "numeric", hour: "numeric", minute: "2-digit" }));
    } else {
      parts.push("do konce bloku");
    }
    if (r.locked) parts.push("přísný zámek – do konce nejde zrušit");
    document.getElementById("detail").textContent = parts.join(" · ");
    const count = document.getElementById("count");
    count.textContent = `Dnes už ${r.attempts}. pokus`;
    count.classList.toggle("many", r.attempts >= 5);
    count.hidden = false;
  }
  document.getElementById("back").addEventListener("click", () => (history.length > 1 ? history.back() : browser.runtime.sendMessage({ type: "close" })));
  document.getElementById("close").addEventListener("click", () => browser.runtime.sendMessage({ type: "close" }));
})();
