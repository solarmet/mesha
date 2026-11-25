//! The watch system: the plugins' builds, each run again whenever its source changes, so the
//! libraries the host loads are rebuilt as they are edited and the host reloads them. It
//! draws nothing.
//!
//! A build is `zig build --watch` in a directory, run through the process system with the
//! compiler on `PATH` and the arguments that make a plugin lay out what it shares with the
//! host as the host does (`Settings.arguments`, which the root build bakes into the host). The
//! host starts one build for the editor and the user's plugin together, `plugins`, from the
//! build directory beside the editor (a distribution's root, a checkout's `plugins/`),
//! which builds each plugin by a step named for it; and one build of its own
//! for every other row of `plugins` whose directory holds a `build.zig`. A build ends when the
//! last plugin it builds goes. Before its first build the watch checks the compiler once
//! (`zig version`, which must be `required_zig_version`). When it is missing or of another
//! version, a build asked for at start-up stops the host with a message saying so, and one
//! asked for once the host runs is refused and the person told (`Phase`).
//!
//! A build's program stays: it builds once when it starts and again whenever a source changes,
//! and says how each such pass went for each plugin it builds (`Pass`), so one plugin that
//! fails to compile does not hold back another built beside it. The host loads a plugin that
//! has a build only once a pass of this run has built it, so the library it loads is never one
//! an earlier host, or an earlier SDK, built.
//!
//! - `watch` is the system's state, a row per build.
//! - `watch_plugins` is a row per plugin a build builds, with what the newest pass came to for
//!   it.
//! - What a build says, a line at a time, is told to a buffer of its own, which is only read:
//!   `*plugins*` for the editor's and the user's, `*plugin <name>*` for a plugin's own. It is
//!   where to look when a plugin did not rebuild.

const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;

/// Whether the host runs builds at all. `MESHA_NO_BUILD` in its environment (any value)
/// turns them off: nothing runs `zig` and nothing is checked, and libraries already there
/// still load. The functional suites and probes set it, so no library is rebuilt under them.
pub const Builds = enum(u8) { on, off };

/// When a build is asked for. At start-up a compiler that will not do stops the host with a
/// message saying why; once it runs, the build is refused, the person told, and the host goes
/// on, so nothing open is lost.
pub const Phase = enum(u8) { start_up, running };

/// What a build refused for its compiler was for: a plugin being loaded or one being created.
pub const Refused = enum(u8) { load, create };

/// The compiler version plugins are built with: the host's.
pub const required_zig_version = "0.16.0";

/// How many of each build's last lines the watch keeps itself, beside its buffer: the host's
/// loading screen shows those of the build of the editor while the editor has no library.
pub const kept_lines = 64;

/// How the host runs builds. Borrowed for as long as the watch runs.
pub const Settings = struct {
    /// The build options every build is given, as `-Doptimize=Debug`.
    arguments: []const []const u8,
    /// Whether builds run at all.
    builds: Builds,
    /// The `PATH` a `compiler` that is a name alone is looked for on: directories separated as
    /// the platform separates them.
    path_variable: []const u8,
    /// The zig every build runs: the path of the one a person put in `vendor/zig`
    /// (`os.PlacesView.vendor_directory`), or a name alone, looked for on `path_variable`.
    compiler: []const u8 = "zig",
};

/// The name of the build of the editor and the user's plugin together: its row's in `watch`.
pub const plugins_build_name = "plugins";

/// The buffer the build of the editor and the user's plugin says what it does in.
pub const plugins_buffer_name = "*plugins*";

/// The name of the buffer a plugin's own build, of the plugin `plugin_name`, says what it does
/// in, written in `buffer`.
pub fn outputBufferName(buffer: []u8, plugin_name: []const u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "*plugin {s}*", .{plugin_name});
}

/// Where a build is.
pub const State = enum(u8) {
    /// Added, and its program not yet asked for.
    off,
    /// The build was asked for and the process system has not answered.
    starting,
    /// The build's program runs; or, for a build that ended and builds its first plugin alone
    /// meanwhile (the editor, while the user's build file does not build), that program runs.
    running,
    /// The build ended, or would not start: it starts again when one of its build files (its
    /// `build.zig` and manifest, and those of each plugin whose `build.zig` its program
    /// compiles) changes.
    ended,
};

/// What the newest pass of a build came to for one plugin it builds. A pass is one run of the
/// build's program over its steps: the first when the program starts, and one more each time
/// a source changes.
pub const Pass = enum(u8) {
    /// No pass has finished since the build's program was last started.
    building,
    /// The newest pass built the plugin's library and installed it: the one there is this
    /// run's.
    succeeded,
    /// The newest pass failed to build the plugin's library, or the build's program ended: the
    /// library there, if any, is not what the source builds.
    failed,
};

/// `watch`, the system's state: a row per build.
pub const state_table_name = "watch";
/// A view of a row of `watch`.
pub const StateRow = struct {
    /// The build's name: `plugins_build_name` for the editor's and the user's, the plugin's
    /// own name, its row's in `plugins`, for a plugin's own build.
    build: *Atom,
    /// A `State`.
    state: *u8,
    /// The build's program, a `process.Process`; none unless it runs.
    process: *u32,
    /// The directory the build runs in.
    directory: []const u8,
};

/// `watch_plugins`: a row per plugin a build builds, there while the build is.
pub const plugins_table_name = "watch_plugins";
/// A view of a row of `watch_plugins`.
pub const PluginRow = struct {
    /// The plugin, its row's name in `plugins`.
    plugin: *Atom,
    /// The build that builds it, its row's `build` in `watch`.
    build: *Atom,
    /// A `Pass`: what the newest pass came to for this plugin.
    pass: *u8,
};
