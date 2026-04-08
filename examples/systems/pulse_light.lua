-- pulse_light.lua — Pulsing point light intensity.
--
-- Creates a breathing/flickering effect on point lights. Attach
-- PulseLight + PointLight to any light entity.

terms = {
    { "PointLight", "inout" },
    { "PulseLight", "in" },
}

function system(entity, dt, point_light, pulse)
    local t = elapsed * pulse.speed + pulse.phase
    point_light.intensity = pulse.base_intensity + math.sin(t) * pulse.amplitude
end
