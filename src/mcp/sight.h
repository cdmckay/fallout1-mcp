#ifndef FALLOUT_MCP_SIGHT_H_
#define FALLOUT_MCP_SIGHT_H_

#include "game/object_types.h"

namespace fallout {

// What a player can see of the map, from what the engine draws. Fallout has
// no fog of war: everything on screen is drawn, and the darkest light the
// engine draws with is a quarter (LIGHT_LEVEL_MIN), which turning up the
// brightness makes out. What hides things is what's drawn over them: roofs
// (the dark rock over a cave's solid parts is roof too) and walls and scenery
// in front. So whether something is visible is decided pixel by pixel, the
// way the game decides what's under the mouse (`object_under_mouse`). The
// parts that don't need the engine are in mcp/sight_rules.h, and
// lua/mcp/sight.lua applies the rule: fair play shows only what's visible.

// Whether screen point (x, y) is in the map view, above the interface bar,
// with no roof drawn over it.
bool mcp_point_visible(int x, int y);

// Whether enough of `object` shows on screen: its own pixels, at visible
// points, with nothing drawn over them (mcp_enough_shows).
bool mcp_object_visible(Object* object);

} // namespace fallout

#endif /* FALLOUT_MCP_SIGHT_H_ */
