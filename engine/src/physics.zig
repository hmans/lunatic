// physics.zig — Jolt Physics integration.
// Wraps zphysics (Jolt via JoltC) and provides a physics system that
// syncs Jolt body transforms to ECS Position/Rotation components.

const std = @import("std");
const zp = @import("zphysics");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const core = engine_mod.core_components;

// ============================================================
// Object layers (Jolt requires at least 2 for broad phase)
// ============================================================

pub const object_layers = struct {
    pub const non_moving: zp.ObjectLayer = 0;
    pub const moving: zp.ObjectLayer = 1;
    pub const len: u32 = 2;
};

pub const broad_phase_layers = struct {
    pub const non_moving: zp.BroadPhaseLayer = 0;
    pub const moving: zp.BroadPhaseLayer = 1;
};

// ============================================================
// Layer interfaces (required Jolt boilerplate)
// ============================================================

const BPLayerInterface = extern struct {
    interface: zp.BroadPhaseLayerInterface = .init(@This()),
    map: [object_layers.len]zp.BroadPhaseLayer = .{
        broad_phase_layers.non_moving,
        broad_phase_layers.moving,
    },

    pub fn getNumBroadPhaseLayers(iface: *const zp.BroadPhaseLayerInterface) callconv(.c) u32 {
        const self: *const BPLayerInterface = @alignCast(@fieldParentPtr("interface", iface));
        return @intCast(self.map.len);
    }

    pub fn getBroadPhaseLayer(iface: *const zp.BroadPhaseLayerInterface, layer: zp.ObjectLayer) callconv(.c) zp.BroadPhaseLayer {
        const self: *const BPLayerInterface = @alignCast(@fieldParentPtr("interface", iface));
        return self.map[@intCast(layer)];
    }
};

const ObjVsBPFilter = extern struct {
    filter: zp.ObjectVsBroadPhaseLayerFilter = .init(@This()),

    pub fn shouldCollide(_: *const zp.ObjectVsBroadPhaseLayerFilter, layer1: zp.ObjectLayer, layer2: zp.BroadPhaseLayer) callconv(.c) bool {
        return switch (layer1) {
            object_layers.non_moving => layer2 == broad_phase_layers.moving,
            object_layers.moving => true,
            else => false,
        };
    }
};

const ObjPairFilter = extern struct {
    filter: zp.ObjectLayerPairFilter = .init(@This()),

    pub fn shouldCollide(_: *const zp.ObjectLayerPairFilter, layer1: zp.ObjectLayer, layer2: zp.ObjectLayer) callconv(.c) bool {
        return switch (layer1) {
            object_layers.non_moving => layer2 == object_layers.moving,
            object_layers.moving => true,
            else => false,
        };
    }
};

// ============================================================
// Physics state — stored on Engine
// ============================================================

pub const PhysicsState = struct {
    system: ?*zp.PhysicsSystem = null,
    bp_layer_iface: BPLayerInterface = .{},
    obj_vs_bp_filter: ObjVsBPFilter = .{},
    obj_pair_filter: ObjPairFilter = .{},
    initialized: bool = false,
};

// ============================================================
// Init / Deinit
// ============================================================

pub fn initPhysics(self: *Engine) !void {
    try zp.init(std.heap.c_allocator, .{
        .temp_allocator_size = 64 * 1024 * 1024, // 64MB scratch (default 16MB)
        .num_threads = -1,
    });

    self.physics = .{};

    self.physics.system = try zp.PhysicsSystem.create(
        &self.physics.bp_layer_iface.interface,
        &self.physics.obj_vs_bp_filter.filter,
        &self.physics.obj_pair_filter.filter,
        .{
            .max_bodies = 16384,
            .max_body_pairs = 16384 * 4,
            .max_contact_constraints = 16384 * 4,
        },
    );
    self.physics.initialized = true;
}

pub fn deinitPhysics(self: *Engine) void {
    if (!self.physics.initialized) return;
    if (self.physics.system) |sys| sys.destroy();
    zp.deinit();
    self.physics.initialized = false;
}

// ============================================================
// Public API — re-export zphysics types for game code
// ============================================================

pub const BodyId = zp.BodyId;
pub const BodyCreationSettings = zp.BodyCreationSettings;
pub const MotionType = zp.MotionType;
pub const Activation = zp.Activation;
pub const Shape = zp.Shape;
pub const ShapeSettings = zp.ShapeSettings;
pub const BoxShapeSettings = zp.BoxShapeSettings;
pub const SphereShapeSettings = zp.SphereShapeSettings;

/// Get the mutable body interface for creating/manipulating bodies.
pub fn getBodyInterface(self: *Engine) *zp.BodyInterface {
    return self.physics.system.?.getBodyInterfaceMut();
}

// ============================================================
// Built-in physics system
// ============================================================

const physics_timestep: f32 = 1.0 / 60.0;
var physics_accumulator: f32 = 0;

/// Step the physics simulation and sync body transforms back to ECS.
/// Uses fixed timestep (1/60s) with accumulator to decouple from frame rate.
pub fn physicsSystem(self: *Engine, dt: f32) void {
    const phys = self.physics.system orelse return;
    const body_iface = phys.getBodyInterfaceNoLock();

    // Fixed timestep accumulator — cap at 4 steps and 8ms budget to prevent spiral of death
    physics_accumulator += dt;
    var steps: u32 = 0;
    const budget_start = engine_mod.c.SDL_GetPerformanceCounter();
    const budget_freq = engine_mod.c.SDL_GetPerformanceFrequency();
    const max_budget_us: u64 = 8000; // 8ms max per frame

    while (physics_accumulator >= physics_timestep and steps < 4) {
        phys.update(physics_timestep, .{}) catch break;
        physics_accumulator -= physics_timestep;
        steps += 1;

        // Check budget
        const elapsed_us = (engine_mod.c.SDL_GetPerformanceCounter() - budget_start) * 1_000_000 / budget_freq;
        if (elapsed_us > max_budget_us) {
            physics_accumulator = 0; // drop remaining time
            break;
        }
    }
    if (steps == 0) return;

    // Sync physics → ECS for all entities with RigidBody + Position + Rotation
    var view = self.registry.view(.{ core.Position, core.Rotation, core.RigidBody }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const rb = view.getConst(core.RigidBody, entity);
        const body_id: zp.BodyId = @enumFromInt(rb.body_id);
        if (body_id == .invalid) continue;

        const pos = body_iface.getPosition(body_id);
        const rot = body_iface.getRotation(body_id);

        // Jolt quaternion → Euler angles (degrees) to match engine convention
        const euler = quatToEuler(rot);

        var ecs_pos = view.get(core.Position, entity);
        ecs_pos.x = pos[0];
        ecs_pos.y = pos[1];
        ecs_pos.z = pos[2];

        var ecs_rot = view.get(core.Rotation, entity);
        ecs_rot.x = euler[0];
        ecs_rot.y = euler[1];
        ecs_rot.z = euler[2];
    }
}

// ============================================================
// Helpers
// ============================================================

/// Convert quaternion [x,y,z,w] to Euler angles [pitch,yaw,roll] in degrees.
fn quatToEuler(q: [4]f32) [3]f32 {
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];

    const sinp = 2.0 * (w * x - z * y);
    const pitch = if (@abs(sinp) >= 1.0)
        std.math.copysign(@as(f32, std.math.pi / 2.0), sinp)
    else
        std.math.asin(sinp);

    const siny_cosp = 2.0 * (w * y + x * z);
    const cosy_cosp = 1.0 - 2.0 * (x * x + y * y);
    const yaw = std.math.atan2(siny_cosp, cosy_cosp);

    const sinr_cosp = 2.0 * (w * z + x * y);
    const cosr_cosp = 1.0 - 2.0 * (z * z + x * x);
    const roll = std.math.atan2(sinr_cosp, cosr_cosp);

    const rad2deg = 180.0 / std.math.pi;
    return .{ pitch * rad2deg, yaw * rad2deg, roll * rad2deg };
}
