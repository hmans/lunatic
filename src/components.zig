// components.zig — ECS component types (default set, used by main game and tests).

const core = @import("core_components");

pub const Position = core.Position;
pub const Rotation = core.Rotation;
pub const Scale = core.Scale;
pub const MeshHandle = core.MeshHandle;
pub const MaterialHandle = core.MaterialHandle;
pub const Camera = core.Camera;
pub const DirectionalLight = core.DirectionalLight;
pub const LookAt = core.LookAt;

pub const Spin = struct {
    speed: f32 = 0,
    pub const lua = .{ .name = "spin" };
};

pub const Player = struct {
    pub const lua = .{ .name = "player" };
};

/// Single source of truth: all component types exposed to Lua.
pub const all = core.withExtra(.{ Spin, Player });
