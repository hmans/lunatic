const std = @import("std");

const ShaderStage = enum { vertex, fragment };

fn addShader(
    b: *std.Build,
    mod: *std.Build.Module,
    comptime name: []const u8,
    comptime ext: []const u8,
    stage: ShaderStage,
) void {
    const stage_flag = switch (stage) {
        .vertex => "-fshader-stage=vertex",
        .fragment => "-fshader-stage=fragment",
    };

    const glslc = b.addSystemCommand(&.{
        "glslc", stage_flag,
        "shaders/" ++ name ++ "." ++ ext,
        "-o",
    });
    const spv = glslc.addOutputFileArg(name ++ "." ++ ext ++ ".spv");

    const spirv_cross = b.addSystemCommand(&.{
        "spirv-cross", "--msl", "--msl-decoration-binding",
    });
    spirv_cross.addFileArg(spv);
    spirv_cross.addArg("--output");
    const msl = spirv_cross.addOutputFileArg(name ++ "." ++ ext ++ ".msl");

    mod.addAnonymousImport("shader_" ++ name ++ "_" ++ ext ++ "_spv", .{
        .root_source_file = spv,
    });
    mod.addAnonymousImport("shader_" ++ name ++ "_" ++ ext ++ "_msl", .{
        .root_source_file = msl,
    });
}

fn addShaders(b: *std.Build, mod: *std.Build.Module) void {
    addShader(b, mod, "default", "vert", .vertex);
    addShader(b, mod, "default", "frag", .fragment);
}

/// Add C include paths for @cImport to a module.
fn addCIncludes(mod: *std.Build.Module, vendor_path: std.Build.LazyPath) void {
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/luajit-2.1" });
    mod.addIncludePath(vendor_path);
}

/// Configure shared link dependencies on a compile step.
fn addLinkDeps(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    compile.linkSystemLibrary("SDL3");
    compile.linkSystemLibrary("luajit-5.1");
    compile.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c"), .flags = &.{"-std=c99"} });
    compile.addCSourceFile(.{ .file = b.path("vendor/cgltf_impl.c"), .flags = &.{"-std=c99"} });
}

/// Build an example executable. If components_file is null, uses core_components.zig.
fn addExample(
    b: *std.Build,
    comptime name: []const u8,
    comptime components_file: ?[]const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    entt: *std.Build.Dependency,
) *std.Build.Step.Compile {
    // Shared engine modules that need the "components" import remapped per-example.
    // We create a module for "components" that points to the example's file,
    // then all engine modules reference it.

    const ecs_mod = entt.module("zig-ecs");

    const vendor_path = b.path("vendor");

    const lua_mod = b.createModule(.{
        .root_source_file = b.path("src/lua.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addCIncludes(lua_mod, vendor_path);

    const core_components_mod = b.createModule(.{
        .root_source_file = b.path("src/core_components.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lua", .module = lua_mod },
        },
    });

    const components_mod = if (components_file) |cf|
        b.createModule(.{
            .root_source_file = b.path(cf),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core_components", .module = core_components_mod },
                .{ .name = "lua", .module = lua_mod },
            },
        })
    else
        core_components_mod;

    const geometry_mod = b.createModule(.{
        .root_source_file = b.path("src/geometry.zig"),
        .target = target,
        .optimize = optimize,
    });

    const math3d_mod = b.createModule(.{
        .root_source_file = b.path("src/math3d.zig"),
        .target = target,
        .optimize = optimize,
    });

    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig-ecs", .module = ecs_mod },
            .{ .name = "lua", .module = lua_mod },
            .{ .name = "geometry", .module = geometry_mod },
            .{ .name = "math3d", .module = math3d_mod },
        },
    });
    addCIncludes(engine_mod, vendor_path);

    // Renderer and lua_api need the same imports
    const renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig-ecs", .module = ecs_mod },
            .{ .name = "core_components", .module = core_components_mod },
            .{ .name = "engine", .module = engine_mod },
            .{ .name = "geometry", .module = geometry_mod },
            .{ .name = "math3d", .module = math3d_mod },
        },
    });

    const lua_api_mod = b.createModule(.{
        .root_source_file = b.path("src/lua_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig-ecs", .module = ecs_mod },
            .{ .name = "core_components", .module = core_components_mod },
            .{ .name = "components", .module = components_mod },
            .{ .name = "engine", .module = engine_mod },
            .{ .name = "lua", .module = lua_mod },
            .{ .name = "math3d", .module = math3d_mod },
        },
    });

    const gltf_mod = b.createModule(.{
        .root_source_file = b.path("src/gltf.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "engine", .module = engine_mod },
            .{ .name = "geometry", .module = geometry_mod },
        },
    });
    addCIncludes(gltf_mod, vendor_path);

    // Wire cross-module deps
    engine_mod.addImport("renderer", renderer_mod);
    engine_mod.addImport("lua_api", lua_api_mod);
    engine_mod.addImport("gltf", gltf_mod);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ "/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "engine", .module = engine_mod },
            },
        }),
    });

    addLinkDeps(b, exe);
    addShaders(b, renderer_mod);

    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const entt = b.dependency("entt", .{
        .target = target,
        .optimize = optimize,
    });

    // Examples
    const Example = struct { name: []const u8, components: ?[]const u8 = null };
    const examples = [_]Example{
        .{ .name = "pbr_test" },
        .{ .name = "primitives", .components = "examples/primitives/components.zig" },
    };

    inline for (examples) |ex| {
        const exe = addExample(b, ex.name, ex.components, target, optimize, entt);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.setCwd(b.path("."));
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run-" ++ ex.name, "Run the " ++ ex.name ++ " example");
        run_step.dependOn(&run_cmd.step);
    }

    // Default run step runs pbr_test
    const default_exe = addExample(b, "pbr_test", null, target, optimize, entt);
    const default_run = b.addRunArtifact(default_exe);
    default_run.setCwd(b.path("."));
    default_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        default_run.addArgs(args);
    }
    const run_step = b.step("run", "Run the default example (pbr_test)");
    run_step.dependOn(&default_run.step);

    // Tests
    const test_components_mod = b.createModule(.{
        .root_source_file = b.path("examples/primitives/components.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_components", .module = b.createModule(.{
                .root_source_file = b.path("src/core_components.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "lua", .module = b.createModule(.{
                        .root_source_file = b.path("src/lua.zig"),
                        .target = target,
                        .optimize = optimize,
                        .link_libc = true,
                    }) },
                },
            }) },
            .{ .name = "lua", .module = b.createModule(.{
                .root_source_file = b.path("src/lua.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }) },
        },
    });

    _ = test_components_mod;

    // Unit tests for math3d and geometry (standalone, no engine deps)
    const math_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/math3d.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const geometry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/geometry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_math_tests = b.addRunArtifact(math_tests);
    const run_geometry_tests = b.addRunArtifact(geometry_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_math_tests.step);
    test_step.dependOn(&run_geometry_tests.step);
}
