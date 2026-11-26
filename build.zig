const std = @import("std");

/// The editor's and the user's plugin's libraries, in one `zig build`: the build the host
/// watches for them both. A checkout keeps it in `plugins/`, beside a `build.zig.zon` naming
/// the editor at `../editor` and the user's plugin at `../user` (lazily, as it may not be
/// there); a distribution ships this same file as its root `build.zig`, beside the same
/// manifest with those paths as `editor` and `user`. The user's plugin is built by its own
/// `build.zig` and `build.zig.zon`, so what a person adds there takes effect here; the
/// editor's directory is the editor's package's, and the user's plugin is `user/` beside it.
///
/// Each library lands where the host looks for it: `libeditor.so` in `editor/zig-out/lib`,
/// `libuser.so` in `user/zig-out/lib` (`bin`, as `.dll`, on Windows). The step `editor` builds
/// the first and `user` the second, so the host's watch, which runs them by name, tells from
/// the steps that failed which library a pass built. `install`, the default, runs both.
///
/// The step `vendor` fetches the programs the host runs (`Vendored`) for the target and writes
/// each to `vendor/<program>` beside the editor's directory, where the host looks for them; the
/// step `editor` runs it too, so the host's first build of a distribution fetches them.
///
/// The user's `build.zig` is compiled into this build's program and run when it configures,
/// so one that does not compile or configure ends this build, the editor's step with it: the
/// host's watch then builds the editor alone, by `editor/build.zig`, until a build file
/// changes (`runtime/watch.zig`).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // As the host's default: the self-hosted backend for a Debug build on x86_64 other than
    // Windows, LLVM otherwise. The host's watch always passes it.
    const self_hosted_target = target.result.os.tag != .windows and target.result.cpu.arch == .x86_64;
    const default_llvm = !self_hosted_target or optimize != .Debug;
    const use_llvm = b.option(bool, "llvm", "Build the plugins with the LLVM backend instead of the self-hosted x86_64 backend") orelse default_llvm;
    const enable_profile = b.option(bool, "profile-enabled", "Record profile zones") orelse true;

    const editor_dep = b.dependency("editor", .{ .target = target, .optimize = optimize, .@"profile-enabled" = enable_profile, .llvm = use_llvm });
    const editor_directory = editor_dep.builder.build_root.path orelse @panic("the editor's package has no directory");
    const editor_lib = editor_dep.artifact("editor");
    const editor_step = b.step("editor", "Build the editor's library into editor/zig-out");
    installInto(b, editor_lib, editor_directory, editor_step);

    const plugins_directory = std.fs.path.dirname(editor_directory) orelse @panic("the editor's directory has no parent");
    const vendor_step = b.step("vendor", "Fetch the programs the host runs and write them to vendor/ beside the editor");
    const vendor_directory = b.pathJoin(&.{ plugins_directory, "vendor" });
    for (std.enums.values(Vendored)) |program| addVendored(b, target, vendor_directory, program, vendor_step);
    editor_step.dependOn(vendor_step);
    const user_directory = b.pathJoin(&.{ plugins_directory, "user" });
    const user_step = b.step("user", "Build the user's plugin's library into user/zig-out by its own build.zig, when it is there");
    addUser(b, user_directory, user_step, .{ .target = target, .optimize = optimize, .use_llvm = use_llvm, .enable_profile = enable_profile });

    b.getInstallStep().dependOn(editor_step);
    b.getInstallStep().dependOn(user_step);
}

/// The programs the host runs from `vendor/`, each a release built by its authors for the
/// target, as they do not build with Zig. Each package, named `<program>_<platform>` in
/// `build.zig.zon`, is written whole to `vendor/<program>`, its licence with it. Zig, which
/// runs this build, is not one of them: a person puts it in `vendor/zig` themselves.
const Vendored = enum {
    /// The C and C++ language server, `vendor/clice/bin/clice`: it finds Clang's headers
    /// beside itself.
    clice,
    /// The file finder the editor lists a project's files with, `vendor/fd/fd`.
    fd,
    /// The search the editor greps a project's files with, `vendor/ripgrep/rg`.
    ripgrep,
    /// The Zig language server, `vendor/zls/zls`, of the version the host builds with.
    zls,
};

/// Writes `program` for `target` to `<vendor_directory>/<program>`, `vendor_directory`
/// absolute, as `step`'s work. A target its authors do not build for gets none, and the host
/// then looks for the program on `PATH`; so does a build whose package is still being fetched.
fn addVendored(b: *std.Build, target: std.Build.ResolvedTarget, vendor_directory: []const u8, program: Vendored, step: *std.Build.Step) void {
    const platform = switch (target.result.os.tag) {
        .linux => switch (target.result.cpu.arch) {
            .x86_64 => "linux",
            .aarch64 => "linux_aarch64",
            else => return,
        },
        .windows => switch (target.result.cpu.arch) {
            .x86_64 => "windows",
            else => return,
        },
        else => return,
    };
    const package_name = b.fmt("{s}_{s}", .{ @tagName(program), platform });
    const package = b.lazyDependency(package_name, .{}) orelse return;
    const destination = b.pathJoin(&.{ vendor_directory, @tagName(program) });
    // An install directory is relative to the prefix: the way from it to the destination.
    const from_prefix = std.fs.path.relative(b.allocator, b.graph.cache.cwd, null, b.install_path, destination) catch @panic("OOM");
    const install = b.addInstallDirectory(.{
        .source_dir = package.path(""),
        .install_dir = .{ .custom = from_prefix },
        .install_subdir = "",
    });
    step.dependOn(&install.step);
}

const UserOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
    enable_profile: bool,
};

/// The user's plugin, as `step`'s work: its library `user`, built by its own `build.zig` and
/// `build.zig.zon` (the lazy dependency `user`), given the options every plugin's build takes,
/// and installed into its `zig-out`; nothing when `user/build.zig` is not there, so a missing
/// user's plugin is never asked for.
fn addUser(b: *std.Build, user_directory: []const u8, step: *std.Build.Step, options: UserOptions) void {
    const user_build = b.pathJoin(&.{ user_directory, "build.zig" });
    std.Io.Dir.cwd().access(b.graph.io, user_build, .{}) catch return;
    const user_dep = b.lazyDependency("user", .{
        .target = options.target,
        .optimize = options.optimize,
        .@"profile-enabled" = options.enable_profile,
        .llvm = options.use_llvm,
    }) orelse return;
    const user_lib = user_dep.artifact("user");
    installInto(b, user_lib, user_directory, step);
}

/// Installs `library` into `<directory>/zig-out/lib` (`bin` on Windows), `directory` absolute,
/// as `step`'s work: where the host's loader looks for it, whatever this build's own install
/// prefix is.
fn installInto(b: *std.Build, library: *std.Build.Step.Compile, directory: []const u8, step: *std.Build.Step) void {
    const kind = if (library.rootModuleTarget().os.tag == .windows) "bin" else "lib";
    const destination = b.pathJoin(&.{ directory, "zig-out", kind });
    // An install directory is relative to the prefix: the way from it to the destination.
    const from_prefix = std.fs.path.relative(b.allocator, b.graph.cache.cwd, null, b.install_path, destination) catch @panic("OOM");
    const install = b.addInstallArtifact(library, .{
        .dest_dir = .{ .override = .{ .custom = from_prefix } },
        .implib_dir = .disabled,
        .h_dir = .disabled,
    });
    step.dependOn(&install.step);
}
