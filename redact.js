import { readFile } from "node:fs/promises";
import path from "node:path";

export const REDACTED = "[redacted]";
export const JUDGE_THRESHOLD = 0.4;
const JUDGE = { candidates: 48, concurrency: 4, requestMs: 2_500, totalMs: 10_000, window: 160 };
const QUESTION = "Is the value inside ⟦ ⟧ a secret, such as a password, API key, access token, session ID, signing key or private credential, rather than an ordinary identifier, hash, file name or word?";

// Formats that are secrets wherever they appear. Each is replaced outright.
const KNOWN = [
  ["private-key", /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|$)/g],
  ["age-key", /AGE-SECRET-KEY-1[QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L]{58}/g],
  ["aws-access-key", /\b(?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}\b/g],
  ["aws-bedrock-key", /\bABSK[A-Za-z0-9+/]{100,}={0,2}/g],
  ["azure-client-secret", /(?<![\w~.-])[A-Za-z0-9_~.]{3}\dQ~[A-Za-z0-9_~.-]{31,34}(?![\w~.-])/g],
  ["google-api-key", /\bAIza[0-9A-Za-z_-]{35}/g],
  ["cloudflare-origin-ca-key", /\bv1\.0-[a-f0-9]{24}-[a-f0-9]{146}\b/g],
  ["digitalocean-token", /\bdo[opr]_v1_[a-f0-9]{64}\b/g],
  ["heroku-key", /\bHRKU-AA[0-9A-Za-z_-]{58}/g],
  ["fly-token", /\b(?:fo1_[\w-]{43}|fm[12][ar]?_[A-Za-z0-9+/]{100,}={0,3})/g],
  ["planetscale-token", /\bpscale_(?:tkn|oauth|pw)_[\w=.-]{32,64}/g],
  ["supabase-key", /\b(?:sbp_[a-f0-9]{40}|sb_secret_[A-Za-z0-9_-]{20,})/g],
  ["databricks-token", /\bdapi[a-f0-9]{32}(?:-\d)?\b/g],
  ["doppler-token", /\bdp\.(?:pt|st|sa|ct|scim|audit)\.[A-Za-z0-9]{40,}/g],
  ["onepassword-token", /\bops_eyJ[A-Za-z0-9+/]{250,}={0,3}/g],
  ["github-token", /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})\b/g],
  ["gitlab-token", /\bgl(?:pat|dt|ft|rt|ptt|soat|cbt|agent|oas|imt|ffct)-[A-Za-z0-9_.-]{20,}/g],
  ["npm-token", /\bnpm_[A-Za-z0-9]{36}\b/g],
  ["pypi-token", /\bpypi-AgEIcHlwaS5vcmc[\w-]{50,}/g],
  ["postman-key", /\bPMAK-[a-f0-9]{24}-[a-f0-9]{34}\b/gi],
  ["slack-token", /\b(?:xox[abposre]|xapp)-[A-Za-z0-9.-]{10,}/g],
  ["slack-webhook", /https:\/\/hooks\.slack\.com\/(?:services|workflows|triggers)\/[A-Za-z0-9/_+-]+/g],
  ["linear-key", /\blin_(?:api|oauth)_[A-Za-z0-9]{40}\b/g],
  ["notion-token", /\b(?:ntn_[0-9]{11}[A-Za-z0-9]{35}|secret_[A-Za-z0-9]{43})\b/g],
  ["figma-token", /\bfigd_[A-Za-z0-9_-]{40,}/g],
  ["sentry-token", /\bsntry[su]_[A-Za-z0-9+/=_]{40,}/g],
  ["shopify-token", /\bshp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}\b/g],
  ["sendgrid-key", /\bSG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\b/g],
  ["twilio-key", /\bSK[0-9a-fA-F]{32}\b/g],
  ["stripe-key", /\b[rs]k_(?:live|test|prod)_[A-Za-z0-9]{10,}/g],
  ["openai-anthropic-key", /\bsk-(?:proj-|svcacct-|admin-|ant-(?:api|admin)\d*-|or-v1-)?[A-Za-z0-9_-]{20,}/g],
  ["huggingface-token", /\b(?:hf|api_org)_[A-Za-z]{34}\b/g],
  ["groq-key", /\bgsk_[A-Za-z0-9]{40,}/g],
  ["replicate-token", /\br8_[A-Za-z0-9]{37,}/g],
  ["xai-key", /\bxai-[A-Za-z0-9]{40,}/g],
  ["perplexity-key", /\bpplx-[A-Za-z0-9]{40,}/g],
  ["tavily-key", /\btvly-(?:dev-|prod-)?[A-Za-z0-9]{32,}/g],
  ["pinecone-key", /\bpcsk_[A-Za-z0-9_]{50,}/g],
  ["langsmith-key", /\blsv2_(?:pt|sk)_[a-f0-9]{32}_[a-f0-9]{10}\b/g],
  ["jwt", /\beyJ[A-Za-z0-9_-]{6,}\.eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}/g],
];

// The secret is the `v` group; the label around it stays readable.
const LABELED = [
  ["authorization", /\b(?:Bearer|Basic|Token)\s+(?<v>[A-Za-z0-9._~+/=-]{12,})/g],
  ["url-credentials", /\b[a-z][a-z0-9+.-]*:\/\/[^\s:@/]+:(?<v>[^\s@/]+)@/gi],
  ["assignment", /\b[\w.-]{0,40}(?:password|passwd|pwd|secret|token|credential|api[_-]?key|apikey|(?<=[_-])key|access[_-]?key|private[_-]?key|client[_-]?secret|session[_-]?id|cookie)[\w.-]{0,40}["']?[ \t]*(?:=|:|=>)[ \t]*["']?(?<v>[^\s"'`,;&<>)}\]]{4,})/gi],
];

const SENSITIVE_NAME = /(token|key|secret|password|passwd|auth|session|sig|signature|credential|jwt|bearer|invite|reset|magic|otp)/i;
const URL_PATTERN = /\bhttps?:\/\/[^\s"'<>`]+/g;
const BARE_TOKEN = /(?<![A-Za-z0-9_+=-])[A-Za-z0-9_+=-]{24,}(?![A-Za-z0-9_+=-])/g;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function entropy(value) {
  const counts = new Map();
  for (const char of value) counts.set(char, (counts.get(char) || 0) + 1);
  let bits = 0;
  for (const count of counts.values()) bits -= (count / value.length) * Math.log2(count / value.length);
  return bits;
}

// Long, mixed letters and digits, and close to random: what generated credentials look like.
export function looksRandom(value) {
  if (value.length < 16 || value.includes(REDACTED) || UUID.test(value)) return false;
  if (!/[A-Za-z]/.test(value) || !/\d/.test(value)) return false;
  return entropy(value) >= (value.length < 24 ? 3.2 : 3.5);
}

const alreadyRedacted = (value) => /^(?:\[redacted|%5Bredacted)/i.test(value);

function replaceKnown(text, found) {
  let result = text;
  for (const [kind, pattern] of KNOWN) {
    result = result.replace(pattern, () => {
      found.push({ kind, by: "rule" });
      return REDACTED;
    });
  }
  for (const [kind, pattern] of LABELED) {
    result = result.replace(pattern, (match, ...args) => {
      const value = args.at(-1).v;
      if (alreadyRedacted(value)) return match;
      found.push({ kind, by: "rule" });
      return match.slice(0, match.lastIndexOf(value)) + REDACTED + match.slice(match.lastIndexOf(value) + value.length);
    });
  }
  return result;
}

// Values that might be secrets: random-looking URL path segments and query values,
// anything after a sensitive path word or parameter name, and long random tokens.
export function ambiguousSpans(text) {
  const spans = [];
  const add = (start, value, kind) => {
    if (value && !alreadyRedacted(value) && !spans.some((span) => start < span.end && start + value.length > span.start)) spans.push({ start, end: start + value.length, value, kind });
  };
  for (const match of text.matchAll(URL_PATTERN)) {
    const url = match[0];
    const pathStart = url.indexOf("/", url.indexOf("//") + 2);
    if (pathStart < 0) continue;
    let offset = match.index + pathStart;
    let previous = "";
    const [pathPart, query = ""] = url.slice(pathStart).split(/[?#]/, 2);
    for (const segment of pathPart.split("/")) {
      const decoded = segment.replace(/\.[a-z0-9]{1,5}$/i, "");
      if ((decoded.length >= 6 && SENSITIVE_NAME.test(previous)) || looksRandom(decoded)) add(offset, segment, "url-path");
      offset += segment.length + 1;
      if (segment) previous = segment;
    }
    let queryOffset = match.index + pathStart + pathPart.length + 1;
    for (const pair of query.split("&")) {
      const [name, value = ""] = pair.split("=", 2);
      if (value.length >= 4 && (SENSITIVE_NAME.test(name) || looksRandom(decodeSafe(value)))) add(queryOffset + name.length + 1, value, SENSITIVE_NAME.test(name) ? "url-parameter" : "url-value");
      queryOffset += pair.length + 1;
    }
  }
  for (const match of text.matchAll(BARE_TOKEN)) if (looksRandom(match[0])) add(match.index, match[0], "random-token");
  return spans.sort((a, b) => a.start - b.start);
}

function decodeSafe(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

// The judge's view of one value: nearby text with the value marked and other values hidden.
function judgeState(text, span) {
  const before = text.slice(Math.max(0, span.start - JUDGE.window), span.start);
  const after = text.slice(span.end, span.end + JUDGE.window);
  return `${before}⟦${span.value}⟧${after}`;
}

// Redacts one text. Known formats are always replaced; each ambiguous value is
// replaced unless a local judge answers that it is not a secret.
export async function redactText(text, session = createSession()) {
  if (typeof text !== "string" || !text) return text;
  const found = [];
  const known = replaceKnown(text, found);
  const spans = ambiguousSpans(known);
  const decisions = await Promise.all(spans.map((span) => session.decide(span.value, judgeState(known, span))));
  let result = known;
  for (let index = spans.length - 1; index >= 0; index -= 1) {
    const span = spans[index];
    const decision = decisions[index];
    if (decision.keep) {
      session.report.kept += 1;
      continue;
    }
    found.push({ kind: span.kind, by: decision.by, score: decision.score });
    result = result.slice(0, span.start) + REDACTED + result.slice(span.end);
  }
  for (const entry of found) session.record(entry);
  return result;
}

// One redaction pass shares a judge budget, a per-value cache and a report.
export function createSession(judge) {
  const started = Date.now();
  const cache = new Map();
  let asked = 0;
  let running = 0;
  const queue = [];
  const report = { total: 0, rule: 0, model: 0, fallback: 0, kept: 0, kinds: {}, judge: judge ? "local" : "none" };
  const slot = () => (running < JUDGE.concurrency ? Promise.resolve() : new Promise((resolve) => queue.push(resolve)));
  const release = () => {
    running -= 1;
    queue.shift()?.();
  };
  async function ask(state) {
    if (!judge || asked >= JUDGE.candidates || Date.now() - started > JUDGE.totalMs) return undefined;
    asked += 1;
    await slot();
    running += 1;
    try {
      return await judge(state);
    } catch {
      return undefined;
    } finally {
      release();
    }
  }
  return {
    report,
    decide(value, state) {
      if (!cache.has(value)) {
        cache.set(
          value,
          ask(state).then((score) => (score === undefined ? { keep: false, by: "fallback" } : { keep: score < JUDGE_THRESHOLD, by: "model", score })),
        );
      }
      return cache.get(value);
    },
    record(entry) {
      report.total += 1;
      report[entry.by] += 1;
      report.kinds[entry.kind] = (report.kinds[entry.kind] || 0) + 1;
    },
  };
}

// Returns a copy of the bundle with every text that leaves the Mac redacted.
// The user's own note is left as written.
export async function redactBundle(bundle, judge) {
  const session = createSession(judge);
  const clean = (value) => redactText(value, session);
  const each = (items, fields) => Promise.all(items.map(async (item) => {
    const copy = { ...item };
    for (const field of fields) if (typeof copy[field] === "string") copy[field] = await clean(copy[field]);
    return copy;
  }));
  const safe = {
    ...bundle,
    media: await each(bundle.media, ["text", "title"]),
    browser: bundle.browser ? (await each([bundle.browser], ["url", "title"]))[0] : undefined,
    console: await each(bundle.console, ["message"]),
    network: await each(bundle.network, ["url", "error"]),
    events: await each(bundle.events, ["url", "name", "title", "text", "selector"]),
    customLogs: await each(bundle.customLogs, ["text"]),
  };
  safe.redaction = session.report;
  return safe;
}

export function redactionSummary(report) {
  if (!report?.total) return "";
  const parts = [report.rule ? `${report.rule} by known format` : "", report.model ? `${report.model} confirmed by the local model` : "", report.fallback ? `${report.fallback} unconfirmed (no local model answer)` : ""].filter(Boolean);
  return `${report.total} value${report.total === 1 ? "" : "s"} that looked like secrets ${report.total === 1 ? "was" : "were"} replaced with ${REDACTED} (${parts.join(", ")}).`;
}

const LOCAL_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]", "::1"]);

// Only an endpoint on this Mac may judge values; a hosted model would receive the secrets.
export function localJudgeURL(raw) {
  if (typeof raw !== "string" || !raw.trim()) return undefined;
  let url;
  try {
    url = new URL(raw.trim());
  } catch {
    return undefined;
  }
  if (url.protocol !== "http:" || !LOCAL_HOSTS.has(url.hostname) || url.username || url.password) return undefined;
  return new URL(url.pathname.replace(/\/+$/, "").endsWith("/v1/systemone") ? url.pathname : url.pathname.replace(/\/+$/, "") + "/v1/systemone", url.origin).href;
}

// A Jev-compatible decision endpoint (laya-serve, Unsloth, a local Clef) answering one yes/no question.
export function decisionJudge(raw, { fetch = globalThis.fetch, model } = {}) {
  const endpoint = localJudgeURL(raw);
  if (!endpoint) return undefined;
  return async (state) => {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...(model ? { model } : {}), state: { text: state }, questions: { secret: { type: "noul", instructions: QUESTION } } }),
      signal: AbortSignal.timeout(JUDGE.requestMs),
      redirect: "error",
    });
    if (!response.ok) return undefined;
    const answer = (await response.json())?.answers?.secret;
    const score = typeof answer === "number" ? answer : answer?.noul ?? answer?.probability ?? answer?.yes;
    return Number.isFinite(score) && score >= 0 && score <= 1 ? score : undefined;
  };
}

// The judge the user chose in Capture Studio's menu, if any.
export async function configuredJudge(captures, options = {}) {
  try {
    const settings = JSON.parse(await readFile(path.join(captures, "settings.json"), "utf8"));
    return decisionJudge(settings?.redaction?.judge, { ...options, model: typeof settings?.redaction?.model === "string" ? settings.redaction.model : undefined });
  } catch {
    return undefined;
  }
}
