// gltf.zig — GLTF/GLB loader. Parses meshes, materials, and textures into Engine resources.

const std = @import("std");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const geometry = @import("geometry");
const Vertex = geometry.Vertex;

const c = engine_mod.c;
const cgltf = @cImport({
    @cInclude("cgltf.h");
});
const stbi = @cImport({
    @cInclude("stb_image.h");
});

pub const GltfModel = struct {
    mesh_ids: []u32,
    material_ids: []u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GltfModel) void {
        self.allocator.free(self.mesh_ids);
        self.allocator.free(self.material_ids);
    }
};

pub fn load(engine: *Engine, path: [*:0]const u8) !GltfModel {
    const allocator = std.heap.c_allocator;

    var options = std.mem.zeroes(cgltf.cgltf_options);
    var data: ?*cgltf.cgltf_data = null;

    if (cgltf.cgltf_parse_file(&options, path, &data) != cgltf.cgltf_result_success) {
        return error.GltfParseFailed;
    }
    defer cgltf.cgltf_free(data);
    const gltf = data.?;

    if (cgltf.cgltf_load_buffers(&options, gltf, path) != cgltf.cgltf_result_success) {
        return error.GltfBufferLoadFailed;
    }

    // Load textures
    const tex_count = gltf.images_count;
    var texture_ids = try allocator.alloc(u32, tex_count);
    defer allocator.free(texture_ids);

    for (0..tex_count) |i| {
        const image: *const cgltf.cgltf_image = @ptrCast(&gltf.images[i]);
        texture_ids[i] = try loadImage(engine, gltf, image);
    }

    // Load materials
    const mat_count = gltf.materials_count;
    var material_ids = try allocator.alloc(u32, mat_count);
    errdefer allocator.free(material_ids);

    for (0..mat_count) |i| {
        const mat = &gltf.materials[i];
        var mat_data = engine_mod.MaterialData{};

        if (mat.has_pbr_metallic_roughness != 0) {
            const pbr = &mat.pbr_metallic_roughness;
            mat_data.albedo = .{
                pbr.base_color_factor[0],
                pbr.base_color_factor[1],
                pbr.base_color_factor[2],
                pbr.base_color_factor[3],
            };
            mat_data.metallic = pbr.metallic_factor;
            mat_data.roughness = pbr.roughness_factor;

            mat_data.base_color_texture = resolveImageIndex(gltf, pbr.base_color_texture.texture, texture_ids, tex_count);
            mat_data.metallic_roughness_texture = resolveImageIndex(gltf, pbr.metallic_roughness_texture.texture, texture_ids, tex_count);
        }

        // Normal texture
        mat_data.normal_texture = resolveImageIndex(gltf, mat.normal_texture.texture, texture_ids, tex_count);

        // Emissive
        mat_data.emissive = .{ mat.emissive_factor[0], mat.emissive_factor[1], mat.emissive_factor[2] };
        mat_data.emissive_texture = resolveImageIndex(gltf, mat.emissive_texture.texture, texture_ids, tex_count);

        // Occlusion
        mat_data.occlusion_texture = resolveImageIndex(gltf, mat.occlusion_texture.texture, texture_ids, tex_count);

        material_ids[i] = try engine.createNamedMaterial(null, mat_data);
    }

    // Load meshes (each primitive becomes a separate engine mesh)
    var mesh_list: std.ArrayListUnmanaged(u32) = .{};
    defer mesh_list.deinit(allocator);

    for (0..gltf.meshes_count) |mi| {
        const mesh = &gltf.meshes[mi];
        for (0..mesh.primitives_count) |pi| {
            const prim: *const cgltf.cgltf_primitive = @ptrCast(&mesh.primitives[pi]);
            const mesh_id = try loadPrimitive(engine, allocator, prim);
            try mesh_list.append(allocator, mesh_id);
        }
    }

    return .{
        .mesh_ids = try allocator.dupe(u32, mesh_list.items),
        .material_ids = material_ids,
        .allocator = allocator,
    };
}

fn resolveImageIndex(gltf: *cgltf.cgltf_data, texture_ptr: ?*cgltf.cgltf_texture, texture_ids: []u32, tex_count: usize) ?u32 {
    const tex = texture_ptr orelse return null;
    const img = tex.*.image orelse return null;
    const img_index = (@intFromPtr(img) - @intFromPtr(gltf.images)) / @sizeOf(cgltf.cgltf_image);
    if (img_index < tex_count) return texture_ids[img_index];
    return null;
}

fn loadPrimitive(engine: *Engine, allocator: std.mem.Allocator, prim: *const cgltf.cgltf_primitive) !u32 {

    // Find accessors for position, normal, texcoord
    var pos_accessor: ?*cgltf.cgltf_accessor = null;
    var norm_accessor: ?*cgltf.cgltf_accessor = null;
    var uv_accessor: ?*cgltf.cgltf_accessor = null;
    var tan_accessor: ?*cgltf.cgltf_accessor = null;

    for (0..prim.attributes_count) |ai| {
        const attr = &prim.attributes[ai];
        switch (attr.type) {
            cgltf.cgltf_attribute_type_position => pos_accessor = attr.data,
            cgltf.cgltf_attribute_type_normal => norm_accessor = attr.data,
            cgltf.cgltf_attribute_type_texcoord => uv_accessor = attr.data,
            cgltf.cgltf_attribute_type_tangent => tan_accessor = attr.data,
            else => {},
        }
    }

    const pos_acc = pos_accessor orelse return error.MissingPositionAttribute;
    const vertex_count = pos_acc.count;

    var vertices = try allocator.alloc(Vertex, vertex_count);
    defer allocator.free(vertices);

    // Read positions
    for (0..vertex_count) |vi| {
        var pos: [3]f32 = undefined;
        _ = cgltf.cgltf_accessor_read_float(pos_acc, vi, &pos, 3);
        vertices[vi] = .{ .px = pos[0], .py = pos[1], .pz = pos[2], .nx = 0, .ny = 1, .nz = 0, .u = 0, .v = 0 };
    }

    // Read normals
    if (norm_accessor) |acc| {
        for (0..vertex_count) |vi| {
            var norm: [3]f32 = undefined;
            _ = cgltf.cgltf_accessor_read_float(acc, vi, &norm, 3);
            vertices[vi].nx = norm[0];
            vertices[vi].ny = norm[1];
            vertices[vi].nz = norm[2];
        }
    }

    // Read UVs
    if (uv_accessor) |acc| {
        for (0..vertex_count) |vi| {
            var uv: [2]f32 = undefined;
            _ = cgltf.cgltf_accessor_read_float(acc, vi, &uv, 2);
            vertices[vi].u = uv[0];
            vertices[vi].v = uv[1];
        }
    }

    // Read tangents
    if (tan_accessor) |acc| {
        for (0..vertex_count) |vi| {
            var tan: [4]f32 = undefined;
            _ = cgltf.cgltf_accessor_read_float(acc, vi, &tan, 4);
            vertices[vi].tx = tan[0];
            vertices[vi].ty = tan[1];
            vertices[vi].tz = tan[2];
            vertices[vi].tw = tan[3];
        }
    }

    // Read indices
    var indices: ?[]u32 = null;
    defer if (indices) |idx| allocator.free(idx);

    if (prim.indices) |idx_acc_ptr| {
        const idx_count = idx_acc_ptr.*.count;
        var idx = try allocator.alloc(u32, idx_count);
        for (0..idx_count) |ii| {
            idx[ii] = @intCast(cgltf.cgltf_accessor_read_index(idx_acc_ptr, ii));
        }
        indices = idx;
    }

    return engine.createMesh(null, vertices, indices);
}

fn loadImage(engine: *Engine, gltf: *cgltf.cgltf_data, image: *const cgltf.cgltf_image) !u32 {
    _ = gltf;

    // Try buffer_view first (embedded in GLB)
    if (image.buffer_view) |bv| {
        const buf = bv.*.buffer orelse return error.NoBufferData;
        const buffer_data: [*]const u8 = @ptrCast(buf.*.data orelse return error.NoBufferData);
        const offset = bv.*.offset;
        const size = bv.*.size;

        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;
        const pixels = stbi.stbi_load_from_memory(
            buffer_data + offset,
            @intCast(size),
            &w,
            &h,
            &channels,
            4,
        ) orelse return error.ImageDecodeFailed;
        defer stbi.stbi_image_free(pixels);

        return engine.createTextureFromMemory(@ptrCast(pixels), @intCast(w), @intCast(h));
    }

    // Fall back to external file URI
    if (image.uri) |uri| {
        return engine.createTextureFromFile(uri);
    }

    return error.NoImageData;
}
