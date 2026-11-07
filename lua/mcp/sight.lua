-- What fair play may show: what a player can see on screen. The engine
-- decides that pixel by pixel (src/mcp/sight.h): a critter, item or hex is
-- `visible` when it's in the map view with no roof over it and, for things
-- standing on the map, enough of it showing past whatever's drawn in front.
-- A hex is hidden too when a wall or rock standing in front of it is drawn
-- over it, as the floor inside a building is behind its front walls.
-- Lighting doesn't hide anything: the engine never draws darker than a
-- quarter, and a player turns the brightness up. Omniscient mode sees
-- everything. Every view asks here, so the critter list and the text map
-- always agree.

local sight = {}

function sight.sees(thing)
    return thing.visible == true or fo.omniscient()
end

-- The critters a player can see, living and dead, as fo.critters gives them.
function sight.critters()
    local seen = {}
    for _, critter in ipairs(fo.critters()) do
        if sight.sees(critter) then
            seen[#seen + 1] = critter
        end
    end
    return seen
end

return sight
