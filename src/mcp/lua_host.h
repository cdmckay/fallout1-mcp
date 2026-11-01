#ifndef FALLOUT_MCP_LUA_HOST_H_
#define FALLOUT_MCP_LUA_HOST_H_

#include <string>

struct lua_State;

namespace fallout {

// Owns the Lua state that runs the MCP scripts in lua/. The entry script
// returns a module table; the engine drives it through `call`.
class LuaHost {
public:
    // Installs the global `fo` table of bindings into a new state.
    typedef void RegisterBindings(lua_State* L);

    LuaHost();
    ~LuaHost();

    LuaHost(const LuaHost&) = delete;
    LuaHost& operator=(const LuaHost&) = delete;

    // Creates a state with the standard libraries and the bindings, points
    // `require` at `scriptDir`, and runs `scriptDir/main.lua`, keeping the
    // table it returns. Replaces any state from an earlier start.
    bool start(const std::string& scriptDir, RegisterBindings* registerBindings, std::string& error);

    void stop();

    bool isRunning() const;

    // Calls `module.<name>(arg)`, or `module.<name>()` when `arg` is null. A
    // module without that function is not an error. Returns false and sets
    // `error`, with a traceback, if the call raised.
    bool call(const char* name, const std::string* arg, std::string& error);

    lua_State* state() const;

private:
    lua_State* _state;
    int _moduleRef;
};

} // namespace fallout

#endif /* FALLOUT_MCP_LUA_HOST_H_ */
