#ifndef FALLOUT_MCP_MCP_H_
#define FALLOUT_MCP_MCP_H_

namespace fallout {

// MCP lets an agent play through a local socket; see docs/mcp-design.md. It is
// off unless FALLOUT_MCP_SOCKET is set, and then needs FALLOUT_MCP_LUA to point
// at the lua/ directory. A failure to start is logged and the game plays on
// without it.
bool mcp_init();
void mcp_exit();
bool mcp_is_enabled();

// Services the socket and the Lua scheduler. Called once per frame from
// process_bk, which can nest when a command opens a screen.
void mcp_tick();

} // namespace fallout

#endif /* FALLOUT_MCP_MCP_H_ */
