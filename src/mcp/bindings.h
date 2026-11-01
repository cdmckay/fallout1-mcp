#ifndef FALLOUT_MCP_BINDINGS_H_
#define FALLOUT_MCP_BINDINGS_H_

struct lua_State;

namespace fallout {

// Adds the engine's state and input bindings to the `fo` table on top of the
// stack.
void mcp_register_engine_bindings(lua_State* L);

// Keeps the view on the player as they move, so whoever watches the window
// can follow the agent. Called once per frame.
void mcp_follow_player();

// Whether a game is in progress, with a player on a map.
bool mcp_in_game();

// The inventory bindings (bindings_inventory.cc), added to the same table.
void mcp_register_inventory_bindings(lua_State* L);

// The character sheet bindings (bindings_character.cc), added to the same
// table.
void mcp_register_character_bindings(lua_State* L);

// The text map's bindings (bindings_map.cc), added to the same table.
void mcp_register_map_bindings(lua_State* L);

// The walking bindings (bindings_walk.cc), added to the same table.
void mcp_register_walk_bindings(lua_State* L);

} // namespace fallout

#endif /* FALLOUT_MCP_BINDINGS_H_ */
