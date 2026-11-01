-- Loads every tool file. A new file gets a line here.
return function(core)
    require("tools.basic")(core)
    require("tools.perception")(core)
    require("tools.input")(core)
    require("tools.movement")(core)
end
