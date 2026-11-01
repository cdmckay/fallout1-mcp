#ifndef FALLOUT_GAME_WORLDMAP_H_
#define FALLOUT_GAME_WORLDMAP_H_

#include "plib/db/db.h"

namespace fallout {

typedef enum MapFlags {
    MAP_SAVED = 0x01,
    MAP_DEAD_BODIES_AGE = 0x02,
    MAP_PIPBOY_ACTIVE = 0x04,
    MAP_CAN_REST_ELEVATION_0 = 0x08,
    MAP_CAN_REST_ELEVATION_1 = 0x10,
    MAP_CAN_REST_ELEVATION_2 = 0x20,
} MapFlags;

typedef enum City {
    TOWN_VAULT_13 = 0,
    TOWN_VAULT_15 = 1,
    TOWN_SHADY_SANDS = 2,
    TOWN_JUNKTOWN = 3,
    TOWN_RAIDERS = 4,
    TOWN_NECROPOLIS = 5,
    TOWN_THE_HUB = 6,
    TOWN_BROTHERHOOD = 7,
    TOWN_MILITARY_BASE = 8,
    TOWN_THE_GLOW = 9,
    TOWN_BONEYARD = 10,
    TOWN_CATHEDRAL = 11,
    TOWN_COUNT = 12,
    TOWN_SPECIAL_12 = 12,
    TOWN_SPECIAL_13 = 13,
    TOWN_SPECIAL_14 = 14,
} City;

typedef enum Map {
    MAP_DESERT1,
    MAP_DESERT2,
    MAP_DESERT3,
    MAP_HALLDED,
    MAP_HOTEL,
    MAP_WATRSHD,
    MAP_VAULT13,
    MAP_VAULTENT,
    MAP_VAULTBUR,
    MAP_VAULTNEC,
    MAP_JUNKENT,
    MAP_JUNKCSNO,
    MAP_JUNKKILL,
    MAP_BROHDENT,
    MAP_BROHD12,
    MAP_BROHD34,
    MAP_CAVES,
    MAP_CHILDRN1,
    MAP_CHILDRN2,
    MAP_CITY1,
    MAP_COAST1,
    MAP_COAST2,
    MAP_COLATRUK,
    MAP_FSAUSER,
    MAP_RAIDERS,
    MAP_SHADYE,
    MAP_SHADYW,
    MAP_GLOWENT,
    MAP_LAADYTUM,
    MAP_LAFOLLWR,
    MAP_MBENT,
    MAP_MBSTRG12,
    MAP_MBVATS12,
    MAP_MSTRLR12,
    MAP_MSTRLR34,
    MAP_V13ENT,
    MAP_HUBENT,
    MAP_DETHCLAW,
    MAP_HUBDWNTN,
    MAP_HUBHEIGT,
    MAP_HUBOLDTN,
    MAP_HUBWATER,
    MAP_GLOW1,
    MAP_GLOW2,
    MAP_LABLADES,
    MAP_LARIPPER,
    MAP_LAGUNRUN,
    MAP_CHILDEAD,
    MAP_MBDEAD,
    MAP_MOUNTN1,
    MAP_MOUNTN2,
    MAP_FOOT,
    MAP_TARDIS,
    MAP_TALKCOW,
    MAP_USEDCAR,
    MAP_BRODEAD,
    MAP_DESCRVN1,
    MAP_DESCRVN2,
    MAP_MNTCRVN1,
    MAP_MNTCRVN2,
    MAP_VIPERS,
    MAP_DESCRVN3,
    MAP_MNTCRVN3,
    MAP_DESCRVN4,
    MAP_MNTCRVN4,
    MAP_HUBMIS1,
    MAP_COUNT,
} Map;

typedef enum TerrainType {
    TERRAIN_TYPE_DESERT,
    TERRAIN_TYPE_MOUNTAIN,
    TERRAIN_TYPE_CITY,
    TERRAIN_TYPE_COAST,
} TerrainType;

typedef enum WorldmapFrm {
    WORLDMAP_FRM_LITTLE_RED_BUTTON_NORMAL,
    WORLDMAP_FRM_LITTLE_RED_BUTTON_PRESSED,
    WORLDMAP_FRM_BOX,
    WORLDMAP_FRM_LABELS,
    WORLDMAP_FRM_LOCATION_MARKER,
    WORLDMAP_FRM_DESTINATION_MARKER_BRIGHT,
    WORLDMAP_FRM_DESTINATION_MARKER_DARK,
    WORLDMAP_FRM_RANDOM_ENCOUNTER_BRIGHT,
    WORLDMAP_FRM_RANDOM_ENCOUNTER_DARK,
    WORLDMAP_FRM_WORLDMAP,
    WORLDMAP_FRM_MONTHS,
    WORLDMAP_FRM_NUMBERS,
    WORLDMAP_FRM_HOTSPOT_NORMAL,
    WORLDMAP_FRM_HOTSPOT_PRESSED,
    WORLDMAP_FRM_COUNT,
} WorldmapFrm;

typedef enum TownmapFrm {
    TOWNMAP_FRM_BOX,
    TOWNMAP_FRM_LABELS,
    TOWNMAP_FRM_HOTSPOT_PRESSED,
    TOWNMAP_FRM_HOTSPOT_NORMAL,
    TOWNMAP_FRM_LITTLE_RED_BUTTON_NORMAL,
    TOWNMAP_FRM_LITTLE_RED_BUTTON_PRESSED,
    TOWNMAP_FRM_MONTHS,
    TOWNMAP_FRM_NUMBERS,
    TOWNMAP_FRM_COUNT,
} TownmapFrm;

typedef struct WorldMapContext {
    short state;
    short town;
    short section;
} WorldMapContext;

extern int world_win;
extern int our_section;
extern int our_town;

int init_world_map();
int save_world_map(DB_FILE* stream);
int load_world_map(DB_FILE* stream);
int world_map(WorldMapContext ctx);
WorldMapContext town_map(WorldMapContext ctx);
void KillWorldWin();
int worldmap_script_jump(int city, int a2);
int xlate_mapidx_to_town(int map_idx);

// MCP
bool world_map_is_open();
int PlayCityMapMusic();

// MCP: Event codes the agent injects into the world map's loop, for what
// otherwise needs the mouse: travel to the point worldmap_set_travel_target
// set, as clicking the map there does, and enter the place the player stands
// on, as clicking their marker does.
#define WORLDMAP_TRAVEL_CODE 0x7100
#define WORLDMAP_ENTER_CODE 0x7101

// MCP: How the world map's loop was last left.
typedef enum WorldMapExit {
    WORLDMAP_EXIT_NONE, // not left, or left for the main menu
    WORLDMAP_EXIT_TERRAIN, // into the open ground the player stood on
    WORLDMAP_EXIT_TOWN, // into a town
    WORLDMAP_EXIT_ENCOUNTER, // a random encounter
    WORLDMAP_EXIT_SPECIAL_ENCOUNTER, // one of the special encounters
} WorldMapExit;

// MCP: What the world map shows, in world-map pixels (50 to a square).
typedef struct WorldMapStatus {
    int x; // the player
    int y;
    int moving;
    int target_x; // where they're headed, while moving
    int target_y;
    int can_enter; // standing still with their marker up
    int town; // the town they're in, or -1
    int town_known; // whether the map names it
    int terrain; // a TerrainType
    int known_towns; // a bit per town the map lists
    int last_exit; // a WorldMapExit
} WorldMapStatus;

// MCP
void worldmap_status(WorldMapStatus* status);
void worldmap_town_position(int town, int* x, int* y);
void worldmap_set_travel_target(int x, int y);
int worldmap_town_map(int* town, const char** places, int max);

} // namespace fallout

#endif /* FALLOUT_GAME_WORLDMAP_H_ */
