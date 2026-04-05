// core_components.zig — Engine-provided component types.
// These are always available regardless of which example is running.

pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    pub const lua = .{ .name = "position" };
};

pub const Rotation = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    pub const lua = .{ .name = "rotation" };
};

pub const Scale = struct {
    x: f32 = 1,
    y: f32 = 1,
    z: f32 = 1,
    pub const lua = .{ .name = "scale" };
};

pub const MeshHandle = struct {
    id: u32 = 0,
    pub const lua = .{ .name = "mesh", .resolve = .mesh };
};

pub const MaterialHandle = struct {
    id: u32 = 0,
    pub const lua = .{ .name = "material", .resolve = .material };
};

pub const Camera = struct {
    fov: f32 = 60,
    near: f32 = 0.1,
    far: f32 = 100.0,
    viewport_x: f32 = 0.0,
    viewport_y: f32 = 0.0,
    viewport_w: f32 = 1.0,
    viewport_h: f32 = 1.0,
    // Post-processing (per-camera lens settings)
    exposure: f32 = 1.0,
    bloom_intensity: f32 = 0.0, // 0 = no bloom, just tonemap
    pub const lua = .{ .name = "camera" };
};

pub const DirectionalLight = struct {
    dir_x: f32 = 0.4,
    dir_y: f32 = 0.8,
    dir_z: f32 = 0.4,
    r: f32 = 1.0,
    g: f32 = 1.0,
    b: f32 = 1.0,
    pub const lua = .{ .name = "directional_light" };
};

pub const LookAt = struct {
    target: u32 = 0,
    pub const lua = .{ .name = "look_at" };
};

/// Core component tuple — engine modules reference these directly.
pub const all = .{ Position, Rotation, Scale, MeshHandle, MaterialHandle, Camera, DirectionalLight, LookAt };

/// Concatenate core components with example-specific ones.
/// Usage: `pub const all = core.withExtra(.{ Spin, Player });`
pub fn withExtra(extra: anytype) @TypeOf(all ++ extra) {
    return all ++ extra;
}
