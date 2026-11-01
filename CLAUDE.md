# fallout1-mcp

A fork of [Fallout Community Edition](https://github.com/alexbatalov/fallout1-ce) (fallout1-ce), the C++ re-implementation of Fallout's engine. The goal is a Lua interface inside the engine and an MCP server on top of it, so an agent can play the game.

## Remotes

- `origin` is `cdmckay/fallout1-mcp`: it fetches over HTTPS and pushes over SSH. On mango, SSH fails inside Claude Desktop's bubblewrap, so push with `hop git push`.
- `upstream` is `alexbatalov/fallout1-ce`, fetch only. Its last commit was in January 2025.

## Building

The devShell (`flake.nix`, loaded by direnv) provides CMake, SDL2 and git:

```bash
cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j
```

The first configure downloads `fpattern` and `adecode` (and SDL2 on macOS) with CMake's FetchContent, so it needs network. On Linux it links the system SDL2, which on nixos-26.05 is `sdl2-compat` running on SDL3. The binary is `build/fallout-ce`.

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

From a Claude Desktop session on mango, launch it as a transient user unit with the sandbox off. It then runs in the GNOME session like any app, rather than inside the session's bubblewrap:

```bash
systemd-run --user --unit=fallout1-mcp --collect \
  --working-directory=/home/cdmckay/.local/share/fallout1-mcp \
  -- /home/cdmckay/Code/fallout1-mcp/build/fallout-ce
```

Its output is in `journalctl --user -u fallout1-mcp`, and `systemctl --user stop fallout1-mcp` closes it. The session can't read that process's `/proc` entries; run anything that inspects it through `hop`.

## Changes from upstream

Comments starting `// CE:` mark where upstream departs from the original game. This fork uses the same marker for its own changes:

- **Windowed mouse** (`src/plib/gnw/dxinput.cc`, `src/plib/gnw/mouse.cc`): in a window, the cursor follows the system pointer instead of using SDL's relative mode, which locks the pointer to the window. Fullscreen keeps relative mode.

## License

The [Sustainable Use License](LICENSE.md) allows non-commercial use, modification and free distribution. Keep its notices intact, and keep the modification notice at the top of `README.md`, which the license requires for modified copies.
