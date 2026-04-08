-- orbit.lua — Circular orbit around the world Y axis.
--
-- Entities with Orbit + Position orbit around (0, center_y, 0) at the
-- given radius and speed. Optional vertical bob for a firefly-like effect.
-- Try changing speed or radius while the engine runs!

terms = {
    { "Position", "inout" },
    { "Orbit", "in" },
}

function system(entity, dt, position, orbit)
    local angle = orbit.base_angle + elapsed * orbit.speed
    position.x = math.cos(angle) * orbit.radius
    position.z = math.sin(angle) * orbit.radius
    position.y = orbit.center_y

    -- Optional vertical bob
    if orbit.bob_amplitude > 0 then
        position.y = position.y + math.sin(elapsed * orbit.bob_speed + orbit.base_angle) * orbit.bob_amplitude
    end
end
