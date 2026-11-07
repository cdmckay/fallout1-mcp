// Resting, end to end: out of the Vault 13 cave, onto open ground off the
// world map, and rest through the Pip-Boy's alarm clock without picking its
// codes: until healed, for some hours, and with poison cutting a rest short.
//
// Like cave.test.ts it drives the real bridge over stdio against the real
// game, so it runs only when asked:
//
//   FALLOUT_E2E=1 bun test test/e2e
//
// It uses the same unit and socket as cave.test.ts (`FALLOUT_MCP_UNIT` with
// `-e2e` added), one test file after the other. Omniscient mode is for
// finding the cave's exit, and for hurt, which hurts and poisons Max on cue.
// God mode stays off: it would stop the hurt.

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

beforeAll(async () => {
  if (!enabled) {
    return;
  }

  const runtimeDir = loadConfig({}).runtimeDir;
  const unit = `${process.env.FALLOUT_MCP_UNIT ?? "fallout1-mcp"}-e2e`;
  client = new Client({ name: "rest-e2e", version: "1.0.0" });
  await client.connect(
    new StdioClientTransport({
      command: "bun",
      args: [join(import.meta.dir, "../../src/main.ts")],
      stderr: "inherit",
      env: {
        ...(process.env as Record<string, string>),
        FALLOUT_MCP_TURBO: "8",
        FALLOUT_MCP_OMNISCIENT: "1",
        FALLOUT_MCP_GOD: "0",
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
  "rests through the alarm clock without picking its codes",
  async () => {
    await call("launch_game", { purpose: "e2e: rests through the alarm clock without picking its codes" });

    let view = await call("state");
    for (let i = 0; i < 4 && view.mode === "movie"; i++) {
      view = await call("key", { keys: ["escape"] });
    }
    expect(view.mode).toBe("main_menu");
    view = await call("key", { keys: ["n"] });
    view = await call("key", { keys: ["t"] });
    view = await call("key", { keys: ["escape"] });
    expect(view.mode).toBe("map");
    expect(view.player.conditions).toBeUndefined();

    // The cave's rats aren't on Max's side, so the game won't let him rest.
    await call("show_status", { text: "trying to rest in the cave, where the rats are: the game refuses" });
    await expect(call("rest", { hours: 1 })).rejects.toThrow("You cannot rest at this location!");

    await call("show_status", { text: "leaving the cave for the world map" });
    view = await leaveTheCave(view);
    expect(view.mode).toBe("world_map");

    // Just past the east edge of Vault 13's square, onto open mountains. The
    // map rolls for an encounter once a day of travel, and never in a town's
    // square, so a hop this short (under a day) meets none.
    await call("show_status", { text: "stepping out of Vault 13's square onto open ground" });
    view = await call("travel", { x: 17.04, y: view.world_map.position.y });
    expect(view.travel.result).toBe("arrived");
    expect(view.world_map.here).toBe("Mountains");

    // Open ground has no name of its own; it takes the ground's.
    view = await call("enter");
    expect(view.mode).toBe("map");
    expect(view.player.map.name).toBe("Mountains");

    // The rats may have bitten him on the way out.
    await call("show_status", { text: "hurting Max by 20 HP, then resting until healed" });
    const { hp, max_hp: maxHp } = view.player;
    view = await call("hurt", { hp: 20 });
    expect(view.player.hp).toBe(hp - 20);
    const setOff = view.player.date;
    view = await call("rest", { until: "healed" });
    expect(view.mode).toBe("map");
    expect(view.rest.result).toBe("rested");
    expect(view.rest.hp_gained).toBe(maxHp - hp + 20);
    expect(view.rest.hours).toBeGreaterThan(0);
    expect(view.player.hp).toBe(maxHp);
    expect(view.player.date).not.toEqual(setOff);

    await call("show_status", { text: "resting two hours" });
    view = await call("rest", { hours: 2 });
    expect(view.mode).toBe("map");
    expect(view.rest).toEqual({ hours: 2, hp_gained: 0, result: "rested" });

    // At 6 HP, poison's first tick takes him to 5, and the game stops a rest
    // when poison leaves 5 HP or less.
    await call("show_status", { text: "poisoning Max at 6 HP: the poison cuts his rest short" });
    view = await call("hurt", { hp: view.player.hp - 6, poison: 10 });
    expect(view.player.hp).toBe(6);
    expect(view.player.conditions).toEqual(["poisoned"]);
    await shoot("poisoned");
    view = await call("rest", { hours: 6 });
    expect(view.mode).toBe("map");
    expect(view.rest.result).toBe("interrupted");
    expect(view.rest.hours).toBeLessThan(6);
    expect(view.rest.hp_gained).toBe(-1);
    expect(view.note).toContain("cut the rest short");
    expect(view.messages).toContain("You take damage from poison.");
    expect(view.player.conditions).toEqual(["poisoned"]);
  },
  240_000,
);
