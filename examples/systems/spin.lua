-- spin.lua — Rotates entities around the Y axis.
--
-- Demonstrates a minimal Lua system: reads Spin speed, writes Rotation.
-- Try editing the speed multiplier while the engine is running!

terms = {
    { "Rotation", "inout" },
    { "Spin", "in" },
}

function system(entity, dt, rotation, spin)
    rotation.y = rotation.y + spin.speed * dt
end
