// components.zig — Primitives example components.
// Re-exports core engine components + adds Spin and Player.

const core = @import("core_components");
const lua = @import("lua");

// Re-export core components
pub const Position = core.Position;
pub const Rotation = core.Rotation;
pub const MeshHandle = core.MeshHandle;
pub const MaterialHandle = core.MaterialHandle;
pub const Camera = core.Camera;
pub const DirectionalLight = core.DirectionalLight;
pub const LookAt = core.LookAt;

// Example-specific components
pub const Spin = struct {
    speed: f32 = 0,
    pub const Lua = lua.Component("spin", @This());
};

pub const Player = struct {
    pub const lua_name = "player";
};

/// All component types exposed to Lua.
pub const all = .{ Position, Rotation, Spin, Player, MeshHandle, MaterialHandle, Camera, DirectionalLight, LookAt };
