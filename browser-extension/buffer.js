// Per-tab rolling buffers of console messages and failed requests. Pure logic,
// shared by the service worker and the Node tests.

export const LIMITS = { console: 300, network: 200, ageMs: 10 * 60_000, message: 2000, url: 2000, steps: 500, stepsMs: 6 * 60_000 };
const STEP_KINDS = ["click", "type", "choose", "check", "upload", "submit", "scroll", "select", "navigate", "tab"];
const LEVELS = ["log", "info", "warn", "error", "debug"];
const SENSITIVE = /(token|key|secret|password|passwd|auth|session|sig|signature|code|credential|jwt|bearer)/i;

export function createBuffers() {
  return {};
}

export function redactUrl(raw) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    return String(raw).slice(0, LIMITS.url);
  }
  url.username = "";
  url.password = "";
  for (const name of [...url.searchParams.keys()]) if (SENSITIVE.test(name)) url.searchParams.set(name, "[redacted]");
  if (url.hash.length > 1 && SENSITIVE.test(url.hash)) url.hash = "#[redacted]";
  return url.toString().slice(0, LIMITS.url);
}

export function sanitizeConsole(entry, now = Date.now()) {
  if (!entry || typeof entry !== "object") return undefined;
  const level = LEVELS.includes(entry.level) ? entry.level : "log";
  const message = String(entry.message ?? "").slice(0, LIMITS.message);
  if (!message) return undefined;
  return { time: new Date(Number.isFinite(entry.time) ? entry.time : now).toISOString(), level, message, ...(entry.source ? { source: String(entry.source).slice(0, 200) } : {}) };
}

export function networkEntry(details, now = Date.now()) {
  const failed = details.error || (Number.isInteger(details.statusCode) && details.statusCode >= 400);
  if (!failed || !details.url || details.url.startsWith("chrome-extension://")) return undefined;
  return {
    time: new Date(Number.isFinite(details.timeStamp) ? details.timeStamp : now).toISOString(),
    method: String(details.method || "GET").slice(0, 16),
    url: redactUrl(details.url),
    type: String(details.type || "other").slice(0, 32),
    ...(details.statusCode ? { status: details.statusCode } : {}),
    ...(details.error ? { error: String(details.error).slice(0, 200) } : {}),
  };
}

export function addEntry(buffers, tabId, kind, entry, now = Date.now()) {
  if (!entry || !Number.isInteger(tabId) || tabId < 0 || !["console", "network"].includes(kind)) return buffers;
  const tab = (buffers[tabId] ??= { console: [], network: [] });
  tab[kind].push(entry);
  trim(tab, now);
  return buffers;
}

function trim(tab, now) {
  for (const kind of ["console", "network"]) {
    const fresh = tab[kind].filter((entry) => now - Date.parse(entry.time) <= LIMITS.ageMs);
    tab[kind] = fresh.slice(-LIMITS[kind]);
  }
}

export function snapshot(buffers, tabId, page, now = Date.now()) {
  const tab = buffers[tabId] ?? { console: [], network: [] };
  trim(tab, now);
  return {
    url: redactUrl(page.url || ""),
    title: String(page.title || "").slice(0, 300),
    userAgent: String(page.userAgent || "").slice(0, 400),
    console: tab.console.slice(),
    network: tab.network.slice(),
  };
}

// One snapshot per window's active tab. The helper matches the captured window
// itself, so requests never need to carry window titles.
export function windowSnapshots(buffers, windows, userAgent, now = Date.now()) {
  return windows.slice(0, 8).flatMap((window) => {
    const tab = window.tabs?.find((candidate) => candidate.active);
    return tab ? [{ focused: Boolean(window.focused), snapshot: snapshot(buffers, tab.id, { url: tab.url, title: tab.title, userAgent }, now) }] : [];
  });
}

// One page step from a content script or a tab event. Only descriptive fields
// survive; the content script never sends field values, and nothing else is kept.
export function sanitizeStep(step, tab, now = Date.now()) {
  if (!step || typeof step !== "object" || !STEP_KINDS.includes(step.kind)) return undefined;
  const text = (value, limit) => (typeof value === "string" && value.trim() ? value.replace(/\s+/g, " ").trim().slice(0, limit) : undefined);
  const int = (value) => (Number.isFinite(value) ? Math.round(value) : undefined);
  const result = {
    time: new Date(Number.isFinite(step.time) ? step.time : now).toISOString(),
    kind: step.kind,
    url: tab?.url ? redactUrl(tab.url) : undefined,
    tag: text(step.tag, 20),
    role: text(step.role, 40),
    name: text(step.name, 80),
    selector: text(step.selector, 300),
  };
  if (step.kind === "select") result.text = text(step.text, 200);
  if (step.kind === "choose") result.option = text(step.option, 80);
  if (step.kind === "check") result.checked = step.checked === true;
  if (step.kind === "click" || step.kind === "scroll") Object.assign(result, { x: int(step.x), y: int(step.y) });
  if (step.kind === "click" && int(step.count) > 1) result.count = int(step.count);
  if (step.kind === "navigate" || step.kind === "tab") result.title = text(tab?.title, 120);
  if (step.kind === "select" && !result.text) return undefined;
  return Object.fromEntries(Object.entries(result).filter(([, value]) => value !== undefined));
}

export function addStep(steps, step, now = Date.now()) {
  if (!step || !steps.active || now - steps.startedAt > LIMITS.stepsMs) return steps;
  steps.entries.push(step);
  steps.entries = steps.entries.slice(-LIMITS.steps);
  return steps;
}
