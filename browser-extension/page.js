// Runs in the page's own JavaScript world so it can see console calls and errors.
(() => {
  if (window.__motifsInstalled) return;
  window.__motifsInstalled = true;
  const format = (value) => {
    if (typeof value === "string") return value;
    if (value instanceof Error) return value.stack || `${value.name}: ${value.message}`;
    try {
      return JSON.stringify(value)?.slice(0, 2000) ?? String(value);
    } catch {
      return String(value);
    }
  };
  const post = (level, args) => {
    try {
      window.postMessage({ __motifs: 1, entry: { level, time: Date.now(), message: args.map(format).join(" ").slice(0, 2000) } }, "*");
    } catch {}
  };
  for (const level of ["log", "info", "warn", "error", "debug"]) {
    const original = console[level];
    console[level] = function (...args) {
      post(level, args);
      return original.apply(this, args);
    };
  }
  window.addEventListener("error", (event) => post("error", [event.error ?? event.message, event.filename ? `(${event.filename}:${event.lineno})` : ""]));
  window.addEventListener("unhandledrejection", (event) => post("error", ["Unhandled promise rejection:", event.reason]));
})();
