//! What the host and a plugin share that belongs to no single system: the `plugins` table and the
//! requests that load, create and unload plugins (`plugins`), the panels' requests and focus events
//! (`panels`), the actions a plugin's systems offer (`Actions`, `ActionSink`) and the keymaps they
//! declare (`Keymaps`), the host's debug requests (`debug`), the editor plugin's own command table
//! (`app_commands`), and the layout check between the two images (`abi_fingerprint`). The other
//! systems' contracts are re-exported here as `<name>_api`.
//!
//! A plugin is a shared library the host loads and reloads. It exports, in the C calling
//! convention, `plugin_abi` (an `AbiFn`), `plugin_tag`, `plugin_init`, `plugin_update` and
//! `plugin_render_panel`, which draws a panel's whole frame, its header if it wears one
//! included (`ui.panel_header` has the usual one), and may export `plugin_process_cmd` (a
//! `ProcessCmdFn`), `plugin_render_action_palette`, `plugin_begin_frame` and
//! `plugin_deinit`. The host hands them its memory, atoms and tables, and a `Viewport` and a roop
//! context to draw in; a plugin keeps its state in tables and labeled host memory, so a reload
//! keeps it.
//!
//! A request here is a row appended to a `commands.<name>` table with the namespace's `request`.
//! The host applies it after the frame's run, so its effect and its answer are seen in a later
//! frame.
const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const journal = @import("../core/journal.zig");
const boundary = @import("../core/boundary.zig");
const roop = @import("roop.zig");
const sequencer = @import("../core/sequencer.zig");
const Subscribed = sequencer.Subscribed;
const os = @import("os.zig");
const input = @import("input.zig");
const actions_api = @import("actions.zig");
/// The actions contract (`actions.zig`): actions, chords and the chord state.
pub const action_api = actions_api;
/// The profiler's contract (`profiler.zig`).
pub const profiler_api = @import("profiler.zig");
/// The text editor system's contract (`text_editor.zig`).
pub const text_editor_api = @import("text_editor.zig");
/// The process system's contract (`process.zig`).
pub const process_api = @import("process.zig");
/// The language server system's contract (`lsp.zig`).
pub const lsp_api = @import("lsp.zig");
/// The action palette's and the status bar's contract (`editor_api.zig`).
pub const editor_api = @import("editor_api.zig");
/// The Figure system's contract (`figure.zig`).
pub const figure_api = @import("figure.zig");
/// The editor plugin's own command table, `commands.app`: what its systems ask that only its
/// command hook can do, as delivering the action palette's answer, or another of its systems'
/// answers (`Payload.answer`), to the inbox that asked. The host applies the rows through the
/// plugin's `plugin_process_cmd`; a row appended while the loaded image exports no such hook is
/// dropped with a warning.
pub const app_commands = struct {
    /// A request. Tag ordinals are kept, as a held row outlives a reload of the plugin.
    pub const Payload = union(enum) {
        /// One of the palette's commands.
        action_palette: editor_api.CmdPayload,
        /// An answer one of the plugin's journaled systems gives another's request, which no
        /// journaled run may deliver itself.
        answer: Answer,
    };

    /// An answer for the hook to deliver where `reply` names, under its tag with its user data,
    /// `payload` its message's payload. The hook keeps the row, to deliver again, while the
    /// inbox cannot take it.
    pub const Answer = struct {
        /// Where the answer goes.
        reply: sequencer.ReplyTo,
        /// The payload's bytes, of a type the receiver knows by the reply's tag: copied into the
        /// row as it is appended.
        payload: []const u8,
    };
    /// The plugin's requests to itself, applied through its command hook after the frame's
    /// run, when it can deliver what they carry.
    pub const commands_table_name = "commands.app";
    /// The typed handle on `commands.app`.
    pub const Requests = sequencer.Commands(Payload);

    /// Appends `wanted` for the plugin's hook. A journaled system that asks declares the table
    /// written, so a fault takes its request back.
    pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: Payload) void {
        Requests.of(memory, tables, commands_table_name).push(wanted);
    }
};

/// The plugins the host loads, a row each in `plugins`: the editor's and the user's from the
/// start, those `--plugin` names, and any row added since. The host loads a row's library, reloads
/// it when it is rebuilt, tries one that was missing or refused again when its file changes, and
/// lets a plugin go when its row is removed, when resources releases the tables of its scope and
/// the resources read from its directory (`resources.CmdPayload.release_plugin`). A row whose
/// directory holds a `build.zig` has a build of its own while it is there (the watch system's),
/// and loads only once that build has succeeded in this run: the host never loads a library an
/// earlier run left there.
///
/// Plugins run latest loaded first, so one that builds on another subscribes before it.
///
/// Systems ask the host to load a plugin directory, write a new stage plugin and load it, or
/// unload a plugin with rows of `commands.plugins`, which the host applies after the frame's run,
/// when no plugin's code is running, and answers with an `Answer`. Nothing is kept between
/// runs: a plugin loaded by request is loaded for this run, and a plugin that wants another loaded
/// at every start asks for it from its own code.
pub const plugins = struct {
    /// `plugins`, a row per plugin; see `Row`.
    pub const table_name = "plugins";

    /// The longest plugin name: a table scope and an atom.
    pub const max_name_bytes = 63;

    /// Whether `name`, a plugin directory's name, may name a plugin: `[a-z][a-z0-9_]*`, at most
    /// `max_name_bytes`, so it is a table scope, a Zig identifier for its package and an atom.
    pub fn validName(name: []const u8) bool {
        if (name.len == 0 or name.len > max_name_bytes) return false;
        if (!std.ascii.isLower(name[0])) return false;
        for (name[1..]) |character| {
            const allowed = std.ascii.isLower(character) or std.ascii.isDigit(character) or character == '_';
            if (!allowed) return false;
        }
        return true;
    }

    /// Loads the plugin in `directory`: absolute, or relative to the working directory when the
    /// request is applied, which resolves it to the absolute path its row keeps. Its name is the
    /// directory's. `reply` is answered with an `Answer`.
    pub const Load = struct { directory: []const u8, reply: sequencer.ReplyTo = .{} };
    /// Unloads the plugin `name`: its row goes, and the host lets it go. `reply` is answered with
    /// an `Answer`.
    pub const Unload = struct { name: Atom, reply: sequencer.ReplyTo = .{} };
    /// Writes a new stage plugin `name` in `<parent>/<name>` from the editor's stage templates,
    /// with the editor's font in its `assets/fonts/`, then loads it as `load` does. Refused,
    /// writing nothing, while builds are off, without an SDK, for a name `validName` refuses, a
    /// name a loaded plugin has, or a directory there that holds anything. `reply` is answered
    /// with an `Answer`.
    pub const Create = struct { parent: []const u8, name: []const u8, reply: sequencer.ReplyTo = .{} };
    /// A request to the host about plugins, a row of `commands.plugins`.
    pub const CmdPayload = union(enum) { load: Load, unload: Unload, create: Create };
    /// `commands.plugins`, the requests the host applies after the frame's run.
    pub const commands_table_name = "commands.plugins";
    /// The typed handle on `commands.plugins`.
    pub const Requests = sequencer.Commands(CmdPayload);

    /// Asks the host for `wanted`, a row of `commands.plugins` applied once the frame's run is
    /// flushed. A journaled system that asks declares the table written, so a fault takes its
    /// request back.
    pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: CmdPayload) void {
        Requests.of(memory, tables, commands_table_name).push(wanted);
    }

    /// What became of a request. An enum, not an error, since it crosses images.
    pub const Result = enum(u8) {
        /// A row was added; its library loads once it is there and, where the plugin has a
        /// build, built in this run.
        loaded,
        /// The directory is already loaded under its name.
        already_loaded,
        /// Nothing is at the directory's path.
        not_found,
        /// The path names something other than a directory.
        not_a_directory,
        /// The directory's name is not a plugin name (`validName`).
        invalid_name,
        /// Another directory's plugin has the name.
        name_taken,
        /// The row went, and the host lets the plugin go.
        unloaded,
        /// No plugin has the name.
        not_loaded,
        /// The editor and the user's plugin stay loaded.
        fixed,
        /// A table document of the plugin's scope has edits not yet saved, which unloading
        /// would lose.
        unsaved_tables,
        /// A create found something in the plugin's directory, which it leaves as it is.
        exists,
        /// A create found no SDK for the plugin to build on.
        no_sdk,
        /// A create was asked while builds are off, so the plugin would never be built.
        builds_off,
        /// A create could not write the plugin's files; what it wrote stays.
        write_failed,
        /// The plugin would be built, and `zig` 0.16.0 is not on `PATH`: nothing was added or
        /// written. Only once the host runs; at start-up it stops the host instead.
        no_zig,
    };

    /// The reply's payload: the result, and the plugin's name; none (0) for a load or create
    /// refused before it had a valid name.
    pub const Answer = struct { result: Result, name: Atom };

    /// Where the host is with a row's library.
    pub const State = enum(u8) {
        /// Nothing is loaded yet: the row's build has not succeeded in this run, or no library
        /// is at its path.
        waiting,
        /// The library is loaded and the plugin runs.
        loaded,
        /// The library there would not load, or its init refused.
        refused,
    };

    /// Why the host has the row.
    pub const Origin = enum(u8) {
        /// The editor's, there from the start.
        editor,
        /// The person's own plugin, `user/` beside the editor's directory, there from the start.
        user,
        /// Named when the host was launched (`--plugin`).
        launch,
        /// Loaded by request, for this run.
        loaded,
    };

    /// A view of a row of `plugins`. The texts are the table's; copy what must last.
    pub const Row = struct {
        /// The plugin's tag, as its `plugin_tag` answers.
        name: *Atom,
        /// The plugin's directory, absolute and `/`-separated; empty for a row with none.
        directory: []const u8,
        /// The library's path, absolute: under `directory`, where its build installs it.
        library: []const u8,
        /// A `State`, the host's.
        state: *u8,
        /// An `Origin`.
        origin: *u8,
    };

    /// What a row is added with.
    pub const NewRow = struct {
        /// The plugin's name: its directory's, and its tag.
        name: Atom,
        /// The plugin's directory, absolute and `/`-separated; empty for a row with none.
        directory: []const u8,
        /// The library's path: absolute, as `Row.library` is.
        library: []const u8,
        /// Why the host has the row.
        origin: Origin,
    };

    /// Creates the `plugins` table, or checks the one there, and returns it. `backing` allocates
    /// the schema for the call. The host calls it.
    pub fn ensureTable(backing: std.mem.Allocator, atoms: *Atom.Registry, tables: *Table.Registry) !*Table {
        var schema: Table.Schema = undefined;
        try schema.init(backing, atoms, 5);
        defer schema.deinit();
        schema.addField("name", Atom, .atom);
        schema.addField("directory", Table.String, .text_field);
        schema.addField("library", Table.String, .text_field);
        schema.addField("state", u8, .int);
        schema.addField("origin", u8, .int);
        const initial_rows = 4;
        const ensured = try tables.ensure(&schema, initial_rows, atoms.intern(table_name), .durable);
        return ensured.table;
    }

    /// The row of the plugin `name`, if it has one.
    pub fn find(table: *Table, name: Atom) ?Table.RowHandle {
        var rows = table.query(Row);
        while (rows.next()) |found| {
            if (found.view.name.* == name) return found.handle;
        }
        return null;
    }

    /// The row of the plugin whose table scope holds the table document `id`: of the plugins
    /// with a row, the one with the longest name `N` such that `id` begins `N_`; none when no
    /// plugin's name does. The names are the rows' atoms, read as text through `atoms`.
    pub fn scopeOwner(table: *Table, atoms: *const Atom.Registry, id: []const u8) ?Table.RowHandle {
        var owner: ?Table.RowHandle = null;
        var owner_length: usize = 0;
        var rows = table.readQuery(Row);
        while (rows.next()) |found| {
            const name = atoms.lookup(found.view.name.*) orelse continue;
            if (name.len <= owner_length) continue;
            if (id.len <= name.len or id[name.len] != '_') continue;
            if (!std.mem.startsWith(u8, id, name)) continue;
            owner = found.handle;
            owner_length = name.len;
        }
        return owner;
    }

    /// The fields of a row that say whether and where the plugin keeps table documents.
    pub const TablesView = struct { name: *Atom, directory: []const u8, origin: *u8 };

    /// Whether the plugin `row` keeps its table documents under `<directory>/assets/tables`:
    /// a row with a directory, but not the user's, which keeps none: what a person sets, their
    /// plugin's code sets.
    pub fn holdsTables(row: Table.ReadView(TablesView)) bool {
        if (row.origin.* == @intFromEnum(Origin.user)) return false;
        return row.directory.len != 0;
    }

    /// Adds a row for the plugin `row` names, waiting for its library.
    pub fn add(table: *Table, row: NewRow) !Table.RowHandle {
        const waiting: u8 = @intFromEnum(State.waiting);
        const origin: u8 = @intFromEnum(row.origin);
        return table.tryInsert(.{
            .name = row.name,
            .directory = row.directory,
            .library = row.library,
            .state = waiting,
            .origin = origin,
        });
    }
};

/// The type of a plugin's optional `plugin_process_cmd` export. It applies one row of
/// `app_commands`; `.retry` keeps the row, as the function rewrote it, for the next application.
pub const ProcessCmdFn = *const fn (
    memory: *memory_mod.Memory,
    atoms: *Atom.Registry,
    tables: *Table.Registry,
    payload: *app_commands.Payload,
) callconv(.c) sequencer.Applied;

/// The host's debug requests, rows of `commands.debug`.
pub const debug = struct {
    /// A debug request.
    pub const CmdPayload = union(enum) {
        /// Takes a screenshot of the window and writes it to the file `path`. The path is copied
        /// into the request's row.
        capture_screenshot: struct { path: []const u8 },
    };
    /// `commands.debug`, the requests the host's debug hooks apply.
    pub const commands_table_name = "commands.debug";
    /// The typed handle on `commands.debug`.
    pub const Requests = sequencer.Commands(CmdPayload);

    /// Asks the host's debug hooks for `wanted`, a row of `commands.debug` applied after the
    /// frame's run is flushed.
    pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: CmdPayload) void {
        Requests.of(memory, tables, commands_table_name).push(wanted);
    }
};

/// The window's panels: a tree of splits whose leaves are panels, each opened to a side of the
/// panel that asked for it. A panel's whole frame is its plugin's to draw. One panel at a
/// time is focused, and its owner is the system whose local input subscriptions fire.
pub const panels = struct {
    /// The side of the panel `beside`, or of the window, that a panel opens or docks to.
    pub const Side = enum(u8) { left, right, top, bottom };
    /// The system a panel belongs to, whose `.local` input subscriptions fire while it is focused.
    pub const Owner = input.Source;

    /// What the panels system tells of the panels, a row each (`Event`): each time the focus
    /// moves, the panel that lost it, then the one that took it; and each time a panel's
    /// laid-out size changes, its new size. Any system reads them with a cursor of its own
    /// (`sequencer.Events`) and passes by the kinds it does not want; which panel has the focus
    /// now is `panels_state`'s, and where a panel is, `panels.panelFor`'s.
    pub const events_table_name = "events.panels";
    /// One thing the panels system tells, a row of `events.panels`.
    pub const Event = union(enum) {
        /// The panel that took the focus.
        focused: Atom,
        /// The panel that lost the focus.
        unfocused: Atom,
        /// A panel's laid-out size changed, however it changed (the window resized, a divider
        /// dragged, a panel maximized or restored, a neighbour opened or closed, the panel
        /// moved), or the panel opened and is told its first size. A system that keeps
        /// something that depends on its panel's size settles it again when it hears, and asks
        /// for its panel to be drawn again when what it settled changed.
        resized: Resized,
    };
    /// A panel's new size, as `Event.resized` tells it: its whole frame's, header and all, since
    /// a panel's header is its plugin's to draw and the panels system knows none (the editor's
    /// `panel_frame.contentSize` gives what its header leaves). Window pixels.
    ///
    /// When a system hears it, relative to the draw: a size changed by the window, a divider
    /// dragged or a request applied before the systems run is heard in that run, before the
    /// panels are drawn at it. A size changed by what a system's run asks for (a panel declared,
    /// hidden, shown, moved or focused out of a maximize) is laid out after that run, so the
    /// panels are drawn once at the new size before any system hears; it is heard in the next
    /// run, before the next draw: one update late.
    pub const Resized = struct {
        /// The panel whose size changed.
        panel: Atom,
        /// The frame's width; zero while a maximized panel hides it.
        frame_width: f32,
        /// The frame's height; zero while a maximized panel hides it.
        frame_height: f32,
    };
    /// The typed handle on `events.panels`.
    pub const Events = sequencer.Events(Event);

    /// A panel as its owner declares it open this frame (`declare`). What it is (`title`,
    /// `root`, `owner`) is the panel's while it is open, and follows
    /// its declaration every frame. Where it goes (`beside`, `side`, `share`) and whether it takes the focus
    /// (`focus`) are read only as it opens: `id` goes to `side` of the panel `beside`, taking
    /// `share` of the space they then split, or along that edge of the window with `beside`
    /// none. An open panel stays where it is, wherever a person has since put it.
    pub const Open = struct {
        /// The panel's id, which whoever opens it chooses; never none.
        id: Atom,
        /// The root of the systems the panel shows, a `sequencer.System.root`: `game` for a
        /// game's panel, an editor module's root for its panels. The editor's sequencer asks for
        /// the panels of a root to draw again when a run of one of its systems changed a table.
        /// Never none.
        root: Atom,
        /// The panel's title, which the panels system keeps for whatever draws the panel's
        /// header (`panels.Panel.title`), as much of it as `panels.Title` holds; a panel whose
        /// header names it another way, as a text panel's does by its file, leaves it empty.
        title: []const u8 = "",
        /// The system the panel belongs to, whose local input subscriptions fire while it is
        /// focused: `.game` for a game's panel, so its keys do not fire in the editor's.
        owner: Owner = .plugin,
        /// The open panel to open beside; none (0) for the window's edge, beside the whole
        /// arrangement.
        beside: Atom = @enumFromInt(0),
        /// Which side of `beside`, or of the window, the panel takes.
        side: Side = .right,
        /// The panel's share of the space it splits, the gap excluded: above 0 and below 1.
        share: f32 = 0.5,
        /// Whether the panel takes the focus as it opens.
        focus: FocusOnOpen = .take,
    };
    /// Whether an opened panel takes the focus (`take`) or leaves it where it is (`keep`). The
    /// only panel open is focused either way.
    pub const FocusOnOpen = enum(u8) { take, keep };

    /// A request to the panels system, a row of `commands.panels`: a change to where the open
    /// panels are or which has the focus. Which panels are open is not asked for but declared
    /// (`declare`). A request that cannot be applied (a panel that is not open, a height out
    /// of range) changes nothing and is logged as a warning.
    pub const CmdPayload = union(enum) {
        /// Closes every panel, so the window is laid out afresh: the panels still declared
        /// open again with the frame, in the order their systems run, each by its
        /// declaration's placement. A workspace's owner asks for it as it arranges one.
        close_all,
        /// Docks an open panel to `side` of `beside`, or of the window with `beside` none.
        move: struct { id: Atom, beside: Atom = @enumFromInt(0), side: Side },
        /// Focuses the panel `id`; nothing happens when it is not open.
        focus: struct { id: Atom },
        /// Gives the focus back from the panel `from` to the panel that had it before: the
        /// newest of the panels system's focus history (`panels.focusHistory`) that is still
        /// open and not hidden. Nothing happens unless `from` has the focus as the request is
        /// applied (the person may have moved it since the request was made), or when the
        /// history has no such panel. Nothing closes: for a panel that stays open and is done
        /// with the focus, as a text window is when the buffer another system showed in it ends.
        focus_previous: struct { from: Atom },
        /// Focuses the next panel in reading order, wrapping; nothing happens while a panel is
        /// maximized.
        focus_next,
        /// Fills the window with the focused panel, or restores the arrangement.
        toggle_maximize,
        /// Ends `disable_focus_clicks`: a press focuses the panel under it, and the focused
        /// panel's owner takes local input.
        enable_focus_clicks,
        /// Suspends the focus, as for a modal prompt: a press focuses no panel and no panel
        /// counts as focused, so local input subscriptions fire whichever system they are of.
        disable_focus_clicks,
        /// Keeps `height` of the window's bottom free of panels, which share what is above it;
        /// zero gives it back.
        reserve_bottom: struct { height: f32 },
        /// Hides the panel `id`: it closes, and stays closed while its system declares it,
        /// until `show`. For closing a panel that is another system's to declare, as an
        /// arrangement does with the panels it has no place for, and a close button with a
        /// panel whose owner keeps no state of its own for it. The owner reads whether its
        /// panel is open (`panels.isOpen`) and need do nothing else.
        hide: struct { id: Atom },
        /// Ends `hide`: the panel opens again with the frame, by its declaration's placement,
        /// if its system still declares it.
        show: struct { id: Atom },
    };
    /// Requests to the panels system, a row each, applied in order and cleared.
    pub const commands_table_name = "commands.panels";
    /// The typed handle on `commands.panels`.
    pub const Requests = sequencer.Commands(CmdPayload);

    /// Asks the panels system for `wanted`. A journaled system that asks declares the table
    /// written, so a fault takes its request back.
    pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: CmdPayload) void {
        Requests.of(memory, tables, commands_table_name).push(wanted);
    }

    /// `subscribed.panels`: the panels each system says are open, a row each, appended in its
    /// run. A table of subscriptions, so the sequencer's rules are the panels': a system's rows
    /// stand until it runs again, which replaces them; a system that idles or faults keeps
    /// them; one switched off loses them. The panels system opens a panel a row names that is
    /// not open, keeps what it is in step with its row, and closes one its system no longer
    /// declares.
    pub const declared_table_name = "subscribed.panels";
    /// The typed handle on `subscribed.panels`.
    pub const Declared = Subscribed(Open);

    /// Says the panel `panel` is open this frame: called from a kernel every frame the system
    /// runs, for each panel it shows. A journaled system declares `subscribed.panels` written.
    /// `panel.title` is copied before this returns. The first row for an id is the one
    /// followed; a second is ignored and logged.
    pub fn declare(memory: *memory_mod.Memory, tables: *Table.Registry, panel: Open) void {
        Declared.of(memory, tables, declared_table_name).push(panel);
    }
};

/// The actions the plugin's systems offer this frame, `subscribed.actions`: appended in their
/// runs, cleared before each.
pub const Actions = Subscribed(actions_api.Action);

/// The keymaps the plugin's systems declare this frame, `subscribed.keymaps`: appended in their
/// runs, cleared before each.
pub const Keymaps = Subscribed(actions_api.Keymap);

/// Where a system declares the actions it offers, each naming the inbox of the system that
/// takes it and the tag and user data its message arrives with: the sink appends them.
pub const ActionSink = struct {
    /// What `declare_fn` is called with: the sink's owner.
    context: *anyopaque,
    /// Appends one action for `context`.
    declare_fn: *const fn (context: *anyopaque, action: actions_api.Action) void,

    /// Offers `action` this frame through the sink.
    pub fn declare(sink: ActionSink, action: actions_api.Action) void {
        sink.declare_fn(sink.context, action);
    }
};

/// A sink that appends each action as declared, whatever inbox it names: for a caller outside
/// any run, as a test of what a module declares.
pub const ActionRows = struct {
    /// The table the sink appends to.
    actions: Actions,

    /// A sink that appends to `rows`, which must outlive it.
    pub fn sink(rows: *ActionRows) ActionSink {
        return .{ .context = rows, .declare_fn = declare };
    }

    fn declare(context: *anyopaque, action: actions_api.Action) void {
        const rows: *ActionRows = @ptrCast(@alignCast(context));
        rows.actions.push(action);
    }
};

/// Where a system declares the keymaps it adds to, each a row of `subscribed.keymaps`: the sink
/// appends them.
pub const KeymapSink = struct {
    /// What `declare_fn` is called with: the sink's owner.
    context: *anyopaque,
    /// Appends one keymap for `context`.
    declare_fn: *const fn (context: *anyopaque, keymap: actions_api.Keymap) void,

    /// Declares `keymap` this frame through the sink; its bindings are copied before this returns.
    pub fn declare(sink: KeymapSink, keymap: actions_api.Keymap) void {
        sink.declare_fn(sink.context, keymap);
    }
};

/// A sink that appends each keymap as declared: for a kernel whose system declares
/// `subscribed.keymaps` written, as a person's plugin declares its keys, or for a caller outside
/// any run, as a test of what a module declares. A keymap that cannot be appended is dropped and
/// logged.
pub const KeymapRows = struct {
    /// The table the sink appends to.
    keymaps: Keymaps,

    /// A sink that appends to `rows`, which must outlive it.
    pub fn sink(rows: *KeymapRows) KeymapSink {
        return .{ .context = rows, .declare_fn = declare };
    }

    fn declare(context: *anyopaque, keymap: actions_api.Keymap) void {
        const rows: *KeymapRows = @ptrCast(@alignCast(context));
        rows.keymaps.push(keymap);
    }
};

/// The roots of what the two images share (`core/boundary.zig`), whose layout `abi_fingerprint`
/// hashes: what the host hands a plugin's entry points, and some values one image writes into a
/// table cell or a message payload for the other to read, which nothing the entry points take
/// reaches by type. Of those, the roots are the figure host's: the authoring request and its
/// reply (`Command`, `Result`), the catalog's rows (`DefinitionInfo`), a watch and the answer it
/// is published (`Watch`, `Published`, and the host memory the answer points at), and a query
/// and the head of its answer (`QueryCommand`, `QueryAnswer`); and the OS system's answer to a
/// move of the working directory (`os.WorkingDirectoryMsg`). Other systems' payloads that are
/// plain data (a process's `SpawnedMsg`, a time `WakeMsg`, an input event, and others) cross
/// between the images too and are not roots, nor are payloads that pass only between one
/// image's own systems. The decorations a plugin hands the host (`ui.Element`) are not roots
/// either: the loader's tests check them.
pub const boundary_roots = [_]boundary.Root{
    .{ .name = "Memory", .T = memory_mod.Memory },
    .{ .name = "Atoms", .T = Atom.Registry },
    .{ .name = "Tables", .T = Table.Registry },
    .{ .name = "Layer", .T = journal.Layer },
    .{ .name = "Context", .T = roop.Context },
    .{ .name = "AppCommand", .T = app_commands.Payload },
    .{ .name = "figure.Command", .T = figure_api.Command },
    .{ .name = "figure.Result", .T = figure_api.Result },
    .{ .name = "figure.DefinitionInfo", .T = figure_api.DefinitionInfo },
    .{ .name = "figure.Watch", .T = figure_api.Watch },
    .{ .name = "figure.Published", .T = figure_api.Published },
    .{ .name = "figure.QueryCommand", .T = figure_api.QueryCommand },
    .{ .name = "figure.QueryAnswer", .T = figure_api.QueryAnswer },
    .{ .name = "os.WorkingDirectoryMsg", .T = os.WorkingDirectoryMsg },
};

/// The layout of what the host and a plugin share (`boundary_roots`): a plugin exports it as
/// `plugin_abi`, and the loader refuses one whose layout differs from its own, so a plugin built
/// against another revision of these types is refused rather than reading the host's cells and
/// payloads with the wrong layout.
pub const abi_fingerprint: u64 = boundary.fingerprint(&boundary_roots);
/// The type of a plugin's `plugin_abi` export, which returns the `abi_fingerprint` it was built
/// with.
pub const AbiFn = *const fn () callconv(.c) u64;

/// Crossings that stay: what a plugin is handed reaches them, but only the image that stored
/// the pointer calls it.
pub const boundary_kept = [_]boundary.Kept{
    .{ .prefix = "Memory.global_source", .reason = "called only by the C functions of `Memory.global`, which the host's `Memory.init` makes" },
    .{ .prefix = "Tables.slots.*.*.schema_ref.*.schema.allocator", .reason = "null in a registry's copy, which its registry clones and frees through `Memory.global`" },
    .{ .prefix = "Layer.binding.vtable.", .reason = "a layer's binding is set by the image that attaches it, and a parent's binding is only restored, never called" },
};

/// Crossings to be removed: a plugin built by another backend than the host's calls these.
pub const boundary_pending = [_][]const u8{};

test "what the host hands a plugin stores no Zig calls but those kept" {
    const found = boundary.crossings(&boundary_roots);
    try boundary.expectAllowed(found, &boundary_kept, &boundary_pending);
}

/// Where a plugin draws, in window pixels: a panel's whole frame for `plugin_render_panel`, the
/// whole window for `plugin_render_action_palette`. A panel's roop context has its origin at the
/// viewport's top left corner and is clipped to it.
pub const Viewport = extern struct {
    /// The left edge's distance from the window's left edge.
    x: f32,
    /// The top edge's distance from the window's top edge.
    y: f32,
    /// The width.
    width: f32,
    /// The height.
    height: f32,

    /// Whether the point (x, y) is inside, counting the left and top edges.
    pub fn contains(viewport: Viewport, x: f32, y: f32) bool {
        return x >= viewport.x and x < viewport.x + viewport.width and y >= viewport.y and y < viewport.y + viewport.height;
    }
};

test "a debug request's slices are its row's once appended" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 4);
    defer tables.deinit();
    try debug.Requests.ensure(try memory.tableScratchAllocator(), &atoms, &tables, debug.commands_table_name);

    var path_storage: [32]u8 = undefined;
    const expected_path = "captures/frame.png";
    @memcpy(path_storage[0..expected_path.len], expected_path);
    debug.request(&memory, &tables, .{ .capture_screenshot = .{ .path = path_storage[0..expected_path.len] } });
    @memset(&path_storage, 'x');

    const Kept = struct {
        path: [32]u8 = undefined,
        len: usize = 0,
        fn keep(kept: *@This(), row: *debug.CmdPayload) sequencer.Applied {
            const path = row.capture_screenshot.path;
            kept.len = path.len;
            @memcpy(kept.path[0..path.len], path);
            return .done;
        }
    };
    var kept: Kept = .{};
    debug.Requests.of(&memory, &tables, debug.commands_table_name).drain(&kept, Kept.keep);
    try std.testing.expectEqualStrings("captures/frame.png", kept.path[0..kept.len]);
}

test "the actions table keeps the actions offered, and their text, until reset" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 32);
    defer tables.deinit();
    const scratch = try memory.tableScratchAllocator();
    try Actions.ensure(scratch, &atoms, &tables, actions_api.subscribed_table_name);
    const actions = Actions.of(&memory, &tables, actions_api.subscribed_table_name);

    {
        var doc: [4]u8 = "save".*;
        actions.push(.{ .id = .{ actions_api.global_mode, Atom.from("save") }, .doc = &doc, .tag = Atom.from("save") });
        @memset(&doc, 'x');
    }
    try std.testing.expectEqual(@as(u32, 1), actions.count());
    var listed = actions.iterate();
    // The doc's text is the table's own copy.
    try std.testing.expectEqualStrings("save", listed.next().?.doc);

    actions.reset();
    try std.testing.expectEqual(@as(u32, 0), actions.count());
}
