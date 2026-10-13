const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cpu_target = if (optimize == .ReleaseFast)
        b.resolveTargetQuery(.{ .cpu_model = .native })
    else
        target;

    // nstd (nstandard) compression engine — vendored as a sibling module.
    const nstd_root = b.pathFromRoot("../nstandard/src/root.zig");
    const nstd_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = nstd_root },
        .target = cpu_target,
        .optimize = optimize,
        .pic = true,
    });

    const nzip_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = cpu_target,
        .optimize = optimize,
        .pic = true,
        .imports = &.{.{ .name = "nstd", .module = nstd_mod }},
    });

    const lib = b.addLibrary(.{
        .name = "nzip",
        .root_module = nzip_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const lib_shared = b.addLibrary(.{
        .name = "nzip",
        .root_module = nzip_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib_shared);

    // ---- CLI ----
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = cpu_target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nzip", .module = nzip_mod },
            .{ .name = "nstd", .module = nstd_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = "nzip",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // ---- C ABI conformance test ----
    const c_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    c_mod.addCSourceFile(.{ .file = b.path("tests/c_caller.c"), .flags = &.{"-Wall"} });
    c_mod.addIncludePath(b.path("include"));
    c_mod.linkLibrary(lib);
    const c_test = b.addExecutable(.{ .name = "nzip_c_test", .root_module = c_mod });
    const run_c = b.addRunArtifact(c_test);
    const c_step = b.step("test-c", "Run the C ABI conformance test");
    c_step.dependOn(&run_c.step);

    // ---- Zig unit tests ----
    const tests = b.addTest(.{ .root_module = nzip_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // ---- Run CLI ----
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the nzip CLI");
    run_step.dependOn(&run_cmd.step);
}
