# fallout1-mcp design

Status: the first slice is built (issues #1–#9). The state view, `look`, `key`, `press`, `walk_to`, `attack` and `end_turn` work against the real game, and an end-to-end test leaves the Vault 13 cave without the mouse. The rest of this document is the plan.

## Goal

Let an agent (Claude, through Claude Code) play Fallout end to end. That means seeing the game, understanding what it sees, and acting: walking, talking, fighting, managing inventory and travelling. The person who started it should be able to watch the game window and take over the mouse at any time.

## Shape

```
Claude Code ──MCP over stdio──▶ bridge (TypeScript on bun, official MCP SDK)
                                   │  newline-delimited JSON over a Unix socket
                                   ▼
                          fallout-ce  ─  Lua 5.5 VM  ─  lua/ (tool definitions)
                                   ▲
                          bindings into engine state and input
```

There are three layers, each doing one job:

- **Engine (C++).** It embeds a Lua VM, exposes small bindings into engine state and input, and services a local socket once per frame. It does no MCP and no JSON.
- **Lua (`lua/`).** It defines every tool: its name, description, JSON schema and implementation. It handles the socket protocol and can be reloaded while the game runs, so adding or fixing a tool doesn't need a rebuild.
- **Bridge (`mcp/`).** A generic MCP server. It asks the engine for its tool list, registers those tools, forwards calls, and turns results into MCP content (text, plus PNG images). It also owns the game process: launch, quit and restart.

### Why a separate bridge rather than MCP inside the engine

An in-engine MCP server, over Streamable HTTP, would save a process. It would also need an HTTP server in C++ and the MCP protocol written by hand in Lua. Worse, every game restart or crash would drop the client's connection, and MCP clients recover from that badly. A stdio bridge started by Claude Code outlives the game, can relaunch it, and uses the reference SDK (`@modelcontextprotocol/sdk`, 1.32.2 at the time of writing). bun is already installed on every machine by the nix repo's `core.nix`, so the bridge needs no extra runtime.

## Engine side

### Where commands run: the top of `process_bk()`

Every screen in the game is its own blocking loop nested on the C stack: main menu, character creation, dialog, barter, inventory, Pip-Boy, world map, combat, save/load. They all funnel through `get_input()` (`src/plib/gnw/input.cc:183`), which calls `process_bk()` (`input.cc:214`). `process_bk` is also called directly from the loops that run NPC combat turns (`combat_turn_run`, `combat.cc:2130`) and timed pauses (`pause_for_tocks`). Servicing the socket at the top of `process_bk` therefore reaches every interactive screen.

What it doesn't reach is short: palette fades, animation busy-waits (dialog head transitions, interface bar, world-map travel effects, credits) and movie pre-waits. Commands wait through those, which takes at most a few seconds.

Gaps to close:

- **Focus loss freezes the game.** `get_input` enters `GNW95_lost_focus()` (`input.cc:1206`) when the window isn't focused. That function loops on `GNW95_process_message` until focus returns and never runs `process_bk`. With MCP enabled, skip it and keep audio playing, because the window is usually unfocused while the agent plays.
- **Main menu timeout.** After two minutes idle, the main menu starts the intro or self-running demo (`main_menu_timeout`, `mainmenu.cc:60`). Disable it when MCP is on.
- **Re-entrancy.** A binding must never call into a modal screen directly. If it did, that screen's loop would call `process_bk` again from inside the command. The service hook gets a re-entrancy guard, and anything that opens a screen does it by injecting the key or click the player would use. The game's own loop then runs the screen.

### Long-running commands are Lua coroutines

Almost every action is asynchronous. Walking queues an animation, talking requests a dialog that opens on a later frame, and a combat turn passes through NPC turns. Each request runs as a Lua coroutine. `process_bk` resumes the live coroutine once per frame, and tool code waits with plain calls such as `wait.frames(2)` or `wait.until(idle, 10)`. This keeps "walk there, wait until arrived, return what changed" as straight-line code, without blocking the game. It's also the main reason to put Lua in at all.

Requests are handled one at a time. If a request arrives while a coroutine is still running, it is rejected as busy rather than queued. The bridge queues the agent's calls, so the agent never sees "busy".

### The agent never uses the mouse

Every player action has a path that doesn't read the mouse. If the agent has to click, a tool is missing. Each action takes the first of these routes that works:

1. **Inject the code the game already has.** Most of the UI is GNW `Button`s that emit an event code, and many actions have hotkeys. `GNW_add_input_buffer(code)` (`input.cc:238`) injects either kind, and the screen's own loop then handles it. Raw scancodes go through `kb_simulate_key` (`kb.cc:306`). No engine change is needed.
2. **Call the engine directly for actions on the map.** Walking, using, picking up, talking, looting, skills, items on targets and attacks all have engine functions (`register_object_move_to_tile`, `action_*`, `combat_attack`). An aimed shot passes the hit location straight to `combat_attack`, so the called-shot picker never opens.
3. **Add a command code for mouse-only operations inside a screen.** Examples are dragging an item to a hand slot, moving items onto the barter table, and choosing a free-travel point on the world map. Each gets a new event code (in a range of its own) that the screen's own loop handles, calling the internal function the drag would have called. Arguments travel in a small pending-command struct that Lua fills before injecting the code. Handling the command inside the loop keeps that screen's local state (list offsets, displayed stacks, redraws) consistent. A call from outside the loop would bypass it.

The punch list of route-3 actions comes from a screen-by-screen audit, under "No-mouse punch list" below.

**Deferred calls.** Some engine calls open a screen synchronously, for example a loot animation's callback or a script's dialog request. A coroutine that made such a call would be stuck inside that screen's loop with nobody resuming it. So coroutines never make those calls directly. They `defer(fn)` and yield, and the hook runs deferred functions outside any coroutine. The screen's own loop then calls `process_bk` → the hook again, one level deeper, and that nested hook can resume the waiting coroutine. The re-entrancy guard only stops a coroutine being resumed while one is already running.

### Raw mouse (omniscient mode only)

A virtual pointer in `dxinput.cc` backs `click` and `move_mouse` for debugging. While it is active, `dxinput_get_mouse_state` reports the virtual position and buttons instead of SDL's. A click takes several frames: move, press, release, each a frame apart, because the game computes button edges between frames in `mouse_simulate_input`. Moving the real mouse takes control back. Coordinates match the screenshots' logical 1024×768, whatever the window's scale.

### Bindings and engine shims

Most of the state the agent needs is in file-`static` variables, so the engine needs small accessor functions alongside the code it reads:

- dialog: `dialogBlock` and `gdNumOptions`;
- combat: `combat_list`, `combat_turn_running` and `combat_state`;
- world map: `wwin_flag` and `world_xpos`/`world_ypos`;
- the window ids of the inventory, barter, loot and Pip-Boy screens;
- the message log, `disp_str` (`display.cc:59`);
- pending script requests;
- save/load: `SaveSlot`/`LoadSlot`.

The bindings themselves live in new files under `src/mcp/`. Each change to an upstream file stays small and is marked `// MCP:`, so merging upstream stays easy.

Screenshots come from `gSdlTextureSurface` (`svga.cc`). It is already RGB888, with palette and gamma applied, at logical resolution, and it includes the cursor. It is encoded to PNG with `stb_image_write` and returned as base64.

### Enabling it

MCP is off unless `FALLOUT_MCP_SOCKET=<path>` is set; normal play is unchanged. The bridge sets it to `$XDG_RUNTIME_DIR/fallout1-mcp/game.sock` on Linux (`$TMPDIR` on macOS), creates the socket mode 0600, and points `FALLOUT_MCP_LUA` at the repo's `lua/` directory.

### Dependencies

- **Lua 5.5.1**: the current release (2026-08-03). Fetched as a source tarball with a pinned hash and built as a static library in `third_party/lua`, like upstream's `fpattern` and `adecode`. That keeps macOS working without the devShell supplying it.
- **stb_image_write**: one header, pinned by commit.
- **A JSON module for Lua**: pure Lua and vendored. Lua 5.5 makes `for` loop variables read-only, so check the module against 5.5 before choosing.

## Lua side

- `lua/main.lua`, the entry point, and `lua/mcp/core.lua`: protocol handling, a tool registry, the coroutine scheduler, and the `wait_*`, `defer` and `post` helpers.
- `lua/tools/*.lua`: one file per area (perception, input, movement, dialog, combat, inventory, world map, save/load). A tool is a table with `name`, `description`, `schema` and `run(args)`.
- `reload` re-runs every file. The bridge then sends `notifications/tools/list_changed`, so new tools appear without restarting anything.

## Tools

Every action tool waits until the game is idle (with a timeout) and then returns what changed: mode, HP/AP, new messages, and dialog or combat state where relevant. A screenshot is added on request. "Idle" means:

- the player's animation is done (`anim_busy(obj_dude) == 0`);
- the UI isn't disabled (`game_ui_is_disabled()`);
- no script request is pending;
- in combat, it's the player's turn and input is allowed.

| Group | Tools | Built on |
|---|---|---|
| Perception | `look` (screenshot + summary), `state`, `objects`, `inventory`, `character`, `messages` | mode flags: `in_main_menu`, `isInCombat()`, `dialog_active()`, world map and screen window ids; `obj_find_first_at`; `tile_coord` (+16, +8 for the hex centre); `object_name`; `stat_level` and `skill_level`; the message log |
| Keys | `key(name)` | `GNW_add_input_buffer`, `kb_simulate_key` |
| Raw mouse (omniscient only) | `click(x, y, button)`, `move_mouse(x, y)` | virtual pointer |
| Movement | `walk_to(tile, screen point, or direction and distance; run)`; a short walk says why in `stopped_by`, and one a fight stops returns on the player's turn | `register_begin` / `register_object_move_to_tile` / `register_end`, as `gmouse_handle_event` does; in combat, AP is passed and spent per step. A direction walk picks its spot from a breadth-first search over `obj_blocking_at` (`src/mcp/bindings_walk.cc`) |
| Interaction | `objects`, `pick_up`, `loot` and `take`, `use`, `look_at` (built); `use_skill`, `use_item_on` | `action_get_an_object`, `action_loot_container`, `action_use_an_object`, `obj_examine` (`src/mcp/bindings_objects.cc`); the loot screen's `A` key and `INVEN_TAKE_ITEM_CODE`; `action_use_skill_on`, `action_use_an_item_on_object` |
| Dialog | `talk(npc)`, `choose(n)`, `barter(...)` | `action_talk_to`; option keys `'1'`–`'9'` (`gdialog.cc:1374`); `'b'` and `'m'` for barter |
| Combat | `attack(target; repeat, end_turn, min_hp)`, which fights a target to the death across turns and says in `stopped_by` what stopped it short; `end_turn`, `end_combat`, `hit_chance(target)` | `combat_attack`, `determine_to_hit`, Space and Return |
| World map | `travel(place or point)`, `enter(place)` | town buttons `500 + town`, town-map places `514 +`, and command codes for a point and the player's marker |
| Rest | `rest(hours or until)`, which waits until the clock stops; `hurt` (omniscient only, for testing) | the Pip-Boy's `p`, its alarm clock (`504`) and the clock's choices (`510 +`); `critter_can_obj_dude_rest`; `pipboy_is_resting` |
| Saves | `save(slot)`, `load(slot)` | `SaveSlot`/`LoadSlot` shims |
| Lifecycle (bridge) | `launch_game`, `quit_game`, `reload_lua`, `eval_lua` (omniscient only) | — |

Objects are referred to by `Object::id` rather than by pointer. Whether an id survives a save and reload is still to be checked. Screens without a semantic tool yet, such as character creation, options and the Pip-Boy, are driven by injected keys and button codes, never by clicks.

## Decision views

The agent should be able to decide from one call. Each mode has a view that returns everything needed for the next choice, using the numbers the game itself shows on hover, in examine text and on the interface bar. A screenshot then helps the agent understand a scene but is rarely needed to choose. Reusing the game's own displays also keeps fair play honest: if the player could see a number, the agent gets it too, and no more.

### Round trips

The rule: **the agent should never need several calls to learn what a person would see at a glance.** In practice:

- **Each action returns the next decision.** Every action returns the full view for whatever mode it ends in, plus what changed: new messages, HP and AP changes, a change of mode. The agent can go decide → act → decide without separate state calls.
- **An action carries on until there's something to decide (#19).** `attack` keeps at its target until it dies, ending turns as the AP runs out, so a fight with one rat is one call. It stops early, before ending a turn, for whatever the agent should decide on: a hostile critter coming into sight, HP falling low, the weapon running dry, the target out of sight or out of reach. Like a walk's, its result says which (`stopped_by`).
- **The whole view, not a diff.** The view for the current mode is returned in full each time, kept compact, so the agent never has to piece state together from earlier answers.
- **Approaching is part of the action.** `talk`, `use`, `pick_up`, `loot` and `use_skill` walk to the target first, as clicking a distant object does in the game. Out of combat, "go and talk to Killian" is one call, not a walk followed by a talk.
- **Descriptions come with first sight.** The first time an object appears in a view, its look-at description is included, so the agent doesn't have to examine each one. After that it's listed by name.
- **Ranked and capped.** Long lists (objects on a big map, a trader's inventory) are sorted by relevance, nearest first, and capped. The view says how many entries it left out, and `objects` or `inventory` page through the rest.
- **Screenshots when the scene changes.** A screenshot (about a thousand tokens) is attached automatically on entering a new map, combat, dialog or the world map, and otherwise only when asked for with `look`.

### Combat

This view comes back from every combat action, and from `state` during combat.

- **Turn:** whose turn it is, your AP and any free-move AP (`combat_free_move`), and whether you can act now.
- **You:**
  - HP and maximum HP, and crippled limbs.
  - Which hand is active, and for each hand's weapon:
    - each attack mode with its AP cost (`item_w_mp_cost`);
    - range (`item_w_range`) and damage range (`item_w_damage_min_max`);
    - ammo loaded and capacity (`item_w_curr_ammo`, `item_w_max_ammo`);
    - the AP cost to reload.
  - Armor, and quick-use items such as stimpaks, with their counts.
- **Each visible critter:**
  - id and name, and distance in hexes (`tile_dist`);
  - whether it will attack (`hostile`, below), in and out of combat;
  - health, as the examine text would give it (`protinst.cc`): one of five descriptions ("uninjured" down to "almost dead"), or exact HP plus its weapon and ammo if you have the Awareness perk. Omniscient mode always gives exact HP;
  - knocked down or crippled;
  - for each of your attack modes:
    - hit chance (`determine_to_hit(obj_dude, target, HIT_LOCATION_UNCALLED, mode)`, the same figure the game shows on hover via `combat_to_hit`, `gmouse.cc:726`), left out for a target out of range, where the figure means nothing;
    - whether the shot is possible right now (`combat_check_bad_shot`: out of range, not enough AP, out of ammo, blocked), and why not;
  - for aimed shots, the chance against each body part (`determine_to_hit` for each `HIT_LOCATION_*`), as the called-shot screen shows;
  - AP needed to get adjacent, for melee.
- **What happened:** combat messages since the agent's last turn, such as hits, misses, criticals, damage and deaths. A line from another critter's attack starts with who made it, `[Cave Rat, id 711] You were hit for 3 hit points.`, which the game's own line leaves out; fair play names only an attacker the player could see when it attacked (`[someone out of sight]` otherwise). `combat_display` records the attacker for each line it prints (`src/mcp/bindings_combat.cc`).
- **Turn order:** omniscient only. The game shows whose turn it is, not the queue (`combat_list`).

### Exploration

`state` on the map returns:

- **Where:** map name, elevation, and game date and time.
- **You:** HP, level and XP to the next level, and status. Built (#37): `player.conditions` names what the character screen lights up (poisoned, radiated, eye damage, crippled limbs) in every view, and is left out when there's none.
- **Nearby**, grouped:
  - critters (with health as above, and whether they can be talked to, `obj_action_can_talk_to`);
  - items on the ground;
  - containers;
  - doors;
  - usable scenery;
  - exits, with the map they lead to.

  Each entry has its id, its distance in hexes and the actions that apply to it: talk, use, pick up, loot, or a skill.

Built (#14): `objects` in the view lists the nearest dozen things a player can see besides the living, and the `objects` tool lists them all. Each has a `kind`, with the tool that acts on it, as a click on it does (`gmouse.cc:904-950`):
- `item`, on the ground: `pick_up`;
- `body` and `container`: `loot`, then `take`;
- `door` and `scenery` that can be used: `use`.

The text map marks each kind with the legend's symbol: `*`, `%`, `=`, `+` and `!`. Doors and containers say whether they're open. A lock can't be seen, so fair play says `locked` only once the player has tried it; omniscient mode always says. Every action walks up first, through the game's own action, so it runs when far off and costs AP in combat. Critters carry `can_talk` out of combat, from `obj_action_can_talk_to`, which is every living critter; `talk` waits for dialog.

### Other screens

- **Dialog:** the NPC's name, its whole reply (unpaged), the numbered options, and whether barter is available.
- **Barter and loot:** both sides' items with quantity, weight and value, plus the totals on offer.
- **Character:** stats, skills with percentages, perks, traits, tagged skills, unspent points and carry weight. Built as the `character` tool; the state view carries the same sheet on the character screen, and elsewhere `player.unspent` says when skill points or a perk are waiting.
- **World map:** where you are (the name the player's marker shows, the terrain, the position in map squares), whether you're travelling and where to, and the places the map's list names, with distance and direction. On the town map, the town's places a player can go into. Fallout 1 has no encounter prompt: an encounter drops you on its map, and `travel` says that's what stopped it, and where: the position in squares and the terrain (#39). Encounter maps and the open ground have no name of their own, so `player.map.name` gives the ground's, as the world map does ("Desert", "Mountains"). Built.

## Fair play, with an omniscient override

Decided: fair play is the default.

- **Fair play** reports only what a player could see or know: what's visible on screen (below), the player's own stats and inventory, the dialog and message text shown, and visible combat state. There are no script variables, no hidden containers' contents, and no `eval_lua` or raw mouse.
- **Omniscient** is for debugging. It adds full engine state (every object on the map, global and script variables, hidden inventories), `eval_lua`, `click` and `move_mouse`. It is chosen when the bridge starts (`FALLOUT_MCP_OMNISCIENT=1`), so a playing session can't switch it on by itself. Every result says which mode produced it.

Each state field is tagged fair or omniscient where it is defined in Lua, so the filter is one place, not a check scattered through every tool. Some fields still need a judgement as they are added.

**Hostility (#19), decided:** a critter is `hostile` when it's taking part in the fight (`combat_list`'s combatants), has been hit by the player's side in it (`who_hit_me`), or is a creature that attacks on sight: rats, radscorpions, floaters, centaurs, mantises, deathclaws and the plants, by its kill type, which a player knows on sight. Companions and the dead never are. Whether people, brahmin, dogs and robots will turn on the player before a fight is up to their scripts, which nothing on screen shows, so they aren't hostile until they join one. The rule is `mcp_hostile` (`src/mcp/combat_rules.h`), and the flag rides on the critters that `lua/mcp/sight.lua` lets through.

### What "visible" means (#20)

Decided: visible is what the screen shows, worked out pixel by pixel from what the engine draws (`src/mcp/sight.cc`).

- **Lighting hides nothing.** The engine never draws darker than a quarter (`LIGHT_LEVEL_MIN`), and a player turns the brightness up, as `look` does.
- **Line of sight isn't the rule.** Fallout has no fog of war: the screen shows critters around corners and in the next corridor, and a player sees them.
- **What's drawn over a thing hides it.** That's roofs, and walls or scenery drawn in front. In play test 2 the rats "inside the dark rock" stood in a corridor behind the cave's rock face, which is a wall sprite drawn over them.
- **`OBJECT_SEEN` isn't sight.** It's the automap's memory: it marks everything within about 16 hexes of anywhere the player has walked, whatever is in between.

The rule:

- **A point** is visible when it's in the map view, above the interface bar, with no roof drawn over it (except where the egg cuts the roof away), as `object_under_mouse` has it.
- **A critter or item** is visible when at least a quarter of its own pixels show at visible points, with nothing drawn over them. "Drawn over" comes from `obj_create_intersect_list`, the list the game uses to find what's under the mouse. Translucent things and walls cut away by the egg don't hide what's behind them.

`fo.critters` and `fo.hexes` carry the engine's `visible` flag. `lua/mcp/sight.lua` is the one place that applies it: fair play sees what's visible, and omniscient mode sees everything. The critter list and the text map both go through it, so they always agree.

## Text map (#22)

`look` adds a text map of the screen to the state and screenshot, one character per hex. `look` with `screenshot: false` leaves the image out once the map is enough.

- **Layout.** Each line is a row of hexes as they sit on screen, offset half a hex from the next, so odd columns sit half a row down. `walk_to`'s directions stay straight: e and w are two characters along a line; ne, se, sw and nw are a line up or down and a character across; n and s are straight up and down.
- **Floor.** Floor is drawn only where the player can walk. That's what the game's move cursor tells a player who points at a hex: it shows an X where `make_path` finds no way. A breadth-first walk from the player answers it for the whole screen at once. In a cave this leaves the rock blank (it's floor art the player can't reach), so the corridors stand out between their walls.
- **Walls.** Walls and doors are drawn where they border that floor.
- **Critters** get letters keyed to their ids, nearest first, in fair play only those `critters` lists.
- **Why on `look`.** `look` is the call for getting one's bearings, so one call gives the picture and the map. A separate `map` tool would mean two calls at every new scene.

## No-mouse punch list

A screen-by-screen audit (2026-11-01) sorted every player action into three kinds: a key the screen handles, a button event code that can be injected, or something that only works with the mouse. These screens need nothing new, because keys and button codes already reach everything on them:
- the main menu and character select;
- dialog, except replies past the ninth and Review;
- skilldex, options and save/load;
- the elevator, called shot and automap;
- death, endgame, credits and movies;
- popups.

What follows is everything that needs the mouse today, and how each will get a mouse-free path. Engine locations are file:line.

**Map view: semantic tools, route 2.** These are the core of play:
- walking: `walk_to`, built;
- the primary action on an object: `use`, `pick_up` or `talk`, as `gmouse.cc:904-950` dispatches it. Built except `talk`, with `loot` for bodies and containers;
- the hold-click action menu: each outcome as its own tool;
- attacking: `attack`, built;
- using an item on an object: `action_use_an_item_on_object`;
- a skill on a target: `action_use_skill_on`. This is also how First Aid and Doctor are used on yourself.

**Inventory: command codes inside `handle_inventory`, route 3.**
- **Equip and drop.** Equipping a hand or armor, unequipping, dropping into a bag and reloading by drag all go through `inven_pickup` (`inventry.cc:1946`), using `switch_hand`, `drop_into_container` and `drop_ammo_into_weapon`.
- **The item menu.** Look, use, drop and unload are in `inven_action_cursor` (`:3222`).
- **State to keep consistent:** the statics `i_lhand`, `i_rhand` and `i_worn`, which `setup_inventory` and `exit_inventory` move in and out of the inventory, and `stack_offset[curr_stack]`. Each code has to end with the same redraws the drag does (`:2132-2135`).

**Use-item-on, loot and barter: command codes, route 3.**
- **Picking the item for use-on:** `inventry.cc:2357-2361`.
- **Loot and steal.** Moving one item either way goes through `move_inventory` → `item_move` (`:3910`, `:3934`), quantity included. When stealing, `gStealCount`, `gStealSize` and the stealing XP locals must stay in step. Built for taking while looting: `INVEN_TAKE_ITEM_CODE` (`0x7300`) moves the item `inven_take_request` names, as dropping it on the player's side does, and `take` uses it. The `A` key takes everything. Putting items back and stealing are still to come.
- **Barter.** Each of the four table moves is `item_move_force` between the inventories and `ptable`/`btable` (`:4738-4786`), followed by redrawing both tables.

**World map: command codes inside `world_map`, route 3.**
- **Free travel to a point** (`worldmap.cc:1205-1231`) sets `target_xpos`/`target_ypos` and several of `world_map`'s own locals (`is_moving`, `autofollow`, `is_moving_to_town`). That's why the handler has to live inside that loop.
- **Entering the current location by its marker** (`:1206-1220`) is the only way into empty terrain, or into a town discovered on foot.
- Known towns already have button codes (`500 + town`).
- Built: `WORLDMAP_TRAVEL_CODE` travels to a point Lua sets first, and `WORLDMAP_ENTER_CODE` clicks the player's marker (`worldmap.h`). The map's line-stepping stops a pixel short of a point, as it always did, so `travel` allows a pixel's slack.

**Character editor (level-up): command codes, route 3.**
- Choosing which skill to raise (`InfoButton(531)`, `editor.cc:4701`) sets `skill_cursor`; after that the existing slider keys work. Built: the code `EDITOR_SELECT_SKILL_CODE` plus a skill selects it, and `raise_skill` then presses `+`.
- The perk list needs no code: Home, Down and Return reach every perk, and Tag!'s and Mutate!'s follow-up lists work the same way. `choose_perk` uses them.
- The Perks/Karma/Kills folder tab (`FldrButton`, `:4612`) sets `folder`. The character view lists perks whichever tab is open, so this one waits until karma or kills are needed.

**Pip-Boy: command code, route 3.** Resting needs nothing new: the alarm clock's choices are button codes, and `rest` presses them and waits while `pipboy_is_resting()`. On the status tab, choosing a quest location or a holodisk depends on the mouse's x position (`PipStatus`, `pipboy.cc:1002`). The new code sets that choice directly.

**Preferences: command codes or engine calls.** Every setting is changed in `DoThing` (`options.cc:1122`), which reads the mouse, and the sliders are drag loops. This is low priority: the agent rarely needs preferences.

**Gaps that aren't the mouse:**
- **Dialog replies past the ninth** can't be chosen at all. Their button codes fail the `'0'..'9'` check (`gdialog.cc:1374`), so they need a code of their own.
- **Dialog Review** and **message-log scrolling** are button callbacks with no code. The views already give the agent the reply history and the message log, so neither is needed.
- **Running instead of walking**, **Ctrl-reserving AP in combat** and **the main menu's quotes** read raw key state (`keys[]`), not input codes. `walk_to` and `attack` already pass run and reserved AP directly.
- **F12** never reaches a screen: the engine turns it into a screenshot on disk. `key` refuses it.

## Decisions to make

1. **Should the game pause between commands?** Outside combat, the world keeps running in real time while the agent thinks. *Recommendation: not in the first slice.* Fallout's combat is already turn-based, and exploration rarely punishes a slow reader. Freezing the clock means skipping `GNW_do_bk_process` between commands, which risks leaving animations or scripts half-done. Revisit if wandering NPCs turn out to be a problem.
2. **Bridge language.** *Recommendation: TypeScript on bun.* It has the reference SDK and nothing to install. Python's SDK (2.3.0) would work equally well, at the cost of a uv environment.

## First slice

The first slice is thin but runs end to end, so every seam is exercised before the tool surface grows:

1. Lua 5.5.1 builds in, and the VM loads `lua/` at startup.
2. Socket server, `process_bk` hook with its re-entrancy guard, and the coroutine scheduler. Focus-loss freeze and main-menu timeout are disabled when MCP is on.
3. Bindings for `look` (screenshot), `key`, `press` (inject a button code), a minimal `state` (mode, HP, tile, map name) and `walk_to`.
4. A bridge with dynamic tool discovery, `launch_game` and `reload_lua`.
5. **Proof:** from Claude Code, launch the game, start a new game with a premade character, and walk out of the Vault 13 cave, all without touching the mouse.

Built, with three additions the cave turned out to need:
- **Combat basics (#8).** The cave has rats.
- **The exits a player can see**, in the state view.
- **Turbo mode (#9).** The end-to-end test takes about 10 seconds instead of minutes.

The view also follows the player, so the game is easy to watch.

Semantic tools follow, roughly in the order a game needs them: objects (`use`, `pick_up`, `talk`, `look_at`), dialog, inventory, world map, saves. Then the remaining punch-list command codes.

## Running on mango

Claude Code starts the bridge inside Claude Desktop's bubblewrap. On Linux the bridge launches the game with `systemd-run --user`, so the game runs in the GNOME session like any app. The socket under `$XDG_RUNTIME_DIR` is visible on both sides. `CLAUDE.md` describes the same launch.
