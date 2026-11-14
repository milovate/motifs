// Forwards page console entries to the extension. Page content can post the
// same shape, so entries are treated as untrusted page output.
window.addEventListener("message", (event) => {
  if (event.source !== window || event.data?.__motifs !== 1) return;
  try {
    chrome.runtime.sendMessage({ type: "console", entry: event.data.entry }).catch(() => {});
  } catch {}
});
