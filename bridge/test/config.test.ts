import { expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { loadConfig } from "../src/config";

test("defaults follow the repo layout", () => {
  const config = loadConfig({ XDG_RUNTIME_DIR: "/run/user/1234" });

  expect(config.socketPath).toBe("/run/user/1234/fallout1-mcp/game.sock");
  expect(config.luaDir).toMatch(/\/lua$/);
  expect(config.binary).toMatch(/\/build\/fallout-ce$/);
  expect(config.omniscient).toBe(false);
});

test("the environment overrides every default", () => {
  const config = loadConfig({
    FALLOUT_MCP_SOCKET: "/tmp/x.sock",
    FALLOUT_MCP_LUA: "/opt/lua",
    FALLOUT_BINARY: "/opt/fallout-ce",
    FALLOUT_DATA_DIR: "/games/fallout",
    FALLOUT_MCP_OMNISCIENT: "1",
    FALLOUT_MCP_LAUNCHER: "direct",
    FALLOUT_MCP_TIMEOUT_MS: "5000",
  });

  expect(config).toMatchObject({
    socketPath: "/tmp/x.sock",
    luaDir: "/opt/lua",
    binary: "/opt/fallout-ce",
    dataDir: "/games/fallout",
    omniscient: true,
    launcher: "direct",
    requestTimeoutMs: 5000,
  });
});

test("omniscient mode needs exactly 1", () => {
  expect(loadConfig({ FALLOUT_MCP_OMNISCIENT: "true" }).omniscient).toBe(false);
});

test("a missing XDG_RUNTIME_DIR falls back to the user's runtime directory", () => {
  const config = loadConfig({});
  const expected = `/run/user/${process.getuid?.()}`;

  if (existsSync(expected)) {
    expect(config.runtimeDir).toBe(expected);
  }
  expect(config.socketPath.startsWith(config.runtimeDir)).toBe(true);
});

test("turbo defaults to normal speed and accepts 1 to 16", () => {
  expect(loadConfig({}).turbo).toBe(1);
  expect(loadConfig({ FALLOUT_MCP_TURBO: "8" }).turbo).toBe(8);
  expect(() => loadConfig({ FALLOUT_MCP_TURBO: "0" })).toThrow(/1 to 16/);
  expect(() => loadConfig({ FALLOUT_MCP_TURBO: "17" })).toThrow(/1 to 16/);
  expect(() => loadConfig({ FALLOUT_MCP_TURBO: "fast" })).toThrow(/1 to 16/);
});

test("the window title's label comes from the unit unless given", () => {
  expect(loadConfig({}).title).toBeUndefined();
  expect(loadConfig({ FALLOUT_MCP_UNIT: "fallout1-mcp-walking" }).title).toBe("walking");
  expect(loadConfig({ FALLOUT_MCP_UNIT: "fallout1-mcp-walking-e2e" }).title).toBe("walking-e2e");
  expect(loadConfig({ FALLOUT_MCP_UNIT: "my-game" }).title).toBe("my-game");
  expect(loadConfig({ FALLOUT_MCP_TITLE: "play test 3" }).title).toBe("play test 3");
});

test("god mode needs exactly 1", () => {
  expect(loadConfig({}).god).toBe(false);
  expect(loadConfig({ FALLOUT_MCP_GOD: "1" }).god).toBe(true);
  expect(loadConfig({ FALLOUT_MCP_GOD: "yes" }).god).toBe(false);
});

test("an unknown launcher is rejected", () => {
  expect(() => loadConfig({ FALLOUT_MCP_LAUNCHER: "docker" })).toThrow(/systemd.*direct/);
});
