import { addEntry, createBuffers, networkEntry, sanitizeConsole, windowSnapshots } from "./buffer.js";

const HOST = "local.opencode.capturestudio";
let buffers = createBuffers();
let port;
let saveTimer;

// storage.session is memory-only; it survives service-worker restarts, not browser restarts.
const restored = chrome.storage.session.get("buffers").then(({ buffers: saved }) => {
  if (saved) buffers = saved;
});

function record(tabId, kind, entry) {
  if (!entry) return;
  restored.then(() => {
    addEntry(buffers, tabId, kind, entry);
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => chrome.storage.session.set({ buffers }), 1000);
  });
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type === "console" && sender.tab && sender.id === chrome.runtime.id) record(sender.tab.id, "console", sanitizeConsole(message.entry));
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
    if (message?.type !== "snapshot" || typeof message.requestID !== "string") return;
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
