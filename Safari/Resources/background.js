// Soustředění ve Study Trackeru: blokování webů podle Strážce (pravidla zná jen aplikace, sem chodí přes
// nativní zprávy). Známé domény blokuje declarativeNetRequest ještě před načtením; slova v adrese a režim
// „povolit jen tyhle“ hlídá kontrola při každé navigaci.
const APP = "cz.rawzuu.studytracker";
const BLOCKED = browser.runtime.getURL("blocked.html");
let rulesKey = "";
const origins = new Map();

async function ask(message) {
  try {
    return await browser.runtime.sendNativeMessage(APP, message);
  } catch (e) {
    return null;
  }
}

function filterFor(text) {
  const slash = text.indexOf("/");
  return slash < 0 ? `||${text}^` : `||${text}`;
}

async function applyRules(rules) {
  if (!rules) return;
  const key = JSON.stringify(rules);
  if (key === rulesKey) return;
  rulesKey = key;
  const add = [];
  let id = 1;
  for (const text of rules.block) {
    add.push({ id: id++, priority: 1, action: { type: "redirect", redirect: { extensionPath: "/blocked.html" } },
               condition: { urlFilter: filterFor(text), resourceTypes: ["main_frame"] } });
  }
  for (const text of rules.allow) {
    add.push({ id: id++, priority: 2, action: { type: "allow" }, condition: { urlFilter: filterFor(text), resourceTypes: ["main_frame"] } });
  }
  const old = await browser.declarativeNetRequest.getDynamicRules();
  await browser.declarativeNetRequest.updateDynamicRules({ removeRuleIds: old.map((r) => r.id), addRules: add });
}

async function refresh() {
  const r = await ask({ type: "check" });
  if (r) await applyRules(r.rules);
}

browser.webNavigation.onBeforeNavigate.addListener(async (details) => {
  if (details.frameId !== 0 || !/^https?:/.test(details.url)) return;
  origins.set(details.tabId, details.url);
  const r = await ask({ type: "check", url: details.url });
  if (!r) return;
  await applyRules(r.rules);
  if (r.blocked) {
    const tab = await browser.tabs.get(details.tabId).catch(() => null);
    if (tab && !String(tab.url || "").startsWith(BLOCKED)) {
      browser.tabs.update(details.tabId, { url: `${BLOCKED}?u=${encodeURIComponent(details.url)}` });
    }
  }
});

browser.runtime.onMessage.addListener(async (message, sender) => {
  if (message.type === "origin") return origins.get(sender.tab?.id) || null;
  if (message.type === "attempt") return ask({ type: "attempt", url: message.url });
  if (message.type === "close" && sender.tab) return browser.tabs.remove(sender.tab.id);
  return null;
});

browser.alarms.create("refresh", { periodInMinutes: 1 });
browser.alarms.onAlarm.addListener(refresh);
browser.runtime.onStartup.addListener(refresh);
browser.runtime.onInstalled.addListener(refresh);
refresh();
