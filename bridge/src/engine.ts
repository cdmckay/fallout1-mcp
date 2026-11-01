import type { Socket } from "bun";

// A tool the game offers, as the Lua layer describes it.
export interface EngineTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export interface ToolList {
  access: "fair" | "omniscient";
  tools: EngineTool[];
}

// MCP content, built by the Lua layer: text and base64 PNG images.
export interface CallResult {
  content: Array<Record<string, unknown>>;
  access: "fair" | "omniscient";
}

// The game answered a request with an error. Its message is for the agent.
export class EngineError extends Error {}

// The game isn't running, or the connection to it went away.
export class NotConnectedError extends Error {}

type Request = { op: "list" } | { op: "call"; tool: string; args: Record<string, unknown> } | { op: "reload" };

interface Pending {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

const BUSY_RETRY_MS = 250;

// A client for the game's MCP socket: one JSON object per line, each request
// answered once, matched by id. Requests go one at a time, because the game
// runs one at a time and answers a second with "busy".
export class EngineClient {
  #socket: Socket | null = null;
  #decoder = new TextDecoder();
  #buffer = "";
  #nextId = 1;
  #pending = new Map<number, Pending>();
  #queue: Promise<unknown> = Promise.resolve();

  // Called when the connection goes away, whoever closed it.
  onDisconnect: (() => void) | null = null;

  constructor(
    readonly socketPath: string,
    readonly timeoutMs: number,
  ) {}

  get connected(): boolean {
    return this.#socket !== null;
  }

  // Connects if the game is listening. Returns whether it's connected.
  async connect(): Promise<boolean> {
    if (this.#socket !== null) {
      return true;
    }

    try {
      this.#socket = await Bun.connect({
        unix: this.socketPath,
        socket: {
          data: (_socket, data) => this.#receive(data),
          close: () => this.#closed(),
          error: () => this.#closed(),
        },
      });
      return true;
    } catch {
      return false;
    }
  }

  // Keeps trying to connect until the game listens or `timeoutMs` passes.
  async waitForGame(timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await this.connect()) {
        return true;
      }
      await Bun.sleep(250);
    }
    return false;
  }

  close(): void {
    const socket = this.#socket;
    if (socket !== null) {
      this.#closed();
      socket.end();
    }
  }

  list(): Promise<ToolList> {
    return this.#enqueue({ op: "list" }) as Promise<ToolList>;
  }

  call(tool: string, args: Record<string, unknown>): Promise<CallResult> {
    return this.#enqueue({ op: "call", tool, args }) as Promise<CallResult>;
  }

  reload(): Promise<unknown> {
    return this.#enqueue({ op: "reload" });
  }

  #enqueue(request: Request): Promise<unknown> {
    const run = this.#queue.then(() => this.#sendRetryingBusy(request));
    this.#queue = run.catch(() => {});
    return run;
  }

  // The game is still busy if an earlier request timed out here but kept
  // running there; wait for it rather than failing this one.
  async #sendRetryingBusy(request: Request): Promise<unknown> {
    const deadline = Date.now() + this.timeoutMs;
    for (;;) {
      try {
        return await this.#send(request, deadline - Date.now());
      } catch (error) {
        const busy = error instanceof EngineError && error.message.startsWith("busy");
        if (!busy || Date.now() + BUSY_RETRY_MS >= deadline) {
          throw error;
        }
        await Bun.sleep(BUSY_RETRY_MS);
      }
    }
  }

  #send(request: Request, timeoutMs: number): Promise<unknown> {
    const socket = this.#socket;
    if (socket === null) {
      return Promise.reject(new NotConnectedError("The game isn't running. Start it with launch_game."));
    }

    const id = this.#nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new EngineError(`the game didn't answer within ${Math.round(this.timeoutMs / 1000)} s`));
      }, timeoutMs);

      this.#pending.set(id, { resolve, reject, timer });

      // Requests are small, so one write always takes the whole line.
      socket.write(JSON.stringify({ id, ...request }) + "\n");
    });
  }

  #receive(data: Uint8Array): void {
    this.#buffer += this.#decoder.decode(data, { stream: true });

    let newline;
    while ((newline = this.#buffer.indexOf("\n")) >= 0) {
      const line = this.#buffer.slice(0, newline);
      this.#buffer = this.#buffer.slice(newline + 1);
      if (line !== "") {
        this.#dispatch(line);
      }
    }
  }

  #dispatch(line: string): void {
    let reply: { id?: unknown; result?: unknown; error?: { message?: string } };
    try {
      reply = JSON.parse(line);
    } catch {
      console.error(`[bridge] unparseable reply from the game: ${line.slice(0, 200)}`);
      return;
    }

    if (typeof reply.id !== "number") {
      console.error(`[bridge] the game reported: ${reply.error?.message ?? line.slice(0, 200)}`);
      return;
    }

    const pending = this.#pending.get(reply.id);
    if (pending === undefined) {
      // The reply to a request that already timed out.
      return;
    }

    this.#pending.delete(reply.id);
    clearTimeout(pending.timer);

    if (reply.error !== undefined) {
      pending.reject(new EngineError(reply.error.message ?? "the game reported an error"));
    } else {
      pending.resolve(reply.result);
    }
  }

  #closed(): void {
    if (this.#socket === null) {
      return;
    }

    this.#socket = null;
    this.#buffer = "";
    this.#decoder = new TextDecoder();

    for (const [id, pending] of this.#pending) {
      clearTimeout(pending.timer);
      pending.reject(new NotConnectedError("The game closed the connection. Start it again with launch_game."));
      this.#pending.delete(id);
    }

    this.onDisconnect?.();
  }
}
