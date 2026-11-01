#include "mcp/sight_rules.h"

namespace fallout {

// A rat's nose past a rock is easy to miss; a quarter of the rat isn't, and
// neither is one half off the edge of the screen.
static constexpr int kVisibleShare = 4;

bool mcp_target_on_top(const std::vector<McpLayer>& layers)
{
    // Later layers are drawn over earlier ones, but every flat one is drawn
    // before any that isn't.
    const McpLayer* top = nullptr;
    const McpLayer* topFlat = nullptr;
    for (auto it = layers.rbegin(); it != layers.rend() && top == nullptr; ++it) {
        if (it->seeThrough && !it->target) {
            continue;
        }
        if (!it->flat) {
            top = &*it;
        } else if (topFlat == nullptr) {
            topFlat = &*it;
        }
    }

    const McpLayer* shown = top != nullptr ? top : topFlat;
    return shown != nullptr && shown->target;
}

int mcp_pixels_needed(int own)
{
    return (own + kVisibleShare - 1) / kVisibleShare;
}

bool mcp_enough_shows(int own, int shown)
{
    return own > 0 && shown >= mcp_pixels_needed(own);
}

} // namespace fallout
