#ifndef FALLOUT_MCP_SIGHT_RULES_H_
#define FALLOUT_MCP_SIGHT_RULES_H_

#include <vector>

namespace fallout {

// The parts of the sight rule (mcp/sight.h) that don't need the engine.

// Something drawn at a screen point, with an opaque pixel there.
struct McpLayer {
    // The object whose visibility is in question.
    bool target;
    // Flat objects (floor items, blood) are drawn in a pass of their own,
    // before everything else.
    bool flat;
    // Translucent, or cut away by the egg around the player: what's behind
    // shows through.
    bool seeThrough;
};

// Whether the target is what a player sees at a point, given everything
// drawn there in the order the engine lists it (`obj_create_intersect_list`).
bool mcp_target_on_top(const std::vector<McpLayer>& layers);

// Whether an object with `own` pixels, `shown` of them visible, is one a
// player sees: a quarter of it has to show.
bool mcp_enough_shows(int own, int shown);

// How many of `own` pixels have to show.
int mcp_pixels_needed(int own);

} // namespace fallout

#endif /* FALLOUT_MCP_SIGHT_RULES_H_ */
