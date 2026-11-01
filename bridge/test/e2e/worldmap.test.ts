// The world map, end to end: out of the Vault 13 cave onto the world map,
// read where you are and the places you know, travel, and go back in, all
// without the mouse. Then a long trip east to Vault 15, which a random
// encounter may cut short.
//
// Like cave.test.ts it drives the real bridge over stdio against the real
// game, so it runs only when asked:
//
//   FALLOUT_E2E=1 bun test test/e2e
//
// It uses the same unit and socket as cave.test.ts (`FALLOUT_MCP_UNIT` with
// `-e2e` added), one test file after the other. Omniscient mode is only for
// finding the cave's exit.

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

function place(view: View, name: string): View {
  return view.world_map.places.find((entry: View) => entry.name === name);
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

beforeAll(async () => {
  if (!enabled) {
    return;
  }

  const runtimeDir = loadConfig({}).runtimeDir;
  const unit = `${process.env.FALLOUT_MCP_UNIT ?? "fallout1-mcp"}-e2e`;
  client = new Client({ name: "worldmap-e2e", version: "1.0.0" });
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
  "travels the world map and goes in without the mouse",
  async () => {
    await call("launch_game", { purpose: "e2e: travels the world map and goes in without the mouse" });

    // The Interplay logo, then the intro.
    let view = await call("state");
    for (let i = 0; i < 4 && view.mode === "movie"; i++) {
      expect(view.hint).toContain("two escapes");
      view = await call("key", { keys: ["escape"] });
    }
    expect(view.mode).toBe("main_menu");

    view = await call("key", { keys: ["n"] });
    view = await call("key", { keys: ["t"] });

    // The Overseer's briefing takes one escape.
    expect(view.mode).toBe("movie");
    view = await call("key", { keys: ["escape"] });
    expect(view.mode).toBe("map");

    await call("show_status", { text: "leaving the cave for the world map" });
    view = await leaveTheCave(view);
    expect(view.mode).toBe("world_map");
    // Walking onto the exit counts as arriving.
    expect(view.walk.arrived).toBe(true);

    // Where you are, and the places the map's list names.
    expect(view.hint).toContain("travel");
    expect(view.hint).toContain("enter");
    expect(view.player.map).toBeUndefined();
    expect(view.player.date.year).toBe(2161);
    expect(view.world_map.here).toBe("Vault 13");
    expect(view.world_map.can_enter).toBe(true);
    expect(place(view, "Vault 13").here).toBe(true);
    expect(place(view, "Vault 15").direction).toBe("e");
    expect(place(view, "Vault 15").distance).toBeGreaterThan(8);

    // A short trip that stays in Vault 13's square, where no encounter can
    // happen.
    await call("show_status", { text: "a short trip north-east, staying near Vault 13" });
    const start = view.world_map.position;
    const setOff = view.player.date;
    view = await call("travel", { x: start.x + 0.3, y: start.y - 0.3 });
    expect(view.travel.result).toBe("arrived");
    expect(view.travel.hours).toBeGreaterThan(0);
    expect(view.world_map.position.x).toBeCloseTo(start.x + 0.3);
    expect(view.world_map.position.y).toBeCloseTo(start.y - 0.3);
    expect(view.player.date).not.toEqual(setOff);

    view = await call("travel", { to: "Vault 13" });
    expect(view.travel.result).toBe("arrived");
    expect(view.note).toContain("enter goes in");

    // Back in through the town map. The cave is known from the start; the
    // vault itself only after the first day.
    await call("show_status", { text: "going back into the cave through Vault 13's town map" });
    view = await call("enter", { place: "Cavern Entrance" });
    expect(view.mode).toBe("map");
    expect(view.entered).toBe("Cavern Entrance");
    expect(view.player.map.name).toBe("Vault 13");

    // Out again, and east to Vault 15.
    await call("show_status", { text: "out of the cave again" });
    view = await leaveTheCave(view);
    expect(view.mode).toBe("world_map");

    await call("show_status", { text: "travelling east to Vault 15: an encounter may stop the trip" });

    view = await call("travel", { to: "Vault 15" });
    expect(["arrived", "encounter", "special_encounter"]).toContain(view.travel.result);
    expect(view.travel.hours).toBeGreaterThan(0);

    if (view.travel.result === "arrived") {
      expect(view.world_map.here).toBe("Vault 15");
      view = await call("enter");
      if (view.mode === "town_map") {
        view = await call("enter", { place: view.town_map.places[0] });
      }
      expect(view.mode).toBe("map");
      expect(view.entered).toBeDefined();
    } else {
      // On the encounter's map, with whatever was met.
      expect(view.mode).not.toBe("world_map");
      expect(view.world_map).toBeUndefined();
      expect(view.note).toContain("encounter");
    }
  },
  240_000,
);
