#include "mcp/talk_rules.h"

#include "game/proto_types.h"

namespace fallout {

// Whether critters of kill type `killType` are people, who may answer from
// a script's `start`.
static bool is_person(int killType)
{
    switch (killType) {
    case KILL_TYPE_MAN:
    case KILL_TYPE_WOMAN:
    case KILL_TYPE_CHILD:
    case KILL_TYPE_SUPER_MUTANT:
    case KILL_TYPE_GHOUL:
        return true;
    default:
        return false;
    }
}

bool mcp_can_talk(const McpTalker& critter)
{
    if (!critter.offered || !critter.scripted) {
        return false;
    }

    return critter.talkProc || is_person(critter.killType);
}

} // namespace fallout
