// Desktop backends.
//  HostDesktop    – your real Hyprland session. Pointer actions borrow the real pointer and give it back.
//  SandboxDesktop – a nested sway session in a window, with its own pointer, keyboard focus and clipboard.
import { mkdirSync, writeFileSync, readFileSync, existsSync, openSync, closeSync, unlinkSync, statSync, rmSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { run, writeStdin, runUnit, stopUnit, unitActive } from "./proc.js";
import { Overlay } from "./overlay.js";
import { luaStr, monitorLogical, parseKeyCombo, wtypeArgs, swayWindows, safeName } from "./lib.js";
import { SENSITIVE_LAYER } from "./redact/index.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const OVERLAY_DIR = fileURLToPath(new URL("./overlay", import.meta.url));
const GLIDE_MS = 280; // overlay cursor animation time; actions wait for it so you can see where they land

export function runtimeDir() {
  const d = join(process.env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`, "desktop-mcp");
  mkdirSync(d, { recursive: true });
  return d;
}

// ---------------------------------------------------------------- host

// Cross-process lock so several agents never fight over the one real pointer.
async function withHostPointerLock(fn) {
  const path = join(runtimeDir(), "host-pointer.lock");
  const deadline = Date.now() + 15_000;
  for (;;) {
    try {
      const fd = openSync(path, "wx");
      writeFileSync(fd, String(process.pid));
      closeSync(fd);
      break;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      let stale = false;
      try {
        const pid = Number(readFileSync(path, "utf8"));
        try { process.kill(pid, 0); } catch { stale = true; }
        if (Date.now() - statSync(path).mtimeMs > 10_000) stale = true;
      } catch { stale = true; }
      if (stale) { try { unlinkSync(path); } catch { /* raced */ } continue; }
      if (Date.now() > deadline) throw new Error("Timed out waiting for another agent to finish using the pointer.");
      await sleep(25);
    }
  }
  try { return await fn(); } finally { try { unlinkSync(path); } catch { /* ignore */ } }
}

export class HostDesktop {
  constructor(agent) {
    this.kind = "host";
    this.agent = agent; // {id, label, color}
    this.display = process.env.WAYLAND_DISPLAY;
    this.overlay = new Overlay({
      socket: join(runtimeDir(), `overlay-host-${this.display}.sock`),
      display: this.display,
      unit: `desktop-mcp-overlay-host-${safeName(this.display)}`,
      env: {
        HYPRLAND_INSTANCE_SIGNATURE: process.env.HYPRLAND_INSTANCE_SIGNATURE ?? "",
        DMCP_ROLE: "host",
        DMCP_CTL: fileURLToPath(new URL("./bin/desktop-mcp-ctl", import.meta.url)),
      },
    });
    this.legacyDispatch = null;
  }

  async hyprJson(what) { return JSON.parse(await run("hyprctl", ["-j", what])); }

  // Hyprland >= 0.56 takes Lua for `hyprctl dispatch`; older versions take "dispatcher args".
  async dispatch(lua, legacy) {
    const once = async (args) => {
      const out = (await run("hyprctl", ["dispatch", ...args])).trim();
      if (out !== "ok") throw new Error(`hyprctl dispatch ${args.join(" ")}: ${out}`);
    };
    if (this.legacyDispatch !== true) {
      try { await once([lua]); this.legacyDispatch = false; return; } catch (e) {
        if (this.legacyDispatch === false || !/invalid dispatcher|unknown dispatcher/i.test(e.message)) throw e;
        this.legacyDispatch = true;
      }
    }
    await once(legacy.map(String));
  }

  /** Keep sandbox windows rendering on hidden workspaces (re-applied: config reloads drop runtime rules). */
  async ensureSandboxRule() {
    await run("hyprctl", ["eval", 'hl.window_rule({ name = "desktop-mcp-sandbox", enabled = true, match = { class = "^wlroots$" }, render_unfocused = true, float = false, no_initial_focus = true })']).catch(() => {});
    await run("hyprctl", ["eval", "hl.exec_scheduled_prop_refresh_immediately()"]).catch(() => {});
  }

  moveCursor(p) { return this.dispatch(`hl.dsp.cursor.move({ x = ${Math.round(p.x)}, y = ${Math.round(p.y)} })`, ["movecursor", p.x, p.y]); }
  focusAddress(a) { return this.dispatch(`hl.dsp.focus({ window = ${luaStr("address:" + a)} })`, ["focuswindow", `address:${a}`]); }

  async monitors() {
    return (await this.hyprJson("monitors")).map((m) => ({
      name: m.name, focused: m.focused, ...monitorLogical(m), scale: m.scale, active_workspace: m.activeWorkspace?.name,
    }));
  }

  async capture(rect) {
    await this.overlay.send({ op: "suspend" });
    await sleep(60);
    try {
      return await run("grim", ["-g", `${rect.x},${rect.y} ${rect.width}x${rect.height}`, "-s", "1", "-t", "png", "-"], { encoding: "buffer" });
    } finally {
      await this.overlay.send({ op: "resume" });
    }
  }

  async cursorPos() { return this.hyprJson("cursorpos"); }

  async ghost(op, p) {
    await this.overlay.send({ op, id: this.agent.id, x: p.x, y: p.y, label: this.agent.label, color: this.agent.color });
  }

  /** Fade this agent's cursor out; the next pointer action shows it again. */
  hideGhost() { this.overlay.sendIfConnected({ op: "hide", id: this.agent.id }); }


  /** Borrow the real pointer: glide the ghost there, run `act`, then put the user's pointer back. */
  async borrow(p, act, { restore = true } = {}) {
    await this.ghost("move", p);
    await sleep(GLIDE_MS);
    return withHostPointerLock(async () => {
      const orig = await this.cursorPos();
      await this.moveCursor(p);
      await sleep(30);
      const result = await act();
      await sleep(40);
      let restored = false;
      if (restore) {
        const now = await this.cursorPos();
        // If the user grabbed the mouse meanwhile, leave it where they put it.
        if (Math.abs(now.x - p.x) <= 2 && Math.abs(now.y - p.y) <= 2 && (orig.x !== p.x || orig.y !== p.y)) {
          // A pointer warp does not trigger focus-follows-mouse, so focus stays on what the agent clicked.
          await this.moveCursor(orig);
          restored = true;
        }
      }
      return { ...result, pointer_restored: restored };
    });
  }

  async click(p, button, double) {
    const code = { left: "0xC0", right: "0xC1", middle: "0xC2" }[button];
    return this.borrow(p, async () => {
      await run("ydotool", double ? ["click", "--repeat", "2", "--next-delay", "80", code] : ["click", code]);
      await this.ghost("click", p);
      return {};
    });
  }

  async move(p) {
    // An explicit move is a request to leave the pointer there (e.g. to hover), so no restore.
    await this.ghost("move", p);
    await sleep(GLIDE_MS);
    await withHostPointerLock(() => this.moveCursor(p));
    return { pointer_restored: false };
  }

  async drag(a, b) {
    return this.borrow(a, async () => {
      await run("ydotool", ["click", "0x40"]);
      try {
        for (let i = 1; i <= 12; i++) {
          await sleep(15);
          const q = { x: Math.round(a.x + ((b.x - a.x) * i) / 12), y: Math.round(a.y + ((b.y - a.y) * i) / 12) };
          await this.moveCursor(q);
          if (i % 3 === 0) this.ghost("move", q);
        }
        await sleep(30);
      } finally {
        await run("ydotool", ["click", "0x80"]);
      }
      // borrow() checks the pointer is still where *it* put it; report the drag end there.
      await this.moveCursor(a);
      return {};
    });
  }

  async scroll(p, direction, amount) {
    const dx = direction === "left" ? -amount : direction === "right" ? amount : 0;
    const dy = direction === "up" ? amount : direction === "down" ? -amount : 0;
    const act = async () => { await run("ydotool", ["mousemove", "--wheel", "-x", String(dx), "-y", String(dy)]); return {}; };
    if (p) return this.borrow(p, act);
    await withHostPointerLock(act);
    return { pointer_restored: false };
  }

  async typeText(text, delayMs) { await run("wtype", delayMs ? ["-d", String(delayMs), "--", text] : ["--", text]); }
  async key(combo) { await run("wtype", wtypeArgs(parseKeyCombo(combo))); }

  async windows() {
    const [clients, active] = await Promise.all([this.hyprJson("clients"), this.hyprJson("activewindow").catch(() => ({}))]);
    const mons = await this.hyprJson("monitors").catch(() => []);
    const visibleWs = new Set(mons.flatMap((m) => [m.activeWorkspace?.id, m.specialWorkspace?.id]).filter((x) => x));
    return clients.filter((c) => c.mapped && !c.hidden).map((c) => ({
      address: c.address, class: c.class, title: c.title, workspace: c.workspace?.name, pid: c.pid,
      visible: visibleWs.has(c.workspace?.id),
      x: c.at[0], y: c.at[1], width: c.size[0], height: c.size[1],
      focused: c.address === active?.address, floating: c.floating, fullscreen: Boolean(c.fullscreen),
    }));
  }

  /** Hyprland warps the pointer to a window when it gets focus; put the user's pointer back afterwards. */
  async keepPointer(fn) {
    return withHostPointerLock(async () => {
      const orig = await this.cursorPos();
      try { return await fn(); } finally {
        await sleep(30);
        const now = await this.cursorPos();
        if (now.x !== orig.x || now.y !== orig.y) await this.moveCursor(orig).catch(() => {});
      }
    });
  }

  /** Layer surfaces (polkit prompts, lock screens...) that must never be shown or typed into. */
  async sensitiveLayers() {
    const data = await this.hyprJson("layers").catch(() => ({}));
    const out = [];
    for (const mon of Object.values(data)) {
      for (const list of Object.values(mon.levels ?? {})) {
        for (const l of list) if (SENSITIVE_LAYER.test(l.namespace ?? "")) out.push({ x: l.x, y: l.y, width: l.w, height: l.h, namespace: l.namespace });
      }
    }
    return out;
  }

  async focus(w) { await this.keepPointer(() => this.focusAddress(w.address)); }
  async close(w) { await this.keepPointer(() => this.dispatch(`hl.dsp.window.close({ window = ${luaStr("address:" + w.address)} })`, ["closewindow", `address:${w.address}`])); }
  async launch(cmd) { await this.dispatch(`hl.dsp.exec_cmd(${luaStr(cmd)})`, ["exec", cmd]); }
  async workspace(ws) { await this.keepPointer(() => this.dispatch(`hl.dsp.focus({ workspace = ${luaStr(ws)} })`, ["workspace", ws])); }

  async clipboardRead() {
    try { return await run("wl-paste", ["--no-newline"]); } catch (e) {
      if (/nothing is copied|no suitable type/i.test(e.message)) return "";
      throw e;
    }
  }
  async clipboardWrite(t) { await writeStdin("wl-copy", [], t); }
  async clipboardTypes() { return (await run("wl-paste", ["--list-types"])).split("\n").filter(Boolean); }

  async dispose() {
    await this.overlay.send({ op: "remove", id: this.agent.id });
    this.overlay.close();
  }
}

// ---------------------------------------------------------------- sandbox

export class SandboxDesktop {
  constructor(agent, host) {
    this.kind = "sandbox";
    this.agent = agent;
    this.host = host;
    this.id = `${safeName(agent.label).toLowerCase()}-${process.pid}`;
    this.unit = `desktop-mcp-sb-${this.id}`;
    this.slice = `desktop-mcp-sb-${this.id}.slice`;
    this.appSeq = 0;
    this.dir = join(runtimeDir(), `sb-${this.id}`);
    this.swaysock = join(this.dir, "ipc.sock");
    this.display = null;
    this.hostWindow = null;
    this.pos = { x: 1, y: 1 };
    this.overlay = new Overlay({ socket: join(this.dir, "overlay.sock"), display: "" });
  }

  get env() { return { WAYLAND_DISPLAY: this.display, SWAYSOCK: this.swaysock }; }

  async running() { return this.display !== null && (await unitActive(this.unit)); }

  async start({ workspace } = {}) {
    if (await this.running()) return this.status();
    rmSync(this.dir, { recursive: true, force: true });
    mkdirSync(this.dir, { recursive: true });
    const displayFile = join(this.dir, "display");
    const overlaySock = join(this.dir, "overlay.sock");
    // Paths come from XDG_RUNTIME_DIR + our own sanitized id; reject anything odd before it reaches a config file.
    if (!/^[\w./-]+$/.test(this.dir) || !/^[\w./-]+$/.test(OVERLAY_DIR)) throw new Error(`unsafe path: ${this.dir}`);
    writeFileSync(join(this.dir, "sway.conf"), [
      "default_border pixel 2",
      "focus_follows_mouse no",
      "mouse_warping none",
      `exec sh -c 'printf %s "$WAYLAND_DISPLAY" > ${displayFile}'`,
      `exec env DMCP_SOCKET=${overlaySock} qs -p ${OVERLAY_DIR}`,
      "",
    ].join("\n"));

    const hostBefore = await this.host.hyprJson("activewindow").catch(() => ({}));
    await this.host.ensureSandboxRule();
    await runUnit(this.unit, ["sway", "-c", join(this.dir, "sway.conf")], {
      WAYLAND_DISPLAY: this.host.display, SWAYSOCK: this.swaysock,
    }, { slice: this.slice });
    for (let i = 0; i < 100 && !existsSync(displayFile); i++) await sleep(50);
    if (!existsSync(displayFile)) {
      const log = await run("journalctl", ["--user", "-u", this.unit, "-n", "20", "--no-pager"]).catch(() => "");
      await stopUnit(this.unit);
      throw new Error(`sandbox failed to start:\n${log}`);
    }
    this.display = readFileSync(displayFile, "utf8").trim();

    // Find our window on the host by the sway PID.
    const pid = Number((await run("systemctl", ["--user", "show", "-p", "MainPID", "--value", this.unit])).trim());
    for (let i = 0; i < 60 && !this.hostWindow; i++) {
      const c = (await this.host.hyprJson("clients")).find((x) => x.pid === pid);
      if (c) this.hostWindow = c.address; else await sleep(50);
    }
    if (this.hostWindow) await this.host.keepPointer(async () => {
      const win = luaStr("address:" + this.hostWindow);
      // Agent desktops are ordinary tiled windows, never floating overlays.
      const me = (await this.host.hyprJson("clients")).find((c) => c.address === this.hostWindow);
      if (me?.floating) {
        await this.host.dispatch(`hl.dsp.window.float({ action = "off", window = ${win} })`, ["settiled", `address:${this.hostWindow}`]).catch(() => {});
      }
      if (workspace) {
        await this.host.dispatch(`hl.dsp.window.move({ workspace = ${luaStr(workspace)}, follow = false, window = ${win} })`,
          ["movetoworkspacesilent", `${workspace},address:${this.hostWindow}`]).catch(() => {});
      }
      // The rule above stops Hyprland focusing the new window; if something still did, give focus back
      // (checked twice: focus can land a moment after the window maps).
      for (let i = 0; i < 2 && hostBefore?.address; i++) {
        const now = await this.host.hyprJson("activewindow").catch(() => ({}));
        if (now?.address === this.hostWindow) await this.host.focusAddress(hostBefore.address).catch(() => {});
        await sleep(150);
      }
    });
    await this.ghost("move", this.pos);
    return this.status();
  }

  async status() {
    return {
      running: await this.running(), unit: this.unit, wayland_display: this.display,
      host_window: this.hostWindow, outputs: this.display ? await this.monitors() : [],
    };
  }

  async stop() {
    this.overlay.close();
    await stopUnit(this.slice);
    await stopUnit(this.unit);
    rmSync(this.dir, { recursive: true, force: true });
    this.display = null;
    this.hostWindow = null;
  }

  async ensure() {
    if (!(await this.running())) {
      this.display = null;
      await this.start();
    }
  }

  async sway(...cmds) {
    const out = JSON.parse(await run("swaymsg", ["-r", cmds.join("; ")], { env: this.env }));
    const bad = out.find((r) => !r.success);
    if (bad) throw new Error(`sway: ${bad.error}`);
    return out;
  }
  async swayGet(type) { return JSON.parse(await run("swaymsg", ["-r", "-t", type], { env: this.env })); }

  async ghost(op, p) {
    await this.overlay.send({ op, id: this.agent.id, x: p.x, y: p.y, label: this.agent.label, color: this.agent.color });
  }

  /** Fade this agent's cursor out; the next pointer action shows it again. */
  hideGhost() { this.overlay.sendIfConnected({ op: "hide", id: this.agent.id }); }

  async monitors() {
    return (await this.swayGet("get_outputs")).filter((o) => o.active).map((o) => ({
      name: o.name, focused: o.focused, x: o.rect.x, y: o.rect.y, width: o.rect.width, height: o.rect.height, scale: o.scale,
    }));
  }

  async capture(rect) {
    await this.host.ensureSandboxRule();
    await this.overlay.send({ op: "suspend" });
    await sleep(60);
    try {
      return await run("grim", ["-g", `${rect.x},${rect.y} ${rect.width}x${rect.height}`, "-s", "1", "-t", "png", "-"], { encoding: "buffer", env: this.env, timeout: 6000 });
    } finally {
      await this.overlay.send({ op: "resume" });
    }
  }

  async cursorPos() { return { ...this.pos }; }

  // sway's `cursor set` ignores a 0 coordinate, so clamp to >= 1.
  async setCursor(p) {
    this.pos = { x: Math.max(1, Math.round(p.x)), y: Math.max(1, Math.round(p.y)) };
    await this.sway(`seat seat0 cursor set ${this.pos.x} ${this.pos.y}`);
  }

  async click(p, button, double) {
    const b = { left: "button1", middle: "button2", right: "button3" }[button];
    await this.ghost("move", p);
    await sleep(GLIDE_MS);
    await this.setCursor(p);
    const once = [`seat seat0 cursor press ${b}`, `seat seat0 cursor release ${b}`];
    await this.sway(...once);
    if (double) { await sleep(60); await this.sway(...once); }
    await this.ghost("click", p);
    return {};
  }

  async move(p) { await this.ghost("move", p); await this.setCursor(p); return {}; }

  async drag(a, b) {
    await this.ghost("move", a);
    await sleep(GLIDE_MS);
    await this.setCursor(a);
    await this.sway("seat seat0 cursor press button1");
    try {
      for (let i = 1; i <= 12; i++) {
        await sleep(15);
        const q = { x: a.x + ((b.x - a.x) * i) / 12, y: a.y + ((b.y - a.y) * i) / 12 };
        await this.setCursor(q);
        if (i % 3 === 0) this.ghost("move", this.pos);
      }
    } finally {
      await this.sway("seat seat0 cursor release button1");
    }
    return {};
  }

  async scroll(p, direction, amount) {
    if (p) { await this.ghost("move", p); await sleep(GLIDE_MS); await this.setCursor(p); }
    const b = { up: "button4", down: "button5", left: "button6", right: "button7" }[direction];
    for (let i = 0; i < amount; i++) await this.sway(`seat seat0 cursor press ${b}`);
    return {};
  }

  async typeText(text, delayMs) { await run("wtype", delayMs ? ["-d", String(delayMs), "--", text] : ["--", text], { env: this.env }); }
  async key(combo) { await run("wtype", wtypeArgs(parseKeyCombo(combo)), { env: this.env }); }

  async windows() { return swayWindows(await this.swayGet("get_tree")).map((w) => ({ ...w, visible: true })); }
  async sensitiveLayers() { return []; }
  async focus(w) { await this.sway(`[con_id=${Number(w.address)}] focus`); }
  async close(w) { await this.sway(`[con_id=${Number(w.address)}] kill`); }
  async launch(cmd) {
    // Each app is its own unit in the sandbox's slice: sandbox_stop kills them all.
    // Accessibility is forced on so password fields can be found and redacted.
    await runUnit(`${this.unit}-app-${++this.appSeq}`, ["sh", "-c", cmd], {
      ...this.env, ACCESSIBILITY_ENABLED: "1", QT_ACCESSIBILITY: "1", QT_LINUX_ACCESSIBILITY_ALWAYS_ON: "1", NO_AT_BRIDGE: "0",
    }, { slice: this.slice });
  }
  async workspace(ws) {
    if (!/^[\w:+\- ]{1,40}$/.test(ws)) throw new Error("workspace name may only contain letters, digits, space, _ : + -");
    await this.sway(`workspace "${ws}"`);
  }

  async clipboardRead() {
    try { return await run("wl-paste", ["--no-newline"], { env: this.env }); } catch (e) {
      if (/nothing is copied|no suitable type/i.test(e.message)) return "";
      throw e;
    }
  }
  async clipboardWrite(t) { await writeStdin("wl-copy", [], t, { env: this.env }); }
  async clipboardTypes() { return (await run("wl-paste", ["--list-types"], { env: this.env })).split("\n").filter(Boolean); }

  async dispose() { if (this.display !== null || (await unitActive(this.unit))) await this.stop(); }
}
