// The character sheet, end to end: start a new game with Max Stone, read his
// sheet, level him up, and spend the level-up's perk and skill points, all
// through the real character screen and without the mouse.
//
// Like cave.test.ts it drives the real bridge over stdio against the real
// game, so it runs only when asked:
//
//   FALLOUT_E2E=1 bun test test/e2e
//
// It uses the same unit and socket as cave.test.ts (`FALLOUT_MCP_UNIT` with
// `-e2e` added), one test file after the other. Omniscient mode is for
// give_xp: the cave's rats aren't worth a level.

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

function skill(sheet: View, name: string): View {
  return sheet.skills.find((entry: View) => entry.name === name);
}

beforeAll(async () => {
  if (!enabled) {
    return;
  }

  const runtimeDir = loadConfig({}).runtimeDir;
  const unit = `${process.env.FALLOUT_MCP_UNIT ?? "fallout1-mcp"}-e2e`;
  client = new Client({ name: "character-e2e", version: "1.0.0" });
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
  "reads Max Stone's sheet and spends a level-up without the mouse",
  async () => {
    await call("launch_game", { purpose: "e2e: reads Max Stone's sheet and spends a level-up without the mouse" });

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

    // The first play test's question: why 6 AP with Agility 7? Bruiser.
    let sheet = await call("character");
    expect(sheet.name).toBe("Max Stone");
    expect(sheet.level).toBe(1);
    expect(sheet.next_level_xp).toBe(1000);
    expect(sheet.special.agility).toBe(7);
    expect(sheet.derived.action_points).toBe(6);
    const bruiser = sheet.traits.find((trait: View) => trait.name === "Bruiser");
    expect(bruiser.effect).toContain("-2 action points");
    expect(sheet.skills).toHaveLength(18);
    expect(sheet.skills.filter((entry: View) => entry.tagged)).toHaveLength(3);
    expect(sheet.perk_to_choose).toBeUndefined();

    // The character screen opens with c and shows the same sheet.
    view = await call("key", { keys: ["c"] });
    expect(view.mode).toBe("character");
    expect(view.character.derived.action_points).toBe(6);
    view = await call("key", { keys: ["escape"] });
    expect(view.mode).toBe("map");

    // Level 3 brings a perk and two levels' skill points.
    view = await call("give_xp", { amount: 3000 });
    expect(view.character.level).toBe(3);
    expect(view.player.unspent.perk).toBe(true);
    const points = view.player.unspent.skill_points;
    expect(points).toBeGreaterThan(sheet.skill_points);
    const offered = view.character.perk_to_choose.options;
    expect(offered.length).toBeGreaterThan(1);

    // The last perk on the list, so choosing walks the whole list.
    const perk = offered[offered.length - 1].name;
    view = await call("choose_perk", { name: perk });
    expect(view.mode).toBe("map");
    expect(view.chosen).toBe(perk);
    expect(view.character.perks.map((entry: View) => entry.name)).toContain(perk);
    expect(view.character.perk_to_choose).toBeUndefined();
    expect(view.character.skill_points).toBe(points);

    // Small Guns is tagged, so 5 points raise it 10%; Lockpick isn't.
    const smallGuns = skill(view.character, "Small Guns");
    expect(smallGuns.tagged).toBe(true);
    view = await call("raise_skill", { skill: "Small Guns", points: 5 });
    expect(view.mode).toBe("map");
    expect(view.raised).toEqual({ skill: "Small Guns", from: smallGuns.percent, to: smallGuns.percent + 10, points: 5 });

    const lockpick = skill(view.character, "Lockpick");
    view = await call("raise_skill", { skill: "Lockpick", points: 3 });
    expect(view.raised.to).toBe(lockpick.percent + 3);
    expect(view.character.skill_points).toBe(points - 8);

    // What was spent stays spent: the character screen shows it too.
    sheet = await call("character");
    expect(skill(sheet, "Small Guns").percent).toBe(smallGuns.percent + 10);
    expect(skill(sheet, "Lockpick").percent).toBe(lockpick.percent + 3);
    view = await call("key", { keys: ["c"] });
    expect(view.mode).toBe("character");
    expect(skill(view.character, "Lockpick").percent).toBe(lockpick.percent + 3);
    expect(view.character.skill_points).toBe(points - 8);
    view = await call("key", { keys: ["escape"] });
    expect(view.mode).toBe("map");
  },
  180_000,
);
