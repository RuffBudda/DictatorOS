// Process helpers. Commands are always run with execFile/spawn, never through a shell.
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";

const execFileP = promisify(execFile);
export const TIMEOUT_MS = 10_000;

export async function run(cmd, args, { env, encoding = "utf8", timeout = TIMEOUT_MS } = {}) {
  try {
    const { stdout } = await execFileP(cmd, args, {
      timeout, encoding, maxBuffer: 128 * 1024 * 1024,
      env: env ? { ...process.env, ...env } : process.env,
    });
    return stdout;
  } catch (err) {
    const detail = [err.stderr, err.stdout].map((s) => (s ? String(s).trim() : "")).filter(Boolean).join("\n");
    throw new Error(`${cmd} ${args.join(" ")} failed: ${detail || err.message}`);
  }
}

export function writeStdin(cmd, args, input, { env } = {}) {
  return new Promise((resolve, reject) => {
    // wl-copy forks a background server that inherits stdio; ignore stdout/stderr so we only wait for exit.
    const child = spawn(cmd, args, { stdio: ["pipe", "ignore", "ignore"], env: env ? { ...process.env, ...env } : process.env });
    const timer = setTimeout(() => { child.kill(); reject(new Error(`${cmd} timed out`)); }, TIMEOUT_MS);
    child.on("error", (e) => { clearTimeout(timer); reject(e); });
    child.on("exit", (code) => {
      clearTimeout(timer);
      code === 0 ? resolve() : reject(new Error(`${cmd} exited with code ${code}`));
    });
    child.stdin.end(input);
  });
}

/** Start a long-lived process as a transient systemd user unit (survives the MCP client's process cleanup). */
export async function runUnit(unit, argv, env = {}, { slice } = {}) {
  const pass = ["PATH", "HOME", "LANG", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "XCURSOR_THEME", "XCURSOR_SIZE"];
  const args = ["--user", `--unit=${unit}`, "--collect", "--quiet"];
  if (slice) args.push(`--slice=${slice}`);
  for (const k of pass) if (process.env[k] && !(k in env)) args.push("-E", `${k}=${process.env[k]}`);
  for (const [k, v] of Object.entries(env)) args.push("-E", `${k}=${v}`);
  await run("systemd-run", [...args, ...argv]);
}

export async function unitActive(unit) {
  try { return (await run("systemctl", ["--user", "is-active", unit])).trim() === "active"; } catch { return false; }
}

export async function stopUnit(unit) {
  await run("systemctl", ["--user", "stop", unit]).catch(() => {});
}

/** Spawn a detached GUI app (not tied to this process). */
export function spawnDetached(command, env) {
  const child = spawn("sh", ["-c", command], { detached: true, stdio: "ignore", env: { ...process.env, ...env } });
  child.unref();
  return child.pid;
}
