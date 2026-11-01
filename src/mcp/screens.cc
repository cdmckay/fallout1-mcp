#include "mcp/screens.h"

namespace fallout {

static std::vector<std::string> gScreens;

void mcp_screen_push(const char* name)
{
    gScreens.emplace_back(name);
}

void mcp_screen_pop(const char* name)
{
    // The innermost screen of that name. Screens close in order, but a
    // mismatch shouldn't leave a stale name on top.
    for (auto it = gScreens.rbegin(); it != gScreens.rend(); ++it) {
        if (*it == name) {
            gScreens.erase(std::next(it).base());
            return;
        }
    }
}

const std::vector<std::string>& mcp_screens()
{
    return gScreens;
}

} // namespace fallout
