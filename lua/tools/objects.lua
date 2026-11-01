local objects = require("mcp.objects")
local sight = require("mcp.sight")
local state = require("mcp.state")

-- A slow walking pace, so the walk up to an object finishes well inside the
-- wait, and time for the action's own animation once there.
local MS_PER_HEX = 600
local ACTION_MS = 3000

-- How long the player may stay busy finishing something else before an
-- action gives up waiting to start.
local BUSY_TIMEOUT_MS = 2000

-- How long the loot screen may take to open once the player is done: the
-- game opens it on its main loop's next pass.
local OPEN_TIMEOUT_MS = 500

-- How long the loot screen may take to read a key or close.
local SCREEN_TIMEOUT_MS = 3000

-- How long the others' turns may take, once a fight has stopped an action.
local TURN_TIMEOUT_MS = 60000

-- Frames for what the action set off to land in the views.
local SETTLE_FRAMES = 3

-- Keys the loot screen reads: A takes everything, escape leaves.
local KEY_TAKE_ALL = 65
local KEY_ESCAPE = 27

-- What to do instead, for an object of the wrong kind.
local USE_INSTEAD = {
    item = "pick it up with pick_up",
    body = "loot it with loot",
    container = "loot it with loot",
    door = "open or close it with use",
    scenery = "use it with use",
}

return function(core)
    local function place(player)
        return player and ("%s:%d"):format(player.map and player.map.file or "?", player.elevation or 0) or nil
    end

    -- The player, if they're on the map where objects can be acted on.
    local function on_map()
        local player = fo.player()
        if player == nil then
            core.fail("there's no game in progress")
        end
        local mode = state.mode(fo.flags())
        if mode ~= "map" and mode ~= "combat" then
            core.fail(("this works on the map, and the %s screen is up"):format(mode))
        end
        return player
    end

    -- Object `id` as the objects list has it, if the player can see it and
    -- it's one of `kinds`.
    local function seen(player, id, kinds)
        if math.type(id) ~= "integer" then
            core.fail("target must be an object's id, from the state view's objects or the objects tool")
        end

        for _, object in ipairs(objects.list(player)) do
            if object.id == id then
                if not kinds[object.kind] then
                    core.fail(("%s is a %s: %s"):format(object.name, object.kind, USE_INSTEAD[object.kind]))
                end
                return object
            end
        end
        core.fail(("there's nothing with id %d in sight"):format(id))
    end

    local function finish(fields, note)
        local view = state.view()
        for key, value in pairs(fields or {}) do
            view[key] = value
        end
        view.note = note
        return { data = view }
    end

    -- A fight stopped the action, or was on before it without the agent
    -- knowing. Either way this returns on the player's turn, as walk_to does.
    local function fight_started(began)
        core.wait_until(function()
            local combat = fo.combat()
            return combat == nil or (combat.can_act and not combat.animating)
        end, TURN_TIMEOUT_MS)
        core.wait_frames(SETTLE_FRAMES)

        local what = began and "A fight started and stopped you." or "A fight has started, so you didn't act."
        if fo.combat() == nil then
            return finish(nil, what .. " It's over already.")
        end
        return finish(nil, what .. " It's your turn.")
    end

    local function fight_unseen()
        return fo.combat() ~= nil and not state.showed_fight()
    end

    -- Starts an action. A player still finishing a step gets a moment, as
    -- for walk_to.
    local function start(binding, id)
        local ok, why = binding(id)
        if not ok and why == "busy" then
            core.wait_until(function()
                return not fo.player_busy()
            end, BUSY_TIMEOUT_MS)
            ok, why = binding(id)
        end
        if not ok then
            core.fail(why == "busy" and "the game didn't take the action: the player is still busy with something else" or why)
        end
    end

    -- Waits while the player walks up and acts, and while the object moves
    -- (a door swinging), or until `done` says it's over.
    local function settle(object, done)
        core.wait_frames(2)
        core.wait_until(function()
            if done ~= nil and done() then
                return true
            end
            if fo.player_busy() then
                return false
            end
            local now = fo.object(object.id)
            return now == nil or not now.busy
        end, object.distance * MS_PER_HEX + ACTION_MS)
        core.wait_frames(SETTLE_FRAMES)
    end

    -- Why an action didn't happen, when nothing else says. Items and bodies
    -- don't block, so the game's path to their own hex says whether there's
    -- a way there at all.
    local function not_reached(object, otherwise)
        local player = fo.player()
        if player ~= nil and fo.tile_distance(player.tile, object.tile) > 1 then
            if (object.kind == "item" or object.kind == "body") and fo.path_length(object.tile) == 0 then
                return "The game finds no way there from here."
            end
            return "You couldn't get next to it."
        end
        return otherwise
    end

    -- What's on the loot screen, by name and type, so a stack split by
    -- taking part of it still adds up.
    local function loot_counts()
        local counts = {}
        local screen = fo.loot_screen()
        for _, item in ipairs(screen and screen.items or {}) do
            local key = item.name .. "\0" .. item.type
            local count = counts[key] or { name = item.name, quantity = 0 }
            count.quantity = count.quantity + item.quantity
            counts[key] = count
        end
        return counts
    end

    -- What left the loot screen between two loot_counts.
    local function taken_between(before, after)
        local taken = {}
        for key, count in pairs(before) do
            local gone = count.quantity - (after[key] and after[key].quantity or 0)
            if gone > 0 then
                taken[#taken + 1] = { name = count.name, quantity = gone }
            end
        end
        table.sort(taken, function(a, b)
            return a.name < b.name
        end)
        return core.array(taken)
    end

    -- Presses a key on the loot screen and waits until it's been read.
    local function press(code)
        if not fo.inject(code) then
            core.fail("the game's input queue is full; try again")
        end
        core.wait_until(function()
            return not fo.input_pending()
        end, SCREEN_TIMEOUT_MS)
        core.wait_frames(2)
    end

    -- Takes everything, as the loot screen's A key does, unless it's more
    -- than the player can carry: then A would only put up a message box.
    local function take_all()
        local loot = objects.loot_view()
        local room = loot.capacity - loot.weight
        if loot.items_weight > room then
            core.fail(("you can't carry all of it: it weighs %d and you can carry %d more; take items one by one instead"):format(loot.items_weight, room))
        end
        press(KEY_TAKE_ALL)
    end

    -- Takes item `id`, all of its stack or `quantity`, through the loot
    -- screen's take code. Returns nil, or why it wasn't taken.
    local function take_one(id, quantity)
        if not fo.take(id, quantity or 0) then
            core.fail("the game's input queue is full; try again")
        end
        if not core.wait_until(function()
            return fo.take_result() ~= nil
        end, SCREEN_TIMEOUT_MS) then
            return "the loot screen didn't answer"
        end

        local result = fo.take_result()
        if result == "taken" then
            return nil
        elseif result == "not there" then
            return "it isn't there"
        elseif result == "too heavy" then
            return "it's more than you can carry"
        elseif result == "stealing" then
            return "stealing isn't supported yet"
        end
        return result
    end

    local function close_loot()
        press(KEY_ESCAPE)
        core.wait_until(function()
            return fo.loot_screen() == nil
        end, SCREEN_TIMEOUT_MS)
        core.wait_frames(SETTLE_FRAMES)
    end

    core.tool({
        name = "objects",
        description = "Everything you can see on the map besides the living, nearest first, beyond the dozen the state view lists: items on the ground (pick_up), bodies and containers (loot), doors and other things to use (use). Each has its id, name, kind, tile, distance and direction, and the actions that apply; a door or container says whether it's open, and that it's locked once you've found it so. look_at describes any of them.",
        run = function()
            local player = fo.player()
            if player == nil then
                core.fail("there's no game in progress")
            end
            return { data = { objects = core.array(objects.list(player)) } }
        end,
    })

    core.tool({
        name = "pick_up",
        description = "Walks to an item on the ground (kind item in objects) and picks it up, as clicking it does, then waits until that's done. In combat the walk and the pick-up (3) cost AP. Returns the state view, with picked_up: the item, once it's yours. Otherwise a note says why not, as do the messages (too heavy, say).",
        schema = core.schema({
            target = { type = "integer", description = "The item's id, from objects." },
        }, { "target" }),
        run = function(args)
            local player = on_map()
            if fight_unseen() then
                return fight_started(false)
            end
            local item = seen(player, args.target, { item = true })
            local fight = fo.combat() ~= nil

            start(fo.pick_up, item.id)
            local function gone()
                return fo.object(item.id) == nil
            end
            settle(item, gone)

            if not fight and fo.combat() ~= nil then
                return fight_started(true)
            end
            if gone() then
                return finish({ picked_up = { name = item.name, type = item.type, quantity = item.quantity } })
            end
            return finish(nil, not_reached(item, "You didn't pick it up."))
        end,
    })

    core.tool({
        name = "loot",
        description = "Walks to a body or a container (kind body or container in objects) and opens it, as clicking it does. Returns the state view on the loot screen: `loot` lists what's inside by id, what it weighs, and what you carry and can carry. Take from it with take. With take_all: true this takes everything and leaves again in the same call, and `taken` says what you got. A locked container stays shut, and from then on objects says it's locked. In combat it costs AP: the walk, and 3 to open it.",
        schema = core.schema({
            target = { type = "integer", description = "The body's or container's id, from objects." },
            take_all = { type = "boolean", description = "Take everything and close it again." },
        }, { "target" }),
        run = function(args)
            local player = on_map()
            if fight_unseen() then
                return fight_started(false)
            end
            local target = seen(player, args.target, { body = true, container = true })
            local fight = fo.combat() ~= nil

            local function opened()
                return fo.loot_screen() ~= nil
            end

            -- Clicking an open container closes it; a second click opens it
            -- and loots it.
            if target.kind == "container" and target.open then
                start(fo.loot, target.id)
                settle(target)
                if not fight and fo.combat() ~= nil then
                    return fight_started(true)
                end
            end

            start(fo.loot, target.id)
            settle(target, opened)
            core.wait_until(opened, OPEN_TIMEOUT_MS)

            if not opened() then
                if not fight and fo.combat() ~= nil then
                    return fight_started(true)
                end
                local now = fo.object(target.id)
                if target.kind == "container" and now ~= nil and now.locked and not now.open then
                    objects.tried(player, target.id, true)
                    return finish(nil, "It's locked.")
                end
                return finish(nil, not_reached(target, "It didn't open; the messages may say why."))
            end

            if target.kind == "container" then
                objects.tried(player, target.id, false)
            end

            if args.take_all then
                local before = loot_counts()
                take_all()
                local taken = taken_between(before, loot_counts())
                close_loot()
                return finish({ taken = taken })
            end
            return finish()
        end,
    })

    core.tool({
        name = "take",
        description = "On the loot screen, moves items from the body or container to you: the ones whose ids you list (whole stacks, or `quantity` of one item's stack), or everything with all: true, as the screen's A key does. close: true then leaves the loot screen, and close alone just leaves. Returns the state view with `taken`: what you got. What's more than you can carry stays, and a note says so.",
        schema = core.schema({
            items = { type = "array", items = { type = "integer" }, description = "Item ids, from the loot view." },
            quantity = { type = "integer", minimum = 1, description = "How many of the stack, when taking one item. Default: all of it." },
            all = { type = "boolean", description = "Take everything." },
            close = { type = "boolean", description = "Leave the loot screen afterwards." },
        }),
        run = function(args)
            if state.mode(fo.flags()) ~= "loot" or fo.loot_screen() == nil then
                core.fail("take works on the loot screen; loot a body or container first")
            end

            local items = args.items or {}
            if type(items) ~= "table" then
                core.fail("items must be a list of item ids from the loot view")
            end
            for _, id in ipairs(items) do
                if math.type(id) ~= "integer" then
                    core.fail("items must be a list of item ids from the loot view")
                end
            end
            if args.quantity ~= nil and (math.type(args.quantity) ~= "integer" or args.quantity < 1 or #items ~= 1) then
                core.fail("quantity is a whole number of at least 1, for taking part of one item's stack")
            end
            if #items == 0 and not args.all and not args.close then
                core.fail("say what to take: items by id, or all: true; or close: true to leave")
            end

            local before = loot_counts()
            local problems = {}
            if args.all then
                take_all()
            end
            for _, id in ipairs(items) do
                local why = take_one(id, args.quantity)
                if why ~= nil then
                    problems[#problems + 1] = ("%d: %s"):format(id, why)
                end
            end
            local taken = taken_between(before, loot_counts())

            if args.close then
                close_loot()
            end

            local note = nil
            if #problems > 0 then
                note = "Not taken: " .. table.concat(problems, "; ") .. "."
            end
            return finish({ taken = taken }, note)
        end,
    })

    core.tool({
        name = "use",
        description = "Walks to a door or something usable (kind door or scenery in objects) and uses it, as clicking it does: a door opens or closes, ladders and stairs take you up or down, and anything else does what it does, which the messages say. A locked door stays shut, and from then on objects says it's locked. In combat it costs AP: the walk, and 3 to use it. Returns the state view, with `door`: whether the door is open now.",
        schema = core.schema({
            target = { type = "integer", description = "The door's or thing's id, from objects." },
        }, { "target" }),
        run = function(args)
            local player = on_map()
            if fight_unseen() then
                return fight_started(false)
            end
            local target = seen(player, args.target, { door = true, scenery = true })
            local fight = fo.combat() ~= nil
            local here = place(player)

            start(fo.use_object, target.id)
            settle(target, function()
                return place(fo.player()) ~= here
            end)

            if not fight and fo.combat() ~= nil then
                return fight_started(true)
            end
            if place(fo.player()) ~= here then
                return finish(nil, "You're somewhere else now.")
            end

            if target.kind ~= "door" then
                return finish(nil, not_reached(target, nil))
            end

            local now = fo.object(target.id)
            local door = { id = target.id, open = now ~= nil and now.open or false }
            if now ~= nil and now.open ~= target.open then
                objects.tried(player, target.id, false)
                return finish({ door = door })
            end
            if not target.open and now ~= nil and now.locked then
                objects.tried(player, target.id, true)
                return finish({ door = door }, "It's locked.")
            end
            return finish({ door = door }, not_reached(target, "The door didn't move; the messages may say why."))
        end,
    })

    core.tool({
        name = "look_at",
        description = "Examines something you can see, as the action menu's look does: an object from objects, or a critter. You don't move and it costs no AP. Returns the state view; its messages have the description.",
        schema = core.schema({
            target = { type = "integer", description = "An object's or critter's id." },
        }, { "target" }),
        run = function(args)
            local player = on_map()
            if math.type(args.target) ~= "integer" then
                core.fail("target must be an id from objects or critters")
            end

            local found = nil
            for _, object in ipairs(objects.list(player)) do
                if object.id == args.target then
                    found = object
                end
            end
            for _, critter in ipairs(sight.critters()) do
                if critter.id == args.target then
                    found = critter
                end
            end
            if found == nil then
                core.fail(("there's nothing with id %d in sight"):format(args.target))
            end

            local ok, why = fo.look_at(found.id)
            if not ok then
                core.fail(why or "the game refused")
            end
            core.wait_frames(SETTLE_FRAMES)
            return finish({ looked_at = { id = found.id, name = found.name } })
        end,
    })
end
