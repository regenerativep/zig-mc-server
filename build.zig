const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mcp_mod = b.dependency("mcp", .{
        .optimize = optimize,
        .target = target,
    }).module("mcp");
    const xev_mod = b.dependency("libxev", .{
        .optimize = optimize,
        .target = target,
    }).module("xev");
    const mpsc_mod = b.dependency("mpsc", .{
        .optimize = optimize,
        .target = target,
    }).module("mpsc");

    //const lib = b.addStaticLibrary(.{
    //    .name = "zig-mc-server",
    //    .root_source_file = .{ .path = "src/lib.zig" },
    //    .target = target,
    //    .optimize = optimize,
    //});
    //lib.root_module.addImport("mcp", mcp_mod);
    //lib.root_module.addImport("xev", xev_mod);
    //lib.root_module.addImport("mpsc", mpsc_mod);
    //b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "zig-mc-server",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("mcp", mcp_mod);
    exe.root_module.addImport("xev", xev_mod);
    exe.root_module.addImport("mpsc", mpsc_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.root_module.addImport("mcp", mcp_mod);
    lib_unit_tests.root_module.addImport("xev", xev_mod);
    lib_unit_tests.root_module.addImport("mpsc", mpsc_mod);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("mcp", mcp_mod);
    exe_unit_tests.root_module.addImport("xev", xev_mod);
    exe_unit_tests.root_module.addImport("mpsc", mpsc_mod);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
