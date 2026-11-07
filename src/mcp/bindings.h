#ifndef FALLOUT_MCP_BINDINGS_H_
#define FALLOUT_MCP_BINDINGS_H_

#include <vector>

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

// The hexes the player could walk to from where they stand, by tile
// (bindings_map.cc). A walk stops at an exit grid, which leaves the map. With
// `throughDoors`, closed doors don't stop it, as a player could open them.
std::vector<bool> mcp_reachable_tiles(int elevation, bool throughDoors);

// The walking bindings (bindings_walk.cc), added to the same table.
void mcp_register_walk_bindings(lua_State* L);

// The world map bindings (bindings_worldmap.cc), added to the same table.
void mcp_register_worldmap_bindings(lua_State* L);

// Sets `attacker` (id, name and whether the player could see it) on the
// table on top of the stack, if message `seq` was printed during another
// critter's attack (bindings_combat.cc).
void mcp_set_message_attacker(lua_State* L, long long seq);

// The bindings for objects on the map (bindings_objects.cc), added to the
// same table.
void mcp_register_object_bindings(lua_State* L);

// The resting bindings (bindings_rest.cc), added to the same table.
void mcp_register_rest_bindings(lua_State* L);

} // namespace fallout

#endif /* FALLOUT_MCP_BINDINGS_H_ */
