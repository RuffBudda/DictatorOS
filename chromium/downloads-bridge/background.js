// Streams Chromium's downloads to the native host dev.abu.downloads (bin/downloads-host),
// which feeds the abu.downloads bar widget, and runs pause/resume/cancel sent back by it.
// Web-app windows (Outlook, SharePoint...) share this profile, so their downloads show too.
const HOST = "dev.abu.downloads";
const DAY = 24 * 60 * 60 * 1000;
let port = null;
let backoff = 1000;
let pollTimer = null;
const rates = new Map(); // id -> { bytes, t, speed }

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    setTimeout(connect, backoff);
    return;
  }
  port.onMessage.addListener(onCommand);
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    port = null;
    backoff = Math.min(backoff * 2, 60000);
    setTimeout(connect, backoff);
  });
  backoff = 1000;
  sendSnapshot();
}

async function onCommand(msg) {
  const id = msg && msg.id;
  if (!Number.isInteger(id)) return;
  try {
    if (msg.action === "pause") await chrome.downloads.pause(id);
    else if (msg.action === "resume") await chrome.downloads.resume(id);
    else if (msg.action === "cancel") await chrome.downloads.cancel(id);
  } catch (e) { /* already finished or gone */ }
  sendSnapshot();
}

function basename(p) {
  return String(p || "").split("/").pop();
}

function toItem(d, now) {
  const received = d.bytesReceived || 0;
  const total = d.totalBytes > 0 ? d.totalBytes : 0;
  let speed = 0;
  if (d.state === "in_progress" && !d.paused) {
    const r = rates.get(d.id);
    if (r && now > r.t) {
      const inst = Math.max(0, (received - r.bytes) * 1000 / (now - r.t));
      speed = r.speed ? r.speed * 0.6 + inst * 0.4 : inst;
    }
    rates.set(d.id, { bytes: received, t: now, speed });
  } else {
    rates.delete(d.id);
  }
  let eta = -1;
  if (d.state === "in_progress" && !d.paused) {
    if (d.estimatedEndTime) eta = Math.max(0, Math.round((Date.parse(d.estimatedEndTime) - now) / 1000));
    else if (speed > 0 && total > 0) eta = Math.round((total - received) / speed);
  }
  return {
    id: d.id,
    name: basename(d.filename) || basename(d.finalUrl || d.url) || "download",
    path: d.filename || "",
    state: d.state,
    paused: !!d.paused,
    canResume: !!d.canResume,
    received,
    total,
    speed: Math.round(speed),
    eta,
    error: d.error || "",
    started: Date.parse(d.startTime) || 0,
    ended: d.state === "in_progress" ? 0 : (Date.parse(d.endTime) || now),
  };
}

async function sendSnapshot() {
  if (!port) return;
  const now = Date.now();
  const all = await chrome.downloads.search({ orderBy: ["-startTime"], limit: 20 });
  const items = all.filter(d => now - (Date.parse(d.startTime) || 0) < DAY).map(d => toItem(d, now));
  try {
    port.postMessage({ type: "snapshot", downloads: items });
  } catch (e) {
    return;
  }
  clearTimeout(pollTimer);
  pollTimer = null;
  // chrome.downloads.onChanged doesn't fire for byte progress, so poll while active.
  if (items.some(d => d.state === "in_progress")) pollTimer = setTimeout(sendSnapshot, 1000);
}

chrome.downloads.onCreated.addListener(sendSnapshot);
chrome.downloads.onChanged.addListener(sendSnapshot);
chrome.downloads.onErased.addListener(sendSnapshot);
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();
