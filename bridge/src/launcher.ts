import { existsSync, readdirSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import type { Subprocess } from "bun";
import type { Config } from "./config";

// Starts and stops the game.
export interface Launcher {
  start(): Promise<void>;
  stop(): Promise<void>;
}

export function createLauncher(config: Config): Launcher {
  return config.launcher === "systemd" ? new SystemdLauncher(config) : new DirectLauncher(config);
}

// The environment that turns MCP on in the game.
function mcpEnvironment(config: Config): Record<string, string> {
  const env: Record<string, string> = {
    FALLOUT_MCP_SOCKET: config.socketPath,
    FALLOUT_MCP_LUA: config.luaDir,
  };
  if (config.omniscient) {
    env.FALLOUT_MCP_OMNISCIENT = "1";
  }
  if (config.turbo > 1) {
    env.FALLOUT_MCP_TURBO = String(config.turbo);
  }
  return env;
}

// Catches the usual setup mistakes with a message that says what to fix.
async function prepare(config: Config): Promise<void> {
  if (!existsSync(config.binary)) {
    throw new Error(`No game binary at ${config.binary}. Build it (see CLAUDE.md) or set FALLOUT_BINARY.`);
  }

  if (!existsSync(config.dataDir)) {
    throw new Error(`No game data at ${config.dataDir}. Copy a Fallout install there or set FALLOUT_DATA_DIR.`);
  }

  const files = readdirSync(config.dataDir).map((name) => name.toLowerCase());
  if (!files.includes("master.dat")) {
    throw new Error(`${config.dataDir} has no master.dat; it doesn't look like a Fallout install.`);
  }

  // The socket's directory is what keeps other users out.
  await mkdir(dirname(config.socketPath), { recursive: true, mode: 0o700 });
}

async function run(command: string[], env: Record<string, string | undefined> = process.env): Promise<{ code: number; output: string }> {
  const proc = Bun.spawn(command, { env, stdout: "pipe", stderr: "pipe" });
  const [code, stdout, stderr] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  return { code, output: (stdout + stderr).trim() };
}

// Runs the game as a transient systemd user unit. On mango that puts it in
// the GNOME session rather than inside Claude Desktop's sandbox, and it
// outlives the bridge.
class SystemdLauncher implements Launcher {
  // systemctl --user finds the user's bus through these, which an MCP
  // client's trimmed environment may lack.
  readonly #env: Record<string, string | undefined>;

  constructor(readonly config: Config) {
    this.#env = {
      ...process.env,
      XDG_RUNTIME_DIR: config.runtimeDir,
      DBUS_SESSION_BUS_ADDRESS: process.env.DBUS_SESSION_BUS_ADDRESS ?? `unix:path=${config.runtimeDir}/bus`,
    };
  }

  async start(): Promise<void> {
    await prepare(this.config);

    const { unit } = this.config;
    if ((await run(["systemctl", "--user", "is-active", "--quiet", unit], this.#env)).code === 0) {
      throw new Error(`The ${unit} unit is already running, but its game isn't answering on ${this.config.socketPath}. Stop it with quit_game first.`);
    }

    const setenv = Object.entries(mcpEnvironment(this.config)).map(([key, value]) => `--setenv=${key}=${value}`);
    const { code, output } = await run(
      ["systemd-run", "--user", `--unit=${unit}`, "--collect", `--working-directory=${this.config.dataDir}`, ...setenv, "--", this.config.binary],
      this.#env,
    );

    if (code !== 0) {
      throw new Error(`systemd-run failed: ${output}`);
    }
  }

  async stop(): Promise<void> {
    await run(["systemctl", "--user", "stop", this.config.unit], this.#env);
  }
}

// Runs the game as a child of the bridge, for platforms without systemd.
class DirectLauncher implements Launcher {
  #process: Subprocess | null = null;

  constructor(readonly config: Config) {}

  async start(): Promise<void> {
    await prepare(this.config);

    if (this.#process !== null && this.#process.exitCode === null) {
      throw new Error("The game the bridge started is still running. Stop it with quit_game first.");
    }

    // The game's log goes to the bridge's stderr, which MCP clients keep.
    this.#process = Bun.spawn([this.config.binary], {
      cwd: this.config.dataDir,
      env: { ...process.env, ...mcpEnvironment(this.config) },
      stdin: "ignore",
      stdout: "ignore",
      stderr: "inherit",
    });
  }

  async stop(): Promise<void> {
    const proc = this.#process;
    if (proc !== null && proc.exitCode === null) {
      proc.kill();
      await proc.exited;
    }
    this.#process = null;
  }
}
