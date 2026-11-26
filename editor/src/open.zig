//! Opening a file of any kind the editor shows: the platform's picker or the find-file prompt
//! (C-x C-f) asks which, and the file's extension says where it goes. A figure or a sketch
//! opens in the figure editor, a table document in a table window when a loaded plugin holds
//! it, a log in the profiler, and anything else as text in a text panel. Find-file starts in
//! the directory of the focused text window's file, or of the figure shown, else in the
//! working directory; in its text, as in Emacs's, a `//` starts the path again from the root
//! and a `~/` from the home directory (`TypedPath`).
//!
//! And opening a project, as Emacs's project.el does under `C-x p`: a project is a directory,
//! and opening one is making it the working directory, which every tool that runs a program
//! or reads a relative path then works in.
//!
//! - `project_switch` (C-x p p) asks which project, listing the remembered ones by `shown`
//!   and, last, `Choose a directory…`, which opens the prompt on the working directory, as it
//!   opens at once with none remembered; a text with a `/` in it is a path, whose
//!   directories the prompt completes as find-file completes files. The text is the
//!   directory: RET on the entry for the text as typed (first once the text ends in `/` or
//!   names a listed directory whole) chooses it, and RET on a listed directory goes into it,
//!   the prompt's text becoming its path, as Emacs's directory prompts do. The directory
//!   chosen is sent to the OS system to enter; once it has, it is remembered, the message
//!   line says `Project: <path>` and the project menu shows (`transient.zig`), as project.el's
//!   `project-switch-commands` do: `f` finds a file, `g` greps, `d` opens find-file on the
//!   project, `b` switches among its buffers, `c` compiles and `v` shows the git status
//!   (vcs-git), each invoking that global action. When it could not, the message line says why.
//! - `project_find_directory` (C-x p d) opens the find-file prompt on the working directory.
//! - `project_forget` (C-x p S-d, Emacs's `C-x p D`) asks which remembered project to forget.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const plugin = mesha.plugin;
const os = mesha.os;
const memory_mod = mesha.memory;
const resources = mesha.resources;
const table_document = mesha.table_document;
const sequencer = mesha.sequencer;
const action_palette = @import("action_palette.zig");
const transient = @import("transient.zig");
const ui = mesha.ui;
const editor_mod = @import("editor.zig");
const text_editor = plugin.text_editor_api;
const text_panel = @import("text_panel.zig");
const figure_workspace = @import("figure/workspace.zig");
const editor_state = @import("state.zig");

const Msg = enum(u64) {
    /// Asks which file to open, in the platform's picker.
    open = Atom.from("open").value(),
    /// The picker's answer: the path chosen.
    open_path = Atom.from("open_path").value(),
    /// Asks for a path to open, in the palette's find-file prompt.
    text_find_file = Atom.from("text_find_file").value(),
    /// The text editor's listing of the directory the find-file prompt opens on.
    open_find_file_listing = Atom.from("open_find_file_listing").value(),
    /// The text editor's listing of the directory a path is being typed in, the hash of the
    /// typed directory its user data.
    open_path_listing = Atom.from("open_path_listing").value(),
    /// The find-file prompt's events: the path as it is typed, and the entry chosen.
    open_typed_path = Atom.from("open_typed_path").value(),
    /// The text editor's listing of the directory of a table document being opened: its real
    /// path, which says whose table it is. The file's name is the user data.
    open_table_directory = Atom.from("open_table_directory").value(),
    /// Asks which project to switch to: a remembered one, or a directory typed.
    project_switch = Atom.from("project_switch").value(),
    /// Opens the find-file prompt on the working directory, the project's root.
    project_find_directory = Atom.from("project_find_directory").value(),
    /// Asks which remembered project to forget.
    project_forget = Atom.from("project_forget").value(),
    /// The project prompt's events: the text as it is typed, and the entry chosen.
    open_project_typed = Atom.from("open_project_typed").value(),
    /// The text editor's listing of the directory a project's path is being typed in, the hash
    /// of the typed directory its user data.
    open_project_path_listing = Atom.from("open_project_path_listing").value(),
    /// The text editor's listing of a directory chosen in the project prompt, which the prompt
    /// opens on again.
    open_project_listing = Atom.from("open_project_listing").value(),
    /// The forget prompt's events: the text as it is typed, and the project chosen.
    open_project_forgotten = Atom.from("open_project_forgotten").value(),
    /// The OS system's answer to a project's directory being entered, the directory's path the
    /// user data.
    open_project_entered = Atom.from("open_project_entered").value(),
    /// The project menu's answer, a `transient.Chosen`.
    open_project_menu = Atom.from("open_project_menu").value(),
    _,
};

/// Finding a file by typing its path, which the editor offers whatever has the focus and
/// `global_keys` binds; the name is older than the prompt's opening anything but text.
pub const find_file_action: plugin.action_api.Def = .{ .name = "find_file", .tag = @tagName(Msg.text_find_file), .doc = "Open a file by typing its path: a figure, a sketch, a log or a text file" };

/// The project's actions are offered from anywhere too; their keys, `C-x p`, are
/// `text_tools.global_keys`, with the other project commands'.
pub const actions = [_]plugin.action_api.Def{
    .{ .name = "open", .tag = @tagName(Msg.open), .doc = "Open a file: a figure, a sketch, a log or a text file" },
    find_file_action,
    .{ .name = "project_switch", .tag = @tagName(Msg.project_switch), .doc = "Switch to a project, a remembered one or a directory typed, making it the working directory: RET on the text typed chooses that directory, RET on a listed one goes into it" },
    .{ .name = "project_find_directory", .tag = @tagName(Msg.project_find_directory), .doc = "Open a file by typing its path, from the project's directory" },
    .{ .name = "project_forget", .tag = @tagName(Msg.project_forget), .doc = "Forget one of the projects remembered" },
};

/// The keys of `actions`, of the mode `global`.
pub const global_keys = [_]mesha.keybinds.KeyDef{
    .{ .chord = "C-x C-f", .action = .{ "global", "find_file" } },
};

pub fn system() sequencer.System {
    return .{
        .name = "editor_open",
        .names = comptime &sequencer.enumNames(Msg),
        .root = editor_mod.editor_root,
        .claims = claims,
        .access = access,
        .kernels = &.{.{ .name = "editor_open.take_messages", .run = takeMessages }},
    };
}

/// What the figure editor is asked to open or make, one row: this system writes it and asks the
/// figure canvas to open it (`figure_workspace.Request.open_requested`) or to make it new at its
/// path (`create_requested`), and the canvas reads it.
pub const table_name = "editor_open";
const state_table = Atom.from(table_name);

pub const DocumentKind = enum(u8) { none, figure, sketch };

pub const StateRow = struct {
    /// The document's id: its file's stem.
    document: *Atom,
    /// A `DocumentKind`.
    kind: *u8,
    /// The document's file, as it was named: relative to the working directory, or absolute.
    path: *Table.String,
};

const RequestView = struct { document: *Atom, kind: *u8, path: []const u8 };

pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ table_name, find_file_owner_name, project_owner_name });
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 3);
    defer schema.deinit();
    try schema.addFieldFallible("document", Atom, .atom);
    try schema.addFieldFallible("kind", u8, .int);
    try schema.addFieldFallible("path", Table.String, .text_field);
    const none: Atom = @enumFromInt(0);
    const defaults = .{ .document = none, .kind = @as(u8, @intFromEnum(DocumentKind.none)), .path = Table.String{} };
    _ = try tables.ensureSingleton(&schema, state_table, defaults, .durable);
}

/// The document the figure editor was last asked to open or make. Its path is the table's until
/// the table next changes.
pub fn requested(tables: *Table.Registry) ?struct { document: Atom, kind: DocumentKind, path: []const u8 } {
    const found = tables.findByName(state_table) orelse return null;
    var rows = found.readQuery(RequestView);
    const row = rows.next() orelse return null;
    const kind = std.enums.fromInt(DocumentKind, row.view.kind.*) orelse return null;
    if (kind == .none) return null;
    return .{ .document = row.view.document.*, .kind = kind, .path = row.view.path };
}

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

fn access(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    if (frame.messages.len == 0) return result;
    declareOpenAccess(&result, tables);
    // A table document opens where a loaded plugin holds it, as a request to resources.
    if (tables.findByName(plugins_table) != null) result.read(plugins_table);
    result.writeIfPresent(tables, Atom.from(resources.commands_table_name));
    result.read(Atom.from(action_palette.table_name));
    result.write(Atom.from(action_palette.requests_table_name));
    // A project switched to offers its menu, whose choice is a global action invoked.
    result.write(Atom.from(transient.requests_table_name));
    result.writeIfPresent(tables, Atom.from(plugin.action_api.commands_table_name));
    result.writeIfPresent(tables, Atom.from(os.commands_table_name));
    // The projects remembered, labelled by where the working directory is.
    result.read(projects_table);
    result.read(places_table);
    // Where find-file starts: the focused text window's file, else the figure shown.
    result.read(view_focus_table);
    result.read(text_windows_table);
    result.read(buffers_table);
    figure_workspace.declareFindFileDirectoryReads(&result);
    return result;
}

/// What `openPath` needs of a system that calls it: the request for the figure editor and
/// the requests to what opens each kind of file.
pub fn declareOpenAccess(result: *sequencer.Access, tables: *Table.Registry) void {
    result.write(state_table);
    result.writeIfPresent(tables, Atom.from(text_editor.commands_table_name));
    // A figure opens through a request to the figure canvas; a log through the profiler, which
    // reads it, and its panel.
    result.writeIfPresent(tables, Atom.from(mesha.profiler.commands_table_name));
    result.writeIfPresent(tables, Atom.from(figure_workspace.commands_table_name));
    result.writeIfPresent(tables, Atom.from(plugin.panels.commands_table_name));
}

fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    for (frame.messages) |received| {
        handle(pass, received) catch |err| received.unreadable(err);
    }
}

fn handle(pass: *sequencer.Pass, received: sequencer.Message) !void {
    const frame = pass.frame;
    const tables = frame.tables;
    switch (received.tag.to(Msg)) {
        .open => {
            const reply = sequencer.ReplyTo.of(system(), .from(Msg.open_path));
            os.request(frame.memory, tables, .{ .open_file_dialog = .{ .reply = reply } });
        },
        .open_path => {
            // No path is the picker cancelled; the platform's picker chooses a file that is there.
            const path = received.payload;
            if (path.len == 0) return;
            try openPath(pass, path, .present);
        },
        .text_find_file => {
            const start_directory = findFileStart(pass);
            requestFindFile(tables, start_directory);
        },
        .project_find_directory => requestFindFile(tables, ""),
        .open_find_file_listing, .open_project_listing => {
            const head = try text_panel.headOf(text_editor.ListedMsg, received);
            const purpose: PathPurpose = if (received.tag.to(Msg) == .open_find_file_listing) .file else .directory;
            const home_directory = places(pass).home_directory;
            presentPathPrompt(tables, head.value.*, head.trailing, home_directory, purpose);
        },
        .open_path_listing, .open_project_path_listing => {
            const head = try text_panel.headOf(text_editor.ListedMsg, received);
            const directory_hash = (try received.userDataAs(u64)).*;
            const purpose: PathPurpose = if (received.tag.to(Msg) == .open_path_listing) .file else .directory;
            const home_directory = places(pass).home_directory;
            replacePathCompletions(tables, frame.atoms, head.value.*, head.trailing, directory_hash, home_directory, purpose);
        },
        .open_typed_path => {
            const event = try action_palette.eventOf(received);
            if (event.kind == .query_changed) {
                const allocator = (try frame.memory.frameScratchAllocator()).allocator;
                const home_directory = places(pass).home_directory;
                const path = try TypedPath.of(allocator, event.query, home_directory);
                return requestListing(tables, path, .open_path_listing);
            }
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = find_file_owner } });
            const chosen = event.completion orelse return;
            try choosePath(pass, event.query, chosen, .file);
        },
        .project_switch, .project_forget => {
            const prompt: ProjectPrompt = if (received.tag.to(Msg) == .project_switch) .switch_project else .forget_project;
            const projects = projectRows(pass);
            // With none remembered there is only a directory to read, as Emacs's
            // `project-switch-project` reads one.
            if (prompt == .switch_project and !remembersAny(projects)) return requestProjectDirectory(tables);
            const working_directory = places(pass).working_directory;
            presentProjects(tables, projects, working_directory, "", prompt, .open);
        },
        .open_project_typed => {
            const event = try action_palette.eventOf(received);
            if (event.kind == .query_changed) {
                if (namesPath(event.query)) {
                    const allocator = (try frame.memory.frameScratchAllocator()).allocator;
                    const home_directory = places(pass).home_directory;
                    const path = try TypedPath.of(allocator, event.query, home_directory);
                    return requestListing(tables, path, .open_project_path_listing);
                }
                const projects = projectRows(pass);
                const working_directory = places(pass).working_directory;
                return presentProjects(tables, projects, working_directory, event.query, .switch_project, .relist);
            }
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = project_owner } });
            const chosen = event.completion orelse return;
            try choosePath(pass, event.query, chosen, .directory);
        },
        .open_project_forgotten => {
            const event = try action_palette.eventOf(received);
            if (event.kind == .query_changed) {
                const projects = projectRows(pass);
                const working_directory = places(pass).working_directory;
                return presentProjects(tables, projects, working_directory, event.query, .forget_project, .relist);
            }
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = project_owner } });
            const chosen = event.completion orelse return;
            try forgetProject(frame.memory, tables, chosen.key);
        },
        .open_project_entered => {
            const answer = try received.payloadAs(os.WorkingDirectoryMsg);
            try tellProjectEntered(frame.memory, tables, received.user_data, answer.result);
        },
        .open_project_menu => {
            const chosen = try received.payloadAs(transient.Chosen);
            if (chosen.cancelled != 0) return;
            const command = std.enums.fromInt(ProjectCommand, chosen.id) orelse return;
            const action = command.action();
            plugin.action_api.requestInvoke(tables, action);
        },
        .open_table_directory => {
            const head = try text_panel.headOf(text_editor.ListedMsg, received);
            try openTable(pass, head.value.*, head.trailing, received.user_data);
        },
        _ => {},
    }
}

const FileKind = enum { figure, sketch, table, log, text };

/// Whether a file being opened is there, as far as the asker knows: `absent` when the
/// directory's listing did not hold it, so a figure or a sketch of that path is made new.
pub const Presence = enum { present, absent };

/// A figure, a sketch or a table document only by its extension as its system names it,
/// exactly, after a stem: another spelling, or a bare `.mshf`, opens as text.
fn kindOf(path: []const u8) FileKind {
    const extension = std.fs.path.extension(path);
    const named = documentStem(path).len != 0;
    if (named and std.mem.eql(u8, extension, resources.figure_document_extension)) return .figure;
    if (named and std.mem.eql(u8, extension, resources.sketch_document_extension)) return .sketch;
    if (named and std.mem.eql(u8, extension, table_document.file_extension)) return .table;
    if (std.ascii.eqlIgnoreCase(extension, ".meshalog")) return .log;
    return .text;
}

/// Sends the file at `path` to what shows its kind: a figure or a sketch, at any path, to the
/// figure editor, which opens it by its path, or, when it is `absent`, makes a new one of its
/// stem whose file is that path; a table document to this system, once the text editor has said
/// where its directory really is (`openTable`). The caller's system declares
/// `declareOpenAccess`.
pub fn openPath(pass: *sequencer.Pass, path: []const u8, presence: Presence) !void {
    const frame = pass.frame;
    const tables = frame.tables;
    const kind = kindOf(path);
    switch (kind) {
        .text => text_panel.openPath(tables, path),
        .table => requestTableDirectory(tables, path),
        .log => editor_mod.profiler.openLog(tables, frame.atoms, path),
        .figure, .sketch => {
            // Its id is its stem, which the figure editor interns as it takes the request.
            const state = try pass.writeSingleton(state_table, StateRow);
            const cells = try pass.writeTable(state_table);
            state.document.* = Atom.from(documentStem(path));
            state.kind.* = @intFromEnum(if (kind == .figure) DocumentKind.figure else DocumentKind.sketch);
            try cells.assignString(state.path, path);
            const wanted: figure_workspace.Request = switch (presence) {
                .present => .open_requested,
                .absent => .create_requested,
            };
            figure_workspace.request(frame.memory, tables, wanted);
        },
    }
}

/// The name of the file at `path` without its extension: a figure's or a sketch's id.
pub fn documentStem(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    return name[0 .. name.len - std.fs.path.extension(name).len];
}

// ---- opening a table document ---------------------------------------------------------------
//
// A table document loads only where code registered its schema under its id, so it opens
// only from a loaded plugin's `assets/tables/`, as `<plugin>_<stem>`: the table resources
// resolves that id to. Whether the file lies there is decided by its directory's real path,
// which the text editor answers, not by how the path was spelled.

const plugins_table = Atom.from(plugin.plugins.table_name);

const table_refusal = "A table document opens from a loaded plugin's assets/tables folder, whose code registers its schema.";

/// Asks the text editor for the real path of the directory holding the table document at
/// `path`, answered to this system with the file's name as the user data.
fn requestTableDirectory(tables: *Table.Registry, path: []const u8) void {
    const directory = std.fs.path.dirname(path) orelse "";
    const file_name = std.fs.path.basename(path);
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.open_table_directory)).with(.{ .bytes = file_name });
    text_editor.request(tables.memory, tables, .{ .list_directory = .{ .path = directory, .reply = reply } });
}

/// Opens the table document `file_name` in the directory `listed` gives the real path of, in a
/// table window, when that directory is a loaded plugin's `assets/tables/` and the id it makes
/// there is that plugin's; else tells the person it cannot, or that the directory could not be
/// read.
fn openTable(pass: *sequencer.Pass, listed: text_editor.ListedMsg, trailing: []const u8, file_name: []const u8) !void {
    const frame = pass.frame;
    const tables = frame.tables;
    const atoms = frame.atoms;
    const stem = documentStem(file_name);
    if (listed.result != .listed or trailing.len < listed.directory_len) {
        return text_editor.message(frame.memory, tables, unreadableDirectory(listed.result));
    }
    const real_directory = trailing[0..listed.directory_len];
    var id_buffer: [plugin.plugins.max_name_bytes + 1 + 128]u8 = undefined;
    var id: ?[]const u8 = null;
    if (tables.findByName(plugins_table)) |rows| {
        var query = rows.readQuery(plugin.plugins.TablesView);
        while (query.next()) |row| {
            if (!isPluginTablesDirectory(row.view, real_directory)) continue;
            const name = atoms.lookup(row.view.name.*) orelse continue;
            const made = std.fmt.bufPrint(&id_buffer, "{s}_{s}", .{ name, stem }) catch continue;
            if (!table_document.validId(made)) continue;
            // A plugin with a longer name that `made` begins with holds that id instead.
            const owner = plugin.plugins.scopeOwner(rows, atoms, made) orelse continue;
            if (owner.row != row.handle.row or owner.generation != row.handle.generation) continue;
            id = made;
            break;
        }
    }
    const table_id = id orelse return text_editor.message(frame.memory, tables, table_refusal);
    // The id is a file's, known only now: interned so resources and the window can name it.
    try atoms.tryInternAll(&.{table_id});
    // The table windows open the window on the answer, as for their own requests.
    const reply: sequencer.ReplyTo = .{ .inbox = Atom.from("inbox.table_windows"), .tag = Atom.from("table_request") };
    const scope = resources.applicationScope(frame.memory);
    resources.request(frame.memory, tables, .{ .request_table = .{ .scope = scope, .id = Atom.from(table_id), .reply = reply } });
}

/// What the person is told when the directory of a table document being opened could not be
/// listed, by the text editor's answer.
fn unreadableDirectory(result: text_editor.ListResult) []const u8 {
    return switch (result) {
        .not_found => "The table document's folder could not be read: it is not there.",
        .not_a_directory => "The table document's folder could not be read: it is not a folder.",
        .read_failed => "The table document's folder could not be read: listing it failed.",
        .out_of_memory => "The table document's folder could not be read: there was no memory to list it.",
        // A listing answered without its directory's path.
        .listed => "The table document's folder could not be read: its path did not come back.",
    };
}

/// Whether `real_directory` is the `assets/tables/` of the plugin `row`, which keeps its
/// tables there (`plugins.holdsTables`).
fn isPluginTablesDirectory(row: Table.ReadView(plugin.plugins.TablesView), real_directory: []const u8) bool {
    if (!plugin.plugins.holdsTables(row)) return false;
    if (real_directory.len == 0) return false;
    const suffix = "/" ++ table_document.kTablesDir;
    if (real_directory.len != row.directory.len + suffix.len) return false;
    if (!std.mem.startsWith(u8, real_directory, row.directory)) return false;
    return std.mem.endsWith(u8, real_directory, suffix);
}

// ---- finding a file -------------------------------------------------------------------------
//
// The find-file prompt opens on a directory, its path the text and its entries what it
// holds. Each edit of the text asks the text editor for the directory part of what is typed,
// up to its last `/`, and the entries become those whose names begin with the rest. Choosing
// a directory opens the prompt again on it; choosing a file opens it where its kind goes, as
// a path the platform's picker gives does. The project prompt completes a typed path the same
// way, listing directories only, and the text as typed is the directory it chooses.

/// The find-file prompt's owner and identity among the palette's prompts.
const find_file_owner_name = "editor_open_find_file";
pub const find_file_owner = Atom.from(find_file_owner_name);
const find_file_identity: u64 = Atom.from("text_find_file").value();

/// The most entries a find-file prompt lists.
const max_path_completions = 256;

const PathChoice = enum(u8) {
    file,
    directory,
    /// The text as typed: a file to make, or one the listing does not have; in the project
    /// prompt, the directory to switch to.
    typed,
    /// A remembered project, its path the entry's key.
    project,
    /// The project prompt's last entry, which reads a directory instead.
    choose_directory,
};

/// What a find-file entry leads to, and the hash of the typed directory it was listed for.
const PathEntry = extern struct {
    directory_hash: u64,
    choice: PathChoice,
    /// Zero, so the entry's bytes are all set.
    padding: [7]u8 = @splat(0),
};

/// What a path is typed for: a file to open, in the find-file prompt, or a directory to make
/// the project, in the project prompt.
const PathPurpose = enum(u8) {
    file,
    directory,

    fn owner(purpose: PathPurpose) Atom {
        return switch (purpose) {
            .file => find_file_owner,
            .directory => project_owner,
        };
    }

    fn identity(purpose: PathPurpose) u64 {
        return switch (purpose) {
            .file => find_file_identity,
            .directory => ProjectPrompt.switch_project.identity(),
        };
    }

    /// The listing of a directory the prompt opens on.
    fn openingListing(purpose: PathPurpose) Msg {
        return switch (purpose) {
            .file => .open_find_file_listing,
            .directory => .open_project_listing,
        };
    }

    /// The prompt's events.
    fn events(purpose: PathPurpose) Msg {
        return switch (purpose) {
            .file => .open_typed_path,
            .directory => .open_project_typed,
        };
    }

    fn title(purpose: PathPurpose) []const u8 {
        return switch (purpose) {
            .file => "Find file",
            .directory => ProjectPrompt.switch_project.title(),
        };
    }

    /// The label of the entry for the text as typed.
    fn typedLabel(purpose: PathPurpose) []const u8 {
        return switch (purpose) {
            .file => "Open the file at this path",
            .directory => "Switch to this directory",
        };
    }
};

/// A typed path as the prompts read it, cut after its last `/`: the directory it names and the
/// name begun in it. As Emacs reads a file name, what comes before a `//` or a `~/` is ignored:
/// after a `//` the path starts again from the root, and at a `~/` from the home directory. A
/// `~` counts only as a whole component followed by `/`; text that begins with `//` names a
/// network path and is taken as it is, as is a `~/` while the home directory is not known.
const TypedPath = struct {
    /// The path the text names, which is listed and opened: a slice of the text, or, from a
    /// `~/`, a copy made in the allocator `of` was given.
    whole: []const u8,
    /// `whole` up to and with its last `/`; empty when it has none.
    directory: []const u8,
    /// What follows `directory`: the name begun, which the text ends with too.
    name: []const u8,

    /// `typed` as a path, `home_directory` (absolute, `/`-separated, or empty when not known)
    /// standing for a `~`.
    fn of(allocator: std.mem.Allocator, typed: []const u8, home_directory: []const u8) !TypedPath {
        const whole = try effectivePath(allocator, typed, home_directory);
        return ofEffective(whole);
    }

    /// `whole`, a path already read by the rule (`of`), cut after its last `/`: a `//` or a `~/`
    /// in it is part of a name and is not read again.
    fn ofEffective(whole: []const u8) TypedPath {
        const cut = if (std.mem.lastIndexOfScalar(u8, whole, '/')) |slash| slash + 1 else 0;
        return .{ .whole = whole, .directory = whole[0..cut], .name = whole[cut..] };
    }

    fn directoryHash(path: TypedPath) u64 {
        return std.hash.Wyhash.hash(0, path.directory);
    }
};

/// The path `typed` names by `TypedPath`'s rule: from its last `//` that follows other text, on
/// from the second `/`, or its last `~/` that begins a component, on from the home directory.
fn effectivePath(allocator: std.mem.Allocator, typed: []const u8, home_directory: []const u8) ![]const u8 {
    var start: usize = 0;
    var from_home = false;
    for (typed, 0..) |byte, index| {
        const after_slash = index != 0 and typed[index - 1] == '/';
        const root_again = byte == '/' and after_slash and index >= 2;
        const component_start = index == 0 or after_slash;
        const followed_by_slash = index + 1 < typed.len and typed[index + 1] == '/';
        const home_again = byte == '~' and component_start and followed_by_slash and home_directory.len != 0;
        if (root_again) {
            start = index;
            from_home = false;
        } else if (home_again) {
            // The `/` after the `~` goes on from the home directory.
            start = index + 1;
            from_home = true;
        }
    }
    const rest = typed[start..];
    if (!from_home) return rest;
    // A root's own `/` is the one `rest` begins with.
    const home = std.mem.trimEnd(u8, home_directory, "/");
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, rest });
}

/// The focused view, as the editor records it: kept while a prompt has the keyboard.
const view_focus_table = Atom.from(editor_state.view_focus_name);
const text_windows_table = Atom.from(text_panel.table_name);
const buffers_table = Atom.from(text_editor.buffers_table_name);

/// The part of the editor's record of the focused view this module reads.
const FocusRow = struct { id: *Atom };

/// The directory `text_find_file` opens on, as Emacs's find-file starts from the current
/// buffer's: that of the file of the focused text window's buffer; else, from the figure
/// workspace, that of the figure shown; else empty, the working directory.
fn findFileStart(pass: *const sequencer.Pass) []const u8 {
    const file = focusedFile(pass);
    if (file.len != 0) return std.fs.path.dirname(file) orelse "";
    return figure_workspace.findFileDirectory(pass.frame.tables, pass.frame.atoms);
}

/// The file of the buffer the focused view shows, when it is a text window; empty when it is
/// not or its buffer holds no file.
fn focusedFile(pass: *const sequencer.Pass) []const u8 {
    const focus = pass.readSingleton(view_focus_table, FocusRow) catch return "";
    const windows = pass.rows(text_windows_table, text_panel.WindowBufferRow) catch return "";
    const buffers = pass.rows(buffers_table, text_editor.BufferEntry) catch return "";
    const window_rows = windows.read();
    const buffer_rows = buffers.read();
    return text_panel.windowFile(window_rows, buffer_rows, focus.id.*);
}

/// Opens the find-file prompt on `start_directory`, its path the prompt's text once the text
/// editor has listed it; on the working directory when it is empty. Its answer comes to this
/// system, which opens the file chosen where its kind goes (`openPath`).
pub fn requestFindFile(tables: *Table.Registry, start_directory: []const u8) void {
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.open_find_file_listing));
    text_editor.request(tables.memory, tables, .{ .list_directory = .{ .path = start_directory, .reply = reply } });
}

/// Asks the text editor for the directory of `path`, the working directory when it names none,
/// answered under `answer` with the directory's hash as the user data.
fn requestListing(tables: *Table.Registry, path: TypedPath, answer: Msg) void {
    const directory_hash = path.directoryHash();
    const reply = sequencer.ReplyTo.of(system(), .from(answer)).with(.of(&directory_hash));
    text_editor.request(tables.memory, tables, .{ .list_directory = .{ .path = path.directory, .reply = reply } });
}

/// The entries of `listed`, the listing of `typed`'s directory, whose names begin with the
/// name `typed` has begun, only its directories for a `directory`; then the text as typed,
/// unless an entry has its name. A dotted name is listed only once a dot is typed. For a
/// `directory` the text as typed is always offered, the directory it names, and first when the
/// text ends in `/` or names a directory listed, so that RET chooses it. `home_directory`
/// stands for a `~` (`TypedPath`). Tab on an entry completes the text to its name after the
/// directory as typed, with `/` after a directory; on the text as typed, to the text.
fn pathCompletions(allocator: std.mem.Allocator, typed: []const u8, home_directory: []const u8, listed: text_editor.ListedMsg, trailing: []const u8, purpose: PathPurpose) ![]action_palette.Completion {
    const path = try TypedPath.of(allocator, typed, home_directory);
    const directory_hash = path.directoryHash();
    // What the text says before the name begun, kept as typed whatever directory it names.
    const typed_directory = typed[0 .. typed.len - path.name.len];
    const entries = try allocator.alloc(action_palette.Completion, max_path_completions + 1);
    var count: usize = 0;
    var exact = false;
    const has_listing = listed.result == .listed and trailing.len >= listed.directory_len;
    if (has_listing) {
        var listing: text_editor.ListedEntries = .{ .remaining = trailing[listed.directory_len..] };
        const dotted_wanted = std.mem.startsWith(u8, path.name, ".");
        while (listing.next()) |entry| {
            if (purpose == .directory and entry.kind == .file) continue;
            const dotted = std.mem.startsWith(u8, entry.name, ".");
            if (dotted and !dotted_wanted) continue;
            if (!std.ascii.startsWithIgnoreCase(entry.name, path.name)) continue;
            // Every match counts toward whether the name typed is there; only so many are listed.
            if (std.mem.eql(u8, entry.name, path.name)) exact = true;
            if (count == max_path_completions) continue;
            const choice: PathChoice = switch (entry.kind) {
                .file => .file,
                .directory => .directory,
            };
            const label = switch (choice) {
                .directory => try std.fmt.allocPrint(allocator, "{s}/", .{entry.name}),
                .file, .typed, .project, .choose_directory => entry.name,
            };
            const data = pathEntryData(choice, directory_hash);
            const completes_to = try std.fmt.allocPrint(allocator, "{s}{s}", .{ typed_directory, label });
            entries[count] = .{ .label = label, .data = data, .completes_to = completes_to };
            count += 1;
        }
    }
    const offers_typed = switch (purpose) {
        .file => path.name.len != 0 and !exact,
        .directory => typed.len != 0,
    };
    if (offers_typed) {
        const data = pathEntryData(.typed, directory_hash);
        // Its detail is what it names, under the directory's real path when it was listed.
        const real_directory = if (has_listing) trailing[0..listed.directory_len] else "";
        const detail = if (!has_listing)
            ""
        else if (path.name.len == 0)
            real_directory
        else
            try joinedPath(allocator, real_directory, path.name);
        entries[count] = .{ .label = purpose.typedLabel(), .detail = detail, .data = data, .completes_to = typed };
        count += 1;
        const typed_first = purpose == .directory and (path.name.len == 0 or exact);
        if (typed_first) std.mem.rotate(action_palette.Completion, entries[0..count], count - 1);
    }
    return entries[0..count];
}

/// `directory` as a prompt's text names it, ending in `/`: a copy in `allocator` when it does
/// not already; empty stays empty.
fn directoryText(allocator: std.mem.Allocator, directory: []const u8) ![]const u8 {
    const needs_slash = directory.len != 0 and !std.mem.endsWith(u8, directory, "/");
    if (!needs_slash) return directory;
    return std.fmt.allocPrint(allocator, "{s}/", .{directory});
}

/// `name` in `directory`, an absolute path, joined by one `/`.
pub fn joinedPath(allocator: std.mem.Allocator, directory: []const u8, name: []const u8) ![]const u8 {
    const separator = if (std.mem.endsWith(u8, directory, "/")) "" else "/";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ directory, separator, name });
}

fn pathEntryData(choice: PathChoice, directory_hash: u64) [action_palette.kCompletionDataSize]u8 {
    var data = std.mem.zeroes([action_palette.kCompletionDataSize]u8);
    const entry: PathEntry = .{ .directory_hash = directory_hash, .choice = choice };
    @memcpy(data[0..@sizeOf(PathEntry)], std.mem.asBytes(&entry));
    return data;
}

/// Opens the prompt for `purpose` on `listed`'s directory, its path the text, the caret after
/// it.
fn presentPathPrompt(tables: *Table.Registry, listed: text_editor.ListedMsg, trailing: []const u8, home_directory: []const u8, purpose: PathPurpose) void {
    const memory = tables.memory;
    const allocator = action_palette.completionAllocator(memory, .open) catch return;
    action_palette.resetCompletionArena(memory, .open);
    const has_directory = listed.result == .listed and trailing.len >= listed.directory_len;
    const directory = if (has_directory) trailing[0..listed.directory_len] else "";
    const initial_query = directoryText(allocator, directory) catch return;
    const offered = pathCompletions(allocator, initial_query, home_directory, listed, trailing, purpose) catch return;
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = .{
        .owner = purpose.owner(),
        .identity = purpose.identity(),
        .presentation = .prompt,
        .title = purpose.title(),
        .initial_query = initial_query,
        .initial_query_edit = .append,
        .entries = offered,
    };
    action_palette.ownRequestText(allocator, completions) catch return;
    const reply = sequencer.ReplyTo.of(system(), .from(purpose.events()));
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

/// Lists `listed` in the open prompt for `purpose`, if it is still the directory being typed
/// in.
fn replacePathCompletions(tables: *Table.Registry, atoms: *Atom.Registry, listed: text_editor.ListedMsg, trailing: []const u8, directory_hash: u64, home_directory: []const u8, purpose: PathPurpose) void {
    const shown_completions = action_palette.currentCompletions(tables, atoms) orelse return;
    if (shown_completions.owner != purpose.owner() or shown_completions.identity != purpose.identity()) return;
    const typed = action_palette.promptText(tables, atoms);
    const memory = tables.memory;
    // The arena is not reset: the prompt may still read the entries it shows.
    const allocator = action_palette.completionAllocator(memory, .open) catch return;
    const path = TypedPath.of(allocator, typed, home_directory) catch return;
    // A listing of a directory since typed past: the one asked for since replaces it.
    if (path.directoryHash() != directory_hash) return;
    const offered = pathCompletions(allocator, typed, home_directory, listed, trailing, purpose) catch return;
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = shown_completions.*;
    completions.entries = offered;
    action_palette.ownRequestText(allocator, completions) catch return;
    action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
}

/// Acts on the entry chosen in the prompt for `purpose`: opens the file it leads to, where its
/// kind goes; opens the prompt again on the directory it leads to; switches to the project or
/// to the directory typed. An entry listed for a directory since typed past is not in the one
/// typed: the text is taken as typed.
fn choosePath(pass: *sequencer.Pass, typed: []const u8, chosen: action_palette.Completion, purpose: PathPurpose) !void {
    const tables = pass.frame.tables;
    const allocator = (try pass.frame.memory.frameScratchAllocator()).allocator;
    const entry = std.mem.bytesToValue(PathEntry, chosen.data[0..@sizeOf(PathEntry)]);
    const home_directory = places(pass).home_directory;
    const path = try TypedPath.of(allocator, typed, home_directory);
    const listing: EntryListing = if (entry.directory_hash == path.directoryHash()) .current else .stale;
    const choice: PathChoice = switch (listing) {
        .current => entry.choice,
        .stale => .typed,
    };
    var joined_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    switch (choice) {
        .typed => try chooseTyped(pass, path.whole, chosen.detail, listing, purpose),
        .file => {
            const joined = std.fmt.bufPrint(&joined_buffer, "{s}{s}", .{ path.directory, chosen.label }) catch return;
            try openPath(pass, joined, .present);
        },
        .directory => {
            const directory = enteredDirectory(&joined_buffer, path, chosen.label) orelse return;
            requestListing(tables, directory, purpose.openingListing());
        },
        .project => enterProject(tables, chosen.key),
        .choose_directory => requestProjectDirectory(tables),
    }
}

/// The directory the listed directory `label`, its name and `/`, leads to from `path`'s, the
/// two joined in `buffer`: `path` is already the path the text names, so a directory named `~`
/// is that directory and not the home directory. Null when the path does not fit.
fn enteredDirectory(buffer: []u8, path: TypedPath, label: []const u8) ?TypedPath {
    const joined = std.fmt.bufPrint(buffer, "{s}{s}", .{ path.directory, label }) catch return null;
    return TypedPath.ofEffective(joined);
}

/// Whether a prompt's entry was listed for the directory now typed, or for one since typed
/// past.
const EntryListing = enum { current, stale };

/// The text as typed, chosen. Offered because the listing of its directory holds no entry of
/// its name, it is a file that is not there, named by the directory's real path (`detail`); in
/// the project prompt, the directory `detail` names. With no listing of its directory, only an
/// absolute path is taken, and a relative one is told why not. Chosen from a `stale` listing,
/// the text is taken as it is: a file that may be there, or, when it is absolute, a directory.
fn chooseTyped(pass: *sequencer.Pass, typed: []const u8, detail: []const u8, listing: EntryListing, purpose: PathPurpose) !void {
    if (typed.len == 0) return;
    const frame = pass.frame;
    const named: ?[]const u8 = if (listing == .stale)
        typed
    else if (detail.len != 0)
        detail
    else if (resources.isAbsolutePath(typed))
        typed
    else
        null;
    const memory = frame.memory;
    switch (purpose) {
        .file => {
            const presence: Presence = switch (listing) {
                .current => .absent,
                .stale => .present,
            };
            if (named) |file| return openPath(pass, file, presence);
            const allocator = (try memory.frameScratchAllocator()).allocator;
            const sentence = try std.fmt.allocPrint(allocator, "Nothing was opened: the folder of {s} could not be listed, so where it is is not known.", .{typed});
            text_editor.message(memory, frame.tables, sentence);
        },
        .directory => {
            // The OS system is sent an absolute path: what a relative one is read against is
            // not this system's to know.
            if (named) |directory| {
                if (resources.isAbsolutePath(directory)) return enterProject(frame.tables, directory);
            }
            const allocator = (try memory.frameScratchAllocator()).allocator;
            const sentence = try std.fmt.allocPrint(allocator, "The project was not switched: where {s} is is not known.", .{typed});
            text_editor.message(memory, frame.tables, sentence);
        },
    }
}

// ---- projects -------------------------------------------------------------------------------
//
// A project is a directory, and switching to one is making it the working directory. The
// text editor remembers the projects switched to, the latest first; the prompts list them by
// `shown`, so one under the working directory is named from it.

/// The project prompts' owner among the palette's prompts; each prompt's identity is its
/// `ProjectPrompt`'s.
const project_owner_name = "editor_open_project";
const project_owner = Atom.from(project_owner_name);

const projects_table = Atom.from(text_editor.projects_table_name);
/// Where things are, which the OS system keeps; a host without it has no such table.
const places_table = Atom.from(os.places_table_name);

/// Which project prompt is asking.
const ProjectPrompt = enum {
    switch_project,
    forget_project,

    fn identity(prompt: ProjectPrompt) u64 {
        return switch (prompt) {
            .switch_project => Atom.from("project_switch").value(),
            .forget_project => Atom.from("project_forget").value(),
        };
    }

    fn title(prompt: ProjectPrompt) []const u8 {
        return switch (prompt) {
            .switch_project => "Switch to project",
            .forget_project => "Forget project",
        };
    }

    fn events(prompt: ProjectPrompt) Msg {
        return switch (prompt) {
            .switch_project => .open_project_typed,
            .forget_project => .open_project_forgotten,
        };
    }
};

/// The part of `path` below `directory`, both absolute and `/`-separated: what follows
/// `directory` and the `/` after it, or after the root's own `/`. Null when `path` is not
/// below `directory`, is `directory`, or `directory` is empty.
pub fn partUnder(path: []const u8, directory: []const u8) ?[]const u8 {
    if (directory.len == 0) return null;
    if (!std.mem.startsWith(u8, path, directory)) return null;
    const rest = path[directory.len..];
    const below = if (std.mem.endsWith(u8, directory, "/"))
        rest
    else if (std.mem.startsWith(u8, rest, "/"))
        rest[1..]
    else
        return null;
    if (below.len == 0) return null;
    return below;
}

/// How a list names the file or directory at `path`: the part of it under
/// `working_directory`, or all of it. The slice is `path`'s.
pub fn shown(path: []const u8, working_directory: []const u8) []const u8 {
    return partUnder(path, working_directory) orelse path;
}

/// How a path is named where there is no project to name it from: `~` and the part under
/// `home_directory` for a path below it, `~` for the home directory itself, else the path. In
/// `allocator` when it is shortened, else `path` itself.
pub fn shownFromHome(allocator: std.mem.Allocator, path: []const u8, home_directory: []const u8) ![]const u8 {
    if (home_directory.len == 0) return path;
    if (std.mem.eql(u8, path, home_directory)) return "~";
    const below = partUnder(path, home_directory) orelse return path;
    return std.fmt.allocPrint(allocator, "~/{s}", .{below});
}

/// The part of `os_places` this module and its callers read: the working directory, the
/// home directory, which a `~` in a typed path stands for (`TypedPath`), and the folder of the
/// programs the editor runs (`os.PlacesView.vendor_directory`).
pub const Places = struct { working_directory: []const u8, home_directory: []const u8, vendor_directory: []const u8 };

/// Where things are, as `os_places` names them, for a system that declares
/// `os.places_table_name` read; each empty when the host has no OS system or does not know it.
/// The slices are the table's, good for the kernel's run.
pub fn places(pass: *const sequencer.Pass) Places {
    const unknown: Places = .{ .working_directory = "", .home_directory = "", .vendor_directory = "" };
    if (!pass.declares(places_table)) return unknown;
    return pass.readSingleton(places_table, Places) catch unknown;
}

/// The projects remembered, the latest first; none when the text editor keeps no list.
fn projectRows(pass: *const sequencer.Pass) ?Table.ReadQuery(text_editor.ProjectRow) {
    if (!pass.declares(projects_table)) return null;
    const rows = pass.rows(projects_table, text_editor.ProjectRow) catch return null;
    return rows.read();
}

/// Whether `projects` lists any.
fn remembersAny(projects: ?Table.ReadQuery(text_editor.ProjectRow)) bool {
    var rows = projects orelse return false;
    return rows.next() != null;
}

/// Opens the project prompt on the working directory, its path the text, to read the
/// directory to switch to.
fn requestProjectDirectory(tables: *Table.Registry) void {
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.open_project_listing));
    text_editor.request(tables.memory, tables, .{ .list_directory = .{ .path = "", .reply = reply } });
}

/// The label of the switch prompt's last entry, which reads a directory to switch to.
const choose_directory_label = "Choose a directory…";

/// Whether the project prompt's text is a path, whose directories are listed, rather than
/// words that narrow the projects remembered.
fn namesPath(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '/') != null;
}

/// Asks, in the palette, which remembered project `prompt` is for: those whose path holds
/// `query`, in either case, the latest first, each labelled by `shown`; the switch prompt's
/// last entry reads a directory instead (`choose_directory_label`). `how` says whether the
/// prompt opens or is open and has new text to narrow by. Tab completes the text to a
/// project's whole path: in the switch prompt with its `/`, so the prompt lists what is in it,
/// and on the last entry to the working directory's, or to the text while it is not known.
fn presentProjects(tables: *Table.Registry, projects: ?Table.ReadQuery(text_editor.ProjectRow), working_directory: []const u8, query: []const u8, prompt: ProjectPrompt, how: enum { open, relist }) void {
    const memory = tables.memory;
    const allocator = action_palette.completionAllocator(memory, .open) catch return;
    // While narrowing the arena is not reset: the prompt may still read the entries it shows.
    if (how == .open) action_palette.resetCompletionArena(memory, .open);
    const entries = allocator.alloc(action_palette.Completion, text_editor.max_projects + 1) catch return;
    // Listed for the text's directory, as a path's entries are: once a path is typed, an entry
    // listed before is not taken for the text. The projects are narrowed by text that names no
    // path (`namesPath`), so no `~` stands for the home directory here.
    const typed_path = TypedPath.of(allocator, query, "") catch return;
    const directory_hash = typed_path.directoryHash();
    var count: usize = 0;
    if (projects) |listed| {
        var rows = listed;
        while (rows.next()) |row| {
            if (count == text_editor.max_projects) break;
            const path = row.view.path;
            if (std.ascii.indexOfIgnoreCase(path, query) == null) continue;
            const data = pathEntryData(.project, directory_hash);
            const completes_to = switch (prompt) {
                .switch_project => directoryText(allocator, path) catch return,
                .forget_project => path,
            };
            entries[count] = .{ .key = path, .label = shown(path, working_directory), .data = data, .completes_to = completes_to };
            count += 1;
        }
    }
    if (prompt == .switch_project) {
        const data = pathEntryData(.choose_directory, directory_hash);
        // While the working directory is not known Tab leaves the text as it is.
        const known_directory = directoryText(allocator, working_directory) catch return;
        const completes_to = if (known_directory.len != 0) known_directory else query;
        entries[count] = .{ .label = choose_directory_label, .data = data, .completes_to = completes_to };
        count += 1;
    }
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = .{
        .owner = project_owner,
        .identity = prompt.identity(),
        .presentation = .prompt,
        .title = prompt.title(),
        .initial_query = query,
        .entries = entries[0..count],
    };
    action_palette.ownRequestText(allocator, completions) catch return;
    if (how == .relist) return action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
    const reply = sequencer.ReplyTo.of(system(), .from(prompt.events()));
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

/// Asks the OS system to make `directory`, an absolute path, the working directory, answered
/// to this system with the path as the user data.
fn enterProject(tables: *Table.Registry, directory: []const u8) void {
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.open_project_entered)).with(.{ .bytes = directory });
    os.request(tables.memory, tables, .{ .set_working_directory = .{ .path = directory, .reply = reply } });
}

/// What the project menu offers, by its items' ids: each the global action of that name.
const ProjectCommand = enum(u32) {
    find_project_file = 1,
    grep,
    project_find_directory,
    project_switch_buffer,
    compile,
    vcs_status,

    fn item(command: ProjectCommand, key: []const u8, label: []const u8) ui.transient.Item {
        return .{ .key = key, .label = label, .id = @intFromEnum(command) };
    }

    /// The action the command invokes, of `global`.
    fn action(command: ProjectCommand) plugin.action_api.ActionId {
        const name: Atom = switch (command) {
            .find_project_file => Atom.from("find_project_file"),
            .grep => Atom.from("grep"),
            .project_find_directory => Atom.from("project_find_directory"),
            .project_switch_buffer => Atom.from("project_switch_buffer"),
            .compile => Atom.from("compile"),
            .vcs_status => Atom.from("vcs_status"),
        };
        return .{ plugin.action_api.global_mode, name };
    }
};

/// What to do in a project just switched to, as project.el's `project-switch-commands` offers.
const project_menu: ui.transient.Menu = .{
    .title = "Project",
    .groups = &.{
        .{ .title = "Find", .items = &.{
            ProjectCommand.find_project_file.item("f", "Find file"),
            ProjectCommand.grep.item("g", "Grep"),
            ProjectCommand.project_find_directory.item("d", "Directory"),
            ProjectCommand.project_switch_buffer.item("b", "Buffer"),
        } },
        .{ .title = "Run", .items = &.{
            ProjectCommand.compile.item("c", "Compile"),
        } },
        .{ .title = "Version control", .items = &.{
            ProjectCommand.vcs_status.item("v", "vcs status"),
        } },
    },
};

/// What came of entering `directory`: once it is the working directory, it is remembered, the
/// person told it is the project and the project menu shown, which answers this system; else
/// told why it is not.
fn tellProjectEntered(memory: *memory_mod.Memory, tables: *Table.Registry, directory: []const u8, result: os.WorkingDirectoryMsg.Result) !void {
    const allocator = (try memory.frameScratchAllocator()).allocator;
    const sentence = switch (result) {
        .changed => try std.fmt.allocPrint(allocator, "Project: {s}", .{directory}),
        .not_found => try std.fmt.allocPrint(allocator, "No such directory: {s}", .{directory}),
        .not_a_directory => try std.fmt.allocPrint(allocator, "Not a directory: {s}", .{directory}),
        .access_denied => try std.fmt.allocPrint(allocator, "Cannot enter {s}: permission denied", .{directory}),
        .failed => try std.fmt.allocPrint(allocator, "Could not enter {s}", .{directory}),
    };
    if (result == .changed) text_editor.request(memory, tables, .{ .remember_project = directory });
    text_editor.message(memory, tables, sentence);
    if (result != .changed) return;
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.open_project_menu));
    transient.present(memory, tables, .{ .menu = &project_menu, .reply = reply });
}

/// Forgets the remembered project at `directory`, and tells the person so.
fn forgetProject(memory: *memory_mod.Memory, tables: *Table.Registry, directory: []const u8) !void {
    if (directory.len == 0) return;
    text_editor.request(memory, tables, .{ .forget_project = directory });
    const allocator = (try memory.frameScratchAllocator()).allocator;
    const sentence = try std.fmt.allocPrint(allocator, "Forgot the project {s}", .{directory});
    text_editor.message(memory, tables, sentence);
}

test "a file's extension says what opens it" {
    try std.testing.expectEqual(FileKind.figure, kindOf("/home/someone/game/figures/blue.mshf"));
    try std.testing.expectEqual(FileKind.sketch, kindOf("figures/cast.mshs"));
    // The Figure system names its files in exact case, and a figure has a name.
    try std.testing.expectEqual(FileKind.text, kindOf("figures/cast.MSHS"));
    try std.testing.expectEqual(FileKind.text, kindOf("figures/.mshf"));
    try std.testing.expectEqual(FileKind.table, kindOf("game/assets/tables/world.msht"));
    try std.testing.expectEqual(FileKind.log, kindOf("mesha.meshalog"));
    try std.testing.expectEqual(FileKind.text, kindOf("notes.txt"));
    try std.testing.expectEqual(FileKind.text, kindOf("Makefile"));
}

test "a name listed past the entries shown is not offered as typed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // `B000` to `B299` begin as `b` does, ignoring case, and come before `b` itself.
    const directory = "/d";
    var trailing: std.ArrayListUnmanaged(u8) = .empty;
    try trailing.appendSlice(allocator, directory);
    const file_kind: u8 = @intFromEnum(text_editor.ListedKind.file);
    for (0..300) |index| {
        const name = try std.fmt.allocPrint(allocator, "B{d:0>3}", .{index});
        try trailing.append(allocator, file_kind);
        try trailing.appendSlice(allocator, name);
        try trailing.append(allocator, 0);
    }
    try trailing.append(allocator, file_kind);
    try trailing.appendSlice(allocator, "b");
    try trailing.append(allocator, 0);
    const listed: text_editor.ListedMsg = .{ .directory_len = directory.len, .entry_count = 301, .result = .listed };
    const offered = try pathCompletions(allocator, "/d/b", "", listed, trailing.items, .file);
    try std.testing.expectEqual(@as(usize, max_path_completions), offered.len);
    for (offered) |entry| try std.testing.expect(!std.mem.eql(u8, entry.label, PathPurpose.file.typedLabel()));
}

test "a typed path starts again after a `//` or at a `~/`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const home = "/home/someone";
    const rooted = try TypedPath.of(allocator, "/a/b//c/d", home);
    try std.testing.expectEqualStrings("/c/", rooted.directory);
    try std.testing.expectEqualStrings("d", rooted.name);
    const homed = try TypedPath.of(allocator, "/a/~/x", home);
    try std.testing.expectEqualStrings("/home/someone/", homed.directory);
    try std.testing.expectEqualStrings("x", homed.name);
    try std.testing.expectEqualStrings("/home/someone/x", homed.whole);
    // A `~` that does not stand alone as a component is a name's.
    const tilde_ended = try TypedPath.of(allocator, "/a/b~/c", home);
    try std.testing.expectEqualStrings("/a/b~/", tilde_ended.directory);
    const tilde_begun = try TypedPath.of(allocator, "/a/~x/", home);
    try std.testing.expectEqualStrings("/a/~x/", tilde_begun.directory);
    // A `//` that begins the text is a network path's, and no home known leaves `~/` as typed.
    const network = try TypedPath.of(allocator, "//server/share/x", home);
    try std.testing.expectEqualStrings("//server/share/", network.directory);
    const homeless = try TypedPath.of(allocator, "/a/~/x", "");
    try std.testing.expectEqualStrings("/a/~/", homeless.directory);
}

test "entering a listed directory `~` under `/a/` lists `/a/~/`" {
    const path = try TypedPath.of(std.testing.allocator, "/a/", "/home/someone");
    var buffer: [64]u8 = undefined;
    const entered = enteredDirectory(&buffer, path, "~/").?;
    try std.testing.expectEqualStrings("/a/~/", entered.directory);
    try std.testing.expectEqualStrings("", entered.name);
}

/// A listing of `directory` holding `entries`, as the text editor answers it: the listing and
/// the bytes that trail it.
fn listingOf(allocator: std.mem.Allocator, directory: []const u8, entries: []const text_editor.ListedEntry) !struct { listed: text_editor.ListedMsg, trailing: []const u8 } {
    var trailing: std.ArrayListUnmanaged(u8) = .empty;
    try trailing.appendSlice(allocator, directory);
    for (entries) |entry| {
        try trailing.append(allocator, @intFromEnum(entry.kind));
        try trailing.appendSlice(allocator, entry.name);
        try trailing.append(allocator, 0);
    }
    const listed: text_editor.ListedMsg = .{ .directory_len = @intCast(directory.len), .entry_count = @intCast(entries.len), .result = .listed };
    return .{ .listed = listed, .trailing = trailing.items };
}

test "a directory's path is offered as typed first once it ends in `/` or names a listed directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entries = [_]text_editor.ListedEntry{ .{ .kind = .file, .name = "notes.txt" }, .{ .kind = .directory, .name = "sub" } };
    const listing = try listingOf(allocator, "/real/d", &entries);
    const typed_label = PathPurpose.directory.typedLabel();

    const at_slash = try pathCompletions(allocator, "/d/", "", listing.listed, listing.trailing, .directory);
    try std.testing.expectEqual(@as(usize, 2), at_slash.len);
    try std.testing.expectEqualStrings(typed_label, at_slash[0].label);
    try std.testing.expectEqualStrings("/real/d", at_slash[0].detail);
    try std.testing.expectEqualStrings("sub/", at_slash[1].label);

    const named = try pathCompletions(allocator, "/d/sub", "", listing.listed, listing.trailing, .directory);
    try std.testing.expectEqual(@as(usize, 2), named.len);
    try std.testing.expectEqualStrings(typed_label, named[0].label);
    try std.testing.expectEqualStrings("sub/", named[1].label);

    // A name begun: the directory it begins first, the text as typed last, and no file.
    const begun = try pathCompletions(allocator, "/d/su", "", listing.listed, listing.trailing, .directory);
    try std.testing.expectEqual(@as(usize, 2), begun.len);
    try std.testing.expectEqualStrings("sub/", begun[0].label);
    try std.testing.expectEqualStrings(typed_label, begun[1].label);
}

test "a path is shown from the working directory when it lies under it" {
    try std.testing.expectEqualStrings("src/open.zig", shown("/home/someone/game/src/open.zig", "/home/someone/game"));
    // A sibling whose name begins as the directory's does is not under it.
    try std.testing.expectEqualStrings("/home/someone/gamer/notes", shown("/home/someone/gamer/notes", "/home/someone/game"));
    // The directory itself, and any path with no working directory known, are shown whole.
    try std.testing.expectEqualStrings("/home/someone/game", shown("/home/someone/game", "/home/someone/game"));
    try std.testing.expectEqualStrings("/home/someone/game", shown("/home/someone/game", ""));
    // A root ends in the `/` a path below it goes on from.
    try std.testing.expectEqualStrings("home/someone", shown("/home/someone", "/"));
    try std.testing.expectEqualStrings("work/game", shown("C:/work/game", "C:/"));
}
