import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Socket, UnixSocketListener } from "bun";

export type Handler = (args: Record<string, unknown>) => unknown | Promise<unknown>;

// Stands in for the game's side of the socket protocol: lists tools, runs
// handlers, and like the game answers "busy" to a call that overlaps another.
export class FakeEngine {
  readonly dir = mkdtempSync(join(tmpdir(), "fo-bridge-"));
  readonly socketPath = join(this.dir, "game.sock");
  readonly requests: Array<Record<string, unknown>> = [];

  access: "fair" | "omniscient" = "fair";
  tools = new Map<string, { description: string; handler: Handler }>();
  reloads = 0;

  #listener: UnixSocketListener<undefined> | null = null;
  #clients = new Set<Socket<undefined>>();
  #running = false;

  tool(name: string, handler: Handler, description = `the ${name} tool`): this {
    this.tools.set(name, { description, handler });
    return this;
  }

  start(): this {
    // A restarted game has nothing running.
    this.#running = false;
    const buffers = new Map<Socket<undefined>, string>();
    this.#listener = Bun.listen({
      unix: this.socketPath,
      socket: {
        open: (socket) => {
          this.#clients.add(socket);
          buffers.set(socket, "");
        },
        data: (socket, data) => {
          let buffer = (buffers.get(socket) ?? "") + new TextDecoder().decode(data);
          let newline;
          while ((newline = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0, newline);
            buffer = buffer.slice(newline + 1);
            void this.#handle(socket, JSON.parse(line));
          }
          buffers.set(socket, buffer);
        },
        close: (socket) => {
          this.#clients.delete(socket);
        },
      },
    });
    return this;
  }

  // Closes the socket and every connection, as a game that quit would.
  stop(): void {
    for (const client of this.#clients) {
      client.end();
    }
    this.#clients.clear();
    this.#listener?.stop(true);
    this.#listener = null;
    rmSync(this.socketPath, { force: true });
  }

  cleanup(): void {
    this.stop();
    rmSync(this.dir, { recursive: true, force: true });
  }

  async #handle(socket: Socket<undefined>, request: Record<string, unknown>): Promise<void> {
    this.requests.push(request);
    const reply = (body: Record<string, unknown>) => socket.write(JSON.stringify({ id: request.id, ...body }) + "\n");

    switch (request.op) {
      case "list":
        reply({
          result: {
            access: this.access,
            tools: [...this.tools].map(([name, tool]) => ({
              name,
              description: tool.description,
              inputSchema: { type: "object", properties: {}, additionalProperties: false },
            })),
          },
        });
        return;

      case "reload":
        this.reloads++;
        reply({ result: { reloaded: true } });
        return;

      case "call": {
        const tool = this.tools.get(request.tool as string);
        if (tool === undefined) {
          reply({ error: { message: `unknown tool: ${request.tool}` } });
          return;
        }
        if (this.#running) {
          reply({ error: { message: `busy: still running something` } });
          return;
        }
        this.#running = true;
        try {
          const value = await tool.handler((request.args ?? {}) as Record<string, unknown>);
          const content = typeof value === "string" ? [{ type: "text", text: value }] : value;
          reply({ result: { content, access: this.access } });
        } catch (error) {
          reply({ error: { message: error instanceof Error ? error.message : String(error) } });
        } finally {
          this.#running = false;
        }
        return;
      }
    }
  }
}
