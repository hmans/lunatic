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

fn addShaders(b: *std.Build, mod: *std.Build.Module, pp_mod: *std.Build.Module) void {
    addShader(b, mod, "default", "vert", .vertex);
    addShader(b, mod, "default", "frag", .fragment);
    addShader(b, pp_mod, "fullscreen", "vert", .vertex);
    addShader(b, pp_mod, "downsample", "frag", .fragment);
    addShader(b, pp_mod, "upsample", "frag", .fragment);
    addShader(b, pp_mod, "composite", "frag", .fragment);
    addShader(b, pp_mod, "dof_coc", "frag", .fragment);
    addShader(b, pp_mod, "dof_prefilter", "frag", .fragment);
    addShader(b, pp_mod, "dof_bokeh", "frag", .fragment);
    addShader(b, pp_mod, "dof_composite", "frag", .fragment);
    addShader(b, pp_mod, "dof_tent", "frag", .fragment);
}

/// Add C include paths for @cImport to a module.
// TODO: Replace hardcoded /opt/homebrew paths with pkg-config or env vars for cross-platform builds.
fn addCIncludes(b: *std.Build, mod: *std.Build.Module, vendor_path: std.Build.LazyPath) void {
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/luajit-2.1" });
    mod.addIncludePath(vendor_path);
    mod.addIncludePath(b.path("vendor/imgui"));
}

/// Configure shared link dependencies on a compile step.
fn addLinkDeps(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    compile.linkSystemLibrary("SDL3");
    compile.linkSystemLibrary("luajit-5.1");
    compile.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c"), .flags = &.{"-std=c99"} });
    compile.addCSourceFile(.{ .file = b.path("vendor/cgltf_impl.c"), .flags = &.{"-std=c99"} });

    // Dear ImGui (C++ core + C wrapper + SDL3/GPU backends)
    const imgui_flags: []const []const u8 = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-DIMGUI_IMPL_API=extern \"C\"" };
    const imgui_include: std.Build.LazyPath = b.path("vendor/imgui");
    const imgui_cpp_files = [_][]const u8{
        "vendor/imgui/imgui.cpp",
        "vendor/imgui/imgui_draw.cpp",
        "vendor/imgui/imgui_tables.cpp",
        "vendor/imgui/imgui_widgets.cpp",
        "vendor/imgui/imgui_demo.cpp",
        "vendor/imgui/cimgui.cpp",
        "vendor/imgui/imgui_impl_sdl3.cpp",
        "vendor/imgui/imgui_impl_sdlgpu3.cpp",
        "vendor/imgui/cimgui_impl_sdlgpu3.cpp",
    };
    for (imgui_cpp_files) |src| {
        compile.addCSourceFile(.{ .file = b.path(src), .flags = imgui_flags });
    }
    compile.addIncludePath(imgui_include);
    compile.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    compile.linkSystemLibrary("c++");
}

/// Build the full engine module graph. Returns the engine module and renderer/postprocess
/// modules (needed for shader embedding).
const EngineModules = struct {
    engine: *std.Build.Module,
    renderer: *std.Build.Module,
    postprocess: *std.Build.Module,
    lua: *std.Build.Module,
};

fn buildEngineModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    entt: *std.Build.Dependency,
) EngineModules {
    const ecs_mod = entt.module("zig-ecs");
    const vendor_path = b.path("vendor");

    const lua_mod = b.createModule(.{
        .root_source_file = b.path("src/lua.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addCIncludes(b, lua_mod, vendor_path);

    const core_components_mod = b.createModule(.{
        .root_source_file = b.path("src/core_components.zig"),
        .target = target,
        .optimize = optimize,
    });

    const components_mod = b.createModule(.{
        .root_source_file = b.path("game/components.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_components", .module = core_components_mod },
        },
    });

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
            .{ .name = "core_components", .module = core_components_mod },
            .{ .name = "lua", .module = lua_mod },
            .{ .name = "geometry", .module = geometry_mod },
            .{ .name = "math3d", .module = math3d_mod },
        },
    });
    addCIncludes(b, engine_mod, vendor_path);

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

    const component_ops_mod = b.createModule(.{
        .root_source_file = b.path("src/component_ops.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig-ecs", .module = ecs_mod },
            .{ .name = "engine", .module = engine_mod },
            .{ .name = "lua", .module = lua_mod },
        },
    });
    addCIncludes(b, component_ops_mod, vendor_path);

    const lua_api_mod = b.createModule(.{
        .root_source_file = b.path("src/lua_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig-ecs", .module = ecs_mod },
            .{ .name = "components", .module = components_mod },
            .{ .name = "component_ops", .module = component_ops_mod },
            .{ .name = "engine", .module = engine_mod },
            .{ .name = "lua", .module = lua_mod },
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
    addCIncludes(b, gltf_mod, vendor_path);

    const postprocess_mod = b.createModule(.{
        .root_source_file = b.path("src/postprocess.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "engine", .module = engine_mod },
        },
    });

    // Wire cross-module deps
    engine_mod.addImport("renderer", renderer_mod);
    engine_mod.addImport("postprocess", postprocess_mod);
    engine_mod.addImport("lua_api", lua_api_mod);
    engine_mod.addImport("gltf", gltf_mod);

    return .{
        .engine = engine_mod,
        .renderer = renderer_mod,
        .postprocess = postprocess_mod,
        .lua = lua_mod,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const entt = b.dependency("entt", .{
        .target = target,
        .optimize = optimize,
    });

    // Game executable
    const mods = buildEngineModules(b, target, optimize, entt);
    addShaders(b, mods.renderer, mods.postprocess);

    const exe = b.addExecutable(.{
        .name = "lunatic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("game/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "engine", .module = mods.engine },
            },
        }),
    });
    addLinkDeps(b, exe);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("."));
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);

    // Tests
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

    // Integration tests reuse the same engine module graph
    const test_mods = buildEngineModules(b, target, optimize, entt);
    addShaders(b, test_mods.renderer, test_mods.postprocess);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "engine", .module = test_mods.engine },
                .{ .name = "lua", .module = test_mods.lua },
            },
        }),
    });
    addLinkDeps(b, integration_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(math_tests).step);
    test_step.dependOn(&b.addRunArtifact(geometry_tests).step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
}
