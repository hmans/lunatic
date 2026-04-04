// components.zig — PBR test example components.
// Re-exports core engine components + adds example-specific ones.

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

// No example-specific components needed for PBR test

/// All component types exposed to Lua.
pub const all = .{ Position, Rotation, MeshHandle, MaterialHandle, Camera, DirectionalLight, LookAt };
