// An encounter on the road, end to end: out of the Vault 13 cave and back
// and forth between Vault 13 and Vault 15 until a random encounter stops a
// trip. travel then says where on the world map it stopped and on what
// ground, and the encounter's map is named after that ground, as the world
// map names it.
//
// Like cave.test.ts it drives the real bridge over stdio against the real
// game, so it runs only when asked:
//
//   FALLOUT_E2E=1 bun test test/e2e
//
// It uses the same unit and socket as cave.test.ts (`FALLOUT_MCP_UNIT` with
// `-e2e` added), one test file after the other. Omniscient mode is only for
// finding the cave's exit. Encounters are random: in play test 4 the road to
// Vault 15 met two, and this gives it ten trips to meet one.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { loadConfig } from "../../src/config";

const enabled = process.env.FALLOUT_E2E === "1";

// Where to save screenshots along the way, if anywhere.
const shots = process.env.FALLOUT_E2E_SHOTS;

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

async function shoot(name: string): Promise<void> {
  if (!shots) {
    return;
  }
  const result = await client.callTool({ name: "look", arguments: {} });
  const content = result.content as Array<{ type: string; data?: string }>;
  const image = content.find((part) => part.type === "image");
  if (image?.data) {
    writeFileSync(join(shots, `${name}.png`), Buffer.from(image.data, "base64"));
  }
}

// Fights whatever attacks, otherwise heads for the cave's world-map exit,
// until the world map is up.
async function leaveTheCave(start: View): Promise<View> {
  let view = start;
  for (let step = 0; step < 120 && view.mode !== "world_map"; step++) {
    if (view.mode === "combat") {
      const combat = view.combat;
      const target = (view.critters ?? []).find((critter: View) => critter.hostile);
      if (combat?.your_turn && target && combat.ap >= combat.attack.ap_cost) {
        view = await call("attack", { target: target.id }).catch(() => call("end_turn"));
      } else {
        view = await call("end_turn");
      }
      continue;
    }

    expect(view.mode).toBe("map");
    const exit = (view.exits ?? []).find((candidate: View) => candidate.to === "the world map");
    expect(exit).toBeDefined();
    view = await call("walk_to", { tile: exit.tile, run: true });
  }
  return view;
}

// The ground's names, as the world map shows them, by terrain.
const GROUND: Record<string, string> = { desert: "Desert", mountain: "Mountains" };

beforeAll(async () => {
  if (!enabled) {
    return;
  }

  const runtimeDir = loadConfig({}).runtimeDir;
  const unit = `${process.env.FALLOUT_MCP_UNIT ?? "fallout1-mcp"}-e2e`;
  client = new Client({ name: "encounter-e2e", version: "1.0.0" });
  await client.connect(
    new StdioClientTransport({
      command: "bun",
      args: [join(import.meta.dir, "../../src/main.ts")],
      stderr: "inherit",
      env: {
        ...(process.env as Record<string, string>),
        FALLOUT_MCP_TURBO: "8",
        FALLOUT_MCP_OMNISCIENT: "1",
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
  "says where an encounter stopped the trip",
  async () => {
    await call("launch_game", { purpose: "e2e: says where an encounter stopped the trip" });

    let view = await call("state");
    for (let i = 0; i < 4 && view.mode === "movie"; i++) {
      view = await call("key", { keys: ["escape"] });
    }
    expect(view.mode).toBe("main_menu");
    view = await call("key", { keys: ["n"] });
    view = await call("key", { keys: ["t"] });
    view = await call("key", { keys: ["escape"] });
    expect(view.mode).toBe("map");

    await call("show_status", { text: "leaving the cave for the world map" });
    view = await leaveTheCave(view);
    expect(view.mode).toBe("world_map");

    const ends = ["Vault 15", "Vault 13"];
    for (let trip = 0; trip < 10 && view.mode === "world_map"; trip++) {
      const to = ends[trip % 2];
      await call("show_status", { text: `travelling to ${to} until an encounter stops the trip` });
      view = await call("travel", { to });
      if (view.travel.result === "arrived") {
        expect(view.travel.position).toBeUndefined();
      }
    }

    expect(["encounter", "special_encounter"]).toContain(view.travel.result);
    await call("show_status", { text: "an encounter stopped the trip" });
    await shoot("encounter");

    // Somewhere on the road between the two vaults, which run east and west
    // along the map's second row.
    const { position, terrain } = view.travel;
    expect(position.x).toBeGreaterThan(16);
    expect(position.x).toBeLessThan(26);
    expect(position.y).toBeGreaterThanOrEqual(1);
    expect(position.y).toBeLessThan(2);
    expect(["desert", "mountain", "city", "coast"]).toContain(terrain);

    // On the encounter's map, named after the ground.
    expect(view.mode).not.toBe("world_map");
    expect(view.player.map.name).toBeTruthy();
    if (view.travel.result === "encounter" && GROUND[terrain] !== undefined) {
      expect(view.player.map.name).toBe(GROUND[terrain]);
    }
  },
  600_000,
);
