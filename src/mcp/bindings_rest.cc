#include "mcp/bindings.h"

#include <algorithm>

#include <lua.hpp>

#include "game/critter.h"
#include "game/intface.h"
#include "game/object.h"
#include "game/pipboy.h"

namespace fallout {

// Resting, as the Pip-Boy's alarm clock does it. The alarm clock itself does
// the resting: the agent opens it and picks a choice with its event codes,
// and these say whether the game allows a rest here and when it's over.

// fo.can_rest(): whether the game lets the player rest here, as the alarm
// clock checks before it offers its choices. It says "You cannot rest at
// this location!" when anything alive on this level has been hit by the
// player, and outside the towns when anything alive isn't on their side.
static int fo_can_rest(lua_State* L)
{
    lua_pushboolean(L, mcp_in_game() && critter_can_obj_dude_rest());
    return 1;
}

// fo.resting(): whether the alarm clock is resting right now, and whether
// its last rest was cut short.
static int fo_resting(lua_State* L)
{
    lua_pushboolean(L, pipboy_is_resting());
    lua_pushboolean(L, pipboy_rest_was_interrupted());
    return 2;
}

// fo.hurt(hp, poison): takes `hp` from the player, leaving them at least 1,
// and poisons them by `poison`, less their poison resistance, as a bite
// does. For testing rests and conditions; Lua offers it in omniscient mode
// only.
static int fo_hurt(lua_State* L)
{
    lua_Integer hp = luaL_checkinteger(L, 1);
    lua_Integer poison = luaL_optinteger(L, 2, 0);
    luaL_argcheck(L, hp >= 0 && hp <= 1000, 1, "hp must be 0 to 1000");
    luaL_argcheck(L, poison >= 0 && poison <= 100, 2, "poison must be 0 to 100");

    if (!mcp_in_game()) {
        return luaL_error(L, "no game in progress");
    }

    int damage = std::min(static_cast<int>(hp), critter_get_hits(obj_dude) - 1);
    if (damage > 0) {
        critter_adjust_hits(obj_dude, -damage);
    }
    if (poison > 0) {
        critter_adjust_poison(obj_dude, static_cast<int>(poison));
    }
    intface_update_hit_points(false);
    return 0;
}

void mcp_register_rest_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "can_rest", fo_can_rest },
        { "resting", fo_resting },
        { "hurt", fo_hurt },
        { nullptr, nullptr },
    };

    luaL_setfuncs(L, functions, 0);
}

} // namespace fallout
