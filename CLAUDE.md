# fallout1-mcp

A fork of [Fallout Community Edition](https://github.com/alexbatalov/fallout1-ce) (fallout1-ce), the C++ re-implementation of Fallout's engine. The goal is a Lua interface inside the engine and an MCP server on top of it, so an agent can play the game.

## Remotes

- `origin` is `cdmckay/fallout1-mcp`: it fetches over HTTPS and pushes over SSH. On mango, SSH fails inside Claude Desktop's bubblewrap, so push with `hop git push`.
- `upstream` is `alexbatalov/fallout1-ce`, fetch only. Its last commit was in January 2025.

## Building

The devShell (`flake.nix`, loaded by direnv) provides CMake, SDL2 and git:

```bash
cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DFALLOUT_MCP_TESTS=ON
cmake --build build -j
ctest --test-dir build --output-on-failure
```

The first configure downloads `fpattern`, `adecode`, Lua 5.5.1 (and SDL2 on macOS), plus Catch2 when tests are on, with CMake's FetchContent, so it needs network. Lua and Catch2 come as release tarballs pinned by SHA-256. On Linux it links the system SDL2, which on nixos-26.05 is `sdl2-compat` running on SDL3. The binary is `build/fallout-ce`.

`FALLOUT_MCP_TESTS` builds two kinds of test:

- **C++ (Catch2):** `tests/mcp/`. These test the MCP pieces that don't need the engine (socket, line framing, Lua host) and run the real `lua/` scripts against fake bindings.
- **Lua:** `lua/tests/`, with a fake `fo` table. They run under `build/third_party/lua/lua`, an interpreter built from the same Lua sources the game embeds:

  ```bash
  build/third_party/lua/lua lua/tests/run.lua
  ```

## MCP

The design is in `docs/mcp-design.md`. In short:

- `src/mcp/` is the engine side: socket, Lua host and `fo` bindings. It runs from `mcp_tick()` at the top of `process_bk()`.
- `lua/` is everything else. `main.lua` is the entry point, `mcp/core.lua` holds the protocol and scheduler, and `tools/` holds one file per area, each listed in `tools/init.lua`.

MCP is off unless the game starts with these set:

- `FALLOUT_MCP_SOCKET`: where the game listens, e.g. `$XDG_RUNTIME_DIR/fallout1-mcp/game.sock`, in a 0700 directory.
- `FALLOUT_MCP_LUA`: the repo's `lua/` directory.
- `FALLOUT_MCP_OMNISCIENT=1`: optional, for omniscient mode.
- `FALLOUT_MCP_TURBO=<1..16>`: optional, for development. The engine's clock (`get_time`, a `ScaledClock`) runs that many times faster, and the frame limiter rises with it. Movies and sound keep real time.
- `FALLOUT_MCP_FOLLOW=0`: optional. By default the view recenters on the player whenever they move, so someone watching can follow the agent. A view panned with the arrow keys stays put until the player moves.

The protocol is one JSON object per line, each answered once by id. `{"id":1,"op":"list"}` lists the tools, `{"id":2,"op":"call","tool":"ping","args":{}}` calls one, and `{"id":3,"op":"reload"}` reruns the Lua files in the live game. A reload doesn't need a rebuild or a restart, but it does reset Lua's state.

### The bridge

`bridge/` is the MCP server Claude Code talks to: TypeScript on bun, using `@modelcontextprotocol/sdk`, over stdio. It asks the game for its tools and forwards calls to it one at a time. It adds three tools of its own:

- `launch_game`: on Linux through `systemd-run --user`, as above;
- `quit_game`;
- `reload_lua`.

Register it with Claude Code:

```bash
claude mcp add fallout -- bun /home/cdmckay/Code/fallout1-mcp/bridge/src/main.ts
```

`bridge/src/config.ts` lists the environment it reads. Each setting defaults to this repo's layout. `FALLOUT_MCP_OMNISCIENT=1` and `FALLOUT_MCP_TURBO` are read when the bridge starts and passed to the game it launches; the agent can't change them.

```bash
cd bridge && bun install && bun test && bunx tsc --noEmit
```

The tests run against a fake game that speaks the real socket protocol, and through the SDK's in-memory client.

The end-to-end test (`bridge/test/e2e/cave.test.ts`) plays the real game through the real bridge over stdio. It goes from launch, through a new game with the premade character, to fighting the cave rats and out to the world map, without the mouse. It needs a built game and the game data, so it runs only when asked:

```bash
cd bridge && FALLOUT_E2E=1 bun test test/e2e
```

It takes about 10 s at turbo 8. It uses its own unit and socket, named after `FALLOUT_MCP_UNIT` with `-e2e` added (`fallout1-mcp-e2e` by default), so it never touches a running game. It uses omniscient mode only to find the cave's exit.

## Game data

The game data is Interplay's and never goes in this repo. The engine needs the original `master.dat`, `critter.dat` and `data/` directory, and it reads `fallout.cfg` and `f1_res.ini` from its working directory. Lookups are case-insensitive, so Steam's upper-case `MASTER.DAT` and `DATA/` work as they are.

On mango the data is a reflink copy of the Steam install (app 38400, `~/.local/share/Steam/steamapps/common/Fallout`) at `~/.local/share/fallout1-mcp`, so saves and config changes stay out of Steam's folder.

`f1_res.ini` comes from Steam's Windows hi-res patch. The engine reads only four keys from its `[MAIN]` section (`src/game/game.cc`):

- `SCR_WIDTH` and `SCR_HEIGHT`, at least 640×480.
- `WINDOWED`. Fullscreen is the default.
- `SCALE_2X=1`, which doubles every pixel and divides `SCR_WIDTH`/`SCR_HEIGHT` by 2. So 2048×1536 with `SCALE_2X=1` renders 1024×768 in a 2048×1536 window.

The engine rewrites `fallout.cfg` when it exits.

## Running

```bash
cd ~/.local/share/fallout1-mcp && ~/Code/fallout1-mcp/build/fallout-ce
```

From a Claude Desktop session on mango, launch it as a transient user unit with the sandbox off. It then runs in the GNOME session like any app, rather than inside the session's bubblewrap. This launch also turns MCP on:

```bash
mkdir -p -m 700 /run/user/1000/fallout1-mcp
systemd-run --user --unit=fallout1-mcp --collect \
  --working-directory=/home/cdmckay/.local/share/fallout1-mcp \
  --setenv=FALLOUT_MCP_SOCKET=/run/user/1000/fallout1-mcp/game.sock \
  --setenv=FALLOUT_MCP_LUA=/home/cdmckay/Code/fallout1-mcp/lua \
  -- /home/cdmckay/Code/fallout1-mcp/build/fallout-ce
```

Its output is in `journalctl --user -u fallout1-mcp`, and `systemctl --user stop fallout1-mcp` closes it. The session can't read that process's `/proc` entries; run anything that inspects it through `hop`.

### Several games at once

Each worktree can run a game of its own beside the others. Give each game its own unit, socket and data directory, or two games will stop each other and share saves. The bridge reads all three from the environment, and it runs the build and `lua/` of the checkout it lives in:

```bash
cp -r --reflink=always ~/.local/share/fallout1-mcp ~/.local/share/fallout1-mcp-<name>
FALLOUT_MCP_UNIT=fallout1-mcp-<name> \
  FALLOUT_MCP_SOCKET=/run/user/1000/fallout1-mcp/<name>.sock \
  FALLOUT_DATA_DIR=$HOME/.local/share/fallout1-mcp-<name> \
  bun bridge/src/main.ts   # or the e2e test, or a script driving the bridge
```

On mango's btrfs the reflink copy is instant and takes no extra space. It also keeps each game's saves and `fallout.cfg` apart. Claude Code's Bash calls don't keep exported variables, so set the three on every command that starts a bridge. The e2e test names its game after `FALLOUT_MCP_UNIT`, so it doesn't collide either.

The plain `fallout1-mcp` unit and data directory belong to Cameron and the play tests. Never stop or reuse them from a worktree.

## Changes from upstream

Comments starting `// CE:` mark where upstream departs from the original game. This fork uses the same marker for its own changes:

- **Mouse capture** (`src/plib/gnw/dxinput.cc`, `src/plib/gnw/input.cc`): the pointer works the way it does in a virtual machine's window. The window starts with the pointer free. A click in the window captures it, and that click doesn't reach the game. Ctrl+Alt releases it, and so does switching to another window. While captured, SDL's relative mode locks the pointer to the window, as upstream does, so pushing against an edge scrolls the map, and the window title says how to get out. While released, the game ignores the mouse and doesn't edge-scroll (`gmouse.cc`, `worldmap.cc`). Fullscreen captures from the start.

## License

The [Sustainable Use License](LICENSE.md) allows non-commercial use, modification and free distribution. Keep its notices intact, and keep the modification notice at the top of `README.md`, which the license requires for modified copies.
