import { addEntry, addStep, createBuffers, LIMITS, networkEntry, sanitizeConsole, sanitizeStep, windowSnapshots } from "./buffer.js";

const HOST = "local.motifs";
let buffers = createBuffers();
// Page steps are kept only between the helper's steps-start and steps-stop.
let steps = { active: false, startedAt: 0, entries: [] };
let port;
let saveTimer;

// storage.session is memory-only; it survives service-worker restarts, not browser restarts.
const restored = chrome.storage.session.get(["buffers", "steps"]).then(({ buffers: saved, steps: savedSteps }) => {
  if (saved) buffers = saved;
  if (savedSteps) steps = savedSteps;
});
const recording = () => steps.active && Date.now() - steps.startedAt <= LIMITS.stepsMs;

function recordStep(tab, step) {
  restored.then(() => {
    if (!recording()) return;
    addStep(steps, sanitizeStep(step, tab));
    chrome.storage.session.set({ steps });
  });
}

async function setRecording(active) {
  await restored;
  const finished = steps.entries;
  steps = active ? { active: true, startedAt: Date.now(), entries: [] } : { active: false, startedAt: 0, entries: [] };
  await chrome.storage.session.set({ steps });
  for (const tab of await chrome.tabs.query({})) chrome.tabs.sendMessage(tab.id, { type: "steps", active }).catch(() => {});
  return active ? [] : finished;
}

function record(tabId, kind, entry) {
  if (!entry) return;
  restored.then(() => {
    addEntry(buffers, tabId, kind, entry);
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => chrome.storage.session.set({ buffers }), 1000);
  });
}

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id || !sender.tab) return;
  if (message?.type === "console") record(sender.tab.id, "console", sanitizeConsole(message.entry));
  if (message?.type === "step") recordStep(sender.tab, message.step);
  if (message?.type === "steps-state") {
    restored.then(() => reply({ active: recording() }));
    return true;
  }
});
chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  if (change.url && tab.active) recordStep(tab, { kind: "navigate", time: Date.now() });
});
chrome.tabs.onActivated.addListener(({ tabId }) => {
  chrome.tabs.get(tabId).then((tab) => recordStep(tab, { kind: "tab", time: Date.now() })).catch(() => {});
});

const filter = { urls: ["<all_urls>"] };
chrome.webRequest.onCompleted.addListener((details) => record(details.tabId, "network", networkEntry(details)), filter);
chrome.webRequest.onErrorOccurred.addListener((details) => record(details.tabId, "network", networkEntry(details)), filter);
chrome.tabs.onRemoved.addListener((tabId) => {
  restored.then(() => {
    delete buffers[tabId];
    chrome.storage.session.set({ buffers });
  });
});

// The helper only asks when the user captures a browser window. Replies carry
// the active tab's buffer; nothing is pushed otherwise.
function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch {
    port = undefined;
    return;
  }
  port.onMessage.addListener(async (message) => {
    if (typeof message?.requestID !== "string") return;
    if (message.type === "steps-start" || message.type === "steps-stop") {
      const finished = await setRecording(message.type === "steps-start");
      port?.postMessage({ type: "steps", requestID: message.requestID, steps: finished });
      return;
    }
    if (message.type !== "snapshot") return;
    await restored;
    const windows = await chrome.windows.getAll({ populate: true, windowTypes: ["normal"] });
    port?.postMessage({ type: "snapshot", requestID: message.requestID, windows: windowSnapshots(buffers, windows, navigator.userAgent) });
  });
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    port = undefined;
  });
}

connect();
chrome.runtime.onStartup.addListener(connect);
chrome.alarms.create("reconnect", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(connect);
