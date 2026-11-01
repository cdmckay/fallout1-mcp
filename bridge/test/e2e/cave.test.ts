// The first slice, end to end: from Claude Code's side of the bridge, launch
// the game, start a new game with the premade character, and get out of the
// Vault 13 cave to the world map, fighting the rats on the way, all without
// the mouse. Before that, a shorter case walks into the rats and checks the
// fight starts on the player's turn with full AP. The rats show as hostile
// before any fight, and each one takes a single attack call (#19).
//
// It drives the real bridge over stdio against the real game, so it needs a
// built game and the game data, and runs only when asked:
//
//   FALLOUT_E2E=1 bun test test/e2e
//
// The game runs at turbo 8, on its own systemd unit and socket so it never
// touches a game you're playing. They're named after `FALLOUT_MCP_UNIT` with
// `-e2e` added, so worktrees that each run their own game can run this at the
// same time. It uses omniscient mode for one thing: to know where the cave's
// exit is, rather than exploring for it.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { loadConfig } from "../../src/config";

const enabled = process.env.FALLOUT_E2E === "1";

// biome-ignore lint: the view is whatever JSON the game sends
type View = any;

let client: Client;

async function callContent(name: string, args: Record<string, unknown> = {}): Promise<Array<{ type: string; text?: string }>> {
  const result = await client.callTool({ name, arguments: args });
  const content = result.content as Array<{ type: string; text?: string }>;
  if (result.isError) {
    throw new Error(`${name} failed: ${content[0]?.text ?? ""}`);
  }
  return content;
}

async function call(name: string, args: Record<string, unknown> = {}): Promise<View> {
  const text = (await callContent(name, args))[0]?.text ?? "";
  return text.startsWith("{") ? JSON.parse(text) : text;
}

beforeAll(async () => {
  if (!enabled) {
    return;
  }

  const runtimeDir = loadConfig({}).runtimeDir;
  const unit = `${process.env.FALLOUT_MCP_UNIT ?? "fallout1-mcp"}-e2e`;
  client = new Client({ name: "cave-e2e", version: "1.0.0" });
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

// Starts the game afresh and a new game with the premade character, which
// begins in the Vault 13 cave. The window title says `what` the test checks.
async function newGame(what: string): Promise<View> {
  await call("quit_game").catch(() => {});
  const launched = await call("launch_game", { purpose: `e2e: ${what}` });
  expect(launched).toContain("omniscient mode");
  expect((await call("ping")).turbo).toBe(8);

  // Skip the opening movies until the main menu is up.
  let view = await call("state");
  for (let i = 0; i < 4 && view.mode === "movie"; i++) {
    view = await call("key", { keys: ["escape"] });
  }
  expect(view.mode).toBe("main_menu");

  view = await call("key", { keys: ["n"] });
  expect(view.mode).toBe("character_select");

  view = await call("key", { keys: ["t"] });
  for (let i = 0; i < 4 && view.mode === "movie"; i++) {
    view = await call("key", { keys: ["escape"] });
  }
  expect(view.mode).toBe("map");
  expect(view.player.name).toBe("Max Stone");
  expect(view.player.map.name).toBe("Vault 13");
  expect(view.player.hp).toBe(view.player.max_hp);
  return view;
}

// Every walk explains itself: it arrived, or says what stopped it.
function expectExplained(view: View) {
  expect(view.walk).toBeDefined();
  if (!view.walk.arrived) {
    expect(view.walk.stopped_by).toBeDefined();
  }
}

test.skipIf(!enabled)(
  "walks into the cave rats and gets its turn with full AP",
  async () => {
    let view = await newGame("walks into the cave rats and gets its turn with full AP");

    // East along the cave, where the play test's walk ran into the rats,
    // then straight at the nearest rat until one starts a fight.
    view = await call("walk_to", { direction: "e", distance: 20 });
    expectExplained(view);
    for (let step = 0; step < 20 && view.mode !== "combat"; step++) {
      const rat = (view.critters ?? []).find((critter: View) => critter.screen);
      // Rats attack on sight, and the list says so before they do.
      if (rat) {
        expect(rat.hostile).toBe(true);
      }
      view = rat ? await call("walk_to", { x: rat.screen.x, y: rat.screen.y }) : await call("walk_to", { direction: "e", distance: 10 });
      expectExplained(view);
    }

    expect(view.mode).toBe("combat");
    expect(view.walk.stopped_by).toBe("a fight started");
    expect(view.combat.your_turn).toBe(true);
    expect(view.combat.ap).toBe(view.combat.max_ap);
  },
  180_000,
);

test.skipIf(!enabled)(
  "leaves the Vault 13 cave without the mouse",
  async () => {
    let view = await newGame("leaves the Vault 13 cave without the mouse");

    // The text map: the player among the cave's walls and floor, and each
    // critter on it keyed to one in the critter list.
    const looked = await callContent("look", { screenshot: false });
    expect(looked.map((part) => part.type)).toEqual(["text", "text"]);
    const map = looked[1]?.text ?? "";
    expect(map).toContain("@");
    expect(map).toMatch(/# \./);
    const listed = new Set((JSON.parse(looked[0]?.text ?? "{}").critters ?? []).map((critter: View) => critter.id));
    for (const [, id] of map.matchAll(/^[a-z]: .*, id (\d+)$/gm)) {
      expect(listed.has(Number(id))).toBe(true);
    }

    // Fight whatever attacks, nearest first; otherwise head for the world-map
    // exit. Each attack keeps at its rat across turns until it's dead, unless
    // something comes up that it stops for, and says which.
    let attacks = 0;
    let combatCalls = 0;
    let kills = 0;
    const hits: string[] = [];
    for (let step = 0; step < 120 && view.mode !== "world_map"; step++) {
      hits.push(...(view.messages ?? []).filter((line: string) => /\bYou were (critically )?hit\b/.test(line)));
      if (view.mode === "combat") {
        combatCalls++;
        const target = (view.critters ?? []).find((critter: View) => critter.hostile);
        if (view.combat?.your_turn && target) {
          await call("show_status", { text: `one attack call on rat ${target.id}: it should fight on until the rat dies` });
          view = await call("attack", { target: target.id });
          attacks++;
          expect(view.attacks.target_dead || view.attacks.stopped_by !== undefined).toBe(true);
          if (view.attacks.target_dead) {
            kills++;
          }
        } else {
          view = await call("end_turn");
        }
        continue;
      }

      expect(view.mode).toBe("map");
      const exit = (view.exits ?? []).find((candidate: View) => candidate.to === "the world map");
      expect(exit).toBeDefined();
      view = await call("walk_to", { tile: exit.tile, run: true });
      expectExplained(view);
    }

    expect(view.mode).toBe("world_map");
    expect(view.player.hp).toBeGreaterThan(0);
    // The cave has rats; getting out means having dealt with some.
    console.log(`cave fight: ${attacks} attack calls and ${combatCalls} calls in combat for ${kills} rats`);
    expect(kills).toBeGreaterThan(0);
    // Before #19 a rat cost an attack and an end_turn per swing, 6 to 11
    // calls for the 3 rats on the way out; now it's one call each, give or
    // take one that stopped for something.
    expect(combatCalls).toBeLessThanOrEqual(kills + 2);
    // Damage taken names the rat that did it.
    for (const line of hits) {
      expect(line).toMatch(/^\[[A-Za-z ]*Rat, id \d+\] /);
    }
  },
  180_000,
);
