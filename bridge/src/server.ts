import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { CallToolRequestSchema, type CallToolResult, ListToolsRequestSchema, type Tool } from "@modelcontextprotocol/sdk/types.js";
import type { Config } from "./config";
import { type EngineClient, type EngineTool, NotConnectedError } from "./engine";
import type { Launcher } from "./launcher";

const INSTRUCTIONS = `You are playing Fallout (1997) through this server. Start the game with launch_game.
The game's own tools appear once it's running. Everything is done through them; there is no mouse.
Each action returns what you need for the next decision, so you rarely need to ask for state separately.`;

const NO_ARGUMENTS = { type: "object", properties: {}, additionalProperties: false } as const;

// Tools the bridge answers itself, whether or not the game is running.
const BRIDGE_TOOLS: Tool[] = [
  {
    name: "launch_game",
    description: "Starts Fallout and waits until it's ready. The game's own tools appear once it's running.",
    inputSchema: NO_ARGUMENTS,
  },
  {
    name: "quit_game",
    description: "Closes Fallout. Unsaved progress is lost.",
    inputSchema: NO_ARGUMENTS,
  },
  {
    name: "reload_lua",
    description: "Reruns the game's Lua tool scripts without restarting the game, picking up edits to lua/. For development.",
    inputSchema: NO_ARGUMENTS,
  },
];

function text(message: string, isError = false): CallToolResult {
  return { content: [{ type: "text", text: message }], isError };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// JSON with object keys sorted. The game's JSON encoder doesn't keep key order
// stable, so comparing plain JSON would see changes that aren't there.
function canonicalJson(value: unknown): string {
  return JSON.stringify(value, (_key, inner) =>
    inner !== null && typeof inner === "object" && !Array.isArray(inner)
      ? Object.fromEntries(Object.entries(inner).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
      : inner,
  );
}

// The MCP server Claude Code talks to. It forwards the game's tools, which it
// learns from the game, and adds its own for starting and stopping it.
export class Bridge {
  readonly server: Server;
  #engineTools: EngineTool[] = [];
  #access: "fair" | "omniscient";

  constructor(
    readonly engine: EngineClient,
    readonly launcher: Launcher,
    readonly config: Config,
  ) {
    this.#access = config.omniscient ? "omniscient" : "fair";

    this.server = new Server(
      { name: "fallout1-mcp", version: "0.1.0" },
      { capabilities: { tools: { listChanged: true } }, instructions: INSTRUCTIONS },
    );

    this.server.setRequestHandler(ListToolsRequestSchema, async () => {
      // This answer carries the fresh list, so no change notice is needed.
      await this.#connectIfRunning({ notify: false });
      return { tools: this.tools() };
    });

    this.server.setRequestHandler(CallToolRequestSchema, async (request) => {
      return this.callTool(request.params.name, request.params.arguments ?? {});
    });
  }

  // The bridge's tools followed by the game's, minus any game tool that
  // would shadow one of the bridge's.
  tools(): Tool[] {
    const own = new Set(BRIDGE_TOOLS.map((tool) => tool.name));
    const engine = this.#engineTools
      .filter((tool) => !own.has(tool.name))
      .map((tool) => ({ name: tool.name, description: tool.description, inputSchema: tool.inputSchema as Tool["inputSchema"] }));
    return [...BRIDGE_TOOLS, ...engine];
  }

  async callTool(name: string, args: Record<string, unknown>): Promise<CallToolResult> {
    switch (name) {
      case "launch_game":
        return this.#launch();
      case "quit_game":
        return this.#quit();
      case "reload_lua":
        return this.#reload();
    }

    await this.#connectIfRunning();

    try {
      const result = await this.engine.call(name, args);
      return {
        content: result.content as CallToolResult["content"],
        _meta: { access: result.access },
      };
    } catch (error) {
      return text(errorMessage(error), true);
    }
  }

  // Asks the game for its tools and, unless told not to, tells the client
  // when they changed.
  async refreshTools(options = { notify: true }): Promise<void> {
    const list = await this.engine.list();
    this.#access = list.access;

    const before = canonicalJson(this.#engineTools);
    this.#engineTools = list.tools;

    if (options.notify && canonicalJson(this.#engineTools) !== before) {
      await this.server.sendToolListChanged().catch(() => {});
    }
  }

  // Picks up a game that was started outside the bridge, or restarted.
  async #connectIfRunning(options = { notify: true }): Promise<void> {
    if (!this.engine.connected && (await this.engine.connect())) {
      await this.refreshTools(options).catch(() => {});
    }
  }

  async #launch(): Promise<CallToolResult> {
    if (await this.engine.connect()) {
      await this.refreshTools();
      return text(`The game is already running (${this.#access} mode). ${this.#describeTools()}`);
    }

    try {
      await this.launcher.start();
    } catch (error) {
      return text(`Couldn't start the game: ${errorMessage(error)}`, true);
    }

    if (!(await this.engine.waitForGame(this.config.startupTimeoutMs))) {
      return text(`The game started but didn't open its socket at ${this.config.socketPath} within ${this.config.startupTimeoutMs / 1000} s.`, true);
    }

    await this.refreshTools();
    return text(`The game is running (${this.#access} mode). ${this.#describeTools()}`);
  }

  async #quit(): Promise<CallToolResult> {
    this.engine.close();
    await this.launcher.stop();
    return text("The game is closed.");
  }

  async #reload(): Promise<CallToolResult> {
    try {
      await this.#connectIfRunning();
      await this.engine.reload();
      await this.refreshTools();
      return text(`Reloaded the Lua scripts. ${this.#describeTools()}`);
    } catch (error) {
      if (error instanceof NotConnectedError) {
        return text(error.message, true);
      }
      return text(`Reload failed: ${errorMessage(error)}`, true);
    }
  }

  #describeTools(): string {
    const names = this.#engineTools.map((tool) => tool.name);
    return names.length === 0 ? "It offers no tools yet." : `Its tools: ${names.join(", ")}.`;
  }
}
