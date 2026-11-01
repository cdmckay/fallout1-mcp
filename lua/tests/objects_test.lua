local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

local KEY_TAKE_ALL = 65
local KEY_ESCAPE = 27

-- A fake engine with the player at tile 100 in the Vault 13 cave, and the
-- objects a test puts in `world.objects`. Tiles are numbers along a line, so
-- distances are differences. Each action makes the player busy for a few
-- frames, then lands as the game would: the player steps next to the
-- target and the object is picked up, opened, looted or swung.
local function setup(options)
    options = options or {}
    local core, engine = support.new({ omniscient = options.omniscient })

    local world = {
        player = { name = "Max Stone", tile = 100, elevation = 0, map = { file = "V13ENT.MAP", name = "Vault 13" } },
        objects = {},
        contents = {},
        calls = {},
        input = {},
        messages = {},
        busy = 0,
        landing = nil,
        loot = nil,
        combat = nil,
        reachable = true,
        weight = 11,
        capacity = 275,
    }

    local function copy(t)
        local c = {}
        for k, v in pairs(t) do
            c[k] = v
        end
        return c
    end

    local function message(text)
        world.messages[#world.messages + 1] = text
    end

    local function weight_of(items)
        local total = 0
        for _, item in ipairs(items) do
            total = total + item.weight * item.quantity
        end
        return total
    end

    fo.flags = function()
        return { in_game = true, combat = world.combat ~= nil, inventory_screen = world.loot ~= nil and "loot" or nil }
    end
    fo.player = function()
        local player = copy(world.player)
        player.map = copy(world.player.map)
        return player
    end
    fo.combat = function()
        return world.combat
    end
    fo.player_busy = function()
        return world.busy > 0
    end
    fo.messages = function(after)
        local lines = {}
        for seq = math.min(after or 0, #world.messages) + 1, #world.messages do
            lines[#lines + 1] = { seq = seq, text = world.messages[seq] }
        end
        return lines, #world.messages
    end
    fo.objects = function()
        local list = {}
        for _, object in pairs(world.objects) do
            list[#list + 1] = copy(object)
        end
        table.sort(list, function(a, b)
            return a.id < b.id
        end)
        return list
    end
    fo.object = function(id)
        local object = world.objects[id]
        return object and copy(object) or nil
    end
    fo.path_length = function()
        return world.reachable and 5 or 0
    end
    fo.inject = function(code)
        world.input[#world.input + 1] = code
        return true
    end
    fo.input_pending = function()
        return #world.input > 0
    end

    fo.loot_screen = function()
        if world.loot == nil then
            return nil
        end
        local items = {}
        for i, item in ipairs(world.loot.items) do
            items[i] = copy(item)
        end
        return {
            target = { id = world.loot.id, name = world.loot.name },
            items = items,
            weight = world.weight,
            capacity = world.capacity,
            target_weight = weight_of(world.loot.items),
        }
    end
    fo.take = function(id, quantity)
        world.calls[#world.calls + 1] = { name = "take", id = id, quantity = quantity }
        world.taking = { id = id, quantity = quantity }
        world.take_result = nil
        return true
    end
    fo.take_result = function()
        return world.take_result
    end

    -- Starts an action as the game takes it: the player walks and acts for
    -- a few frames, then `land` runs, if the player could get there.
    local function act(name, land)
        return function(id)
            world.calls[#world.calls + 1] = { name = name, id = id }
            if world.refuse then
                return false, world.refuse
            end
            world.busy = 3
            world.landing = function()
                if not world.reachable then
                    return
                end
                world.player.tile = world.objects[id].tile - 1
                land(world.objects[id])
            end
            return true
        end
    end

    fo.pick_up = act("pick_up", function(item)
        world.objects[item.id] = nil
    end)
    fo.loot = act("loot", function(target)
        if target.kind == "container" then
            if target.open then
                target.open = false
                message("You close the " .. target.name .. ".")
                return
            end
            if target.locked then
                message("It is locked.")
                return
            end
            target.open = true
        end
        message("You search the " .. target.name .. ".")
        world.loot = { id = target.id, name = target.name, items = world.contents[target.id] or {} }
    end)
    fo.use_object = act("use_object", function(target)
        if target.kind == "door" and not target.locked then
            target.open = not target.open
        elseif target.kind == "door" then
            message("This door is locked.")
        end
    end)
    fo.look_at = function(id)
        world.calls[#world.calls + 1] = { name = "look_at", id = id }
        message("You see " .. (world.objects[id] and world.objects[id].name or "a critter") .. ".")
        return true
    end

    local frames = engine.frames
    engine.frames = function(n)
        for _ = 1, n or 1 do
            if world.busy > 0 then
                world.busy = world.busy - 1
                if world.busy == 0 and world.landing ~= nil then
                    local land = world.landing
                    world.landing = nil
                    land()
                end
            end

            -- The loot screen's loop reads its keys and take code.
            local code = table.remove(world.input, 1)
            if code == KEY_TAKE_ALL and world.loot ~= nil then
                world.weight = world.weight + weight_of(world.loot.items)
                world.loot.items = {}
            elseif code == KEY_ESCAPE then
                world.loot = nil
            end
            if world.taking ~= nil and world.loot ~= nil then
                local taking = world.taking
                world.taking = nil
                world.take_result = "not there"
                for i, item in ipairs(world.loot.items) do
                    if item.id == taking.id then
                        local quantity = taking.quantity > 0 and math.min(taking.quantity, item.quantity) or item.quantity
                        if world.weight + item.weight * quantity > world.capacity then
                            world.take_result = "too heavy"
                        else
                            world.weight = world.weight + item.weight * quantity
                            item.quantity = item.quantity - quantity
                            if item.quantity == 0 then
                                table.remove(world.loot.items, i)
                            else
                                -- The rest of a split stack gets a new id.
                                item.id = item.id + 1000
                            end
                            world.take_result = "taken"
                        end
                        break
                    end
                end
            end

            frames(1)
        end
    end

    require("tools.objects")(core)
    require("tools.perception")(core)

    local function call(tool, args)
        engine.request({ id = 1, op = "call", tool = tool, args = args or {} })
        engine.frames(80)
        local reply = engine.reply()
        if reply.error then
            return nil, reply.error.message
        end
        return (json.decode(reply.result.content[1].text))
    end

    return world, call
end

local function bones(world)
    world.objects[271] = { id = 271, name = "Bones", kind = "container", type = "container", tile = 102, visible = true, open = false, locked = false }
    world.contents[271] = {
        { id = 272, name = "Knife", type = "weapon", quantity = 1, weight = 1 },
        { id = 273, name = "10mm AP", type = "ammo", quantity = 24, weight = 1 },
    }
end

local function by_id(list, id)
    for _, entry in ipairs(list or {}) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

local function called(world, name)
    local calls = {}
    for _, entry in ipairs(world.calls) do
        if entry.name == name then
            calls[#calls + 1] = entry
        end
    end
    return calls
end

function tests.the_view_lists_what_a_player_can_see_nearest_first_with_its_actions()
    local world, call = setup()
    bones(world)
    world.objects[29] = { id = 29, name = "Security Door", kind = "door", tile = 123, visible = true, open = false, locked = true }
    world.objects[240] = { id = 240, name = "Door Entry Computer", kind = "scenery", tile = 95, visible = true }
    world.objects[489] = { id = 489, name = "Cave Rat", kind = "body", tile = 104, visible = true }
    world.objects[18] = { id = 18, name = "Rope", kind = "item", type = "misc", tile = 101, visible = false }

    local view = call("state")

    equal(#view.objects, 4, "the rope out of sight isn't listed")
    equal(view.objects[1].name, "Bones", "nearest first")
    equal(view.objects[1].kind, "container", "kind")
    equal(view.objects[1].actions[1], "loot", "a container is looted")
    equal(view.objects[1].type, nil, "a container's item type says nothing more")
    equal(view.objects[2].name, "Cave Rat", "a body")
    equal(view.objects[2].actions[1], "loot", "a body is looted")
    equal(view.objects[3].actions[1], "use", "scenery is used")
    equal(view.objects[4].distance, 23, "distance")
    equal(view.objects[4].open, false, "a door says whether it's open")
    equal(view.objects[4].locked, nil, "but not that it's locked, until tried")
end

function tests.omniscient_mode_lists_everything_and_says_what_is_locked()
    local world, call = setup({ omniscient = true })
    world.objects[29] = { id = 29, name = "Security Door", kind = "door", tile = 123, visible = false, open = false, locked = true }
    world.objects[18] = { id = 18, name = "Rope", kind = "item", type = "misc", tile = 101, visible = false }

    local view = call("state")

    equal(#view.objects, 2, "everything")
    equal(by_id(view.objects, 18).actions[1], "pick_up", "an item is picked up")
    equal(by_id(view.objects, 29).locked, true, "the lock")
end

function tests.a_long_list_is_capped_and_says_how_many_it_left_out()
    local world, call = setup()
    for i = 1, 15 do
        world.objects[i] = { id = i, name = "Rock", kind = "item", type = "misc", tile = 100 + i, visible = true }
    end

    local view = call("state")
    equal(#view.objects, 12, "the nearest dozen")
    equal(view.objects_left_out, 3, "left out")

    local all = call("objects")
    equal(#all.objects, 15, "objects has them all")
end

function tests.pick_up_walks_over_and_says_what_it_picked_up()
    local world, call = setup()
    world.objects[18] = { id = 18, name = "Rope", kind = "item", type = "misc", tile = 105, visible = true }

    local view = call("pick_up", { target = 18 })

    equal(called(world, "pick_up")[1].id, 18, "the game's pick-up")
    equal(view.picked_up.name, "Rope", "picked up")
    equal(by_id(view.objects, 18), nil, "it's off the ground")
end

function tests.pick_up_says_when_there_is_no_way_there()
    local world, call = setup()
    world.reachable = false
    world.objects[18] = { id = 18, name = "Rope", kind = "item", type = "misc", tile = 150, visible = true }

    local view = call("pick_up", { target = 18 })

    equal(view.picked_up, nil, "nothing picked up")
    contains(view.note, "no way there", "why")
end

function tests.pick_up_only_takes_items_a_player_can_see()
    local world, call = setup()
    bones(world)
    world.objects[18] = { id = 18, name = "Rope", kind = "item", type = "misc", tile = 105, visible = false }

    local _, unseen = call("pick_up", { target = 18 })
    contains(unseen, "nothing with id 18 in sight", "out of sight")

    local _, container = call("pick_up", { target = 271 })
    contains(container, "loot it with loot", "a container is looted, not picked up")

    equal(#called(world, "pick_up"), 0, "no pick-up")
end

function tests.loot_opens_the_loot_screen_and_lists_what_is_inside()
    local world, call = setup()
    bones(world)

    local view = call("loot", { target = 271 })

    equal(view.mode, "loot", "mode")
    equal(view.loot.from.name, "Bones", "what's looted")
    equal(#view.loot.items, 2, "what's inside")
    equal(view.loot.items[1].name, "Knife", "item")
    equal(view.loot.items_weight, 25, "its weight")
    equal(view.loot.capacity, 275, "what you can carry")
    equal(view.objects, nil, "the map's lists wait until it closes")
end

function tests.loot_with_take_all_takes_everything_and_closes()
    local world, call = setup()
    bones(world)

    local view = call("loot", { target = 271, take_all = true })

    equal(view.mode, "map", "closed again")
    equal(#view.taken, 2, "taken")
    equal(view.taken[1].name, "10mm AP", "by name")
    equal(view.taken[1].quantity, 24, "the whole stack")
    equal(world.loot, nil, "the screen closed with escape")
end

function tests.an_open_container_is_closed_then_opened_as_two_clicks_do()
    local world, call = setup()
    bones(world)
    world.objects[271].open = true

    local view = call("loot", { target = 271 })

    equal(#called(world, "loot"), 2, "two clicks")
    equal(view.mode, "loot", "looting")
end

function tests.a_locked_container_says_so_and_is_listed_locked_from_then_on()
    local world, call = setup()
    bones(world)
    world.objects[271].locked = true
    call("state")

    local view = call("loot", { target = 271 })
    equal(view.mode, "map", "it stayed shut")
    equal(view.note, "It's locked.", "note")
    equal(view.messages[1], "It is locked.", "the game's message")
    equal(by_id(view.objects, 271).locked, true, "remembered")
end

function tests.take_moves_chosen_items_and_part_of_a_stack()
    local world, call = setup()
    bones(world)
    call("loot", { target = 271 })

    local view = call("take", { items = { 273 }, quantity = 10 })

    local takes = called(world, "take")
    equal(takes[1].id, 273, "the item")
    equal(takes[1].quantity, 10, "how many")
    equal(view.mode, "loot", "still looting")
    equal(view.taken[1].name, "10mm AP", "taken")
    equal(view.taken[1].quantity, 10, "part of the stack")
    equal(by_id(view.loot.items, 1273).quantity, 14, "the rest stays")

    view = call("take", { items = { 272 }, close = true })
    equal(view.taken[1].name, "Knife", "taken")
    equal(view.mode, "map", "and left")
end

function tests.take_says_what_was_too_heavy_to_take()
    local world, call = setup()
    bones(world)
    world.contents[271][1].weight = 300
    call("loot", { target = 271 })

    local view = call("take", { items = { 272, 273 } })

    equal(#view.taken, 1, "the ammo")
    contains(view.note, "272: it's more than you can carry", "the knife")
end

function tests.take_all_refuses_more_than_you_can_carry_without_pressing_a()
    local world, call = setup()
    bones(world)
    world.capacity = 20
    call("loot", { target = 271 })

    local _, err = call("take", { all = true })

    contains(err, "it weighs 25 and you can carry 9 more", "why")
    equal(#world.loot.items, 2, "nothing moved")
end

function tests.take_needs_the_loot_screen()
    local _, call = setup()

    local _, err = call("take", { all = true })

    contains(err, "loot a body or container first", "why")
end

function tests.use_opens_and_closes_a_door()
    local world, call = setup()
    world.objects[29] = { id = 29, name = "Security Door", kind = "door", tile = 103, visible = true, open = false, locked = false }

    local view = call("use", { target = 29 })
    equal(view.door.open, true, "open")
    equal(view.note, nil, "nothing to explain")

    view = call("use", { target = 29 })
    equal(view.door.open, false, "closed again")
end

function tests.a_locked_door_says_so_and_is_listed_locked_from_then_on()
    local world, call = setup()
    world.objects[29] = { id = 29, name = "Security Door", kind = "door", tile = 103, visible = true, open = false, locked = true }

    local view = call("use", { target = 29 })

    equal(view.door.open, false, "still shut")
    equal(view.note, "It's locked.", "note")
    equal(by_id(view.objects, 29).locked, true, "remembered")
end

function tests.look_at_examines_objects_and_critters_in_sight()
    local world, call = setup()
    bones(world)
    fo.critters = function()
        return { { id = 489, name = "Cave Rat", tile = 110, visible = true, dead = false, health = "Unhurt" } }
    end
    call("state")

    local view = call("look_at", { target = 271 })
    equal(view.looked_at.name, "Bones", "looked at")
    equal(view.messages[1], "You see Bones.", "the description")

    view = call("look_at", { target = 489 })
    equal(view.looked_at.name, "Cave Rat", "a critter")

    local _, err = call("look_at", { target = 5 })
    contains(err, "nothing with id 5 in sight", "unknown")
end

function tests.a_fight_the_agent_has_not_seen_stops_the_action_before_it_starts()
    local world, call = setup()
    bones(world)
    world.combat = { can_act = true, animating = false, ap = 6, max_ap = 6, free_move = 0, turn = "Max Stone" }

    local view = call("loot", { target = 271 })

    equal(#called(world, "loot"), 0, "didn't act")
    contains(view.note, "A fight has started, so you didn't act.", "why")
end

function tests.the_engine_s_reason_reaches_the_agent()
    local world, call = setup()
    bones(world)
    world.refuse = "it isn't your turn"

    local _, err = call("loot", { target = 271 })

    contains(err, "it isn't your turn", "reason")
end

return tests
