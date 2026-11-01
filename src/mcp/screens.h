#ifndef FALLOUT_MCP_SCREENS_H_
#define FALLOUT_MCP_SCREENS_H_

#include <string>
#include <vector>

namespace fallout {

// The screens open over the map, innermost last, for the state view. Many of
// the engine's screens keep no flag saying they're up, so each one's function
// opens an McpScreen scope (marked MCP), which records the screen for as long
// as the function runs, however it returns.
void mcp_screen_push(const char* name);
void mcp_screen_pop(const char* name);
const std::vector<std::string>& mcp_screens();

class McpScreen {
public:
    explicit McpScreen(const char* name)
        : _name(name)
    {
        mcp_screen_push(name);
    }

    ~McpScreen()
    {
        mcp_screen_pop(_name);
    }

    McpScreen(const McpScreen&) = delete;
    McpScreen& operator=(const McpScreen&) = delete;

private:
    const char* _name;
};

} // namespace fallout

#endif /* FALLOUT_MCP_SCREENS_H_ */
