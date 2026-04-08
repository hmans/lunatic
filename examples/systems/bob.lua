-- bob.lua — Sinusoidal vertical bobbing.
--
-- Makes entities float gently up and down. Attach Bob + Position to
-- any entity. Great for decorative objects, pickups, or floating lights.

terms = {
    { "Position", "inout" },
    { "Bob", "in" },
}

function system(entity, dt, position, bob)
    position.y = bob.base_y + math.sin(elapsed * bob.speed + bob.phase) * bob.amplitude
end
