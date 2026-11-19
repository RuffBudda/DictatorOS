// Credential redaction. Everything the agent receives (screenshots and text) passes through here.
//
// Layers:
//  1. Sensitive windows/layers (password managers, keyring/polkit/pinentry prompts, lock screens):
//     blacked out entirely; input to them is refused elsewhere.
//  2. Password fields exposed over AT-SPI: blacked out.
//  3. OCR (tesseract): text that looks like a credential is blacked out.
//  4. Text outputs (clipboard, window titles) are scrubbed with the same patterns.
//
// Fail-closed: if OCR fails the caller must not return the image.
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { PNG } from "pngjs";

const A11Y_HELPER = fileURLToPath(new URL("./a11y_secrets.py", import.meta.url));

// ---------------------------------------------------------------- patterns

// Known credential formats. Kept loose enough to survive small OCR errors.
export const SECRET_PATTERNS = [
  ["private key block", /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ["anthropic key", /\bsk-ant-[A-Za-z0-9_\-]{10,}/],
  ["openai-style key", /\bsk-(?:proj-|live-|test-)?[A-Za-z0-9_\-]{16,}/],
  ["stripe key", /\b[rsp]k_(?:live|test)_[A-Za-z0-9]{10,}/],
  ["github token", /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/],
  ["gitlab token", /\bglpat-[A-Za-z0-9_\-]{16,}/],
  ["slack token", /\bxox[abposr]-[A-Za-z0-9\-]{10,}/],
  ["aws access key", /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/],
  ["google api key", /\bAIza[0-9A-Za-z_\-]{30,}/],
  ["jwt", /\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}/],
  ["npm token", /\bnpm_[A-Za-z0-9]{30,}/],
  ["hf token", /\bhf_[A-Za-z0-9]{30,}/],
  ["url credentials", /\b[a-z][a-z0-9+.\-]*:\/\/[^\s:@/]+:[^\s@/]+@/i],
  ["secret url param", /[?&#](?:access_token|refresh_token|id_token|token|code|key|api_key|apikey|secret|client_secret|password|passwd|pwd|sig|signature|auth)=[^&\s#]{6,}/i],
];

// "password: hunter2", "API_KEY=abc", "Authorization: Bearer x" → the value after the separator.
const LABEL_RE = /\b(?:[A-Za-z0-9_]*(?:pass(?:word|wd|phrase|code)?|pwd|secret|token|api[_\- ]?key|apikey|access[_\- ]?key|private[_\- ]?key|client[_\- ]?secret|credentials?|auth(?:orization)?|bearer|cookie|session(?:[_\- ]?id)?|otp|pin(?:code)?)[A-Za-z0-9_]*)\s*(?:[:=]|=>|\bis\b)\s*["']?(\S.*)$/i;

const ENTROPY_RE = /^[A-Za-z0-9_\-+/=]{24,}$/;

function looksRandom(word) {
  if (!ENTROPY_RE.test(word)) return false;
  if ((word.match(/\//g) || []).length > 2) return false; // paths
  const classes = [/[a-z]/, /[A-Z]/, /[0-9]/].filter((r) => r.test(word)).length;
  if (classes < 2 || !/[0-9]/.test(word)) return false;
  // Shannon entropy per char
  const freq = {};
  for (const ch of word) freq[ch] = (freq[ch] || 0) + 1;
  let h = 0;
  for (const n of Object.values(freq)) { const p = n / word.length; h -= p * Math.log2(p); }
  return h >= 3.5;
}

/** Character spans in a line of text that should be hidden. */
export function secretSpans(line) {
  const spans = [];
  for (const [, re] of SECRET_PATTERNS) {
    const g = new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
    for (const m of line.matchAll(g)) spans.push([m.index, m.index + m[0].length]);
  }
  const lm = LABEL_RE.exec(line);
  if (lm && lm[1].trim() && !/^(?:\*+|•+|●+|\.{3,}|none|null|true|false|required|optional|\[redacted\])$/i.test(lm[1].trim())) {
    const start = lm.index + lm[0].length - lm[1].length;
    spans.push([start, line.length]);
  }
  for (const m of line.matchAll(/\S+/g)) {
    const w = m[0].replace(/^["'(<\[]+|["')>\],;.]+$/g, "");
    if (looksRandom(w)) spans.push([m.index, m.index + m[0].length]);
  }
  return spans;
}

/** Scrub credentials from text the agent will receive. */
export function scrubText(text) {
  return String(text).split("\n").map((line) => {
    const spans = secretSpans(line).sort((a, b) => a[0] - b[0]);
    if (!spans.length) return line;
    let out = "", pos = 0;
    for (const [s, e] of spans) {
      if (e <= pos) continue;
      out += line.slice(pos, Math.max(pos, s)) + "[REDACTED]";
      pos = Math.max(pos, e);
    }
    return out + line.slice(pos);
  }).join("\n");
}

// ---------------------------------------------------------------- sensitive apps

export const SENSITIVE_CLASS = /1password|bitwarden|keepass|kwallet|seahorse|gcr-prompter|pinentry|polkit|gnome-keyring|enpass|lastpass|proton.?pass|authenticator|yubico|ente.?auth|secrets|passwordsafe|gopass|nm-openconnect-auth/i;
export const SENSITIVE_TITLE = /\b(password|passphrase|keyring|unlock|authentication required|pinentry|2fa|two-factor|one-time code|recovery code|seed phrase|private key)\b/i;
export const SENSITIVE_LAYER = /polkit|pinentry|keyring|lock|password|passphrase/i;

export function isSensitiveWindow(w) {
  return SENSITIVE_CLASS.test(w.class || "") || SENSITIVE_TITLE.test(w.title || "");
}

// ---------------------------------------------------------------- processes

function runWithInput(cmd, args, input, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, OMP_THREAD_LIMIT: "2" } });
    const out = [], err = [];
    const timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error(`${cmd} timed out`)); }, timeoutMs);
    child.stdout.on("data", (d) => out.push(d));
    child.stderr.on("data", (d) => err.push(d));
    child.on("error", (e) => { clearTimeout(timer); reject(e); });
    child.on("close", (code) => {
      clearTimeout(timer);
      code === 0 ? resolve(Buffer.concat(out).toString("utf8")) : reject(new Error(`${cmd} exited ${code}: ${Buffer.concat(err).toString().slice(0, 300)}`));
    });
    if (input) child.stdin.end(input); else child.stdin.end();
  });
}

/** Password fields reported over AT-SPI (best effort; [] if unavailable). */
export async function a11yPasswordFields() {
  try {
    return JSON.parse(await runWithInput("python3", ["-I", A11Y_HELPER], null, 2500));
  } catch {
    return [];
  }
}

/**
 * Crop a region from decoded RGBA, convert to grayscale, upscale (bilinear) and invert if the region is
 * mostly dark. Small UI/terminal text is unreadable to tesseract at 1x and dark themes hurt accuracy.
 */
export function prepareForOcr(img, region, scale = 2) {
  const rx = Math.max(0, Math.floor(region.x)), ry = Math.max(0, Math.floor(region.y));
  const rw = Math.min(img.width - rx, Math.ceil(region.width)), rh = Math.min(img.height - ry, Math.ceil(region.height));
  if (rw <= 0 || rh <= 0) return null;
  const gray = new Float32Array(rw * rh);
  let sum = 0;
  for (let y = 0; y < rh; y++) {
    for (let x = 0; x < rw; x++) {
      const i = ((ry + y) * img.width + rx + x) * 4;
      const v = 0.299 * img.data[i] + 0.587 * img.data[i + 1] + 0.114 * img.data[i + 2];
      gray[y * rw + x] = v; sum += v;
    }
  }
  const invert = sum / (rw * rh) < 128;
  const W = rw * scale, H = rh * scale;
  const out = new PNG({ width: W, height: H });
  for (let y = 0; y < H; y++) {
    const fy = Math.min(rh - 1, Math.max(0, (y + 0.5) / scale - 0.5));
    const y0 = Math.floor(fy), y1 = Math.min(rh - 1, y0 + 1), ay = fy - y0;
    for (let x = 0; x < W; x++) {
      const fx = Math.min(rw - 1, Math.max(0, (x + 0.5) / scale - 0.5));
      const x0 = Math.floor(fx), x1 = Math.min(rw - 1, x0 + 1), ax = fx - x0;
      let v = (gray[y0 * rw + x0] * (1 - ax) + gray[y0 * rw + x1] * ax) * (1 - ay) +
              (gray[y1 * rw + x0] * (1 - ax) + gray[y1 * rw + x1] * ax) * ay;
      if (invert) v = 255 - v;
      const o = (y * W + x) * 4;
      out.data[o] = out.data[o + 1] = out.data[o + 2] = v; out.data[o + 3] = 255;
    }
  }
  return { png: PNG.sync.write(out), ox: rx, oy: ry, scale };
}

/**
 * OCR the image region by region (each window separately, so dark and light windows each get the right
 * treatment, in parallel) and return boxes in image pixel coords of text that looks like a credential.
 * Throws if OCR fails, so the caller withholds the image.
 */
export async function ocrSecretBoxes(png, regions) {
  const img = PNG.sync.read(png);
  const all = [{ x: 0, y: 0, width: img.width, height: img.height }, ...(regions ?? [])];
  const jobs = all.map(async (r) => {
    // The whole-image pass is a safety net for bars/panels; windows get the 2x treatment.
    const prep = prepareForOcr(img, r, r === all[0] && all.length > 1 ? 1 : 2);
    if (!prep) return [];
    const tsv = await runWithInput("tesseract", ["stdin", "stdout", "--psm", "11", "tsv"], prep.png, 20000);
    return secretBoxesFromTsv(tsv).map((b) => ({
      x: prep.ox + b.x / prep.scale, y: prep.oy + b.y / prep.scale, width: b.width / prep.scale, height: b.height / prep.scale,
    }));
  });
  return (await Promise.all(jobs)).flat();
}

/** Pure: tesseract TSV → boxes to hide. */
export function secretBoxesFromTsv(tsv) {
  const lines = new Map();
  for (const row of tsv.split("\n").slice(1)) {
    const c = row.split("\t");
    if (c.length < 12 || c[0] !== "5") continue; // level 5 = word
    const text = c[11];
    if (!text || !text.trim()) continue;
    const key = `${c[2]}-${c[3]}-${c[4]}`; // block-par-line
    const word = { text, left: +c[6], top: +c[7], width: +c[8], height: +c[9] };
    if (!lines.has(key)) lines.set(key, []);
    lines.get(key).push(word);
  }
  const boxes = [];
  for (const words of lines.values()) {
    words.sort((a, b) => a.left - b.left);
    let lineText = "";
    const offs = [];
    for (const w of words) {
      if (lineText) lineText += " ";
      offs.push([lineText.length, lineText.length + w.text.length, w]);
      lineText += w.text;
    }
    for (const [s, e] of secretSpans(lineText)) {
      for (const [ws, we, w] of offs) {
        if (we > s && ws < e) boxes.push({ x: w.left, y: w.top, width: w.width, height: w.height });
      }
    }
  }
  return boxes;
}

// ---------------------------------------------------------------- image ops

/** Black out boxes (image pixel coords) in a PNG, padding each a little. Returns a new PNG buffer. */
export function blackout(pngBuf, boxes, pad = 4) {
  const img = PNG.sync.read(pngBuf);
  for (const b of boxes) {
    const x0 = Math.max(0, Math.floor(b.x - pad)), y0 = Math.max(0, Math.floor(b.y - pad));
    const x1 = Math.min(img.width, Math.ceil(b.x + b.width + pad)), y1 = Math.min(img.height, Math.ceil(b.y + b.height + pad));
    for (let y = y0; y < y1; y++) {
      for (let x = x0; x < x1; x++) {
        const i = (y * img.width + x) * 4;
        // dark gray with a diagonal hatch so redactions are recognizable as deliberate
        const hatch = ((x + y) % 12) < 2;
        img.data[i] = hatch ? 70 : 24; img.data[i + 1] = hatch ? 70 : 24; img.data[i + 2] = hatch ? 70 : 24; img.data[i + 3] = 255;
      }
    }
  }
  return PNG.sync.write(img);
}

/** Area-average downscale of a PNG to width x height. */
export function downscale(pngBuf, width, height) {
  const src = PNG.sync.read(pngBuf);
  if (width >= src.width && height >= src.height) return pngBuf;
  const dst = new PNG({ width, height });
  const sx = src.width / width, sy = src.height / height;
  for (let y = 0; y < height; y++) {
    const y0 = Math.floor(y * sy), y1 = Math.max(y0 + 1, Math.floor((y + 1) * sy));
    for (let x = 0; x < width; x++) {
      const x0 = Math.floor(x * sx), x1 = Math.max(x0 + 1, Math.floor((x + 1) * sx));
      let r = 0, g = 0, b = 0, a = 0, n = 0;
      for (let yy = y0; yy < y1; yy++) {
        let i = (yy * src.width + x0) * 4;
        for (let xx = x0; xx < x1; xx++, i += 4) { r += src.data[i]; g += src.data[i + 1]; b += src.data[i + 2]; a += src.data[i + 3]; n++; }
      }
      const o = (y * width + x) * 4;
      dst.data[o] = r / n; dst.data[o + 1] = g / n; dst.data[o + 2] = b / n; dst.data[o + 3] = a / n;
    }
  }
  return PNG.sync.write(dst);
}

/**
 * Full pipeline for one capture.
 * @param {Buffer} png        full-resolution capture of `rect`
 * @param {object} rect       captured region in desktop coordinates {x,y,width,height}
 * @param {Array}  windows    desktop windows [{x,y,width,height,class,title,pid?}] in desktop coordinates
 * @param {Array}  layers     sensitive layer-surface rects in desktop coordinates (host only)
 * @param {(f:object)=>Array} mapField  maps an a11y field to desktop-coordinate rects
 */
export async function redactCapture(png, rect, { windows = [], layers = [], mapField = () => [] } = {}) {
  const { width: iw, height: ih } = PNG.sync.read(png, { skipRescale: true });
  const kx = iw / rect.width, ky = ih / rect.height;
  const toImg = (r) => ({ x: (r.x - rect.x) * kx, y: (r.y - rect.y) * ky, width: r.width * kx, height: r.height * ky });
  const reasons = { sensitive_windows: 0, password_fields: 0, ocr_text: 0 };
  const boxes = [];

  for (const w of windows) if (isSensitiveWindow(w)) { boxes.push(toImg(w)); reasons.sensitive_windows++; }
  for (const l of layers) { boxes.push(toImg(l)); reasons.sensitive_windows++; }
  for (const f of await a11yPasswordFields()) {
    for (const r of mapField(f)) { boxes.push(toImg(r)); reasons.password_fields++; }
  }
  const regions = windows.filter((w) => !isSensitiveWindow(w)).map(toImg)
    .map((r) => ({ x: Math.max(0, r.x), y: Math.max(0, r.y), width: Math.min(iw, r.x + r.width) - Math.max(0, r.x), height: Math.min(ih, r.y + r.height) - Math.max(0, r.y) }))
    .filter((r) => r.width > 8 && r.height > 8);
  const ocr = await ocrSecretBoxes(png, regions); // throws → caller withholds the image
  boxes.push(...ocr);
  reasons.ocr_text = ocr.length;

  return { png: boxes.length ? blackout(png, boxes) : png, reasons, total: boxes.length };
}
