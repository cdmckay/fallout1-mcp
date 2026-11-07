# Play tests

A play test is a fresh Claude Code session that plays the game through the `fallout` MCP server and reports what got in its way. Each one turns into issues. Run one from `main` after a batch of changes lands.

## Results so far

| Play test | Date | Built from | Outcome |
| --- | --- | --- | --- |
| 1 | 2026-11-01 | the first slice | Got out of the cave. Found the equip, walk and screen-state gaps (#11–#13). |
| 2 | 2026-11-01 | `a2c412b` | Got out in about 76 calls at 24/43 HP. About 30 calls went on dead ends and about 40 on attack/end_turn (#16–#21). |
| 3 | 2026-11-01 | `6792149` (text map and the new `walk_to`; before the world map) | Got out in about 33 calls at full HP. Finding the exit is still guesswork (#18). Also: attack then end_turn (#19), weapon stats (#28), and a sight mismatch (#29). |
| 4 | 2026-11-07 | `7e834c0` (world map, one-call fights, objects) | Got into Vault 15 in about 80 calls, at 32/43 HP and poisoned. The cave took about 35, 12 of them on a dead end (#18). The road took about 37: a mole rat fight down to 1 HP, rest by guessed codes, and a run from radscorpions. Found a missed turn in `attack` (#32) and #33–#40. |

## Setting one up

The session needs an account whose organisation doesn't block local MCP servers. Cameron's Process Street account has a managed MCP allowlist, so play tests use a separate config directory, `~/.claude-ultra`, signed in to another account. Register the bridge there once per machine, from this repository's root:

```bash
CLAUDE_CONFIG_DIR=~/.claude-ultra claude mcp add --scope local fallout -e FALLOUT_MCP_TURBO=4 -e FALLOUT_MCP_TITLE="play test" -- bun "$PWD/bridge/src/main.ts"
```

The server's name goes before `-e`. Play tests run at 4× speed and in fair mode. Never use omniscient or god mode for one.

## Running one

Start it from this repository's root, in a terminal the watcher can see. The game opens on the plain `fallout1-mcp` unit, so stop any game already running there first.

```bash
CLAUDE_CONFIG_DIR=~/.claude-ultra claude --allowedTools mcp__fallout -- "$(cat docs/play-test-prompt.md)"
```

When it finishes, copy its report from the terminal. On mango, the full text is also in the newest file under `~/.claude-ultra/projects/<this repo>/`. File each limitation and bug as an issue, or as a comment on an open one, and add a row to the table above.

The prompt is in [play-test-prompt.md](play-test-prompt.md). Change its goal as the game opens up, and its number in the purpose for each run. From play test 4 it goes on past the cave to Vault 15, to cover travel and encounters (#21), the one-call fights (#19) and looting (#14).
