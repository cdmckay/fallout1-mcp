// Objects on the map, end to end: in the Vault 13 cave, loot the bones by
// the vault door one item at a time and then everything, fight a rat, and
// loot its body, all without the mouse and in fair play, seeing only what a
// player sees.
//
// Like cave.test.ts it drives the real bridge over stdio against the real
// game, so it runs only when asked:
//
//   FALLOUT_E2E=1 bun test test/e2e
//
// It uses the same unit and socket as the other e2e tests (`FALLOUT_MCP_UNIT`
// with `-e2e` added), one test file after the other. God mode keeps the rat
// fight short and the player alive: the fight isn't what's being tested.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { loadConfig } from "../../src/config";

const enabled = process.env.FALLOUT_E2E === "1";

// biome-ignore lint: the view is whatever JSON the game sends
type View = any;

let client: Client;

async function call(name: string, args: Record<string, unknown> = {}): Promise<View> {
  const result = await client.callTool({ name, arguments: args });
  const content = result.content as Array<{ type: string; text?: string }>;
  const text = content[0]?.text ?? "";
  if (result.isError) {
    throw new Error(`${name} failed: ${text}`);
  }
  return text.startsWith("{") ? JSON.parse(text) : text;
}

function find(list: View[] | undefined, predicate: (entry: View) => boolean): View {
  return (list ?? []).find(predicate);
}

beforeAll(async () => {
  if (!enabled) {
    return;
  }

  const runtimeDir = loadConfig({}).runtimeDir;
  const unit = `${process.env.FALLOUT_MCP_UNIT ?? "fallout1-mcp"}-e2e`;
  client = new Client({ name: "objects-e2e", version: "1.0.0" });
  await client.connect(
    new StdioClientTransport({
      command: "bun",
      args: [join(import.meta.dir, "../../src/main.ts")],
      stderr: "inherit",
      env: {
        ...(process.env as Record<string, string>),
        FALLOUT_MCP_TURBO: "8",
        FALLOUT_MCP_OMNISCIENT: "0",
        FALLOUT_MCP_GOD: "1",
        FALLOUT_MCP_UNIT: unit,
        FALLOUT_MCP_SOCKET: join(runtimeDir, "fallout1-mcp", `${unit}.sock`),
      },
    }),
  );
});

afterAll(async () => {
  if (!enabled) {
    return;
  }
  await call("quit_game").catch(() => {});
  await client.close();
});

test.skipIf(!enabled)(
  "loots the bones and a rat's body in the Vault 13 cave without the mouse",
  async () => {
    await call("quit_game").catch(() => {});
    const launched = await call("launch_game", { purpose: "e2e: loots the bones and a rat's body in the Vault 13 cave without the mouse" });
    expect(launched).toContain("fair mode, god mode");

    let view = await call("state");
    for (let i = 0; i < 4 && view.mode === "movie"; i++) {
      view = await call("key", { keys: ["escape"] });
    }
    view = await call("key", { keys: ["n"] });
    view = await call("key", { keys: ["t"] });
    for (let i = 0; i < 4 && view.mode === "movie"; i++) {
      view = await call("key", { keys: ["escape"] });
    }
    expect(view.mode).toBe("map");

    // The bones lie two hexes from where the game starts, by the vault door.
    await call("show_status", { text: "looting the bones by the vault door, the knife first" });
    const bones = find(view.objects, (object) => object.name === "Bones");
    expect(bones.kind).toBe("container");
    expect(bones.actions).toEqual(["loot"]);
    expect(find(view.objects, (object) => object.kind === "door")).toBeDefined();

    view = await call("loot", { target: bones.id });
    expect(view.mode).toBe("loot");
    expect(view.loot.from.id).toBe(bones.id);
    const knife = find(view.loot.items, (item) => item.name === "Knife");
    expect(knife).toBeDefined();
    const others = view.loot.items.length - 1;

    view = await call("take", { items: [knife.id] });
    expect(view.mode).toBe("loot");
    expect(view.taken).toEqual([{ name: "Knife", quantity: 1 }]);
    expect(view.loot.items.length).toBe(others);

    view = await call("take", { all: true, close: true });
    expect(view.mode).toBe("map");
    expect(view.taken.length).toBe(others);

    // Into the rats, and fight until one of them is a body.
    await call("show_status", { text: "fighting a cave rat, to loot its body" });
    view = await call("walk_to", { direction: "e", distance: 20 });
    for (let step = 0; step < 20 && view.mode !== "combat"; step++) {
      const rat = find(view.critters, (critter) => critter.screen);
      view = rat ? await call("walk_to", { x: rat.screen.x, y: rat.screen.y }) : await call("walk_to", { direction: "e", distance: 10 });
    }
    expect(view.mode).toBe("combat");

    for (let step = 0; step < 60 && view.mode === "combat"; step++) {
      const combat = view.combat;
      const target = find(view.critters, (critter) => critter.hostile);
      if (combat?.your_turn && target && combat.ap >= combat.attack.ap_cost) {
        view = await call("attack", { target: target.id }).catch(() => call("end_turn"));
      } else {
        view = await call("end_turn");
      }
    }
    expect(view.mode).toBe("map");

    await call("show_status", { text: "looting the dead rat" });
    const body = find(view.objects, (object) => object.kind === "body");
    expect(body).toBeDefined();
    expect(body.actions).toEqual(["loot"]);

    view = await call("loot", { target: body.id });
    expect(view.mode).toBe("loot");
    expect(view.loot.from.id).toBe(body.id);

    view = await call("take", { close: true });
    expect(view.mode).toBe("map");
  },
  240_000,
);
