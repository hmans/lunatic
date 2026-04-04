const std = @import("std");
const builtin = @import("builtin");
const math3d = @import("math3d.zig");
const components = @import("components.zig");
const ecs = @import("zig-ecs");
const Mat4 = math3d.Mat4;
const Vec3 = math3d.Vec3;

const lua = @import("lua.zig");
const lc = lua.c;
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

// Re-export component types for convenience
const Position = components.Position;
const Rotation = components.Rotation;
const MeshHandle = components.MeshHandle;
const Spin = components.Spin;

// ============================================================
// Vertex format
// ============================================================

const Vertex = extern struct {
    px: f32,
    py: f32,
    pz: f32,
    nx: f32,
    ny: f32,
    nz: f32,
};

// ============================================================
// Built-in cube mesh
// ============================================================

fn vtx(px: f32, py: f32, pz: f32, nx: f32, ny: f32, nz: f32) Vertex {
    return .{ .px = px, .py = py, .pz = pz, .nx = nx, .ny = ny, .nz = nz };
}

const cube_vertices = [36]Vertex{
    vtx(-0.5, -0.5, 0.5, 0, 0, 1), vtx(0.5, -0.5, 0.5, 0, 0, 1), vtx(0.5, 0.5, 0.5, 0, 0, 1),
    vtx(-0.5, -0.5, 0.5, 0, 0, 1), vtx(0.5, 0.5, 0.5, 0, 0, 1),  vtx(-0.5, 0.5, 0.5, 0, 0, 1),
    vtx(0.5, -0.5, -0.5, 0, 0, -1),  vtx(-0.5, -0.5, -0.5, 0, 0, -1), vtx(-0.5, 0.5, -0.5, 0, 0, -1),
    vtx(0.5, -0.5, -0.5, 0, 0, -1),  vtx(-0.5, 0.5, -0.5, 0, 0, -1),  vtx(0.5, 0.5, -0.5, 0, 0, -1),
    vtx(-0.5, 0.5, 0.5, 0, 1, 0),  vtx(0.5, 0.5, 0.5, 0, 1, 0),  vtx(0.5, 0.5, -0.5, 0, 1, 0),
    vtx(-0.5, 0.5, 0.5, 0, 1, 0),  vtx(0.5, 0.5, -0.5, 0, 1, 0), vtx(-0.5, 0.5, -0.5, 0, 1, 0),
    vtx(-0.5, -0.5, -0.5, 0, -1, 0), vtx(0.5, -0.5, -0.5, 0, -1, 0), vtx(0.5, -0.5, 0.5, 0, -1, 0),
    vtx(-0.5, -0.5, -0.5, 0, -1, 0), vtx(0.5, -0.5, 0.5, 0, -1, 0),  vtx(-0.5, -0.5, 0.5, 0, -1, 0),
    vtx(0.5, -0.5, 0.5, 1, 0, 0),  vtx(0.5, -0.5, -0.5, 1, 0, 0), vtx(0.5, 0.5, -0.5, 1, 0, 0),
    vtx(0.5, -0.5, 0.5, 1, 0, 0),  vtx(0.5, 0.5, -0.5, 1, 0, 0),  vtx(0.5, 0.5, 0.5, 1, 0, 0),
    vtx(-0.5, -0.5, -0.5, -1, 0, 0), vtx(-0.5, -0.5, 0.5, -1, 0, 0),  vtx(-0.5, 0.5, 0.5, -1, 0, 0),
    vtx(-0.5, -0.5, -0.5, -1, 0, 0), vtx(-0.5, 0.5, 0.5, -1, 0, 0),   vtx(-0.5, 0.5, -0.5, -1, 0, 0),
};

// ============================================================
// Metal shaders (MSL)
// ============================================================

const vertex_shader_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct Vertex {
    \\    float3 position [[attribute(0)]];
    \\    float3 normal   [[attribute(1)]];
    \\};
    \\
    \\struct VertexUniforms {
    \\    float4x4 mvp;
    \\    float4x4 model;
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float3 world_pos;
    \\    float3 world_normal;
    \\};
    \\
    \\vertex VertexOut vertex_main(
    \\    Vertex in [[stage_in]],
    \\    constant VertexUniforms &u [[buffer(0)]]
    \\) {
    \\    VertexOut out;
    \\    out.position = u.mvp * float4(in.position, 1.0);
    \\    out.world_pos = (u.model * float4(in.position, 1.0)).xyz;
    \\    out.world_normal = normalize((u.model * float4(in.normal, 0.0)).xyz);
    \\    return out;
    \\}
;

const fragment_shader_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float3 world_pos;
    \\    float3 world_normal;
    \\};
    \\
    \\struct FragUniforms {
    \\    float4 light_dir;
    \\    float4 camera_pos;
    \\    float4 fog_color;
    \\    float4 fog_params;
    \\    float4 albedo;
    \\    float4 ambient;
    \\};
    \\
    \\fragment float4 fragment_main(
    \\    VertexOut in [[stage_in]],
    \\    constant FragUniforms &u [[buffer(0)]]
    \\) {
    \\    float3 N = normalize(in.world_normal);
    \\    float3 L = normalize(u.light_dir.xyz);
    \\    float ndotl = dot(N, L);
    \\    float diffuse = ndotl * 0.5 + 0.5;
    \\    diffuse = diffuse * diffuse;
    \\
    \\    float3 color = u.albedo.xyz * (u.ambient.xyz + diffuse);
    \\
    \\    if (u.fog_color.w > 0.5) {
    \\        float dist = length(in.world_pos - u.camera_pos.xyz);
    \\        float fog_start = u.fog_params.x;
    \\        float fog_end = u.fog_params.y;
    \\        float fog_factor = clamp((dist - fog_start) / (fog_end - fog_start), 0.0, 1.0);
    \\        color = mix(color, u.fog_color.xyz, fog_factor);
    \\    }
    \\
    \\    return float4(color, 1.0);
    \\}
;

// ============================================================
// Uniform structs
// ============================================================

const VertexUniforms = extern struct {
    mvp: [4][4]f32,
    model: [4][4]f32,
};

const FragUniforms = extern struct {
    light_dir: [4]f32,
    camera_pos: [4]f32,
    fog_color: [4]f32, // .xyz = color, .w = fog_enabled (1.0 or 0.0)
    fog_params: [4]f32, // .x = fog_start, .y = fog_end
    albedo: [4]f32,
    ambient: [4]f32,
};

// ============================================================
// Mesh registry
// ============================================================

const MeshData = struct {
    buffer: *c.SDL_GPUBuffer,
    vertex_count: u32,
};

const max_meshes = 64;
var mesh_registry: [max_meshes]?MeshData = .{null} ** max_meshes;
var mesh_names: [max_meshes]?[*:0]const u8 = .{null} ** max_meshes;
var mesh_count: u32 = 0;

fn registerMesh(name: [*:0]const u8, buffer: *c.SDL_GPUBuffer, vertex_count: u32) u32 {
    const id = mesh_count;
    mesh_registry[id] = .{ .buffer = buffer, .vertex_count = vertex_count };
    mesh_names[id] = name;
    mesh_count += 1;
    return id;
}

fn findMesh(name: [*:0]const u8) ?u32 {
    const needle = std.mem.span(name);
    for (0..mesh_count) |i| {
        if (mesh_names[i]) |n| {
            if (std.mem.eql(u8, std.mem.span(n), needle)) return @intCast(i);
        }
    }
    return null;
}

// ============================================================
// Engine globals
// ============================================================

var gpu_device: ?*c.SDL_GPUDevice = null;
var sdl_window: ?*c.SDL_Window = null;
var pipeline: ?*c.SDL_GPUGraphicsPipeline = null;
var depth_texture: ?*c.SDL_GPUTexture = null;
var depth_w: u32 = 0;
var depth_h: u32 = 0;

var camera_eye = Vec3.new(0, 1.5, 4);
var camera_target = Vec3.new(0, 0, 0);
var clear_color = [4]f32{ 0.08, 0.08, 0.12, 1.0 };

var light_dir = [4]f32{ 0.4, 0.8, 0.4, 0.0 };
var ambient_color = [4]f32{ 0.15, 0.15, 0.2, 0.0 };

var fog_enabled: bool = false;
var fog_start: f32 = 10.0;
var fog_end: f32 = 30.0;
var fog_color = [3]f32{ 0.08, 0.08, 0.12 };

// ECS registry — lives for the lifetime of the engine
var registry: ecs.Registry = undefined;

// ============================================================
// Lua API
// ============================================================

fn luaKeyDown(L: ?*lc.lua_State) callconv(.c) c_int {
    const name = lc.luaL_checklstring(L, 1, null);
    const scancode = c.SDL_GetScancodeFromName(name);
    const state = c.SDL_GetKeyboardState(null);
    lc.lua_pushboolean(L, if (state[scancode]) 1 else 0);
    return 1;
}

fn luaSetCamera(L: ?*lc.lua_State) callconv(.c) c_int {
    camera_eye.x = @floatCast(lc.luaL_checknumber(L, 1));
    camera_eye.y = @floatCast(lc.luaL_checknumber(L, 2));
    camera_eye.z = @floatCast(lc.luaL_checknumber(L, 3));
    camera_target.x = @floatCast(lc.luaL_checknumber(L, 4));
    camera_target.y = @floatCast(lc.luaL_checknumber(L, 5));
    camera_target.z = @floatCast(lc.luaL_checknumber(L, 6));
    return 0;
}

fn luaSetClearColor(L: ?*lc.lua_State) callconv(.c) c_int {
    clear_color[0] = @floatCast(lc.luaL_checknumber(L, 1));
    clear_color[1] = @floatCast(lc.luaL_checknumber(L, 2));
    clear_color[2] = @floatCast(lc.luaL_checknumber(L, 3));
    return 0;
}

fn luaSetFog(L: ?*lc.lua_State) callconv(.c) c_int {
    if (lc.lua_isboolean(L, 1) and lc.lua_toboolean(L, 1) == 0) {
        fog_enabled = false;
        return 0;
    }
    fog_enabled = true;
    fog_start = @floatCast(lc.luaL_checknumber(L, 1));
    fog_end = @floatCast(lc.luaL_checknumber(L, 2));
    fog_color[0] = @floatCast(lc.luaL_optnumber(L, 3, clear_color[0]));
    fog_color[1] = @floatCast(lc.luaL_optnumber(L, 4, clear_color[1]));
    fog_color[2] = @floatCast(lc.luaL_optnumber(L, 5, clear_color[2]));
    return 0;
}

fn luaSetLight(L: ?*lc.lua_State) callconv(.c) c_int {
    light_dir[0] = @floatCast(lc.luaL_checknumber(L, 1));
    light_dir[1] = @floatCast(lc.luaL_checknumber(L, 2));
    light_dir[2] = @floatCast(lc.luaL_checknumber(L, 3));
    return 0;
}

fn luaSetAmbient(L: ?*lc.lua_State) callconv(.c) c_int {
    ambient_color[0] = @floatCast(lc.luaL_checknumber(L, 1));
    ambient_color[1] = @floatCast(lc.luaL_checknumber(L, 2));
    ambient_color[2] = @floatCast(lc.luaL_checknumber(L, 3));
    return 0;
}

/// lunatic.spawn() -> entity_id
fn luaSpawn(L: ?*lc.lua_State) callconv(.c) c_int {
    const entity = registry.create();
    const entity_int: u32 = @bitCast(entity);
    lc.lua_pushinteger(L, @intCast(entity_int));
    return 1;
}

/// lunatic.destroy(entity_id)
fn luaDestroy(L: ?*lc.lua_State) callconv(.c) c_int {
    const entity = entityFromLua(L, 1);
    registry.destroy(entity);
    return 0;
}

// ---- Generic component dispatch (comptime) ----

fn entityFromLua(L: ?*lc.lua_State, idx: c_int) ecs.Entity {
    const id: u32 = @intCast(lc.luaL_checkinteger(L, idx));
    const entity: ecs.Entity = @bitCast(id);
    if (!registry.valid(entity)) {
        _ = lc.luaL_error(L, "invalid entity %d", @as(c_int, @intCast(id)));
    }
    return entity;
}

fn componentName(L: ?*lc.lua_State, idx: c_int) []const u8 {
    return std.mem.span(lc.luaL_checklstring(L, idx, null));
}

/// lunatic.add(entity_id, component_name, ...) — add/replace a component
fn luaAdd(L: ?*lc.lua_State) callconv(.c) c_int {
    const entity = entityFromLua(L, 1);
    const name = componentName(L, 2);

    inline for (components.all) |T| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            if (comptime lua.isTag(T)) {
                registry.addOrReplace(entity, T{});
                return 0;
            } else if (comptime @hasDecl(T, "Lua")) {
                registry.addOrReplace(entity, T.Lua.fromLua(L, 3));
                return 0;
            }
        }
    }

    // Components without auto-bindings (special cases)
    if (std.mem.eql(u8, name, lua.nameOf(MeshHandle))) {
        const mesh_name = lc.luaL_checklstring(L, 3, null);
        const mesh_id = findMesh(mesh_name) orelse {
            _ = lc.luaL_error(L, "unknown mesh: %s", mesh_name);
            return 0;
        };
        registry.addOrReplace(entity, MeshHandle{ .id = mesh_id });
        return 0;
    }

    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

/// lunatic.get(entity_id, component_name) -> values...
fn luaGet(L: ?*lc.lua_State) callconv(.c) c_int {
    const entity = entityFromLua(L, 1);
    const name = componentName(L, 2);

    inline for (components.all) |T| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            if (comptime lua.isTag(T)) {
                // Tags: return true/false
                lc.lua_pushboolean(L, if (registry.has(T, entity)) 1 else 0);
                return 1;
            } else if (comptime @hasDecl(T, "Lua")) {
                if (registry.tryGet(T, entity)) |val| {
                    return T.Lua.toLua(val.*, L);
                }
                return 0;
            }
        }
    }

    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

/// lunatic.remove(entity_id, component_name)
fn luaRemove(L: ?*lc.lua_State) callconv(.c) c_int {
    const entity = entityFromLua(L, 1);
    const name = componentName(L, 2);

    inline for (components.all) |T| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            registry.remove(T, entity);
            return 0;
        }
    }

    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

// ---- Query support ----

/// Function type for "does this entity have component X?"
const HasFn = *const fn (*ecs.Registry, ecs.Entity) bool;
/// Function type for "how many entities have component X?"
const LenFn = *const fn (*ecs.Registry) usize;
/// Function type for "get the entity list for component X"
const DataFn = *const fn (*ecs.Registry) []ecs.Entity;

/// Build comptime lookup table: name -> has/len/data functions
const QueryEntry = struct {
    name: []const u8,
    hasFn: HasFn,
    lenFn: LenFn,
    dataFn: DataFn,
};

fn makeQueryEntries() [components.all.len]QueryEntry {
    var entries: [components.all.len]QueryEntry = undefined;
    inline for (components.all, 0..) |T, i| {
        entries[i] = .{
            .name = lua.nameOf(T),
            .hasFn = &struct {
                fn has(reg: *ecs.Registry, entity: ecs.Entity) bool {
                    return reg.has(T, entity);
                }
            }.has,
            .lenFn = &struct {
                fn len(reg: *ecs.Registry) usize {
                    return reg.len(T);
                }
            }.len,
            .dataFn = &struct {
                fn data(reg: *ecs.Registry) []ecs.Entity {
                    return reg.data(T);
                }
            }.data,
        };
    }
    return entries;
}

const query_entries = makeQueryEntries();

fn findQueryEntry(name: []const u8) ?QueryEntry {
    for (query_entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry;
    }
    return null;
}

/// lunatic.query("position", "rotation", ...) -> {entity_id, ...}
// ---- Query cache ----
// Caches query results per frame. Same query called multiple times in one
// frame returns the same Lua table without re-iterating the ECS.

var current_frame: u64 = 0;

const QueryCacheEntry = struct {
    lua_ref: c_int = lc.LUA_NOREF,
    frame: u64 = 0,
    hash: u64 = 0,
};

const max_cached_queries = 64;
var query_cache: [max_cached_queries]QueryCacheEntry = .{QueryCacheEntry{}} ** max_cached_queries;

fn queryHash(entries: []const QueryEntry, count: usize) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
    for (0..count) |i| {
        for (entries[i].name) |byte| {
            h ^= byte;
            h *%= 0x100000001b3; // FNV-1a prime
        }
        h ^= 0xff; // separator
        h *%= 0x100000001b3;
    }
    return h;
}

fn findCachedQuery(hash: u64) ?usize {
    for (0..max_cached_queries) |i| {
        if (query_cache[i].hash == hash and query_cache[i].frame == current_frame) {
            return i;
        }
    }
    return null;
}

fn findCacheSlot(hash: u64) usize {
    // Try to find existing slot for this hash (from a previous frame)
    for (0..max_cached_queries) |i| {
        if (query_cache[i].hash == hash) return i;
    }
    // Find an empty or oldest slot
    var oldest_idx: usize = 0;
    var oldest_frame: u64 = std.math.maxInt(u64);
    for (0..max_cached_queries) |i| {
        if (query_cache[i].lua_ref == lc.LUA_NOREF) return i;
        if (query_cache[i].frame < oldest_frame) {
            oldest_frame = query_cache[i].frame;
            oldest_idx = i;
        }
    }
    // Evict oldest — release its Lua ref
    if (query_cache[oldest_idx].lua_ref != lc.LUA_NOREF) {
        if (lua_system_state) |L| {
            lc.luaL_unref(L, lc.LUA_REGISTRYINDEX, query_cache[oldest_idx].lua_ref);
        }
        query_cache[oldest_idx].lua_ref = lc.LUA_NOREF;
    }
    return oldest_idx;
}

fn buildQueryTable(L: ?*lc.lua_State, entries: []const QueryEntry, count: usize) void {
    // Find the smallest component storage to iterate
    var smallest_idx: usize = 0;
    var smallest_len: usize = entries[0].lenFn(&registry);
    for (1..count) |i| {
        const l = entries[i].lenFn(&registry);
        if (l < smallest_len) {
            smallest_len = l;
            smallest_idx = i;
        }
    }

    const entity_list = entries[smallest_idx].dataFn(&registry);
    lc.lua_createtable(L, @intCast(smallest_len), 0);
    var table_idx: c_int = 1;

    for (entity_list) |entity| {
        var match = true;
        for (0..count) |i| {
            if (i == smallest_idx) continue;
            if (!entries[i].hasFn(&registry, entity)) {
                match = false;
                break;
            }
        }
        if (match) {
            const entity_int: u32 = @bitCast(entity);
            lc.lua_pushinteger(L, @intCast(entity_int));
            lc.lua_rawseti(L, -2, table_idx);
            table_idx += 1;
        }
    }
}

fn luaQuery(L: ?*lc.lua_State) callconv(.c) c_int {
    const nargs = lc.lua_gettop(L);
    if (nargs == 0) {
        _ = lc.luaL_error(L, "query requires at least one component name");
        return 0;
    }

    var entries: [16]QueryEntry = undefined;
    const count: usize = @intCast(nargs);
    if (count > 16) {
        _ = lc.luaL_error(L, "query supports at most 16 components");
        return 0;
    }

    for (0..count) |i| {
        const name = std.mem.span(lc.luaL_checklstring(L, @intCast(i + 1), null));
        entries[i] = findQueryEntry(name) orelse {
            _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, @intCast(i + 1), null));
            return 0;
        };
    }

    // Sort entries by name so query("a","b") and query("b","a") hash identically
    std.mem.sort(QueryEntry, entries[0..count], {}, struct {
        fn lessThan(_: void, a: QueryEntry, b: QueryEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    const hash = queryHash(&entries, count);

    // Check cache — return existing table if built this frame
    if (findCachedQuery(hash)) |idx| {
        lc.lua_rawgeti(L, lc.LUA_REGISTRYINDEX, query_cache[idx].lua_ref);
        return 1;
    }

    // Build new result table
    buildQueryTable(L, &entries, count);

    // Cache it: store a ref to the table, push a copy for the caller
    lc.lua_pushvalue(L, -1); // duplicate table on stack
    const slot = findCacheSlot(hash);
    // Release old ref if reusing slot
    if (query_cache[slot].lua_ref != lc.LUA_NOREF) {
        lc.luaL_unref(L, lc.LUA_REGISTRYINDEX, query_cache[slot].lua_ref);
    }
    query_cache[slot] = .{
        .lua_ref = lc.luaL_ref(L, lc.LUA_REGISTRYINDEX), // pops the duplicate
        .frame = current_frame,
        .hash = hash,
    };

    return 1; // original table still on stack
}

// ---- Lua system registration ----

const max_lua_systems = 64;
var lua_system_refs: [max_lua_systems]c_int = .{0} ** max_lua_systems;
var lua_system_disabled: [max_lua_systems]bool = .{false} ** max_lua_systems;
var lua_system_count: u32 = 0;
var lua_system_state: ?*lc.lua_State = null;

/// lunatic.system(name, function) — register a Lua system
fn luaSystemRegister(L: ?*lc.lua_State) callconv(.c) c_int {
    _ = lc.luaL_checklstring(L, 1, null); // name (for debugging/identification)
    lc.luaL_checktype(L, 2, lc.LUA_TFUNCTION);

    // Store a reference to the function
    lc.lua_pushvalue(L, 2);
    const ref = lc.luaL_ref(L, lc.LUA_REGISTRYINDEX);

    if (lua_system_count >= max_lua_systems) {
        _ = lc.luaL_error(L, "too many Lua systems (max 64)");
        return 0;
    }

    lua_system_refs[lua_system_count] = ref;
    lua_system_count += 1;
    lua_system_state = L;
    return 0;
}

/// Run all registered Lua systems with dt
fn runLuaSystems(dt: f32) void {
    const L = lua_system_state orelse return;
    for (0..lua_system_count) |i| {
        if (lua_system_disabled[i]) continue;
        lc.lua_rawgeti(L, lc.LUA_REGISTRYINDEX, lua_system_refs[i]);
        lc.lua_pushnumber(L, dt);
        if (lc.lua_pcall(L, 1, 0, 0) != 0) {
            if (comptime !builtin.is_test) {
                const err = lc.lua_tolstring(L, -1, null);
                std.debug.print("Lua system error (disabling): {s}\n", .{err});
            }
            lc.lua_pop(L, 1);
            lua_system_disabled[i] = true;
        }
    }
}

// ---- Component ref proxies ----

const ComponentRef = extern struct {
    entity_id: u32,
    type_tag: u8,
};

const ref_metatable_name: [*:0]const u8 = "lunatic_component_ref";

/// lunatic.ref(entity_id, component_name) -> proxy userdata
fn luaRef(L: ?*lc.lua_State) callconv(.c) c_int {
    const entity = entityFromLua(L, 1);
    const entity_id: u32 = @bitCast(entity);
    const name = componentName(L, 2);

    inline for (components.all, 0..) |T, i| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            if (!registry.has(T, entity)) {
                _ = lc.luaL_error(L, "entity %d has no component '%s'", @as(c_int, @intCast(entity_id)), lc.luaL_checklstring(L, 2, null));
                return 0;
            }

            const ptr: *ComponentRef = @ptrCast(@alignCast(lc.lua_newuserdata(L, @sizeOf(ComponentRef))));
            ptr.* = .{ .entity_id = entity_id, .type_tag = @intCast(i) };
            lc.luaL_getmetatable(L, ref_metatable_name);
            _ = lc.lua_setmetatable(L, -2);
            return 1;
        }
    }

    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

/// __index metamethod: proxy.field_name -> read from ECS
fn refIndex(L: ?*lc.lua_State) callconv(.c) c_int {
    const ptr: *const ComponentRef = @ptrCast(@alignCast(lc.lua_touserdata(L, 1) orelse return 0));
    const field_name = std.mem.span(lc.luaL_checklstring(L, 2, null));
    const entity: ecs.Entity = @bitCast(ptr.entity_id);

    if (!registry.valid(entity)) {
        _ = lc.luaL_error(L, "stale ref: entity %d has been destroyed", @as(c_int, @intCast(ptr.entity_id)));
        return 0;
    }

    inline for (components.all, 0..) |T, i| {
        if (ptr.type_tag == i) {
            if (comptime lua.isTag(T)) {
                lc.lua_pushboolean(L, if (registry.has(T, entity)) 1 else 0);
                return 1;
            } else if (registry.tryGet(T, entity)) |val| {
                inline for (std.meta.fields(T)) |field| {
                    if (std.mem.eql(u8, field_name, field.name)) {
                        const fval = @field(val.*, field.name);
                        if (comptime field.type == f32) {
                            lc.lua_pushnumber(L, fval);
                        } else if (comptime field.type == u32) {
                            lc.lua_pushinteger(L, @intCast(fval));
                        }
                        return 1;
                    }
                }
                _ = lc.luaL_error(L, "no field '%s' on component", lc.luaL_checklstring(L, 2, null));
                return 0;
            }
            return 0;
        }
    }
    return 0;
}

/// __newindex metamethod: proxy.field_name = value -> write to ECS
fn refNewIndex(L: ?*lc.lua_State) callconv(.c) c_int {
    const ptr: *const ComponentRef = @ptrCast(@alignCast(lc.lua_touserdata(L, 1) orelse return 0));
    const field_name = std.mem.span(lc.luaL_checklstring(L, 2, null));
    const entity: ecs.Entity = @bitCast(ptr.entity_id);

    if (!registry.valid(entity)) {
        _ = lc.luaL_error(L, "stale ref: entity %d has been destroyed", @as(c_int, @intCast(ptr.entity_id)));
        return 0;
    }

    inline for (components.all, 0..) |T, i| {
        if (ptr.type_tag == i) {
            if (comptime !lua.isTag(T)) {
                if (registry.tryGet(T, entity)) |comp| {
                    inline for (std.meta.fields(T)) |field| {
                        if (std.mem.eql(u8, field_name, field.name)) {
                            if (comptime field.type == f32) {
                                @field(comp, field.name) = @floatCast(lc.luaL_checknumber(L, 3));
                            } else if (comptime field.type == u32) {
                                @field(comp, field.name) = @intCast(lc.luaL_checkinteger(L, 3));
                            }
                            return 0;
                        }
                    }
                    _ = lc.luaL_error(L, "no field '%s' on component", lc.luaL_checklstring(L, 2, null));
                }
            }
            return 0;
        }
    }
    return 0;
}

const ref_metatable = [_]lc.luaL_Reg{
    .{ .name = "__index", .func = refIndex },
    .{ .name = "__newindex", .func = refNewIndex },
    .{ .name = null, .func = null },
};

fn registerRefMetatable(L: ?*lc.lua_State) void {
    _ = lc.luaL_newmetatable(L, ref_metatable_name);
    lc.luaL_register(L, null, &ref_metatable);
    lc.lua_pop(L, 1);
}

const lunatic_lib = [_]lc.luaL_Reg{
    .{ .name = "key_down", .func = luaKeyDown },
    .{ .name = "set_camera", .func = luaSetCamera },
    .{ .name = "set_clear_color", .func = luaSetClearColor },
    .{ .name = "set_fog", .func = luaSetFog },
    .{ .name = "set_light", .func = luaSetLight },
    .{ .name = "set_ambient", .func = luaSetAmbient },
    .{ .name = "spawn", .func = luaSpawn },
    .{ .name = "destroy", .func = luaDestroy },
    .{ .name = "add", .func = luaAdd },
    .{ .name = "get", .func = luaGet },
    .{ .name = "remove", .func = luaRemove },
    .{ .name = "query", .func = luaQuery },
    .{ .name = "ref", .func = luaRef },
    .{ .name = "system", .func = luaSystemRegister },
    .{ .name = null, .func = null },
};

/// Initialize the Lua API on a given state. Can be called without GPU/SDL.
pub fn initLuaApi(L: *lc.lua_State) void {
    lc.luaL_register(L, "lunatic", &lunatic_lib);
    lc.lua_pop(L, 1);
    registerRefMetatable(L);
}

/// Initialize the ECS registry. Must be called before any Lua API usage.
pub fn initRegistry() void {
    registry = ecs.Registry.init(std.heap.c_allocator);
}

/// Deinitialize the ECS registry.
pub fn deinitRegistry() void {
    registry.deinit();
}

/// Reset Lua system state (for testing).
pub fn resetSystems() void {
    lua_system_count = 0;
    lua_system_disabled = .{false} ** max_lua_systems;
    lua_system_state = null;
}

/// Run Lua systems (exposed for testing).
pub const tickSystems = runLuaSystems;

// ============================================================
// Zig-side systems
// ============================================================


// ============================================================
// GPU helpers
// ============================================================

fn createShader(device: *c.SDL_GPUDevice, code: [*:0]const u8, stage: c.SDL_GPUShaderStage, num_uniform_buffers: u32) ?*c.SDL_GPUShader {
    return c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code_size = std.mem.len(code),
        .code = code,
        .entrypoint = if (stage == c.SDL_GPU_SHADERSTAGE_VERTEX) "vertex_main" else "fragment_main",
        .format = c.SDL_GPU_SHADERFORMAT_MSL,
        .stage = stage,
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = num_uniform_buffers,
        .props = 0,
    });
}

fn uploadVertexData(device: *c.SDL_GPUDevice, data: []const u8) ?*c.SDL_GPUBuffer {
    const data_size: u32 = @intCast(data.len);
    const buf = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = data_size,
        .props = 0,
    }) orelse return null;

    const transfer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
        .props = 0,
    }) orelse {
        c.SDL_ReleaseGPUBuffer(device, buf);
        return null;
    };

    const ptr = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        c.SDL_ReleaseGPUBuffer(device, buf);
        return null;
    };
    @memcpy(@as([*]u8, @ptrCast(ptr))[0..data_size], data);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        c.SDL_ReleaseGPUBuffer(device, buf);
        return null;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        c.SDL_ReleaseGPUBuffer(device, buf);
        return null;
    };
    c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = 0,
    }, &c.SDL_GPUBufferRegion{
        .buffer = buf,
        .offset = 0,
        .size = data_size,
    }, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    c.SDL_ReleaseGPUTransferBuffer(device, transfer);
    return buf;
}

fn createDepthTexture(device: *c.SDL_GPUDevice, w: u32, h: u32) ?*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
        .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
        .width = w,
        .height = h,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    });
}

// ============================================================
// Render system
// ============================================================

fn renderSystem(reg: *ecs.Registry, device: *c.SDL_GPUDevice) void {
    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return;

    var swapchain_tex: ?*c.SDL_GPUTexture = null;
    var sw_w: u32 = 0;
    var sw_h: u32 = 0;
    if (!c.SDL_AcquireGPUSwapchainTexture(cmd, sdl_window, &swapchain_tex, &sw_w, &sw_h)) {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    }
    if (swapchain_tex == null) {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    }

    // Recreate depth texture if swapchain dimensions changed
    if (sw_w != depth_w or sw_h != depth_h) {
        if (depth_texture) |dt| c.SDL_ReleaseGPUTexture(device, dt);
        depth_texture = createDepthTexture(device, sw_w, sw_h);
        depth_w = sw_w;
        depth_h = sw_h;
        if (depth_texture == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return;
        }
    }

    const aspect: f32 = @as(f32, @floatFromInt(sw_w)) / @as(f32, @floatFromInt(sw_h));
    const proj = Mat4.perspective(60.0, aspect, 0.1, 100.0);
    const view = Mat4.lookAt(camera_eye, camera_target, Vec3.new(0, 1, 0));
    const vp = Mat4.mul(proj, view);

    const frag_uniforms = FragUniforms{
        .light_dir = light_dir,
        .camera_pos = .{ camera_eye.x, camera_eye.y, camera_eye.z, 0.0 },
        .fog_color = .{ fog_color[0], fog_color[1], fog_color[2], if (fog_enabled) 1.0 else 0.0 },
        .fog_params = .{ fog_start, fog_end, 0.0, 0.0 },
        .albedo = .{ 1.0, 1.0, 1.0, 0.0 },
        .ambient = ambient_color,
    };

    const color_target = c.SDL_GPUColorTargetInfo{
        .texture = swapchain_tex,
        .mip_level = 0,
        .layer_or_depth_plane = 0,
        .clear_color = .{ .r = clear_color[0], .g = clear_color[1], .b = clear_color[2], .a = clear_color[3] },
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
        .resolve_texture = null,
        .resolve_mip_level = 0,
        .resolve_layer = 0,
        .cycle = false,
        .cycle_resolve_texture = false,
        .padding1 = 0,
        .padding2 = 0,
    };

    const depth_target = c.SDL_GPUDepthStencilTargetInfo{
        .texture = depth_texture,
        .clear_depth = 1.0,
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_DONT_CARE,
        .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
        .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
        .cycle = true,
        .clear_stencil = 0,
        .mip_level = 0,
        .layer = 0,
    };

    const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, &depth_target) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };

    c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline);
    c.SDL_PushGPUFragmentUniformData(cmd, 0, &frag_uniforms, @sizeOf(FragUniforms));

    // Query all entities with Position + Rotation + MeshHandle
    var ecs_view = reg.view(.{ Position, Rotation, MeshHandle }, .{});
    var iter = ecs_view.entityIterator();

    var bound_mesh: ?u32 = null;
    while (iter.next()) |entity| {
        const pos = ecs_view.getConst(Position, entity);
        const rot = ecs_view.getConst(Rotation, entity);
        const mesh_handle = ecs_view.getConst(MeshHandle, entity);
        const mesh = mesh_registry[mesh_handle.id] orelse continue;

        if (bound_mesh == null or bound_mesh.? != mesh_handle.id) {
            const binding = c.SDL_GPUBufferBinding{ .buffer = mesh.buffer, .offset = 0 };
            c.SDL_BindGPUVertexBuffers(render_pass, 0, &binding, 1);
            bound_mesh = mesh_handle.id;
        }

        const rotation = Mat4.mul(Mat4.mul(Mat4.rotateZ(rot.z), Mat4.rotateY(rot.y)), Mat4.rotateX(rot.x));
        const model = Mat4.mul(Mat4.translate(pos.x, pos.y, pos.z), rotation);
        const mvp = Mat4.mul(vp, model);

        const vert_uniforms = VertexUniforms{ .mvp = mvp.m, .model = model.m };
        c.SDL_PushGPUVertexUniformData(cmd, 0, &vert_uniforms, @sizeOf(VertexUniforms));
        c.SDL_DrawGPUPrimitives(render_pass, mesh.vertex_count, 1, 0, 0);
    }

    c.SDL_EndGPURenderPass(render_pass);
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
}

// ============================================================
// Main
// ============================================================

pub fn main() !void {
    // ECS
    initRegistry();
    defer deinitRegistry();

    // SDL
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    gpu_device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_MSL, true, null);
    if (gpu_device == null) {
        std.debug.print("SDL_CreateGPUDevice failed: {s}\n", .{c.SDL_GetError()});
        return error.GPUDeviceFailed;
    }
    const device = gpu_device.?;
    defer c.SDL_DestroyGPUDevice(device);

    sdl_window = c.SDL_CreateWindow("lunatic", 800, 600, c.SDL_WINDOW_RESIZABLE);
    if (sdl_window == null) {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLWindowFailed;
    }
    defer c.SDL_DestroyWindow(sdl_window);

    if (!c.SDL_ClaimWindowForGPUDevice(device, sdl_window)) {
        std.debug.print("SDL_ClaimWindowForGPUDevice failed: {s}\n", .{c.SDL_GetError()});
        return error.ClaimWindowFailed;
    }

    // Shaders
    const vert_shader = createShader(device, vertex_shader_msl, c.SDL_GPU_SHADERSTAGE_VERTEX, 1) orelse {
        std.debug.print("Failed to create vertex shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, vert_shader);

    const frag_shader = createShader(device, fragment_shader_msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 1) orelse {
        std.debug.print("Failed to create fragment shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, frag_shader);

    // Pipeline
    const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, sdl_window);

    const vertex_attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "px") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "nx") },
    };

    const vertex_buf_desc = [_]c.SDL_GPUVertexBufferDescription{
        .{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
    };

    const color_target_desc = [_]c.SDL_GPUColorTargetDescription{
        .{ .format = swapchain_format, .blend_state = std.mem.zeroes(c.SDL_GPUColorTargetBlendState) },
    };

    pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buf_desc,
            .num_vertex_buffers = vertex_buf_desc.len,
            .vertex_attributes = &vertex_attrs,
            .num_vertex_attributes = vertex_attrs.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_BACK,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = true,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = .{
            .compare_op = c.SDL_GPU_COMPAREOP_LESS,
            .back_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .front_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .compare_mask = 0,
            .write_mask = 0,
            .enable_depth_test = true,
            .enable_depth_write = true,
            .enable_stencil_test = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .target_info = .{
            .color_target_descriptions = &color_target_desc,
            .num_color_targets = color_target_desc.len,
            .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
            .has_depth_stencil_target = true,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create pipeline: {s}\n", .{c.SDL_GetError()});
        return error.PipelineFailed;
    };
    defer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

    // Meshes
    const cube_buf = uploadVertexData(device, std.mem.asBytes(&cube_vertices)) orelse {
        std.debug.print("Failed to upload cube mesh: {s}\n", .{c.SDL_GetError()});
        return error.BufferFailed;
    };
    _ = registerMesh("cube", cube_buf, cube_vertices.len);

    // Depth texture (initial — resized dynamically in renderSystem)
    depth_texture = createDepthTexture(device, 800, 600) orelse {
        std.debug.print("Failed to create depth texture: {s}\n", .{c.SDL_GetError()});
        return error.DepthTextureFailed;
    };
    depth_w = 800;
    depth_h = 600;
    defer if (depth_texture) |dt| c.SDL_ReleaseGPUTexture(device, dt);

    // Lua
    const L = lc.luaL_newstate() orelse return error.LuaInitFailed;
    defer lc.lua_close(L);
    lc.luaL_openlibs(L);

    initLuaApi(L);

    _ = lc.luaL_dostring(L, "package.path = 'game/?.lua;' .. package.path");

    if (lc.luaL_loadfile(L, "game/main.lua") != 0 or lc.lua_pcall(L, 0, 0, 0) != 0) {
        const err = lc.lua_tolstring(L, -1, null);
        std.debug.print("Lua error: {s}\n", .{err});
        return error.LuaLoadFailed;
    }

    // Run the script — it registers systems via lunatic.system()
    // No explicit init() call needed.

    // Game loop
    var running = true;
    var last_time = c.SDL_GetPerformanceCounter();
    const freq: f64 = @floatFromInt(c.SDL_GetPerformanceFrequency());
    const dt_smoothing = 0.1;
    const dt_max = 0.25;
    var smooth_dt: f64 = 1.0 / 60.0;

    while (running) {
        const now = c.SDL_GetPerformanceCounter();
        const raw_dt = @min(@as(f64, @floatFromInt(now - last_time)) / freq, dt_max);
        last_time = now;
        smooth_dt += dt_smoothing * (raw_dt - smooth_dt);
        const dt: f32 = @floatCast(smooth_dt);

        // Advance frame — query caches from last frame are now stale
        current_frame += 1;

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) running = false;
            if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.scancode == c.SDL_SCANCODE_ESCAPE) running = false;
        }

        // Lua systems (registered via lunatic.system)
        runLuaSystems(dt);

        // Render system (Zig, queries ECS directly)
        renderSystem(&registry, device);
    }
}
