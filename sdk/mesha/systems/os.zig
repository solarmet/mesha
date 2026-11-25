//! The OS system's contract: the cursors and requests systems make of the window and the
//! process, the table that holds the window's size, and the table that says where things are
//! (`os_places`). The window itself, its platform events and the system that applies the
//! requests are the runtime's (`mesha_runtime.os`).
//!
//! A system asks with `request`, a row of `commands.os`; answers (the clipboard's text, a picked
//! path, whether the working directory moved) come to the inbox the request names, in a later
//! frame. A cursor is asked for by a hit region's `cursor` cell: the host shows the cursor of the
//! region under the pointer.

const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const sequencer = @import("../core/sequencer.zig");
const input = @import("input.zig");

/// A pointer shape. `arrow` is the default; `text` is the I-beam and `wait` the busy pointer.
/// `resize_ns`, `resize_ew`, `resize_nwse` and `resize_nesw` are the two-headed arrows along
/// those compass directions, north being up; `resize_n` through `resize_nw` are the shapes for
/// dragging that one edge or corner.
pub const CursorKind = enum(u8) { arrow, crosshair, hand, move, resize_ns, resize_ew, resize_nwse, resize_nesw, resize_n, resize_ne, resize_e, resize_se, resize_s, resize_sw, resize_w, resize_nw, text, wait };

/// A request of the window or the process, a row of `commands.os`.
pub const CmdPayload = union(enum) {
    /// Asks the window to close, which ends the host.
    request_close: struct {},

    /// Puts `text` on the clipboard, in place of what it held; empty text clears it. The text is
    /// copied with the request.
    set_clipboard: struct { text: []const u8 },
    /// Reads the clipboard's text, at most `max_bytes` of it, and answers `reply` with the
    /// text as the payload, none when it is empty. A reply the inbox cannot take is read
    /// again at the next application.
    get_clipboard: struct { max_bytes: usize, reply: sequencer.ReplyTo },
    /// Shows the platform's folder picker over the window. Its answer to `reply` has the
    /// chosen folder's path as the payload, none when the person cancelled or the picker
    /// failed. While one picker shows, of any kind, another request is dropped.
    open_folder_dialog: struct { reply: sequencer.ReplyTo },
    /// Shows the platform's picker of a file to open; answered as the folder picker is.
    open_file_dialog: struct { reply: sequencer.ReplyTo },
    /// Shows the platform's picker of a file to save to, starting at `suggested` (a path, or
    /// empty for the platform's choice); answered as the folder picker is.
    save_file_dialog: struct { reply: sequencer.ReplyTo, suggested: []const u8 },
    /// Moves the whole process's working directory to `path`, between frames: a relative path
    /// is read against the working directory as it is then. The path is copied with the
    /// request. The answer to `reply` is a `WorkingDirectoryMsg`; when the directory moved,
    /// `os_places.working_directory` names it before the answer arrives, and from then every
    /// relative path the engine is given is read against it. On a failure the working
    /// directory and `os_places` are as they were.
    set_working_directory: struct { path: []const u8, reply: sequencer.ReplyTo },
};

/// The answer to `set_working_directory`.
pub const WorkingDirectoryMsg = struct {
    /// What came of the request.
    pub const Result = enum(u8) {
        /// The working directory is now the path asked for.
        changed,
        /// Nothing is at the path.
        not_found,
        /// What is at the path is not a directory.
        not_a_directory,
        /// The process may not enter the directory.
        access_denied,
        /// The directory could not be entered for another reason, which the host logs.
        failed,
    };

    /// What came of the request.
    result: Result,
};

/// The window, as one row the window keeps current: its size in pixels, and whether it has the
/// keyboard focus (`WindowFocusView`). Systems read it; the host writes it between frames, from
/// the window's own events, as they happen.
pub const window_table_name = "os_window";
/// A view of the one row of `os_window`: the window's width and height in pixels.
pub const WindowView = struct { width: *u32, height: *u32 };
/// The cell of `os_window` that says whether the engine's window has the keyboard focus, as
/// `WindowFocusView` reads it.
pub const window_focused_field = "focused";
/// A view of whether the engine's window has the keyboard focus: `focused` is 1 while it has, 0
/// while another program's window has it (the person is elsewhere), as the window's focus events
/// last said; 1 before any, so a platform that never tells counts as focused. A system that does
/// work in the background only while the person is at the engine (a timer that asks a program
/// something) reads it each run; a table made without the cell, as a test's, says nothing, which a
/// reader takes as focused.
pub const WindowFocusView = struct { focused: *u8 };

/// `os_places`, one row that says where things are. The host writes it whole before any plugin
/// is loaded, so a plugin's first run reads it, and its `working_directory` again each time
/// `set_working_directory` moves the working directory; systems only read it.
pub const places_table_name = "os_places";
/// A view of the one row of `os_places`. Each path is absolute and `/`-separated, a Windows
/// drive (`C:`) or server (`//server`) kept as its root. The slices are the table's: good until
/// the row is written again, which is at most once per `set_working_directory` applied.
pub const PlacesView = struct {
    /// The process's working directory, against which a relative path is read: its real path.
    working_directory: []const u8,
    /// The person's home directory, from the environment (`HOME`, or `USERPROFILE` on
    /// Windows), its real path when it is there; empty when the environment does not name one.
    home_directory: []const u8,
    /// The host's own executable file, its real path; empty when the platform cannot tell it.
    executable: []const u8,
    /// Where the programs the host runs are, `vendor/` beside the editor's directory: written
    /// there, a folder each, by the step `vendor` of the build of the editor and the user's
    /// plugin, but for `vendor/zig`, which the person puts there. A program is
    /// `vendor/<program>/<file>`, as its release lays it out (`vendor/fd/fd`,
    /// `vendor/ripgrep/rg`, `vendor/zls/zls`, `vendor/clice/bin/clice`, `vendor/zig/zig`, with
    /// `.exe` on Windows); a target its authors do not build for has none. Absolute and
    /// `/`-separated; empty when the host found no editor, and a reader then runs a program by
    /// its name alone, from `PATH`.
    vendor_directory: []const u8,
};

/// What the platform tells of the window and its devices: `input.Event`.
pub const Event = input.Event;

/// `commands.os`, the requests the `os` system applies.
pub const commands_table_name = "commands.os";
/// The typed handle on `commands.os`.
pub const Requests = sequencer.Commands(CmdPayload);

/// Asks the window or the process for `wanted`, a row of `commands.os` the `os` system applies
/// once the frame's run is flushed. A journaled system that asks declares the table written, so
/// a fault takes its request back.
pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: CmdPayload) void {
    Requests.of(memory, tables, commands_table_name).push(wanted);
}
