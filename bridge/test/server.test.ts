import { afterEach, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { ToolListChangedNotificationSchema } from "@modelcontextprotocol/sdk/types.js";
import { loadConfig } from "../src/config";
import { EngineClient } from "../src/engine";
import type { Launcher } from "../src/launcher";
import { Bridge } from "../src/server";
import { FakeEngine } from "./fake_engine";

let engine: FakeEngine | null = null;
let engineClient: EngineClient | null = null;

afterEach(() => {
  engineClient?.close();
  engine?.cleanup();
  engine = null;
  engineClient = null;
});

// A launcher that "starts the game" by starting the fake engine.
class FakeLauncher implements Launcher {
  starts = 0;
  stops = 0;
  titles: (string | undefined)[] = [];
  constructor(readonly game: FakeEngine) {}
  async start(title?: string) {
    this.starts++;
    this.titles.push(title);
    this.game.start();
  }
  async stop() {
    this.stops++;
    this.game.stop();
  }
}

async function setup(options: { running: boolean }) {
  engine = new FakeEngine();
  engine.tool("ping", () => "pong");
  if (options.running) {
    engine.start();
  }

  const config = { ...loadConfig({}), socketPath: engine.socketPath, startupTimeoutMs: 3_000 };
  engineClient = new EngineClient(engine.socketPath, 2_000);
  const launcher = new FakeLauncher(engine);
  const bridge = new Bridge(engineClient, launcher, config);

  const client = new Client({ name: "test", version: "1.0.0" });
  let listChanges = 0;
  client.setNotificationHandler(ToolListChangedNotificationSchema, async () => {
    listChanges++;
  });

  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await Promise.all([bridge.server.connect(serverTransport), client.connect(clientTransport)]);

  return { engine, launcher, bridge, client, listChanges: () => listChanges };
}

function names(tools: Array<{ name: string }>): string[] {
  return tools.map((tool) => tool.name);
}

function firstText(result: Awaited<ReturnType<Client["callTool"]>>): string {
  const content = result.content as Array<{ type: string; text?: string }>;
  return content[0]?.text ?? "";
}

test("offers only its own tools while the game isn't running", async () => {
  const { client } = await setup({ running: false });

  const { tools } = await client.listTools();

  expect(names(tools)).toEqual(["launch_game", "quit_game", "reload_lua"]);
});

test("picks up a game that's already running", async () => {
  const { client } = await setup({ running: true });

  const { tools } = await client.listTools();

  expect(names(tools)).toEqual(["launch_game", "quit_game", "reload_lua", "ping"]);
});

test("launch_game starts the game, lists its tools and announces the change", async () => {
  const { client, launcher, listChanges } = await setup({ running: false });

  const result = await client.callTool({ name: "launch_game", arguments: {} });

  expect(result.isError).toBeFalsy();
  expect(firstText(result)).toContain("ping");
  expect(launcher.starts).toBe(1);
  expect(names((await client.listTools()).tools)).toContain("ping");
  await Bun.sleep(10);
  expect(listChanges()).toBe(1);
});

test("launch_game's purpose goes to the window title, on one line", async () => {
  const { client, launcher } = await setup({ running: false });

  await client.callTool({ name: "launch_game", arguments: { purpose: "  Checking what happens when I click\non the world map " } });

  expect(launcher.titles).toEqual(["Checking what happens when I click on the world map"]);
});

test("launch_game without a purpose keeps the configured title", async () => {
  const { client, launcher } = await setup({ running: false });

  await client.callTool({ name: "launch_game", arguments: {} });

  expect(launcher.titles).toEqual([undefined]);
});

test("launch_game leaves a running game alone", async () => {
  const { client, launcher } = await setup({ running: true });

  const result = await client.callTool({ name: "launch_game", arguments: {} });

  expect(firstText(result)).toContain("already running");
  expect(launcher.starts).toBe(0);
});

test("forwards a game tool and keeps its images", async () => {
  const { client, engine } = await setup({ running: true });
  engine.tool("look", () => [
    { type: "text", text: "a cave" },
    { type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" },
  ]);

  const result = await client.callTool({ name: "look", arguments: {} });

  expect(result.isError).toBeFalsy();
  expect(result.content).toEqual([
    { type: "text", text: "a cave" },
    { type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" },
  ]);
  expect(result._meta).toEqual({ access: "fair" });
});

test("reports the game's errors as tool errors the agent can read", async () => {
  const { client, engine } = await setup({ running: true });
  engine.tool("walk_to", () => {
    throw new Error("tile 99999 is off the map");
  });

  const result = await client.callTool({ name: "walk_to", arguments: { tile: 99999 } });

  expect(result.isError).toBe(true);
  expect(firstText(result)).toBe("tile 99999 is off the map");
});

test("tells the agent to launch the game when it isn't running", async () => {
  const { client } = await setup({ running: false });

  const result = await client.callTool({ name: "ping", arguments: {} });

  expect(result.isError).toBe(true);
  expect(firstText(result)).toContain("launch_game");
});

test("reload_lua reloads the game's scripts and announces new tools", async () => {
  const { client, engine, listChanges } = await setup({ running: true });
  await client.listTools();

  engine.tool("look", () => "a cave");
  const result = await client.callTool({ name: "reload_lua", arguments: {} });

  expect(result.isError).toBeFalsy();
  expect(engine.reloads).toBe(1);
  expect(names((await client.listTools()).tools)).toContain("look");
  await Bun.sleep(10);
  expect(listChanges()).toBe(1);
});

test("quit_game stops the game, and its tools say so afterwards", async () => {
  const { client, launcher } = await setup({ running: true });
  await client.listTools();

  await client.callTool({ name: "quit_game", arguments: {} });
  const result = await client.callTool({ name: "ping", arguments: {} });

  expect(launcher.stops).toBe(1);
  expect(result.isError).toBe(true);
  expect(firstText(result)).toContain("launch_game");
});

test("reload_lua stays quiet when the tools didn't change", async () => {
  const { client, listChanges } = await setup({ running: true });
  await client.listTools();

  await client.callTool({ name: "reload_lua", arguments: {} });

  await Bun.sleep(10);
  expect(listChanges()).toBe(0);
});

test("a game tool can't shadow a bridge tool", async () => {
  const { client, engine } = await setup({ running: true });
  engine.tool("quit_game", () => "the game's own quit");
  await client.callTool({ name: "reload_lua", arguments: {} });

  const { tools } = await client.listTools();

  expect(names(tools).filter((name) => name === "quit_game")).toHaveLength(1);
});
