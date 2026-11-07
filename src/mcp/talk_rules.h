#ifndef FALLOUT_MCP_TALK_RULES_H_
#define FALLOUT_MCP_TALK_RULES_H_

namespace fallout {

// The part of the rule for who can be talked to that doesn't need the
// engine.

// What the game knows about a critter that tells whether it answers.
struct McpTalker {
    // The game offers Talk on it: it's alive and not knocked out
    // (obj_action_can_talk_to).
    bool offered;
    // It has a script. Talk on a critter without one does nothing.
    bool scripted;
    // Its script has a talk_p_proc, which the game runs when it's talked to.
    bool talkProc;
    // What kind of critter it is, a KILL_TYPE_*.
    int killType;
};

// Whether talking to the critter gets an answer. The game offers Talk on
// every living critter, but only a script answers. One with a talk_p_proc
// does. Older scripts, such as Aradesh's and Tandi's in Shady Sands, have
// none: the game runs their `start` instead, which may answer, and that can't
// be seen from outside. So a scripted person (a man, woman, child, super
// mutant or ghoul) is taken to answer, and a creature, such as a rat or a
// dog, isn't.
bool mcp_can_talk(const McpTalker& critter);

} // namespace fallout

#endif /* FALLOUT_MCP_TALK_RULES_H_ */
