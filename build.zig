const std = @import("std");

const ShaderStage = enum { vertex, fragment };

/// Add a build step that compiles a GLSL shader to SPIR-V and MSL.
fn addShader(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    comptime name: []const u8,
    comptime ext: []const u8,
    stage: ShaderStage,
) void {
    const stage_flag = switch (stage) {
        .vertex => "-fshader-stage=vertex",
        .fragment => "-fshader-stage=fragment",
    };

    // GLSL → SPIR-V (via glslc)
    const glslc = b.addSystemCommand(&.{
        "glslc", stage_flag,
        "shaders/" ++ name ++ "." ++ ext,
        "-o",
    });
    const spv = glslc.addOutputFileArg(name ++ "." ++ ext ++ ".spv");

    // SPIR-V → MSL (via spirv-cross)
    const spirv_cross = b.addSystemCommand(&.{
        "spirv-cross", "--msl",
    });
    spirv_cross.addFileArg(spv);
    spirv_cross.addArg("--output");
    const msl = spirv_cross.addOutputFileArg(name ++ "." ++ ext ++ ".msl");

    // Make compiled shaders available to @embedFile in engine.zig
    exe.root_module.addAnonymousImport("shader_" ++ name ++ "_" ++ ext ++ "_spv", .{
        .root_source_file = spv,
    });
    exe.root_module.addAnonymousImport("shader_" ++ name ++ "_" ++ ext ++ "_msl", .{
        .root_source_file = msl,
    });
}

fn addShaders(b: *std.Build, exe: *std.Build.Step.Compile) void {
    addShader(b, exe, "default", "vert", .vertex);
    addShader(b, exe, "default", "frag", .fragment);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const entt = b.dependency("entt", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "lunatic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig-ecs", .module = entt.module("zig-ecs") },
            },
        }),
    });

    // SDL3
    exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe.linkSystemLibrary("SDL3");

    // LuaJIT (installs as libluajit-5.1)
    exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/luajit-2.1" });
    exe.linkSystemLibrary("luajit-5.1");

    // Compile shaders (GLSL → SPIR-V + MSL)
    addShaders(b, exe);

    b.installArtifact(exe);

    // Run step: `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("."));
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the engine");
    run_step.dependOn(&run_cmd.step);

    // Test step: `zig build test`
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig-ecs", .module = entt.module("zig-ecs") },
            },
        }),
    });

    tests.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    tests.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    tests.linkSystemLibrary("SDL3");
    tests.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/luajit-2.1" });
    tests.linkSystemLibrary("luajit-5.1");

    // Tests also need the compiled shaders
    addShaders(b, tests);

    // Also run math3d unit tests
    const math_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/math3d.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const run_math_tests = b.addRunArtifact(math_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_math_tests.step);
}
