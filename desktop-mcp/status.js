// Per-agent status files read by the Omarchy bar widget (and bin/desktop-mcp-ctl).
//   $XDG_RUNTIME_DIR/desktop-mcp/agents/<agent-id>.json   – written by this server
//   $XDG_RUNTIME_DIR/desktop-mcp/agents/<agent-id>.ack    – written by the bar when you press "Done"
import { mkdirSync, writeFileSync, renameSync, rmSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { run } from "./proc.js";

export class AgentStatus {
  constructor(agent, dir, { onRaise } = {}) {
    this.onRaise = onRaise;
    this.agent = agent;
    this.dir = join(dir, "agents");
    mkdirSync(this.dir, { recursive: true });
    this.file = join(this.dir, `${agent.id}.json`);
    this.ackFile = join(this.dir, `${agent.id}.ack`);
    this.state = { activity: "idle", lastAction: null, attention: null, sandbox: null };
    this.timer = setInterval(() => this.write(), 5000);
    this.timer.unref();
    this.write();
  }

  write() {
    const doc = {
      id: this.agent.id, label: this.agent.label, color: this.agent.color, pid: process.pid,
      updated: Date.now(), ...this.state,
    };
    const tmp = `${this.file}.tmp`;
    try { writeFileSync(tmp, JSON.stringify(doc)); renameSync(tmp, this.file); } catch { /* best effort */ }
  }

  update(patch) { Object.assign(this.state, patch); this.write(); }

  action(name) { this.update({ activity: "working", lastAction: { name, at: Date.now() } }); }

  /** Ask the user for help: bar icon turns urgent and a notification is shown once. */
  async raise(message, kind = "input") {
    const msg = String(message).slice(0, 300);
    if (this.state.attention?.message === msg) return;
    rmSync(this.ackFile, { force: true });
    this.update({ attention: { message: msg, kind, since: Date.now() } });
    // The host overlay shows a banner above everything when the bar is hidden or covered.
    try { await this.onRaise?.(); } catch { /* best effort */ }
    await run("notify-send", ["-a", "Agent desktop", "-u", "critical", "-i", "dialog-question",
      `${this.agent.label} needs you`, msg]).catch(() => {});
  }

  acknowledged() { return existsSync(this.ackFile); }

  clear() {
    rmSync(this.ackFile, { force: true });
    if (this.state.attention) this.update({ attention: null });
  }

  /** Wait until the user presses Done in the bar (or timeout). */
  async waitForAck(timeoutMs) {
    const end = Date.now() + timeoutMs;
    while (Date.now() < end) {
      if (this.acknowledged()) {
        let note = "";
        try { note = readFileSync(this.ackFile, "utf8").trim().slice(0, 500); } catch { /* ignore */ }
        this.clear();
        return { acknowledged: true, note };
      }
      await new Promise((r) => setTimeout(r, 500));
    }
    return { acknowledged: false };
  }

  dispose() {
    clearInterval(this.timer);
    rmSync(this.file, { force: true });
    rmSync(this.ackFile, { force: true });
  }
}
