-- Key names the agent uses, mapped to the engine's KEY_* codes
-- (src/plib/gnw/kb.h).

local keys = {}

local NAMED = {
    escape = 27,
    ["return"] = 13,
    enter = 13,
    space = 32,
    tab = 9,
    backspace = 8,
    insert = 338,
    delete = 339,
    home = 327,
    ["end"] = 335,
    page_up = 329,
    page_down = 337,
    up = 328,
    down = 336,
    left = 331,
    right = 333,
    f1 = 315,
    f2 = 316,
    f3 = 317,
    f4 = 318,
    f5 = 319,
    f6 = 320,
    f7 = 321,
    f8 = 322,
    f9 = 323,
    f10 = 324,
    f11 = 389,
}

-- Returns the code for `name`, or nil and the reason. A single printable
-- character is itself, case and all (loot's "take all" is "A", not "a").
-- Other names ignore case and accept spaces or dashes for underscores.
function keys.code(name)
    if type(name) ~= "string" or name == "" then
        return nil, "a key must be a non-empty string"
    end

    if #name == 1 then
        local byte = name:byte()
        if byte >= 32 and byte <= 126 then
            return byte
        end
        return nil, ("%q isn't a printable character"):format(name)
    end

    local normalized = (name:lower():gsub("[%s%-]", "_"))

    if NAMED[normalized] then
        return NAMED[normalized]
    end

    local letter = normalized:match("^ctrl%+(%a)$")
    if letter then
        return letter:byte() - 96
    end

    if normalized == "f12" then
        return nil, "f12 makes the game save a screenshot to disk; use look instead"
    end

    return nil, ("unknown key %q: use a single character, ctrl+<letter>, or one of escape, return, space, tab, backspace, insert, delete, home, end, page_up, page_down, up, down, left, right, f1 to f11"):format(name)
end

return keys
