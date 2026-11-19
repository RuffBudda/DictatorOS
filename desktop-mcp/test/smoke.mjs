// Live smoke test against the running desktop.
// Host part: only looks at the screen and moves the pointer, then puts it back.
// Sandbox part: opens a small floating sandbox window, runs a terminal in it, types and clicks there,
// and asserts the user's real pointer and keyboard focus never changed. Then closes it.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { pngSize } from "../lib.js";

const serverPath = fileURLToPath(new URL("../server.js", import.meta.url));
const client = new Client({ name: "smoke", version: "0" });
await client.connect(new StdioClientTransport({
  command: process.execPath, args: [serverPath], stderr: "inherit",
  env: { DESKTOP_MCP_LABEL: "Smoke test", DESKTOP_MCP_COLOR: "#a855f7" },
}));

const call = async (name, args = {}) => {
  const r = await client.callTool({ name, arguments: args });
  assert.ok(!r.isError, `${name} failed: ${r.content?.[0]?.text}`);
  return r;
};
const json = (r) => JSON.parse(r.content.find((c) => c.type === "text").text);
const hostCursor = () => {
  const [x, y] = execFileSync("hyprctl", ["cursorpos"], { encoding: "utf8" }).split(",").map((s) => Number(s.trim()));
  return { x, y };
};
const hostActive = () => JSON.parse(execFileSync("hyprctl", ["-j", "activewindow"], { encoding: "utf8" })).address;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const EXPECTED = ["sandbox_start", "sandbox_stop", "sandbox_status", "screenshot", "click", "move_mouse", "drag",
  "scroll", "type_text", "key", "cursor_position", "list_windows", "focus_window", "close_window", "list_monitors",
  "launch_app", "switch_workspace", "clipboard_read", "clipboard_write", "wait",
  "request_user_input", "check_user_input", "clear_user_input"];
const { tools } = await client.listTools();
const names = tools.map((t) => t.name);
for (const n of EXPECTED) assert.ok(names.includes(n), `missing tool ${n}`);
console.log(`ok tools (${names.length})`);

// ---------------- host ----------------
const mons = json(await call("list_monitors", { desktop: "host" }));
assert.ok(mons.length >= 1);
console.log("ok host list_monitors", mons.map((m) => `${m.name} ${m.width}x${m.height}@${m.x},${m.y}`).join("; "));
console.log(`ok host list_windows (${json(await call("list_windows", { desktop: "host" })).length} windows)`);

const typed = await client.callTool({ name: "type_text", arguments: { text: "x", desktop: "host" } });
assert.ok(typed.isError && /click or focus_window/.test(typed.content[0].text), "host typing without a target must be refused");
console.log("ok host typing refused until the agent targets a window");

const early = await client.callTool({ name: "move_mouse", arguments: { x: 1, y: 1, desktop: "host" } });
assert.ok(early.isError && /screenshot first/.test(early.content[0].text));
console.log("ok image coords rejected before screenshot");

const start = hostCursor();
const shot = await call("screenshot", { desktop: "host" });
const size = pngSize(Buffer.from(shot.content.find((c) => c.type === "image").data, "base64"));
assert.ok(size.width <= 1568 && size.height <= 1568);
const meta = json(shot);
console.log(`ok host screenshot ${size.width}x${size.height}`);
try {
  const cx = Math.floor(size.width / 2), cy = Math.floor(size.height / 2);
  await call("move_mouse", { x: cx, y: cy, desktop: "host" });
  const [ox, oy] = meta.image_to_screen.origin, [kx, ky] = meta.image_to_screen.scale;
  const want = { x: Math.round(ox + cx * kx), y: Math.round(oy + cy * ky) };
  const got = hostCursor();
  assert.ok(Math.abs(got.x - want.x) <= 2 && Math.abs(got.y - want.y) <= 2, `cursor at ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
  console.log("ok host move_mouse image→screen mapping", got);
} finally {
  await call("move_mouse", { x: start.x, y: start.y, coordinate_space: "screen", desktop: "host" });
}

// ---------------- sandbox ----------------
const cursor0 = hostCursor();
const focus0 = hostActive();
try {
  const st = json(await call("sandbox_start"));
  assert.ok(st.running && st.wayland_display && st.host_window, `sandbox did not start: ${JSON.stringify(st)}`);
  console.log(`ok sandbox_start ${st.wayland_display}, host window ${st.host_window}, outputs`, st.outputs.map((o) => `${o.width}x${o.height}`).join(","));
  await sleep(300);
  assert.equal(hostActive(), focus0, "sandbox start stole host keyboard focus");

  await call("launch_app", { command: "foot -e sh" });
  let wins = [];
  for (let i = 0; i < 40 && !wins.some((w) => w.class === "foot"); i++) { await sleep(100); wins = json(await call("list_windows")); }
  const foot = wins.find((w) => w.class === "foot");
  assert.ok(foot, "foot did not open in sandbox");
  console.log("ok sandbox launch_app + list_windows", foot.address, `${foot.width}x${foot.height}`);

  const sshot = await call("screenshot");
  assert.equal(json(sshot).desktop, "sandbox");
  const ssize = pngSize(Buffer.from(sshot.content.find((c) => c.type === "image").data, "base64"));
  await call("click", { x: Math.floor(ssize.width / 2), y: Math.floor(ssize.height / 2) });
  await call("type_text", { text: "echo sandbox-ok > /dev/null" });
  await call("key", { combo: "Return" });
  await call("scroll", { direction: "up", amount: 2 });
  await call("drag", { from_x: 10, from_y: 10, to_x: 200, to_y: 120 });
  await call("clipboard_write", { text: "sandbox clipboard" });
  assert.equal((await call("clipboard_read")).content[0].text, "sandbox clipboard");
  console.log("ok sandbox click/type/key/scroll/drag/clipboard");

  const c1 = hostCursor();
  assert.deepEqual(c1, cursor0, `host pointer moved during sandbox actions: ${JSON.stringify(cursor0)} → ${JSON.stringify(c1)}`);
  assert.equal(hostActive(), focus0, "host keyboard focus changed during sandbox actions");
  console.log("ok host pointer and focus untouched by sandbox", c1);

  const shotR = json(await call("screenshot"));
  assert.ok(shotR.redacted && typeof shotR.redacted.areas === "number", "screenshot must report redaction");
  console.log("ok sandbox screenshot redaction ran", shotR.redacted);

  await call("close_window", { class: "foot" });
  console.log("ok sandbox close_window");
} finally {
  await call("sandbox_stop");
}
const after = json(await call("sandbox_status"));
assert.equal(after.sandbox.running, false);
console.log("ok sandbox_stop");

await client.close();
console.log("smoke: all passed");
