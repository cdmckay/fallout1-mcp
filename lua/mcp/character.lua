-- The character view: the sheet the character screen shows, and what there
-- is to spend on it. See "Other screens" in docs/mcp-design.md.

local character = {}

-- What each trait does, in numbers. The game's descriptions only say which
-- way things go ("your action points are lowered"); these come from the
-- engine's code (trait.cc, and the places that check trait_level), as the
-- manual gives them. Keyed by the engine's trait id.
local TRAIT_EFFECTS = {
    [0] = "+2 healing rate; your base radiation and poison resistance are 0%", -- Fast Metabolism
    [1] = "+2 Strength, -2 action points", -- Bruiser
    [2] = "+1 Agility; carry weight 10 lbs less per point of Strength", -- Small Frame
    [3] = "+20% to hit with one-handed weapons, -40% with two-handed ones", -- One Hander
    [4] = "+10% critical chance; targets resist 30% more of your damage", -- Finesse
    [5] = "+5 sequence; no armor class of your own, only your armor's", -- Kamikaze
    [6] = "+4 melee damage; your critical hits do less (-30 on the critical table)", -- Heavy Handed
    [7] = "attacks with a weapon cost 1 AP less; no aimed shots", -- Fast Shot
    [8] = "deaths are more violent; no effect on play", -- Bloody Mess
    [9] = "half of everyone's misses, yours included, become critical failures", -- Jinxed
    [10] = "+15% First Aid, Doctor, Speech and Barter; -10% Small Guns, Big Guns, Energy Weapons, Unarmed, Melee Weapons and Throwing", -- Good Natured
    [11] = "twice the chance of addiction; addictions wear off in half the time", -- Chem Reliant
    [12] = "half the chance of addiction; drugs' effects last half as long", -- Chem Resistant
    [13] = "+1 Perception and Intelligence at night (6 pm to 6 am), -1 by day", -- Night Person
    [14] = "+10% to every skill; a perk every 4 levels instead of 3", -- Skilled
    [15] = "+1 to every SPECIAL stat; -10% to every skill; 5 fewer skill points a level", -- Gifted
}

local PROMPTS = {
    perk = "Pick a perk.",
    tag_skill = "Tag! asks for a fourth skill to tag (tagged skills gain 2% a point).",
    lose_trait = "Mutate! asks which trait to give up.",
    new_trait = "Mutate! asks which trait to take instead.",
}

local function trait_entry(trait)
    return {
        name = trait.name,
        effect = TRAIT_EFFECTS[trait.id],
        description = TRAIT_EFFECTS[trait.id] == nil and trait.description or nil,
    }
end

local function perk_entry(perk)
    return {
        name = perk.name,
        rank = perk.rank > 0 and perk.rank or nil,
        description = perk.description,
    }
end

local function map(list, fn)
    local result = {}
    for i, item in ipairs(list) do
        result[i] = fn(item)
    end
    return result
end

-- The list the perk dialog has open, with each option as the screen shows
-- it, or nil.
local function choice_view(choice)
    if choice == nil then
        return nil
    end

    local options
    if choice.kind == "perk" then
        options = map(choice.options, perk_entry)
    elseif choice.kind == "tag_skill" then
        options = map(choice.options, function(skill)
            return { name = skill.name, percent = skill.percent }
        end)
    else
        options = map(choice.options, trait_entry)
    end

    return {
        kind = choice.kind,
        prompt = PROMPTS[choice.kind],
        options = options,
        selected = choice.options[choice.selected] and choice.options[choice.selected].name or nil,
    }
end

-- The conditions the character screen lights up under hit points (poisoned,
-- radiated, eye damage, crippled limbs), or nil when there are none. `raw`
-- is fo.character()'s sheet, read here when not given.
function character.conditions(raw)
    raw = raw or fo.character()
    if raw == nil or #raw.conditions == 0 then
        return nil
    end
    return raw.conditions
end

-- The character sheet, or nil when no game is in progress: SPECIAL, hit
-- points and conditions, derived stats, skills (tagged ones marked), traits
-- with what they do, perks, level and XP, and what's left to spend. `raw`
-- is fo.character()'s, read here when not given.
function character.sheet(raw)
    raw = raw or fo.character()
    if raw == nil then
        return nil
    end

    local sheet = {
        name = raw.name,
        age = raw.age,
        gender = raw.gender,
        level = raw.level,
        xp = raw.xp,
        next_level_xp = raw.next_level_xp,
        hp = raw.hp,
        max_hp = raw.max_hp,
        conditions = character.conditions(raw),
        special = raw.special,
        derived = raw.derived,
        skills = map(raw.skills, function(skill)
            return { name = skill.name, percent = skill.percent, tagged = skill.tagged or nil }
        end),
        traits = map(raw.traits, trait_entry),
        perks = map(raw.perks, perk_entry),
        skill_points = raw.skill_points,
        selected_skill = raw.selected_skill,
        choice = choice_view(raw.choice),
    }

    if raw.perk_options ~= nil then
        sheet.perk_to_choose = { options = map(raw.perk_options, perk_entry) }
    end

    return sheet
end

-- What's waiting to be spent, for the state view, or nil when nothing is.
function character.unspent(raw)
    raw = raw or fo.character()
    if raw == nil or (raw.skill_points == 0 and not raw.perk_pending) then
        return nil
    end
    return { skill_points = raw.skill_points, perk = raw.perk_pending or nil }
end

-- The raw sheet's skill whose name matches `name` (ignoring case), or nil.
function character.find_skill(raw, name)
    local wanted = name:lower()
    for _, skill in ipairs(raw.skills) do
        if skill.name:lower() == wanted then
            return skill
        end
    end
    return nil
end

-- The 1-based place in `options` of the one named `name` (ignoring case), or
-- nil.
function character.find_option(options, name)
    local wanted = name:lower()
    for i, option in ipairs(options) do
        if option.name:lower() == wanted then
            return i
        end
    end
    return nil
end

function character.names(list)
    local names = {}
    for i, item in ipairs(list) do
        names[i] = item.name
    end
    return table.concat(names, ", ")
end

return character
