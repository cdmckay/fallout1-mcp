local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

-- A fake player carrying a pistol (id 11) and four stimpaks (id 12). Equipping
-- starts a short take-out animation.
local function setup()
    local core, engine = support.new()
    local game = { calls = {}, busy_frames = 0, refuse = nil }

    fo.flags = function()
        return { in_game = true }
    end
    fo.player = function()
        return { name = "Max Stone", tile = 100 }
    end
    fo.player_busy = function()
        return game.busy_frames > 0
    end
    fo.inventory = function()
        return { items = { { id = 11, name = "10mm Pistol", type = "weapon" } }, active_hand = "right" }
    end
    fo.equipped = function()
        return { active_hand = "right", right_hand = game.right_hand }
    end
    local function record(name)
        return function(...)
            game.calls[#game.calls + 1] = { name = name, args = table.pack(...) }
            if game.refuse then
                return false, game.refuse
            end
            game.busy_frames = 3
            return true
        end
    end
    fo.equip = function(id, hand)
        local ok, why = record("equip")(id, hand)
        if ok then
            game.right_hand = { id = id, name = "10mm Pistol" }
        end
        return ok, why
    end
    fo.unequip = record("unequip")
    fo.use_item = record("use_item")
    fo.reload_weapon = record("reload")

    local frames = engine.frames
    engine.frames = function(n)
        for _ = 1, n or 1 do
            if game.busy_frames > 0 then
                game.busy_frames = game.busy_frames - 1
            end
            frames(1)
        end
    end

    require("tools.inventory")(core)

    local function call(tool, args)
        engine.request({ id = 1, op = "call", tool = tool, args = args or {} })
        engine.frames(30)
        local reply = engine.reply()
        if reply.error then
            return nil, reply.error.message
        end
        return (json.decode(reply.result.content[1].text))
    end

    return game, call
end

function tests.inventory_returns_what_the_engine_lists()
    local _, call = setup()

    local inventory = call("inventory")

    equal(inventory.items[1].name, "10mm Pistol", "item")
    equal(inventory.active_hand, "right", "active hand")
end

function tests.equip_waits_for_the_take_out_and_shows_the_hand_in_the_view()
    local game, call = setup()

    local view = call("equip", { item = 11 })

    equal(game.calls[1].name, "equip", "binding")
    equal(game.calls[1].args[1], 11, "item")
    equal(game.calls[1].args[2], nil, "active hand")
    equal(game.busy_frames, 0, "animation finished before the reply")
    equal(view.equipped.right_hand.name, "10mm Pistol", "equipped")
end

function tests.equip_passes_a_chosen_hand()
    local game, call = setup()

    call("equip", { item = 11, hand = "left" })

    equal(game.calls[1].args[2], "left", "hand")
end

function tests.the_engine_s_reason_reaches_the_agent()
    local game, call = setup()
    game.refuse = "not enough AP: using the inventory in combat costs 4"

    local _, err = call("equip", { item = 11 })

    contains(err, "costs 4", "reason")
end

function tests.arguments_are_checked_before_the_engine_is_asked()
    local game, call = setup()

    local _, no_item = call("equip", {})
    contains(no_item, "item must be", "missing item")

    local _, bad_hand = call("equip", { item = 11, hand = "third" })
    contains(bad_hand, "left", "bad hand")

    local _, bad_use = call("use_item", { item = 1.5 })
    contains(bad_use, "item must be", "item that's neither an id nor a name")

    equal(#game.calls, 0, "engine calls")
end

function tests.unequip_use_item_and_reload_call_their_bindings()
    local game, call = setup()

    call("unequip", { hand = "right" })
    call("use_item", { item = 12 })
    call("reload", {})

    equal(game.calls[1].name, "unequip", "unequip")
    equal(game.calls[1].args[1], "right", "hand")
    equal(game.calls[2].name, "use_item", "use_item")
    equal(game.calls[2].args[1], 12, "stimpak")
    equal(game.calls[3].name, "reload", "reload")
    equal(game.calls[3].args[1], nil, "active hand")
end

function tests.use_item_says_how_many_are_left_and_their_new_id()
    local game, call = setup()
    local stack = { id = 12, name = "Stimpak", type = "drug", quantity = 4 }
    fo.inventory = function()
        return { items = { stack } }
    end
    local use = fo.use_item
    fo.use_item = function(id)
        -- The engine leaves the rest of the stack in a copy with a new id.
        stack = { id = 13, name = "Stimpak", type = "drug", quantity = 3 }
        return use(id)
    end

    local view = call("use_item", { item = 12 })

    equal(game.calls[1].name, "use_item", "binding")
    equal(view.used.name, "Stimpak", "name")
    equal(view.used.remaining, 3, "remaining")
    equal(view.used.id, 13, "new id")
end

function tests.using_the_last_one_leaves_none()
    local _, call = setup()
    local items = { { id = 12, name = "Stimpak", type = "drug", quantity = 1 } }
    fo.inventory = function()
        return { items = items }
    end
    local use = fo.use_item
    fo.use_item = function(id)
        items = {}
        return use(id)
    end

    local view = call("use_item", { item = 12 })

    equal(view.used.remaining, 0, "remaining")
    equal(view.used.id, nil, "id")
end

function tests.items_can_be_named_as_the_inventory_lists_them()
    local game, call = setup()
    fo.inventory = function()
        return {
            items = {
                { id = 11, name = "10mm Pistol", type = "weapon", quantity = 1 },
                { id = 12, name = "Stimpak", type = "drug", quantity = 4 },
            },
        }
    end

    call("equip", { item = "10mm Pistol" })
    call("use_item", { item = "stimpak" })

    equal(game.calls[1].args[1], 11, "pistol")
    equal(game.calls[2].args[1], 12, "stimpak, in any case")
end

function tests.the_next_stimpak_by_name_needs_no_new_id()
    local game, call = setup()
    local stack = { id = 12, name = "Stimpak", type = "drug", quantity = 4 }
    fo.inventory = function()
        return { items = { stack } }
    end
    local use = fo.use_item
    fo.use_item = function(id)
        -- The engine leaves the rest of the stack in a copy with a new id.
        stack = { id = stack.id + 1, name = "Stimpak", type = "drug", quantity = stack.quantity - 1 }
        return use(id)
    end

    call("use_item", { item = "Stimpak" })
    local view = call("use_item", { item = "Stimpak" })

    equal(game.calls[1].args[1], 12, "first stimpak")
    equal(game.calls[2].args[1], 13, "second, from the stack's new id")
    equal(view.used.remaining, 2, "remaining")
end

function tests.a_name_two_items_share_needs_the_id()
    local game, call = setup()
    fo.inventory = function()
        return {
            items = {
                { id = 11, name = "10mm Pistol", type = "weapon", quantity = 1, slot = "right_hand" },
                { id = 14, name = "10mm Pistol", type = "weapon", quantity = 1 },
            },
        }
    end

    local _, err = call("equip", { item = "10mm pistol", hand = "left" })

    contains(err, '2 items are called "10mm pistol"', "ambiguous")
    contains(err, "11 (right_hand), 14", "their ids")
    equal(#game.calls, 0, "engine calls")
end

function tests.a_name_nothing_carried_has_is_refused()
    local game, call = setup()

    local _, err = call("use_item", { item = "Stimpak" })

    contains(err, 'not carrying anything called "Stimpak"', "unknown name")
    equal(#game.calls, 0, "engine calls")
end

function tests.names_need_a_game()
    local game, call = setup()
    fo.flags = function()
        return { in_game = false }
    end

    local _, err = call("use_item", { item = "Stimpak" })

    contains(err, "no game in progress", "no game")
    equal(#game.calls, 0, "engine calls")
end

function tests.the_item_schema_takes_an_id_or_a_name()
    local core, engine = support.new()
    require("tools.inventory")(core)

    engine.request({ id = 1, op = "list" })
    local listed
    for _, tool in ipairs(engine.reply().result.tools) do
        if tool.name == "use_item" or tool.name == "equip" then
            listed = tool
            local types = tool.inputSchema.properties.item.type
            equal(#types, 2, tool.name .. " types")
            equal(types[1], "integer", tool.name .. " id")
            equal(types[2], "string", tool.name .. " name")
        end
    end
    equal(listed ~= nil, true, "tools listed")
end

function tests.reload_says_why_not()
    local game, call = setup()
    game.refuse = "you have no ammo that fits it"

    local _, err = call("reload", { hand = "left" })

    contains(err, "no ammo", "reason")
end

return tests
