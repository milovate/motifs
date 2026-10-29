// Records page steps only while Capture Studio is recording the screen. Runs in the
// extension's isolated world. Typed text and field values are never read: typing is
// reported once per field, and selections inside editable fields are ignored.
(() => {
  if (globalThis.__captureStudioSteps) return;
  globalThis.__captureStudioSteps = true;
  const { describe, isEditable, target } = globalThis.CaptureStudioSteps;
  let active = false;
  let typed = new WeakSet();
  let lastSelection = "";
  const scrollTimers = new Map();
  let selectionTimer;

  const send = (step) => {
    if (!active) return;
    try {
      chrome.runtime.sendMessage({ type: "step", step: { ...step, time: Date.now() } }).catch(() => {});
    } catch {}
  };
  const setActive = (value) => {
    active = value === true;
    typed = new WeakSet();
    lastSelection = "";
  };
  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type === "steps") setActive(message.active);
  });
  chrome.runtime.sendMessage({ type: "steps-state" }).then((reply) => setActive(reply?.active)).catch(() => {});

  const origin = (event) => event.composedPath?.()[0] ?? event.target;
  const options = { capture: true, passive: true };

  document.addEventListener("click", (event) => {
    if (!active || !event.isTrusted || event.button !== 0) return;
    const element = target(origin(event));
    if (!element) return;
    const tag = element.tagName.toLowerCase();
    // Labels forward a click to their control, and choices are recorded on change.
    if ((tag === "label" && element.control) || tag === "select" || tag === "option" || (tag === "input" && ["checkbox", "radio", "file"].includes((element.getAttribute("type") || "").toLowerCase()))) return;
    send({ kind: "click", ...describe(element), x: event.clientX, y: event.clientY, ...(event.detail > 1 ? { count: event.detail } : {}) });
  }, options);

  document.addEventListener("input", (event) => {
    if (!active || !event.isTrusted) return;
    let element = origin(event);
    if (element?.nodeType !== 1) element = element?.parentElement;
    while (element && !isEditable(element) && element.parentElement?.isContentEditable) element = element.parentElement;
    if (!isEditable(element) || typed.has(element)) return;
    typed.add(element);
    send({ kind: "type", ...describe(element) });
  }, options);

  document.addEventListener("change", (event) => {
    if (!active || !event.isTrusted) return;
    const element = origin(event);
    if (element?.nodeType !== 1) return;
    const tag = element.tagName.toLowerCase();
    const type = (element.getAttribute("type") || "").toLowerCase();
    if (tag === "select") send({ kind: "choose", ...describe(element), option: element.selectedOptions?.[0]?.label ?? element.selectedOptions?.[0]?.textContent });
    else if (tag === "input" && (type === "checkbox" || type === "radio")) send({ kind: "check", ...describe(element), checked: element.checked });
    else if (tag === "input" && type === "file") send({ kind: "upload", ...describe(element) });
  }, options);

  document.addEventListener("submit", (event) => {
    if (active && event.isTrusted) send({ kind: "submit", ...describe(origin(event)) });
  }, options);

  document.addEventListener("scroll", (event) => {
    if (!active || !event.isTrusted) return;
    const element = event.target === document || event.target === document.documentElement || event.target === document.body ? undefined : event.target;
    const key = element ?? window;
    clearTimeout(scrollTimers.get(key));
    scrollTimers.set(key, setTimeout(() => {
      scrollTimers.delete(key);
      if (element) send({ kind: "scroll", ...describe(element), x: element.scrollLeft, y: element.scrollTop });
      else send({ kind: "scroll", x: window.scrollX, y: window.scrollY });
    }, 400));
  }, options);

  document.addEventListener("selectionchange", () => {
    if (!active) return;
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => {
      const selection = document.getSelection();
      const anchor = selection?.anchorNode?.nodeType === 1 ? selection.anchorNode : selection?.anchorNode?.parentElement;
      if (!anchor || anchor.isContentEditable || isEditable(document.activeElement)) return;
      const text = selection.toString().replace(/\s+/g, " ").trim();
      if (!text || text === lastSelection) return;
      lastSelection = text;
      send({ kind: "select", ...describe(target(anchor)), text });
    }, 500);
  });
})();
