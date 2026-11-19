// Client for the Quickshell overlay (overlay/shell.qml): one overlay per Wayland display.
import net from "node:net";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { runUnit } from "./proc.js";

const OVERLAY_DIR = fileURLToPath(new URL("./overlay", import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class Overlay {
  /**
   * @param {object} o
   * @param {string} o.socket   Unix socket path the overlay listens on
   * @param {string} o.display  WAYLAND_DISPLAY to draw on
   * @param {string} [o.unit]   systemd unit name to start it under (host overlay); omit if started elsewhere
   * @param {object} [o.env]    extra env for the overlay process
   */
  constructor({ socket, display, unit, env = {} }) {
    Object.assign(this, { socketPath: socket, display, unit, env });
    this.conn = null;
    this.disabled = false;
  }

  async #connect() {
    return new Promise((resolve, reject) => {
      const c = net.createConnection(this.socketPath);
      c.once("connect", () => { c.removeAllListeners("error"); c.on("error", () => { this.conn = null; }); c.on("close", () => { this.conn = null; }); resolve(c); });
      c.once("error", reject);
    });
  }

  async ensure() {
    if (this.disabled) return false;
    if (this.conn) return true;
    try {
      this.conn = await this.#connect();
      return true;
    } catch {
      if (!this.unit) {
        // Started by someone else (e.g. inside a sandbox): just wait for it to come up.
        for (let i = 0; i < 40 && !existsSync(this.socketPath); i++) await sleep(50);
      } else {
        await runUnit(this.unit, ["qs", "-p", OVERLAY_DIR], {
          WAYLAND_DISPLAY: this.display, DMCP_SOCKET: this.socketPath, ...this.env,
        }).catch(() => {}); // "already exists" when another agent started it first
      }
      for (let i = 0; i < 60; i++) {
        try { this.conn = await this.#connect(); return true; } catch { await sleep(50); }
      }
      return false;
    }
  }

  /** Fire-and-forget: overlay problems must never break an action. */
  async send(msg) {
    try {
      if (await this.ensure()) this.conn.write(JSON.stringify(msg) + "\n");
    } catch { /* ignore */ }
  }

  close() { try { this.conn?.end(); } catch { /* ignore */ } this.conn = null; }
}
