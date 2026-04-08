// components.zig — Example-specific components (extends core).

const core = @import("core_components");

/// Y-axis rotation speed in degrees/second. Driven by Lua spin system.
pub const Spin = struct {
    speed: f32 = 0,
};

/// Circular orbit around the world origin. Driven by Lua orbit system.
pub const Orbit = struct {
    radius: f32 = 5,
    speed: f32 = 1,
    base_angle: f32 = 0,
    center_y: f32 = 1,
    bob_amplitude: f32 = 0,
    bob_speed: f32 = 0,
};

/// Sinusoidal vertical bobbing. Driven by Lua bob system.
pub const Bob = struct {
    amplitude: f32 = 1,
    speed: f32 = 1,
    base_y: f32 = 0,
    phase: f32 = 0,
};

/// Pulsing light intensity. Driven by Lua pulse_light system.
pub const PulseLight = struct {
    base_intensity: f32 = 4,
    amplitude: f32 = 2,
    speed: f32 = 1,
    phase: f32 = 0,
};

pub const Player = struct {};

pub const all = core.withExtra(.{ Spin, Player, Orbit, Bob, PulseLight });
