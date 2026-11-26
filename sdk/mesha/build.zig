const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Every package that depends on mesha passes the same value, so the host and every
    // plugin record zones alike.
    const profile_options = b.addOptions();
    profile_options.addOption(bool, "enabled", b.option(bool, "profile-enabled", "Record profile zones") orelse true);

    _ = addApiModule(b, "mesha", target, optimize, profile_options);

    // The same sources as the root of the API's test binary. A file belongs to one module
    // per compilation, so tests cannot be rooted at the files inside `mesha`.
    _ = addApiModule(b, "mesha_tests", target, optimize, profile_options);
}

fn addApiModule(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    profile_options: *std.Build.Step.Options,
) *std.Build.Module {
    const api_mod = b.addModule(name, .{
        .root_source_file = b.path("mesha.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_mod.addOptions("profile_options", profile_options);
    return api_mod;
}
