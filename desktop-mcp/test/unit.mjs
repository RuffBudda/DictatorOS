import { test } from "node:test";
import assert from "node:assert/strict";
import {
  parseKeyCombo, wtypeArgs, luaStr, safeName, agentColor, swayWindows, pngSize, monitorLogical, boundingBox,
  captureScale, makeTransform, imageToScreen, screenToImage,
} from "../lib.js";

test("parseKeyCombo", () => {
  assert.deepEqual(parseKeyCombo("ctrl+shift+t"), { modifiers: ["ctrl", "shift"], key: "t" });
  assert.deepEqual(parseKeyCombo("Super+1"), { modifiers: ["logo"], key: "1" });
  assert.deepEqual(parseKeyCombo("enter"), { modifiers: [], key: "Return" });
  assert.deepEqual(parseKeyCombo("alt+F4"), { modifiers: ["alt"], key: "F4" });
  assert.deepEqual(parseKeyCombo("ctrl++"), { modifiers: ["ctrl"], key: "plus" });
  assert.throws(() => parseKeyCombo("hyper+x"), /unknown modifier/);
  assert.throws(() => parseKeyCombo(""), /empty/);
});

test("luaStr escapes quotes, backslashes, control chars and UTF-8", () => {
  assert.equal(luaStr("firefox"), '"firefox"');
  assert.equal(luaStr('a"b\\c'), '"a\\034b\\092c"');
  assert.equal(luaStr('x") os.execute("rm\n'), '"x\\034) os.execute(\\034rm\\010"');
  assert.equal(luaStr("é"), '"\\195\\169"');
});

test("safeName and agentColor", () => {
  assert.equal(safeName("Claude Code!"), "Claude-Code");
  assert.equal(safeName("../../etc"), "etc");
  assert.equal(safeName(""), "agent");
  assert.match(agentColor("x"), /^#[0-9a-f]{6}$/);
  assert.equal(agentColor("same"), agentColor("same"));
});

test("swayWindows flattens the tree", () => {
  const tree = { type: "root", nodes: [
    { type: "output", name: "__i3", nodes: [{ type: "workspace", name: "__i3_scratch", nodes: [], floating_nodes: [] }] },
    { type: "output", name: "WL-1", nodes: [{ type: "workspace", name: "1", nodes: [
      { type: "con", id: 7, app_id: "foot", name: "sh", rect: { x: 0, y: 0, width: 600, height: 400 }, focused: true, fullscreen_mode: 0, nodes: [] },
      { type: "con", id: 8, nodes: [
        { type: "con", id: 9, app_id: null, window_properties: { class: "XApp" }, name: "x", rect: { x: 600, y: 0, width: 600, height: 400 }, focused: false, fullscreen_mode: 0, nodes: [] },
      ] },
    ], floating_nodes: [
      { type: "floating_con", id: 10, app_id: "pavucontrol", name: "Volume", rect: { x: 50, y: 50, width: 300, height: 200 }, focused: false, fullscreen_mode: 0, nodes: [] },
    ] }] },
  ] };
  const w = swayWindows(tree);
  assert.deepEqual(w.map((x) => [x.address, x.class, x.workspace, x.floating]),
    [["7", "foot", "1", false], ["9", "XApp", "1", false], ["10", "pavucontrol", "1", true]]);
});

test("wtypeArgs releases modifiers in reverse", () => {
  assert.deepEqual(wtypeArgs(parseKeyCombo("ctrl+shift+t")),
    ["-M", "ctrl", "-M", "shift", "-k", "t", "-m", "shift", "-m", "ctrl"]);
});

test("pngSize reads IHDR from a real PNG", () => {
  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAEklEQVR4nGNgYGD4z8DAwMDAAAAMAAH+5Wf9AAAAAElFTkSuQmCC",
    "base64");
  assert.deepEqual(pngSize(png), { width: 3, height: 2 });
  assert.throws(() => pngSize(Buffer.from("nope")), /not a PNG/);
});

test("monitorLogical handles scale and rotation", () => {
  assert.deepEqual(monitorLogical({ x: 1600, y: 0, width: 2560, height: 1080, scale: 1, transform: 0 }),
    { x: 1600, y: 0, width: 2560, height: 1080 });
  assert.deepEqual(monitorLogical({ x: 0, y: 0, width: 2880, height: 1800, scale: 1.5, transform: 1 }),
    { x: 0, y: 0, width: 1200, height: 1920 });
});

test("boundingBox and captureScale", () => {
  assert.deepEqual(boundingBox([{ x: 0, y: 0, width: 1600, height: 900 }, { x: 1600, y: 0, width: 2560, height: 1080 }]),
    { x: 0, y: 0, width: 4160, height: 1080 });
  assert.equal(captureScale(800, 600, 1568), 1);
  assert.equal(captureScale(2560, 1080, 1568), 1568 / 2560);
});

test("image → screen mapping with offset origin and fractional scale", () => {
  const t = makeTransform({ x: 1600, y: 0, width: 2560, height: 1080 }, { width: 1568, height: 662 });
  assert.deepEqual(imageToScreen(t, 0, 0), { x: 1600, y: 0 });
  assert.deepEqual(imageToScreen(t, 784, 331), { x: 1600 + Math.round(784 * 2560 / 1568), y: Math.round(331 * 1080 / 662) });
  assert.deepEqual(imageToScreen(t, 1567, 661), { x: Math.round(1600 + 1567 * 2560 / 1568), y: Math.round(661 * 1080 / 662) });
  assert.throws(() => imageToScreen(t, 1568, 0), /outside/);
  assert.throws(() => imageToScreen(t, -1, 0), /outside/);
  assert.throws(() => imageToScreen(null, 1, 1), /screenshot first/);
  const back = screenToImage(t, 2880, 540);
  assert.equal(back.in_frame, true);
  assert.ok(Math.abs(back.x - 784) <= 1 && Math.abs(back.y - 331) <= 1);
});
