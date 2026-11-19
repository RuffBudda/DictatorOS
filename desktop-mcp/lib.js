// Pure helpers: no I/O, unit-tested in test/unit.mjs.

const MODIFIERS = {
  ctrl: "ctrl", control: "ctrl",
  shift: "shift",
  alt: "alt", option: "alt", opt: "alt",
  super: "logo", win: "logo", meta: "logo", cmd: "logo", command: "logo", logo: "logo",
};

const KEY_ALIASES = {
  enter: "Return", return: "Return",
  esc: "Escape", escape: "Escape",
  tab: "Tab",
  backspace: "BackSpace",
  delete: "Delete", del: "Delete",
  space: "space",
  up: "Up", down: "Down", left: "Left", right: "Right",
  pageup: "Prior", pagedown: "Next",
  home: "Home", end: "End",
  insert: "Insert",
};

/** Parse "ctrl+shift+t" → { modifiers: ["ctrl","shift"], key: "t" }. */
export function parseKeyCombo(combo) {
  if (typeof combo !== "string" || combo.trim() === "") throw new Error("empty key combo");
  // Allow a literal "+" as the key, e.g. "ctrl++".
  let parts = combo.split("+");
  if (combo.endsWith("++")) parts = [...combo.slice(0, -2).split("+"), "plus"];
  parts = parts.map((p) => p.trim()).filter((p) => p !== "");
  if (parts.length === 0) throw new Error(`invalid key combo: ${combo}`);
  const rawKey = parts.pop();
  const modifiers = parts.map((m) => {
    const mapped = MODIFIERS[m.toLowerCase()];
    if (!mapped) throw new Error(`unknown modifier "${m}" in "${combo}" (use ctrl, shift, alt, super)`);
    return mapped;
  });
  const key = KEY_ALIASES[rawKey.toLowerCase()] ?? rawKey;
  return { modifiers, key };
}

/** wtype argv for a parsed combo. */
export function wtypeArgs({ modifiers, key }) {
  const args = [];
  for (const m of modifiers) args.push("-M", m);
  args.push("-k", key);
  for (const m of [...modifiers].reverse()) args.push("-m", m);
  return args;
}

/** Restrict a string to characters safe in unit names, file names and sway configs. */
export function safeName(s) {
  const out = String(s ?? "").replace(/[^A-Za-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 32);
  return out || "agent";
}

const PALETTE = ["#d97757", "#10a37f", "#3b82f6", "#a855f7", "#ec4899", "#f59e0b", "#14b8a6", "#ef4444"];

/** Stable-ish distinct color per agent session. */
export function agentColor(seed) {
  let h = 0;
  for (const ch of String(seed)) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return PALETTE[h % PALETTE.length];
}

/** Flatten a sway get_tree result into window records (address = con_id as a string). */
export function swayWindows(tree) {
  const out = [];
  const walk = (n, ws) => {
    if (n.type === "workspace") ws = n.name;
    const isWindow = (n.type === "con" || n.type === "floating_con") && (n.app_id != null || n.window_properties) && n.nodes.length === 0;
    if (isWindow) {
      out.push({
        address: String(n.id), class: n.app_id ?? n.window_properties?.class ?? "", title: n.name ?? "", pid: n.pid,
        workspace: ws, x: n.rect.x, y: n.rect.y, width: n.rect.width, height: n.rect.height,
        focused: n.focused, floating: n.type === "floating_con", fullscreen: n.fullscreen_mode > 0,
      });
    }
    for (const c of [...(n.nodes ?? []), ...(n.floating_nodes ?? [])]) walk(c, ws);
  };
  walk(tree, undefined);
  return out.filter((w) => w.workspace !== "__i3_scratch");
}

/** Encode any JS string as a safe Lua string literal (bytes outside printable ASCII → \ddd). */
export function luaStr(s) {
  let out = '"';
  for (const b of Buffer.from(String(s), "utf8")) {
    const printable = b >= 0x20 && b < 0x7f && b !== 0x22 && b !== 0x5c;
    out += printable ? String.fromCharCode(b) : "\\" + String(b).padStart(3, "0");
  }
  return out + '"';
}

/** Read width/height from a PNG buffer's IHDR chunk. */
export function pngSize(buf) {
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (!buf || buf.length < 24 || !sig.every((b, i) => buf[i] === b)) throw new Error("not a PNG");
  if (buf.toString("ascii", 12, 16) !== "IHDR") throw new Error("PNG missing IHDR");
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

/** Logical (layout) geometry of a hyprctl monitor object. */
export function monitorLogical(m) {
  let w = Math.round(m.width / m.scale);
  let h = Math.round(m.height / m.scale);
  if (m.transform % 2 === 1) [w, h] = [h, w];
  return { x: m.x, y: m.y, width: w, height: h };
}

/** Bounding box of a list of {x,y,width,height}. */
export function boundingBox(rects) {
  const x = Math.min(...rects.map((r) => r.x));
  const y = Math.min(...rects.map((r) => r.y));
  const x2 = Math.max(...rects.map((r) => r.x + r.width));
  const y2 = Math.max(...rects.map((r) => r.y + r.height));
  return { x, y, width: x2 - x, height: y2 - y };
}

/** grim scale so that the longest edge fits max_edge (never upscale). */
export function captureScale(width, height, maxEdge) {
  return Math.min(1, maxEdge / Math.max(width, height));
}

/** Build the image→screen transform from the captured region and the real PNG size. */
export function makeTransform(region, img) {
  return {
    ox: region.x, oy: region.y,
    kx: region.width / img.width, ky: region.height / img.height,
    imgW: img.width, imgH: img.height,
  };
}

/** Map image pixel coords to global logical coords. Throws if out of bounds. */
export function imageToScreen(t, ix, iy) {
  if (!t) throw new Error("No screenshot taken yet: call screenshot first, or pass coordinate_space: \"screen\".");
  if (ix < 0 || iy < 0 || ix >= t.imgW || iy >= t.imgH) {
    throw new Error(`Point (${ix}, ${iy}) is outside the last screenshot (${t.imgW}x${t.imgH}).`);
  }
  return { x: Math.round(t.ox + ix * t.kx), y: Math.round(t.oy + iy * t.ky) };
}

/** Map global logical coords back into the last screenshot's image space (may be out of frame). */
export function screenToImage(t, gx, gy) {
  const x = Math.round((gx - t.ox) / t.kx);
  const y = Math.round((gy - t.oy) / t.ky);
  return { x, y, in_frame: x >= 0 && y >= 0 && x < t.imgW && y < t.imgH };
}
