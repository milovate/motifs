// Describes page elements for Motifs steps: a role and accessible name for
// Playwright's getByRole, plus a CSS selector fallback. Field values and typed
// text are never read. Loaded as a classic content script and by the Node tests.
(function (root) {
  const clip = (value, limit) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, limit);
  const TEST_IDS = ["data-testid", "data-test-id", "data-test", "data-qa", "data-cy"];
  const INTERACTIVE = "a[href],button,input,select,textarea,summary,option,label,[role],[contenteditable],[onclick],[tabindex]";
  const INPUT_ROLES = { checkbox: "checkbox", radio: "radio", button: "button", submit: "button", reset: "button", image: "button", range: "slider", search: "searchbox", number: "spinbutton", email: "textbox", tel: "textbox", url: "textbox", text: "textbox", password: "textbox" };
  const TEXT_INPUTS = new Set(["text", "search", "email", "tel", "url", "password", "number", "date", "datetime-local", "month", "time", "week"]);

  const tagOf = (element) => element.tagName.toLowerCase();
  const typeOf = (element) => (element.getAttribute("type") || "text").toLowerCase();

  function isEditable(element) {
    if (!element || element.nodeType !== 1) return false;
    if (element.isContentEditable) return true;
    const tag = tagOf(element);
    return tag === "textarea" || (tag === "input" && TEXT_INPUTS.has(typeOf(element)));
  }

  function implicitRole(element) {
    const tag = tagOf(element);
    if (tag === "a") return element.hasAttribute("href") ? "link" : undefined;
    if (tag === "button" || tag === "summary") return "button";
    if (tag === "select") return element.multiple ? "listbox" : "combobox";
    if (tag === "textarea" || element.isContentEditable) return "textbox";
    if (tag === "input") return typeOf(element) === "hidden" ? undefined : INPUT_ROLES[typeOf(element)] ?? "textbox";
    if (/^h[1-6]$/.test(tag)) return "heading";
    if (tag === "img") return "img";
    if (tag === "option") return "option";
    return undefined;
  }

  function role(element) {
    return clip(element.getAttribute("role"), 40).split(" ")[0] || implicitRole(element);
  }

  // Never falls back to text content for editable elements: that would be typed text.
  function accessibleName(element) {
    const aria = element.getAttribute("aria-label");
    if (aria?.trim()) return clip(aria, 80);
    const labelledBy = element.getAttribute("aria-labelledby");
    const doc = element.ownerDocument;
    if (labelledBy && doc) {
      const text = labelledBy.split(/\s+/).map((id) => doc.getElementById(id)?.textContent ?? "").join(" ");
      if (text.trim()) return clip(text, 80);
    }
    const tag = tagOf(element);
    if (tag === "input" || tag === "select" || tag === "textarea") {
      const label = element.labels?.[0]?.textContent;
      if (label?.trim()) return clip(label, 80);
      if (["submit", "button", "reset"].includes(typeOf(element)) && element.getAttribute("value")) return clip(element.getAttribute("value"), 80);
      return clip(element.getAttribute("placeholder") || element.getAttribute("title") || element.getAttribute("name"), 80) || undefined;
    }
    if (tag === "img") return clip(element.getAttribute("alt") || element.getAttribute("title"), 80) || undefined;
    if (element.isContentEditable) return clip(element.getAttribute("title") || element.getAttribute("data-placeholder"), 80) || undefined;
    return clip(element.getAttribute("title") || element.textContent, 80) || undefined;
  }

  const quote = (value) => `"${String(value).replace(/["\\]/g, "\\$&")}"`;
  const stableID = (id) => Boolean(id) && id.length <= 64 && !/\d{4,}|^\d|[:.\s]/.test(id);
  const escapeID = (id) => (root.CSS?.escape ? root.CSS.escape(id) : id.replace(/[^\w-]/g, (character) => `\\${character}`));
  const anchorOf = (element) => {
    const attribute = TEST_IDS.find((name) => element.getAttribute(name));
    if (attribute) return `[${attribute}=${quote(element.getAttribute(attribute))}]`;
    return stableID(element.id) ? `#${escapeID(element.id)}` : undefined;
  };

  function selector(element) {
    const own = anchorOf(element);
    if (own) return own;
    const tag = tagOf(element);
    const name = element.getAttribute("name");
    if (name && ["input", "select", "textarea", "button"].includes(tag)) return `${tag}[name=${quote(name)}]`;
    const aria = element.getAttribute("aria-label");
    if (aria && aria.length <= 80) return `${tag}[aria-label=${quote(aria)}]`;
    const parts = [];
    for (let node = element; node && node.nodeType === 1 && parts.length < 5; node = node.parentElement) {
      const anchor = node === element ? undefined : anchorOf(node);
      if (anchor) {
        parts.unshift(anchor);
        break;
      }
      const nodeTag = tagOf(node);
      if (nodeTag === "body" || nodeTag === "html") break;
      const siblings = node.parentElement ? [...node.parentElement.children].filter((child) => child.tagName === node.tagName) : [];
      parts.unshift(siblings.length > 1 ? `${nodeTag}:nth-of-type(${siblings.indexOf(node) + 1})` : nodeTag);
    }
    return parts.join(" > ");
  }

  function target(node) {
    const element = node?.nodeType === 1 ? node : node?.parentElement;
    return element?.closest?.(INTERACTIVE) ?? element ?? undefined;
  }

  function describe(element) {
    if (!element || element.nodeType !== 1) return {};
    const result = { tag: tagOf(element), role: role(element), name: accessibleName(element), selector: selector(element) };
    return Object.fromEntries(Object.entries(result).filter(([, value]) => value));
  }

  root.MotifsSteps = { accessibleName, describe, isEditable, role, selector, target };
})(globalThis);
