import { afterEach, expect, test } from "bun:test";
import { EngineClient, EngineError, NotConnectedError } from "../src/engine";
import { FakeEngine } from "./fake_engine";

let engine: FakeEngine | null = null;
let client: EngineClient | null = null;

afterEach(() => {
  client?.close();
  engine?.cleanup();
  client = null;
  engine = null;
});

function setup(timeoutMs = 2_000): { engine: FakeEngine; client: EngineClient } {
  engine = new FakeEngine().start();
  client = new EngineClient(engine.socketPath, timeoutMs);
  return { engine, client };
}

test("lists the game's tools", async () => {
  const { engine, client } = setup();
  engine.tool("ping", () => "pong");

  expect(await client.connect()).toBe(true);
  const list = await client.list();

  expect(list.access).toBe("fair");
  expect(list.tools.map((tool) => tool.name)).toEqual(["ping"]);
});

test("forwards a call and returns its content", async () => {
  const { engine, client } = setup();
  engine.tool("echo", (args) => `you said ${args.word}`);

  await client.connect();
  const result = await client.call("echo", { word: "hi" });

  expect(result.content).toEqual([{ type: "text", text: "you said hi" }]);
  expect(engine.requests.at(-1)).toMatchObject({ op: "call", tool: "echo", args: { word: "hi" } });
});

test("sends overlapping calls one at a time, so the game never answers busy", async () => {
  const { engine, client } = setup();
  engine.tool("slow", async () => {
    await Bun.sleep(50);
    return "done";
  });

  await client.connect();
  const results = await Promise.all([client.call("slow", {}), client.call("slow", {}), client.call("slow", {})]);

  expect(results.map((result) => result.content[0]?.text)).toEqual(["done", "done", "done"]);
});

test("waits out a busy game instead of failing", async () => {
  const { engine, client } = setup();
  let first = true;
  engine.tool("flaky", () => {
    if (first) {
      first = false;
      throw new Error("busy: still running walk_to");
    }
    return "ok";
  });

  await client.connect();
  const result = await client.call("flaky", {});

  expect(result.content[0]?.text).toBe("ok");
  expect(engine.requests.filter((request) => request.op === "call")).toHaveLength(2);
});

test("passes the game's error message through", async () => {
  const { engine, client } = setup();
  engine.tool("picky", () => {
    throw new Error("tile 99999 is off the map");
  });

  await client.connect();

  await expect(client.call("picky", {})).rejects.toThrow(new EngineError("tile 99999 is off the map"));
});

test("gives up on a call the game never answers", async () => {
  const { engine, client } = setup(200);
  engine.tool("hang", () => new Promise(() => {}));

  await client.connect();

  await expect(client.call("hang", {})).rejects.toThrow(/didn't answer/);
});

test("says the game isn't running when there's no game", async () => {
  client = new EngineClient("/tmp/fo-bridge-nothing-here.sock", 1_000);

  expect(await client.connect()).toBe(false);
  await expect(client.list()).rejects.toBeInstanceOf(NotConnectedError);
});

test("fails pending calls when the game goes away, and reconnects when it's back", async () => {
  const { engine, client } = setup();
  engine.tool("hang", () => new Promise(() => {}));
  engine.tool("ping", () => "pong");

  let disconnects = 0;
  client.onDisconnect = () => disconnects++;
  await client.connect();

  const pending = client.call("hang", {});
  await Bun.sleep(20);
  engine.stop();

  await expect(pending).rejects.toBeInstanceOf(NotConnectedError);
  expect(disconnects).toBe(1);
  expect(client.connected).toBe(false);

  engine.start();
  expect(await client.connect()).toBe(true);
  expect((await client.call("ping", {})).content[0]?.text).toBe("pong");
});

test("waitForGame connects once the game starts listening", async () => {
  engine = new FakeEngine();
  client = new EngineClient(engine.socketPath, 1_000);

  const started = engine;
  setTimeout(() => started.start(), 300);

  expect(await client.waitForGame(3_000)).toBe(true);
});
