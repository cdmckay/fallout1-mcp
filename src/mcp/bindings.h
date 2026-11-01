#ifndef FALLOUT_MCP_BINDINGS_H_
#define FALLOUT_MCP_BINDINGS_H_

struct lua_State;

namespace fallout {

// Adds the engine's state and input bindings to the `fo` table on top of the
// stack.
void mcp_register_engine_bindings(lua_State* L);

} // namespace fallout

#endif /* FALLOUT_MCP_BINDINGS_H_ */
