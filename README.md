# Fallout MCP

> **This is Fallout MCP (fallout1-mcp), a modified version of [Fallout Community Edition](https://github.com/alexbatalov/fallout1-ce).** It adds a Lua interface inside the engine and an MCP server on top of it, so that an agent can play the game. The changes are in this repository's commit history, and it is distributed under the same [license](LICENSE.md).

Fallout MCP lets an AI agent, such as Claude through Claude Code, play Fallout (1997). The agent never touches the mouse. It reads the game through views built for making decisions: in a fight, for example, it sees who's around and its chance to hit each of them. It acts through tools that do what a player means, such as `walk_to`, `attack` and `equip`, rather than through clicks. You can watch the game window while it plays, and take over at any time.

The engine is [Fallout Community Edition](https://github.com/alexbatalov/fallout1-ce), a re-implementation of Fallout's engine that keeps the original gameplay.

## Status

An agent can:
- start a new game with a premade character;
- equip weapons, reload them and use stimpaks;
- fight its way through the Vault 13 cave;
- reach the world map.

It does all of this without the mouse. Each play test turns what tripped the agent up into [issues](https://github.com/cdmckay/fallout1-mcp/issues), and they set what comes next: a text map of what's on screen, talking, picking things up, the character screen and travel on the world map.

| Area | Tools |
| --- | --- |
| The game | `launch_game`, `quit_game`, `reload_lua`, `ping` |
| Seeing | `state` (the current screen, its keys, and what's going on), `look` (the same, plus a screenshot), `survey` (looks around without moving) |
| Input | `key` (keys, as the player presses them), `press` (on-screen buttons that have no key) |
| Moving | `walk_to` (a tile, a point on the screenshot or a direction) |
| Combat | `attack`, `end_turn` |
| Inventory | `inventory`, `equip`, `unequip`, `reload`, `use_item` |

## How it works

- **In the engine** (`src/mcp/`): Lua 5.5 runs inside the game. Each frame it answers requests on a Unix socket, one JSON object per line. Small C++ bindings give it what the game knows and the actions a player can take.
- **In Lua** (`lua/`): the tools themselves. Lua reloads in the running game, without a rebuild.
- **The bridge** (`bridge/`): an MCP server on [bun](https://bun.sh). It launches the game, asks it for its tools and passes calls through. This is what you register with Claude Code.
- **Fair play by default:** the agent learns only what a player could see or know. An omniscient mode, for debugging, reports everything on the map.

The full design, including how every screen is reached without the mouse, is in [docs/mcp-design.md](docs/mcp-design.md).

## Getting started

You need your own copy of Fallout, from [Steam](https://store.steampowered.com/app/38400) or [GOG](https://www.gog.com/game/fallout). It has been developed and tested on Linux (NixOS). The flake also covers macOS on Apple Silicon, but that hasn't been tried.

**Build.** The Nix flake's dev shell provides CMake, SDL2 and bun; with direnv, `direnv allow` loads it. Without Nix, install those three yourself.

```bash
cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DFALLOUT_MCP_TESTS=ON
cmake --build build -j
cd bridge && bun install
```

**Game data.** Copy the game's folder to `~/.local/share/fallout1-mcp`, the place the bridge looks by default. A copy keeps saves and settings out of the store's folder. To play in a window at twice the size, set this in its `f1_res.ini`:

```ini
[MAIN]
SCR_WIDTH=2048
SCR_HEIGHT=1536
WINDOWED=1
SCALE_2X=1
```

**Register the bridge with Claude Code,** from the repository's root:

```bash
claude mcp add fallout -e FALLOUT_MCP_TURBO=4 -- bun "$PWD/bridge/src/main.ts"
```

Then ask Claude to play. It starts the game with `launch_game`.

## Watching

- **The view follows the player,** so you can see what the agent is doing. Set `FALLOUT_MCP_FOLLOW=0` to turn that off.
- **`FALLOUT_MCP_TURBO`** runs the game faster, from 1 to 16 times normal speed. Movies and sound keep their normal speed.
- **The mouse works the way it does in a virtual machine's window.** The window leaves your pointer alone until you click in it. Ctrl+Alt gives the pointer back.

`bridge/src/config.ts` lists every setting. Several games can run at once, each with its own copy of the data; [CLAUDE.md](CLAUDE.md) says how.

## Development

[CLAUDE.md](CLAUDE.md) is the working guide: the build, the tests, how the game runs from a Claude Code session, and every change made to the engine. In short:

```bash
ctest --test-dir build --output-on-failure       # C++ and Lua tests
cd bridge && bun test && bunx tsc --noEmit       # the bridge
cd bridge && FALLOUT_E2E=1 bun test test/e2e     # the real game, from the cave to the world map
```

For playing Fallout Community Edition itself on Windows, macOS, Android or iOS, see [upstream's README](https://github.com/alexbatalov/fallout1-ce#readme).

## License

The source code in this repository is available under the [Sustainable Use License](LICENSE.md).
