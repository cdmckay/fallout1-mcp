import { existsSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";

// Where the game, its data and its socket are. Everything defaults to this
// repo's layout and can be overridden from the environment.
export interface Config {
  // The user's runtime directory. MCP clients may start the bridge with a
  // trimmed environment, so on Linux it falls back to /run/user/<uid>.
  runtimeDir: string;
  // The game's MCP socket. Its directory is created owner-only.
  socketPath: string;
  // The repo's lua/ directory, which the game loads its tools from.
  luaDir: string;
  // The fallout-ce binary.
  binary: string;
  // The game data: master.dat, critter.dat, data/. The game runs here.
  dataDir: string;
  // Omniscient mode, fixed for the bridge's lifetime so a playing agent
  // can't switch it on.
  omniscient: boolean;
  // Turbo mode, for development: the game runs this many times faster than
  // real time (1 to 16; 1 is normal speed).
  turbo: number;
  // "systemd" runs the game as a transient user unit (Linux); "direct"
  // spawns it as a child process.
  launcher: "systemd" | "direct";
  // The systemd unit name, for the systemd launcher.
  unit: string;
  // What this game is for, added to its window title so games running side by
  // side can be told apart. Defaults to the unit's name without its
  // "fallout1-mcp-" prefix; the plain fallout1-mcp unit gets none.
  title: string | undefined;
  // How long one tool call may take before the bridge gives up on it.
  requestTimeoutMs: number;
  // How long the game may take to start listening after launch.
  startupTimeoutMs: number;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const repo = resolve(import.meta.dir, "../..");
  const runtimeDir = env.XDG_RUNTIME_DIR ?? defaultRuntimeDir();

  const launcher = env.FALLOUT_MCP_LAUNCHER;
  if (launcher !== undefined && launcher !== "systemd" && launcher !== "direct") {
    throw new Error(`FALLOUT_MCP_LAUNCHER must be "systemd" or "direct", not "${launcher}"`);
  }

  const turbo = Number(env.FALLOUT_MCP_TURBO ?? 1);
  if (!Number.isInteger(turbo) || turbo < 1 || turbo > 16) {
    throw new Error(`FALLOUT_MCP_TURBO must be a whole number from 1 to 16, not "${env.FALLOUT_MCP_TURBO}"`);
  }

  const unit = env.FALLOUT_MCP_UNIT ?? "fallout1-mcp";
  const title = env.FALLOUT_MCP_TITLE || (unit === "fallout1-mcp" ? undefined : unit.replace(/^fallout1-mcp-/, ""));

  return {
    runtimeDir,
    socketPath: env.FALLOUT_MCP_SOCKET ?? join(runtimeDir, "fallout1-mcp", "game.sock"),
    luaDir: env.FALLOUT_MCP_LUA ?? join(repo, "lua"),
    binary: env.FALLOUT_BINARY ?? join(repo, "build", "fallout-ce"),
    dataDir: env.FALLOUT_DATA_DIR ?? join(homedir(), ".local", "share", "fallout1-mcp"),
    omniscient: env.FALLOUT_MCP_OMNISCIENT === "1",
    turbo,
    launcher: launcher ?? (process.platform === "linux" && Bun.which("systemd-run") ? "systemd" : "direct"),
    unit,
    title,
    requestTimeoutMs: Number(env.FALLOUT_MCP_TIMEOUT_MS ?? 120_000),
    startupTimeoutMs: Number(env.FALLOUT_MCP_STARTUP_TIMEOUT_MS ?? 60_000),
  };
}

function defaultRuntimeDir(): string {
  const uid = process.getuid?.();
  const candidate = uid === undefined ? null : `/run/user/${uid}`;
  return candidate !== null && existsSync(candidate) ? candidate : tmpdir();
}
