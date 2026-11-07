-- Loads every tool file. A new file gets a line here.
return function(core)
    require("tools.basic")(core)
    require("tools.perception")(core)
    require("tools.input")(core)
    require("tools.movement")(core)
    require("tools.combat")(core)
    require("tools.inventory")(core)
    require("tools.character")(core)
    require("tools.worldmap")(core)
    require("tools.objects")(core)
    require("tools.rest")(core)
end
