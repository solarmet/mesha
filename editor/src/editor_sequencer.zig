//! The editor's sequencer (`core/sequencer.zig`) and what its systems need from the editor:
//! their panels drawn again when their kernels changed a table, the targets of what they
//! draw, and the actions and input subscriptions their kernels declare.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const log = mesha.log;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const sequencer = mesha.sequencer;
const journal = mesha.journal;
const input = mesha.input;

const System = sequencer.System;
const Sequencer = sequencer.Sequencer;
const table_authoring = @import("table_authoring.zig");
const editor = @import("editor.zig");
const text_editor = @import("text_editor.zig");
const action_palette = @import("action_palette.zig");
const stage = @import("stage.zig");
const fixed_panels = @import("fixed_panels.zig");
const status_bar = @import("status_bar.zig");
const profiler = @import("profiler/profiler.zig");
const inspector = @import("inspector.zig");
const windows = @import("windows.zig");
const text_panel = @import("text_panel.zig");
const open = @import("open.zig");
const runner = @import("vcs/runner.zig");
const git_status = @import("vcs/git_status.zig");
const p4_status = @import("vcs/p4_status.zig");
const text_tools = @import("text_tools.zig");
const plugins = @import("plugins.zig");
const plugin_list = @import("plugin_list.zig");
const transient = @import("transient.zig");
const workspace = @import("figure/workspace.zig");
const Log = log.scope("editor_sequencer");

/// The editor's sequencer: its systems, and the figure editor's systems as a child sequencer,
/// whose fault discards only its own run. A system runs after those that append requests for
/// it in the same frame: the status bar after workspaces, the figure editor after
/// workspaces, the transient menus after every system that presents one, and the action
/// palette after them all. The version-control runner comes before the systems that own its
/// jobs, so all an owner asked of it in a frame is taken before the owner runs again, and the
/// owner then finds its jobs as the runner left them. The palette's keys come first, as they
/// were pressed at the prompt the last frame left open. Before them all, table authoring
/// applies the changes to tables' shapes asked for last frame, while no system this frame has
/// a row of those tables in the run's layer; then
/// the editor takes its own messages. Last, the editor declares its actions and listens for
/// the frame's final state. The fixed panels shown are declared after every system that may
/// show or close one, the figure editor's among them. The figure editor's step runs `figure_authoring`'s steps.
pub fn frameRoot(figure_authoring: *const FigureAuthoring) sequencer.Built(26) {
    return .{ .name = "editor_frame", .steps = .{
        .{ .system = table_authoring.system() },
        .{ .system = editor.messagesSystem() },
        .{ .system = editor.focusSystem() },
        .{ .system = text_editor.clipboardSystem() },
        .{ .system = action_palette.inputSystem() },
        .{ .system = stage.system() },
        .{ .system = fixed_panels.system() },
        .{ .system = status_bar.system() },
        .{ .system = profiler.system() },
        .{ .system = inspector.system() },
        .{ .system = windows.system() },
        .{ .system = text_panel.system() },
        .{ .system = text_panel.modesSystem() },
        .{ .system = open.system() },
        .{ .system = runner.system() },
        .{ .system = git_status.system() },
        .{ .system = p4_status.system() },
        .{ .system = text_tools.system() },
        .{ .system = plugins.system() },
        .{ .system = plugin_list.system() },
        .{ .sequencer = figure_authoring.sequencer() },
        .{ .system = fixed_panels.shownPanelsSystem() },
        .{ .system = transient.system() },
        .{ .system = action_palette.system() },
        .{ .system = editor.subscriptionsSystem() },
        .{ .system = redrawSystem() },
    } };
}

/// The system whose inbox every tree the editor draws names for its fonts (`ui.Tree.commit`):
/// a font a tree drew before it loaded answers here once it has, and every panel draws again
/// (`Context.finished`). It runs no kernel; a font loads once, so redrawing all is rare.
pub fn redrawSystem() System {
    return .{ .name = "editor_redraw", .root = redraw_root, .claims = sequencer.claims_nothing, .access = noAccess, .kernels = &.{} };
}

/// `redrawSystem`'s inbox, which every `ui.Tree.commit` of the editor's names.
pub fn redrawInbox() Atom {
    return sequencer.inboxOf(redrawSystem());
}

const redraw_root = Atom.from("editor_redraw");

fn noAccess(frame: *const sequencer.Frame) sequencer.Access {
    _ = frame;
    return .{};
}

/// The figure editor's systems, which the frame's root runs as a child where they are: build
/// them into a local first (`figure_workspace.figureAuthoring()`), and keep it while the
/// root built from it is in use.
pub const FigureAuthoring = @TypeOf(workspace.figureAuthoring());

/// The sequencer's fault table and its systems' inboxes.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try sequencer.ensure(scratch, atoms, tables);
    const figure_authoring = workspace.figureAuthoring();
    const frame_root = frameRoot(&figure_authoring);
    try sequencer.ensureInboxes(scratch, atoms, tables, &frame_root.sequencer());
}

/// What the sequencer's hooks see.
const Context = struct {
    tables: *Table.Registry,
    atoms: *Atom.Registry,

    fn of(context: *anyopaque) *Context {
        return @ptrCast(@alignCast(context));
    }

    /// An editor system has no scope to enter: what it draws and asks names its inboxes.
    fn noScope(context: *anyopaque, system: *const System) void {
        _ = context;
        _ = system;
    }

    /// The system's panels draw again when its kernels changed a table or it heard something;
    /// every panel does when a font the editor drew before it loaded has loaded
    /// (`redrawSystem`).
    fn finished(context: *anyopaque, system: *const System, changed: bool) void {
        if (!changed) return;
        const self = of(context);
        // Without the panels, as in a headless run, there is nothing to draw.
        if (self.tables.findByName(Atom.from(panels_mod.nodes_table_name)) == null) return;
        if (system.root == redraw_root) {
            panels_mod.requestRedrawAll(self.tables, self.atoms);
            return;
        }
        var shown: [panels_mod.kMaxPanels]panels_mod.Panel = undefined;
        for (panels_mod.panels(self.tables, self.atoms, &shown)) |panel| {
            if (panel.root == system.root) panels_mod.requestRedraw(self.tables, self.atoms, panel.id);
        }
    }
};

/// Runs `root` as a child of `parent`, main's run, or as the root, its layer flushed into
/// the tables at the end, when there is none (in tests).
pub fn run(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry, root: *const Sequencer, parent: ?*journal.Layer) void {
    var context: Context = .{ .tables = tables, .atoms = atoms };
    const env: sequencer.Env = .{
        .memory = memory,
        .atoms = atoms,
        .tables = tables,
        .hooks = .{ .context = &context, .enter = Context.noScope, .leave = Context.noScope, .finished = Context.finished },
    };
    _ = sequencer.run(root, &env, parent);
}

// ---- what a system draws ------------------------------------------------------------------

/// Where a click or the wheel over what `tree` draws goes: `system`'s inbox, which takes it
/// by `tag`, with `data`'s bytes as its user data (none for void).
pub fn to(tree: *ui.Tree, system: System, tag: Atom, data: anytype) ui.Target {
    return tree.target(sequencer.inboxOf(system), tag, data);
}

// ---- actions from a system's run ----------------------------------------------------------

/// What a system's kernel declares the actions it offers through: rows of `subscribed.actions`
/// appended through the run, which the system declares written, each naming the inbox of the
/// system that runs it.
pub const ActionDeclarer = struct {
    pass: *sequencer.Pass,

    pub const table = Atom.from(plugin.action_api.subscribed_table_name);

    pub fn sink(declarer: *ActionDeclarer) plugin.ActionSink {
        return .{ .context = declarer, .declare_fn = declare };
    }

    /// An action no system takes, or that cannot be appended, is dropped and logged; the
    /// frame's other actions are still offered.
    fn declare(context: *anyopaque, action: plugin.action_api.Action) void {
        const declarer: *ActionDeclarer = @ptrCast(@alignCast(context));
        const frame = declarer.pass.frame;
        if (action.inbox == sequencer.no_inbox) {
            Log.warn("action_unaddressed", .{ .action = action.id[1] });
            return;
        }
        const actions = plugin.Actions.of(frame.memory, frame.tables, plugin.action_api.subscribed_table_name);
        actions.tryPush(action) catch |err| {
            Log.err("action_dropped", .{ .action = action.id[1], .@"error" = @errorName(err) });
        };
    }
};

/// What a system's kernel declares the keymaps it adds to through: rows of `subscribed.keymaps`
/// appended through the run, which the system declares written, as `ActionDeclarer`'s.
pub const KeymapDeclarer = struct {
    pass: *sequencer.Pass,

    pub const table = Atom.from(plugin.action_api.keymaps_table_name);

    pub fn sink(declarer: *KeymapDeclarer) plugin.KeymapSink {
        return .{ .context = declarer, .declare_fn = declare };
    }

    /// A keymap that cannot be appended is dropped and logged; the frame's others are still
    /// declared.
    fn declare(context: *anyopaque, keymap: plugin.action_api.Keymap) void {
        const declarer: *KeymapDeclarer = @ptrCast(@alignCast(context));
        const frame = declarer.pass.frame;
        const keymaps = plugin.Keymaps.of(frame.memory, frame.tables, plugin.action_api.keymaps_table_name);
        keymaps.tryPush(keymap) catch |err| {
            Log.err("keymap_dropped", .{ .mode = keymap.mode, .@"error" = @errorName(err) });
        };
    }
};

// ---- input subscriptions from a system's run ----------------------------------------------

/// What a system's kernel subscribes to input through: rows of `subscriptions.input` naming the
/// system's inbox, appended through the run's journal, which the system declares written.
pub const InputSubscriber = struct {
    pass: *sequencer.Pass,
    inbox: Atom,

    pub const table = Atom.from(input.subscriptions_table_name);

    pub fn of(pass: *sequencer.Pass, system: sequencer.System) InputSubscriber {
        return .{ .pass = pass, .inbox = sequencer.inboxOf(system) };
    }

    /// Pushes `subscription`, which names its tags, its messages carrying `user_data` back,
    /// copied now. A subscription that cannot be appended is dropped; the frame's other
    /// subscribers still hear their input.
    pub fn push(subscriber: InputSubscriber, subscription: input.Subscription, user_data: sequencer.UserData) void {
        subscriber.pushValues(.{ .subscription = subscription, .user_data = user_data });
    }

    /// As `push`, with every value of the row but its source and inbox, which are the
    /// subscriber's: a text subscription's navigation user data among them.
    pub fn pushValues(subscriber: InputSubscriber, values: input.SubscriptionValues) void {
        var row = values;
        row.source = .plugin;
        row.inbox = subscriber.inbox;
        const subscriptions = subscriber.pass.writeTable(table) catch return;
        input.appendSubscription(subscriptions, row) catch return;
    }
};
