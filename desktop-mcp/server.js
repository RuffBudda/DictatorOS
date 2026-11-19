#!/usr/bin/env node
// desktop-mcp: lets an MCP client see and control a Hyprland (Wayland) desktop.
//
// Two desktops per agent session:
//   "sandbox" (default) – a private nested sway desktop shown as a window on your screen, with its own
//                          pointer, keyboard focus and clipboard. Your real pointer is never touched.
//   "host"              – your real desktop. Clicks briefly borrow your pointer and put it back.
// An overlay draws each agent's labeled cursor on whichever desktop it is using.
//
// stdout is the MCP channel: log only to stderr.

import { existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import {
  pngSize, boundingBox, captureScale, makeTransform, imageToScreen, screenToImage, agentColor, safeName,
} from "./lib.js";
import { HostDesktop, SandboxDesktop, runtimeDir } from "./backends.js";
import { AgentStatus } from "./status.js";
import { redactCapture, downscale, scrubText, isSensitiveWindow } from "./redact/index.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.error("[desktop-mcp]", ...a);

// MCP clients often spawn servers with a minimal environment. Recover the
// Wayland/Hyprland session variables from the runtime dir when they're missing.
function bootstrapEnv() {
  const env = process.env;
  env.XDG_RUNTIME_DIR ||= `/run/user/${process.getuid()}`;
  const rt = env.XDG_RUNTIME_DIR;
  const newest = (dir, pred) => {
    try {
      return readdirSync(dir).filter(pred)
        .map((n) => ({ n, t: statSync(join(dir, n)).mtimeMs }))
        .sort((a, b) => b.t - a.t)[0]?.n;
    } catch { return undefined; }
  };
  if (!env.HYPRLAND_INSTANCE_SIGNATURE) {
    const sig = newest(join(rt, "hypr"), (n) => existsSync(join(rt, "hypr", n, ".socket.sock")));
    if (sig) env.HYPRLAND_INSTANCE_SIGNATURE = sig;
  }
  if (!env.WAYLAND_DISPLAY) {
    // The host compositor owns the oldest socket; nested sandboxes create newer ones.
    try {
      const socks = readdirSync(rt).filter((n) => /^wayland-\d+$/.test(n)).sort((a, b) => Number(a.slice(8)) - Number(b.slice(8)));
      if (socks[0]) env.WAYLAND_DISPLAY = socks[0];
    } catch { /* ignore */ }
  }
  if (!env.YDOTOOL_SOCKET && existsSync(join(rt, ".ydotool_socket"))) env.YDOTOOL_SOCKET = join(rt, ".ydotool_socket");
  if (!env.DBUS_SESSION_BUS_ADDRESS && existsSync(join(rt, "bus"))) env.DBUS_SESSION_BUS_ADDRESS = `unix:path=${join(rt, "bus")}`;
}
bootstrapEnv();

// ---------- agent identity ----------

const label = (process.env.DESKTOP_MCP_LABEL || "Agent").slice(0, 24);
const agent = {
  id: `${safeName(label)}-${process.pid}`,
  label,
  color: /^#[0-9a-fA-F]{6}$/.test(process.env.DESKTOP_MCP_COLOR ?? "") ? process.env.DESKTOP_MCP_COLOR : agentColor(`${label}-${process.pid}`),
};
const DEFAULT_DESKTOP = process.env.DESKTOP_MCP_DEFAULT === "host" ? "host" : "sandbox";

const host = new HostDesktop(agent);
const sandbox = new SandboxDesktop(agent, host);
const transforms = { host: null, sandbox: null }; // last screenshot mapping per desktop
const status = new AgentStatus(agent, runtimeDir(), { onRaise: () => host.overlay.ensure() });
const sandboxSummary = async () => {
  const st = await sandbox.status().catch(() => null);
  return st?.running ? { unit: sandbox.unit, host_window: st.host_window, display: st.wayland_display } : null;
};

async function desktopFor(name) {
  const d = name ?? DEFAULT_DESKTOP;
  if (d === "host") return host;
  const wasRunning = sandbox.display !== null;
  await sandbox.ensure();
  if (!wasRunning) status.update({ sandbox: await sandboxSummary() });
  return sandbox;
}

async function visibleWorkspaces() {
  const mons = await host.hyprJson("monitors").catch(() => []);
  return mons.map((m) => `${m.name}:${m.activeWorkspace?.id}:${m.specialWorkspace?.id ?? 0}`).sort().join(",");
}

async function resolvePoint(desk, x, y, space = "image") {
  if (desk.kind === "host" && space !== "screen" && transforms.host) {
    // The user may have switched workspace since the screenshot; the same pixels now show other windows.
    if (transforms.host.workspaces !== (await visibleWorkspaces())) {
      throw new Error("The user switched workspace since your last host screenshot, so those coordinates point at different windows now. Take a new screenshot (or work in your sandbox).");
    }
  }
  if (space === "screen") return { x: Math.round(x), y: Math.round(y) };
  return imageToScreen(transforms[desk.kind], x, y);
}

// ---------- credential protection ----------

const inside = (p, r) => p.x >= r.x && p.y >= r.y && p.x < r.x + r.width && p.y < r.y + r.height;

/** Refuse pointer input aimed at a password manager / auth prompt. */
async function guardPoint(desk, ...points) {
  const wins = (await desk.windows()).filter((w) => w.visible && isSensitiveWindow(w));
  const layers = await desk.sensitiveLayers();
  for (const p of points) {
    if (wins.some((w) => inside(p, w)) || layers.some((l) => inside(p, l))) {
      await status.raise("A password manager or authentication prompt is in the way. Please handle it, then press Done.", "credentials");
      throw new Error("Refused: that point is inside a password manager or authentication prompt. The user has been notified in the top bar; call request_user_input with wait_seconds to wait for them.");
    }
  }
}

// On the host, the window the agent last clicked or focused. Keyboard input is only sent while that
// window still has focus, so keystrokes never land in whatever the user switched to.
let hostTarget = null;
async function noteHostTarget() {
  hostTarget = (await host.hyprJson("activewindow").catch(() => ({})))?.address ?? null;
}

/** Refuse keyboard input while a password manager / auth prompt has focus. */
async function guardKeyboard(desk) {
  if (desk.kind === "host") {
    const active = (await host.hyprJson("activewindow").catch(() => ({})))?.address ?? null;
    if (!hostTarget || active !== hostTarget) {
      throw new Error("Refused: on the host, click or focus_window the target window first; the user may be working in another window. (In your sandbox there is no such restriction.)");
    }
  }
  const wins = await desk.windows();
  const focused = wins.find((w) => w.focused);
  if ((focused && isSensitiveWindow(focused)) || (await desk.sensitiveLayers()).length) {
    await status.raise("A password manager or authentication prompt has keyboard focus. Please handle it, then press Done.", "credentials");
    throw new Error("Refused: a password manager or authentication prompt has keyboard focus. The user has been notified in the top bar; call request_user_input with wait_seconds to wait for them.");
  }
}

const scrubWindow = (w) => ({ ...w, title: scrubText(w.title) });

// ---------- MCP plumbing ----------

const text = (obj) => ({ content: [{ type: "text", text: typeof obj === "string" ? obj : JSON.stringify(obj, null, 2) }] });

const server = new McpServer({ name: "desktop-mcp", version: "0.2.0" });

function tool(name, description, inputSchema, handler) {
  server.registerTool(name, { description, inputSchema }, async (args) => {
    try {
      if (!["sandbox_status", "wait", "request_user_input", "clear_user_input"].includes(name)) status.action(name);
      return await handler(args ?? {});
    } catch (err) {
      log(`${name}:`, err.message);
      return { isError: true, content: [{ type: "text", text: err.message }] };
    }
  });
}

const desktopArg = z.enum(["sandbox", "host"]).optional().describe(
  `"sandbox" = your own private desktop (a window on the user's screen; never touches their pointer or keyboard focus; started automatically). ` +
  `"host" = the user's real desktop (clicks briefly borrow their pointer and return it). Default: "${DEFAULT_DESKTOP}".`,
);
const coordSpace = z.enum(["image", "screen"]).optional().describe(
  'Coordinate space. "image" (default) = pixel coordinates in the most recent screenshot of this desktop. "screen" = the desktop\'s global logical coordinates.',
);

// ---------- sandbox lifecycle ----------

tool("sandbox_start",
  "Start (or return) your private sandbox desktop: a nested tiling desktop shown as a tiled window on the user's screen, with its own pointer, keyboard focus and clipboard. It keeps working while the user is on another workspace. Other tools start it automatically; call this first only to put it on a specific workspace.",
  {
    workspace: z.string().max(40).optional().describe("Host workspace to put the window on, without switching the user there."),
  },
  async (args) => {
    const st = await sandbox.start(args);
    status.update({ sandbox: await sandboxSummary() });
    return text(st);
  });

tool("sandbox_stop", "Close your sandbox desktop and every app running in it.", {},
  async () => { await sandbox.stop(); transforms.sandbox = null; status.update({ sandbox: null }); return text({ stopped: true }); });

tool("sandbox_status", "Report whether your sandbox desktop is running and its size.", {},
  async () => text({ agent, default_desktop: DEFAULT_DESKTOP, sandbox: await sandbox.status() }));

// ---------- seeing ----------

tool("screenshot",
  "Capture a desktop and return it as a PNG. Pointer tools then take coordinates in THIS image's pixel space by default, so take a new screenshot after anything changes. Agent cursor overlays are hidden in the capture.",
  {
    desktop: desktopArg,
    target: z.enum(["all", "monitor", "window", "region"]).optional().describe('"monitor" (default), "all" monitors, a "window", or a "region".'),
    monitor: z.string().optional().describe("Monitor/output name for target=monitor (default: focused)."),
    window_address: z.string().optional().describe("Window address from list_windows, for target=window."),
    region: z.object({ x: z.number(), y: z.number(), width: z.number().positive(), height: z.number().positive() })
      .optional().describe("Global logical coordinates, for target=region."),
    max_edge: z.number().int().min(256).max(2560).optional().describe("Longest image edge in pixels (default 1568)."),
  },
  async ({ desktop, target = "monitor", monitor, window_address, region, max_edge = 1568 }) => {
    const desk = await desktopFor(desktop);
    const mons = await desk.monitors();
    let rect;
    if (target === "all") rect = boundingBox(mons);
    else if (target === "monitor") {
      const m = monitor ? mons.find((x) => x.name === monitor) : (mons.find((x) => x.focused) ?? mons[0]);
      if (!m) throw new Error(`Unknown monitor "${monitor}". Available: ${mons.map((x) => x.name).join(", ")}`);
      rect = { x: m.x, y: m.y, width: m.width, height: m.height };
    } else if (target === "window") {
      if (!window_address) throw new Error("window_address is required for target=window (see list_windows).");
      const w = (await desk.windows()).find((x) => x.address === window_address);
      if (!w) throw new Error(`No window with address ${window_address}.`);
      rect = { x: w.x, y: w.y, width: w.width, height: w.height };
    } else {
      if (!region) throw new Error("region is required for target=region.");
      rect = { x: Math.round(region.x), y: Math.round(region.y), width: Math.round(region.width), height: Math.round(region.height) };
    }
    const full = await desk.capture(rect);
    let red;
    try {
      const windows = (await desk.windows()).filter((w) => w.visible);
      red = await redactCapture(full, rect, {
        windows,
        layers: await desk.sensitiveLayers(),
        mapField: (f) => {
          const mine = windows.filter((w) => w.pid === f.pid);
          const byTitle = mine.filter((w) => f.window && w.title === f.window);
          // a11y extents can be off by a few pixels (decorations); pad generously.
          return (byTitle.length ? byTitle : mine).map((w) => ({ x: w.x + f.x - 6, y: w.y + f.y - 8, width: f.width + 12, height: f.height + 16 }));
        },
      });
    } catch (e) {
      throw new Error(`Screenshot withheld: credential redaction failed (${e.message}).`);
    }
    const s = captureScale(rect.width, rect.height, max_edge);
    const png = downscale(red.png, Math.max(1, Math.round(rect.width * s)), Math.max(1, Math.round(rect.height * s)));
    const size = pngSize(png);
    const t = makeTransform(rect, size);
    if (desk.kind === "host") t.workspaces = await visibleWorkspaces();
    transforms[desk.kind] = t;
    return {
      content: [
        { type: "image", data: png.toString("base64"), mimeType: "image/png" },
        { type: "text", text: JSON.stringify({
          desktop: desk.kind, image: size, captured_region: rect,
          redacted: { areas: red.total, ...red.reasons, note: red.total ? "Hatched dark boxes hide credentials or password prompts. Never try to reveal, read, copy or work around them." : undefined },
          image_to_screen: { origin: [t.ox, t.oy], scale: [t.kx, t.ky] },
          monitors: mons.map((m) => ({ name: m.name, focused: m.focused, x: m.x, y: m.y, width: m.width, height: m.height })),
          note: "Pointer tools take coordinates in this image's pixel space by default.",
        }) },
      ],
    };
  });

tool("cursor_position",
  "Return your pointer position on a desktop, in screen coordinates and in the last screenshot's image space.",
  { desktop: desktopArg },
  async ({ desktop }) => {
    const desk = await desktopFor(desktop);
    const g = await desk.cursorPos();
    const t = transforms[desk.kind];
    return text({ desktop: desk.kind, screen: g, image: t ? screenToImage(t, g.x, g.y) : null });
  });

tool("list_windows",
  "List windows on a desktop (address, class/app_id, title, workspace, position/size in screen coordinates, focus).",
  { desktop: desktopArg },
  async ({ desktop }) => text((await (await desktopFor(desktop)).windows()).map(scrubWindow)));

tool("list_monitors", "List monitors/outputs of a desktop with their geometry in screen coordinates.",
  { desktop: desktopArg },
  async ({ desktop }) => text(await (await desktopFor(desktop)).monitors()));

// ---------- pointer ----------

tool("click",
  "Click at (x, y). Coordinates are in the last screenshot's pixel space unless coordinate_space is \"screen\". On the host desktop your pointer is borrowed and returned to where the user left it.",
  {
    x: z.number(), y: z.number(),
    button: z.enum(["left", "right", "middle"]).optional(),
    double: z.boolean().optional(),
    coordinate_space: coordSpace, desktop: desktopArg,
  },
  async ({ x, y, button = "left", double = false, coordinate_space, desktop }) => {
    const desk = await desktopFor(desktop);
    const p = await resolvePoint(desk, x, y, coordinate_space);
    await guardPoint(desk, p);
    const r = await desk.click(p, button, double);
    if (desk.kind === "host") await noteHostTarget();
    return text({ desktop: desk.kind, clicked: p, button, double, ...r });
  });

tool("move_mouse",
  "Move the pointer to (x, y) without clicking, e.g. to hover. On the host desktop the user's pointer stays there. Coordinates are in the last screenshot's pixel space unless coordinate_space is \"screen\".",
  { x: z.number(), y: z.number(), coordinate_space: coordSpace, desktop: desktopArg },
  async ({ x, y, coordinate_space, desktop }) => {
    const desk = await desktopFor(desktop);
    const p = await resolvePoint(desk, x, y, coordinate_space);
    return text({ desktop: desk.kind, moved_to: p, ...(await desk.move(p)) });
  });

tool("drag",
  "Press the left button at (from_x, from_y), move to (to_x, to_y), and release. Coordinates are in the last screenshot's pixel space unless coordinate_space is \"screen\".",
  { from_x: z.number(), from_y: z.number(), to_x: z.number(), to_y: z.number(), coordinate_space: coordSpace, desktop: desktopArg },
  async ({ from_x, from_y, to_x, to_y, coordinate_space, desktop }) => {
    const desk = await desktopFor(desktop);
    const a = await resolvePoint(desk, from_x, from_y, coordinate_space);
    const b = await resolvePoint(desk, to_x, to_y, coordinate_space);
    await guardPoint(desk, a, b);
    return text({ desktop: desk.kind, from: a, to: b, ...(await desk.drag(a, b)) });
  });

tool("scroll",
  "Scroll the mouse wheel at (x, y) (or wherever the pointer is). Coordinates are in the last screenshot's pixel space unless coordinate_space is \"screen\".",
  {
    direction: z.enum(["up", "down", "left", "right"]),
    amount: z.number().int().min(1).max(20).optional().describe("Wheel clicks (default 3)."),
    x: z.number().optional(), y: z.number().optional(),
    coordinate_space: coordSpace, desktop: desktopArg,
  },
  async ({ direction, amount = 3, x, y, coordinate_space, desktop }) => {
    const desk = await desktopFor(desktop);
    const p = x !== undefined && y !== undefined ? await resolvePoint(desk, x, y, coordinate_space) : null;
    if (p) await guardPoint(desk, p);
    return text({ desktop: desk.kind, scrolled: direction, amount, at: p, ...(await desk.scroll(p, direction, amount)) });
  });

// ---------- keyboard ----------

tool("type_text",
  "Type text into the focused window of a desktop. On the host that is whatever window has keyboard focus (focus or click it first).",
  { text: z.string().min(1).max(5000), delay_ms: z.number().int().min(0).max(500).optional(), desktop: desktopArg },
  async ({ text: t, delay_ms, desktop }) => {
    const desk = await desktopFor(desktop);
    await guardKeyboard(desk);
    await desk.typeText(t, delay_ms);
    return text({ desktop: desk.kind, typed_chars: t.length });
  });

tool("key",
  'Press a key or combination in the focused window, e.g. "Return", "ctrl+c", "ctrl+shift+t", "super+1", "alt+F4". Keys are xkb keysym names (Return, Escape, Tab, BackSpace, Up, F5, a...).',
  { combo: z.string().min(1), repeat: z.number().int().min(1).max(50).optional(), desktop: desktopArg },
  async ({ combo, repeat = 1, desktop }) => {
    const desk = await desktopFor(desktop);
    await guardKeyboard(desk);
    for (let i = 0; i < repeat; i++) {
      await desk.key(combo);
      if (i < repeat - 1) await sleep(30);
    }
    return text({ desktop: desk.kind, pressed: combo, repeat });
  });

// ---------- windows & apps ----------

async function pickWindow(desk, { address, class: cls, title_contains }) {
  if (!address && !cls && !title_contains) throw new Error("Give address, class, or title_contains.");
  const wins = await desk.windows();
  const matches = wins.filter((w) =>
    (!address || w.address === address) &&
    (!cls || w.class.toLowerCase() === cls.toLowerCase()) &&
    (!title_contains || w.title.toLowerCase().includes(title_contains.toLowerCase())));
  if (matches.length !== 1) {
    const list = (matches.length ? matches : wins).map((w) => `${w.address} [${w.class}] ${scrubText(w.title)}`).join("\n");
    throw new Error(`${matches.length} windows matched; need exactly 1. ${matches.length ? "Matches" : "Open windows"}:\n${list}`);
  }
  return matches[0];
}
const windowSel = {
  address: z.string().optional(), class: z.string().optional(), title_contains: z.string().optional(), desktop: desktopArg,
};

tool("focus_window", "Focus a window by address, class, or title substring (must match exactly one).", windowSel,
  async (args) => {
    const desk = await desktopFor(args.desktop);
    const w = await pickWindow(desk, args);
    if (isSensitiveWindow(w)) throw new Error("Refused: that is a password manager or authentication prompt.");
    await desk.focus(w);
    if (desk.kind === "host") await noteHostTarget();
    return text({ desktop: desk.kind, focused: { address: w.address, class: w.class, title: scrubText(w.title) } });
  });

tool("close_window", "Close a window by address, class, or title substring (must match exactly one).", windowSel,
  async (args) => {
    const desk = await desktopFor(args.desktop);
    const w = await pickWindow(desk, args);
    await desk.close(w);
    return text({ desktop: desk.kind, closed: { address: w.address, class: w.class, title: scrubText(w.title) } });
  });

tool("launch_app",
  'Launch an application, e.g. "foot" or "nautilus ~/Downloads". Returns immediately; use wait + screenshot to see it. In the sandbox, browsers that are already open on the host (Chromium, Firefox) would open in the host instance: give them a separate profile, e.g. "chromium --user-data-dir=/tmp/agent-chromium".',
  { command: z.string().min(1), desktop: desktopArg },
  async ({ command, desktop }) => {
    const desk = await desktopFor(desktop);
    await desk.launch(command);
    return text({ desktop: desk.kind, launched: command });
  });

tool("switch_workspace", 'Switch to a workspace, e.g. "3" or "name:web".',
  { workspace: z.string().min(1).max(40), desktop: desktopArg },
  async ({ workspace, desktop }) => {
    const desk = await desktopFor(desktop);
    await desk.workspace(workspace);
    return text({ desktop: desk.kind, workspace });
  });

// ---------- clipboard & misc ----------

tool("clipboard_read", "Read a desktop's clipboard as text (the sandbox has its own clipboard). Credentials are redacted.", { desktop: desktopArg },
  async ({ desktop }) => {
    const desk = await desktopFor(desktop);
    const types = await desk.clipboardTypes().catch(() => []);
    if (types.some((t) => /password|secret|x-kde-passwordManagerHint/i.test(t))) {
      return text("[REDACTED: the clipboard holds a password-manager secret]");
    }
    return text(scrubText(await desk.clipboardRead()));
  });

tool("clipboard_write", "Put text on a desktop's clipboard (the sandbox has its own clipboard).",
  { text: z.string(), desktop: desktopArg },
  async ({ text: t, desktop }) => {
    const desk = await desktopFor(desktop);
    await desk.clipboardWrite(t);
    return text({ desktop: desk.kind, copied_chars: t.length });
  });

// ---------- asking the user ----------

tool("request_user_input",
  "Ask the user for help (log in, approve something, enter a password, make a decision). Shows an urgent icon in their top bar and a notification; they press Done when finished. Never ask the user to tell you a password: ask them to type it themselves. With wait_seconds > 0, blocks until they press Done or the time runs out.",
  {
    message: z.string().min(1).max(300).describe("Short, specific: what you need them to do."),
    wait_seconds: z.number().int().min(0).max(900).optional().describe("How long to wait for Done (default 0 = return immediately)."),
  },
  async ({ message, wait_seconds = 0 }) => {
    await status.raise(scrubText(message));
    if (!wait_seconds) return text({ requested: true, note: "Call again with wait_seconds, or check_user_input, to see when they are done." });
    return text(await status.waitForAck(wait_seconds * 1000));
  });

tool("check_user_input", "Check whether the user pressed Done on your request.", {},
  async () => {
    if (!status.state.attention) return text({ pending: false });
    if (status.acknowledged()) return text(await status.waitForAck(0));
    return text({ pending: true, since: status.state.attention.since });
  });

tool("clear_user_input", "Withdraw your request for the user's help (e.g. you no longer need it).", {},
  async () => { status.clear(); return text({ cleared: true }); });

tool("wait", "Wait for a number of milliseconds (e.g. for an app to open or a page to load).",
  { ms: z.number().int().min(50).max(10000) },
  async ({ ms }) => { await sleep(ms); return text({ waited_ms: ms }); });

// ---------- lifecycle ----------

let shuttingDown = false;
async function shutdown(reason) {
  if (shuttingDown) return;
  shuttingDown = true;
  log("shutting down:", reason);
  const keep = process.env.DESKTOP_MCP_KEEP_SANDBOX === "1";
  await Promise.race([
    Promise.allSettled([host.dispose(), keep ? null : sandbox.dispose(), status.dispose()]),
    sleep(3000),
  ]);
  process.exit(0);
}
process.stdin.on("close", () => shutdown("stdin closed"));
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(sig, () => shutdown(sig));

await server.connect(new StdioServerTransport());
log(`ready as ${agent.label} (${agent.color}), default desktop: ${DEFAULT_DESKTOP}`);
