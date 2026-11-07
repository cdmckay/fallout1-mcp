// The inventory, end to end: the premade character's weapons with the
// figures the game itself shows for them, and items named rather than given
// by id (#28, #38).
//
// The figures were checked by hand against the game's own screens for Max
// Stone (ST 10, melee damage 9 from Heavy Handed): the inventory screen's
// "Dmg:" and "Rng:" for a weapon in hand, the interface bar's AP for each
// attack mode as `n` cycles them, and the examine text's "Min ST:" and
// "It has 12/12 shots of 10mm JHP." Here they come from `inventory` with
// nothing equipped, so the agent can choose before it equips.
//
// Like cave.test.ts it drives the real bridge over stdio against the real
// game, so it runs only when asked:
//
//   FALLOUT_E2E=1 bun test test/e2e
//
// It uses the same unit and socket as the other e2e tests (`FALLOUT_MCP_UNIT`
// with `-e2e` added), one test file after the other. God mode keeps the cave
// rats from starting a fight: the fight isn't what's being tested.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { loadConfig } from "../../src/config";

const enabled = process.env.FALLOUT_E2E === "1";

// biome-ignore lint: the view is whatever JSON the game sends
type View = any;

let client: Client;

async function result(name: string, args: Record<string, unknown> = {}): Promise<{ text: string; isError: boolean }> {
  const result = await client.callTool({ name, arguments: args });
  const content = result.content as Array<{ type: string; text?: string }>;
  return { text: content[0]?.text ?? "", isError: result.isError === true };
}

async function call(name: string, args: Record<string, unknown> = {}): Promise<View> {
  const { text, isError } = await result(name, args);
  if (isError) {
    throw new Error(`${name} failed: ${text}`);
  }
  return text.startsWith("{") ? JSON.parse(text) : text;
}

function find(list: View[] | undefined, predicate: (entry: View) => boolean): View {
  return (list ?? []).find(predicate);
}

function carried(inventory: View, name: string): View[] {
  return inventory.items.filter((item: View) => item.name === name);
}

beforeAll(async () => {
  if (!enabled) {
    return;
  }

  const runtimeDir = loadConfig({}).runtimeDir;
  const unit = `${process.env.FALLOUT_MCP_UNIT ?? "fallout1-mcp"}-e2e`;
  client = new Client({ name: "inventory-e2e", version: "1.0.0" });
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
  "lists each weapon's figures and takes items by name",
  async () => {
    await call("quit_game").catch(() => {});
    const launched = await call("launch_game", { purpose: "e2e: lists each weapon's figures and takes items by name" });
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

    await call("show_status", { text: "reading the weapons' damage, range, AP and Strength from the inventory" });
    let inventory = await call("inventory");

    const [knife] = carried(inventory, "Knife");
    expect(knife.slot).toBeUndefined();
    expect(knife.min_strength).toBe(2);
    expect(knife.attacks).toEqual([
      { mode: "primary", attack: "swing", skill: "Melee Weapons", damage_min: 1, damage_max: 15, range: 1, ap_cost: 3, aimed_ap_cost: 4 },
      { mode: "secondary", attack: "thrust", skill: "Melee Weapons", damage_min: 1, damage_max: 15, range: 1, ap_cost: 3, aimed_ap_cost: 4 },
    ]);

    const [knuckles] = carried(inventory, "Brass Knuckles");
    expect(knuckles.min_strength).toBe(1);
    expect(knuckles.attacks).toEqual([
      { mode: "primary", attack: "punch", skill: "Unarmed", damage_min: 2, damage_max: 14, range: 1, ap_cost: 3, aimed_ap_cost: 4 },
    ]);

    const [pistol] = carried(inventory, "10mm Pistol");
    expect(pistol.min_strength).toBe(3);
    expect(pistol.attacks).toEqual([
      { mode: "primary", attack: "single", skill: "Small Guns", damage_min: 5, damage_max: 12, range: 25, ap_cost: 5, aimed_ap_cost: 6 },
    ]);
    expect(pistol.ammo).toEqual({ loaded: 12, capacity: 12, type: "10mm JHP" });

    // The inventory screen's "Unarmed dmg: 1-11" for an empty hand.
    expect(inventory.unarmed).toEqual({ attack: "punch", skill: "Unarmed", damage_min: 1, damage_max: 11, range: 1, ap_cost: 3, aimed_ap_cost: 4 });

    // Stimpaks by name: each one used leaves the rest under a new id, and the
    // name finds them anyway.
    await call("show_status", { text: "using two stimpaks by name, though the stack's id changes each time" });
    const [stimpaks] = carried(inventory, "Stimpak");
    const ids = [stimpaks.id];
    for (let used = 1; used <= 2; used++) {
      view = await call("use_item", { item: "Stimpak" });
      expect(view.used.name).toBe("Stimpak");
      expect(view.used.remaining).toBe(stimpaks.quantity - used);
      ids.push(view.used.id);
    }
    expect(new Set(ids).size).toBe(3);

    await call("show_status", { text: "equipping the knife and the pistol by name" });
    view = await call("equip", { item: "knife", hand: "left" });
    view = await call("equip", { item: "10mm Pistol", hand: "right" });
    expect(view.equipped.left_hand.name).toBe("Knife");
    expect(view.equipped.right_hand.name).toBe("10mm Pistol");

    // The bones by the vault door hold a second knife. With the first in a
    // hand the two don't stack, so "Knife" names two items and needs an id.
    await call("show_status", { text: "taking the knife from the bones, so two items are called Knife" });
    const bones = find(view.objects, (object) => object.name === "Bones");
    view = await call("loot", { target: bones.id });
    const loose = find(view.loot.items, (item) => item.name === "Knife");
    view = await call("take", { items: [loose.id], close: true });
    expect(view.mode).toBe("map");

    inventory = await call("inventory");
    const knives = carried(inventory, "Knife");
    expect(knives.length).toBe(2);

    const refused = await result("equip", { item: "Knife", hand: "right" });
    expect(refused.isError).toBe(true);
    expect(refused.text).toContain('2 items are called "Knife"');
    for (const each of knives) {
      expect(refused.text).toContain(String(each.id));
    }

    const spare = knives.find((each: View) => each.slot === undefined);
    view = await call("equip", { item: spare.id, hand: "right" });
    expect(view.equipped.right_hand.id).toBe(spare.id);
  },
  240_000,
);
