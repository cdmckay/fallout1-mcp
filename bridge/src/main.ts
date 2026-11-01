// The MCP server for fallout1-mcp, run by an MCP client over stdio:
//
//   claude mcp add fallout -- bun /path/to/fallout1-mcp/bridge/src/main.ts
//
// See docs/mcp-design.md, and src/config.ts for the environment it reads.

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { loadConfig } from "./config";
import { EngineClient } from "./engine";
import { createLauncher } from "./launcher";
import { Bridge } from "./server";

const config = loadConfig();
const engine = new EngineClient(config.socketPath, config.requestTimeoutMs);
const bridge = new Bridge(engine, createLauncher(config), config);

// A game that's already running offers its tools from the start.
if (await engine.connect()) {
  await bridge.refreshTools().catch((error) => console.error(`[bridge] couldn't list the game's tools: ${error}`));
}

await bridge.server.connect(new StdioServerTransport());
