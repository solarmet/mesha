const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const modes = @import("../modes.zig");
const os = mesha.os;
const figure = mesha.figure;
const time = mesha.time;
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const math = mesha.math;
const input = mesha.input;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const panel_frame = @import("../panel_frame.zig");
const workspaces = @import("../workspaces.zig");
const transport = @import("commands.zig");
pub const geometry = @import("geometry.zig");
const editor_state = @import("../state.zig");
const list = @import("list_navigation.zig");
const action_palette = @import("../action_palette.zig");
pub const session = @import("session.zig");
pub const selection = @import("selection.zig");
pub const prompts = @import("prompts.zig");
pub const drawing = @import("drawing.zig");
const color_picker = @import("color_picker.zig");
const sketches = @import("sketches.zig");
const scrub = @import("scrub.zig");
const context_menu = @import("context_menu.zig");
const chrome = @import("chrome.zig");
const motion = @import("motion.zig");
pub const weight = @import("weight.zig");
pub const pose = @import("pose.zig");
pub const gesture = @import("gesture.zig");
pub const filmstrip = @import("filmstrip.zig");
pub const preview = @import("preview.zig");
const view = @import("view.zig");
const watches = @import("watches.zig");
const asks = @import("asks.zig");
const sequencer = mesha.sequencer;

/// The figure editor's root: its panels draw again when its systems change a table.
pub const figure_root = Atom.from("figure_editor");
const resources = mesha.resources;
const Log = mesha.log.scope("editor");
const editor_sequencer = @import("../editor_sequencer.zig");
const open = @import("../open.zig");
const text_editor = plugin.text_editor_api;

const Zones = mesha.log.scope("figure_editor");
/// This file's profile zones, in its log scope.
const Zone = enum { pointer_down, pointer_move, pointer_up };

// ---- the figure editor's systems ------------------------------------------------------------

/// The figure editor's systems, in the order they run each frame. The document follows the
/// host first, so input acts on what it now holds; the canvas takes the pointer and its own
/// actions; each tool family takes its actions; the gesture then sends what the frame's
/// drags sampled; the animation settles its edits; the view shows the result; and, last, the
/// editor declares what it watches of the figure as the frame left it.
pub fn figureAuthoring() sequencer.Built(9) {
    return .{ .name = "figure_authoring", .steps = .{
        .{ .system = transport.system() },
        .{ .system = system() },
        .{ .system = drawing.system() },
        .{ .system = pose.system() },
        .{ .system = weight.system() },
        .{ .system = gesture.system() },
        .{ .system = filmstrip.system() },
        .{ .system = view.system() },
        .{ .system = watches.system() },
    } };
}

/// Every name the figure editor's systems compare or store as an atom: `names.zig`, the tag
/// names of the enums they store as atoms, and the inspector's fields. Interned when the
/// editor starts.
pub const vocabulary = sequencer.namesOf(names) ++
    sequencer.enumNames(Msg) ++
    sequencer.enumNames(motion.Msg) ++
    sequencer.enumNames(transport.Msg) ++
    sequencer.enumNames(filmstrip.Msg) ++
    sequencer.enumNames(pose.Msg) ++
    sequencer.enumNames(weight.Msg) ++
    sequencer.enumNames(drawing.Msg) ++
    sequencer.enumNames(color_picker.Msg) ++
    sequencer.enumNames(sketches.Msg) ++
    sequencer.enumNames(asks.Msg) ++
    sequencer.enumNames(asks.Purpose) ++
    sequencer.enumNames(sketches.PromptKind) ++
    sequencer.enumNames(session.api.PaintChannel) ++
    sequencer.enumNames(session.api.ObjectKind) ++
    sequencer.enumNames(selection.Category) ++
    sequencer.enumNames(drawing.ToolOption) ++
    sequencer.enumNames(drawing.PointAxis) ++
    sequencer.enumNames(geometry.SnapKind) ++
    [_][]const u8{sketches.first_member} ++
    prompts.field_vocabulary;

/// The canvas: the pointer, the wheel, selection and the outliner, the view, documents,
/// prompts, and every action no tool family owns. Pointer presses still reach the tools through
/// `pointerDown`, which decides by mode and tool which of them a press is for.
pub fn system() sequencer.System {
    return .{
        .name = "figure_canvas",
        .names = comptime &vocabulary,
        .root = figure_root,
        .claims = claims,
        .active = canvasActive,
        .access = access,
        .kernels = &.{
            .{ .name = "figure_canvas.take_answers", .run = takeAnswers },
            .{ .name = "figure_canvas.take_requests", .run = takeRequests },
            .{ .name = "figure_canvas.take_input", .run = takeInput },
            .{ .name = "figure_canvas.prune_selection", .run = pruneSelection },
            .{ .name = "figure_canvas.follow_modes", .run = followModes },
        },
    };
}

/// The figure editor's panels' modes, a `modes.PanelModesRow` each.
pub const panel_modes_table_name = "figure_panel_modes";

/// Every panel of the figure editor's is `figure`'s. They are open only while its workspace is
/// shown, which is when the canvas runs.
fn followModes(pass: *sequencer.Pass) !void {
    const figure_panels = [_][]const u8{ canvas_id, outliner_id, inspector_id, sequencer_id };
    var wanted: [figure_panels.len]modes.PanelMajor = undefined;
    for (figure_panels, &wanted) |id, *panel| panel.* = .{ .panel = Atom.from(id), .major = modes.figure };
    try modes.syncPanelModes(pass, panel_modes_table_name, &wanted);
}

/// Whether the figure workspace is shown: while it is hidden, the figure systems run only for
/// their messages and for work they left unfinished. Without the panels, as in a headless
/// run, it counts as shown.
pub fn shown(frame: *const sequencer.Frame) bool {
    return workspaceShown(frame.tables, frame.atoms);
}

/// `shown`, from the tables it reads.
fn workspaceShown(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    // Without the editor's workspaces, as in a test of the figure editor alone, it is shown.
    if (tables.findByName(Atom.from(workspaces.workspace_table_name)) == null) return true;
    return workspaces.activeWorkspace(tables, atoms) == .figure;
}

/// The directory find-file opens on from the figure workspace: that of the file of the figure
/// it shows, while it is showing; empty when it is hidden, shows no figure, or its figure has
/// no file. The slice is the host's figure definitions table's, good until the host next
/// publishes. A system that calls it declares `declareFindFileDirectoryReads`.
pub fn findFileDirectory(tables: *Table.Registry, atoms: *Atom.Registry) []const u8 {
    if (tables.findByName(Atom.from(session.name)) == null) return "";
    if (!workspaceShown(tables, atoms)) return "";
    const editor = session.get(tables);
    if (editor.doc.* == session.none) return "";
    const path = session.definitionPath(tables, atoms, editor.doc.*) orelse return "";
    return std.fs.path.dirname(path) orelse "";
}

/// What `findFileDirectory` reads: which workspace is active, the figure the editor shows, and
/// the host's figure definitions, which hold its file.
pub fn declareFindFileDirectoryReads(result: *sequencer.Access) void {
    result.read(Atom.from(workspaces.workspace_table_name));
    result.read(Atom.from(session.name));
    result.read(Atom.from(figure.definitions_table_name));
}

/// Hidden, the canvas still takes other systems' requests, as leaving the workspace.
fn canvasActive(frame: *const sequencer.Frame) bool {
    if (shown(frame)) return true;
    const requests = Requests.of(frame.memory, frame.tables, commands_table_name);
    return requests.count() != 0;
}

/// What other editor systems ask of the canvas, as rows of `commands.figure_canvas`.
pub const Request = enum(u8) {
    /// The figure workspace is being left: cancel what is in hand, as when its panels lose
    /// the focus, and stop playing the animation.
    leave_workspace,
    /// Open the figure or sketch `editor_open` names, in the figure workspace, shown for it, as
    /// the editor's open system asks for a file chosen to be opened.
    open_requested,
    /// Make a new figure or sketch of the id `editor_open` names, whose file is its path, written
    /// at its first save, in the figure workspace, shown for it, as the editor's open system asks
    /// for a path typed in find-file that names no file. A name a new document may not take
    /// (`prompts.newNameRefusal`) makes nothing and is told.
    create_requested,
};
pub const commands_table_name = "commands.figure_canvas";
pub const Requests = sequencer.Commands(Request);
const requests_table = Atom.from(commands_table_name);

/// Asks the canvas for `request`, in its run this frame.
pub fn request(mem: *memory.Memory, tables: *Table.Registry, wanted: Request) void {
    Requests.of(mem, tables, commands_table_name).push(wanted);
}

pub const time_subscriptions = Atom.from(time.subscriptions_table_name);
pub const input_subscriptions = Atom.from(input.subscriptions_table_name);

/// The tags of the canvas's actions, and of what its subscriptions, panels, prompts and
/// requests send it.
pub const Msg = enum(u64) {
    figure_open = Atom.from("figure_open").value(),
    /// Offers the loaded figures and the open sketches, to show one.
    figure_switch_document = Atom.from("figure_switch_document").value(),
    figure_new = Atom.from("figure_new").value(),
    figure_save = Atom.from("figure_save").value(),
    figure_save_as = Atom.from("figure_save_as").value(),
    figure_close = Atom.from("figure_close").value(),
    figure_reload = Atom.from("figure_reload").value(),
    figure_undo = Atom.from("figure_undo").value(),
    figure_redo = Atom.from("figure_redo").value(),
    figure_select_next = Atom.from("figure_select_next").value(),
    figure_select_previous = Atom.from("figure_select_previous").value(),
    figure_tool_select = Atom.from("figure_tool_select").value(),
    figure_tool_hand = Atom.from("figure_tool_hand").value(),
    figure_tool_bone = Atom.from("figure_tool_bone").value(),
    figure_tool_stick = Atom.from("figure_tool_stick").value(),
    figure_rig_connected = Atom.from("figure_rig_connected").value(),
    figure_stick_head = Atom.from("figure_stick_head").value(),
    figure_snap_joints = Atom.from("figure_snap_joints").value(),
    figure_snap_midpoints = Atom.from("figure_snap_midpoints").value(),
    figure_snap_axes = Atom.from("figure_snap_axes").value(),
    figure_snap_lengths = Atom.from("figure_snap_lengths").value(),
    figure_snap_grid = Atom.from("figure_snap_grid").value(),
    figure_chain_finish = Atom.from("figure_chain_finish").value(),
    figure_gesture_cancel = Atom.from("figure_gesture_cancel").value(),
    figure_view_fit = Atom.from("figure_view_fit").value(),
    figure_view_selection = Atom.from("figure_view_selection").value(),
    figure_view_reset = Atom.from("figure_view_reset").value(),
    figure_zoom_in = Atom.from("figure_zoom_in").value(),
    figure_zoom_out = Atom.from("figure_zoom_out").value(),
    figure_folder_add = Atom.from("figure_folder_add").value(),
    figure_folder_group = Atom.from("figure_folder_group").value(),
    figure_folder_ungroup = Atom.from("figure_folder_ungroup").value(),
    figure_toggle_grid = Atom.from("figure_toggle_grid").value(),
    figure_toggle_bones = Atom.from("figure_toggle_bones").value(),
    figure_select_all = Atom.from("figure_select_all").value(),
    figure_deselect = Atom.from("figure_deselect").value(),
    figure_focus_mode = Atom.from("figure_focus_mode").value(),
    figure_key_panel_next = Atom.from("figure_key_panel_next").value(),
    figure_mode_design = Atom.from("figure_mode_design").value(),
    figure_mode_rig = Atom.from("figure_mode_rig").value(),
    figure_mode_draw = Atom.from("figure_mode_draw").value(),
    figure_rename = Atom.from("figure_rename").value(),
    figure_bone_values = Atom.from("figure_bone_values").value(),
    figure_reparent = Atom.from("figure_reparent").value(),
    figure_delete_bone = Atom.from("figure_delete_bone").value(),
    figure_delete_branch = Atom.from("figure_delete_branch").value(),
    figure_mirror_branch = Atom.from("figure_mirror_branch").value(),
    figure_toggle_visible = Atom.from("figure_toggle_visible").value(),
    figure_toggle_lock = Atom.from("figure_toggle_lock").value(),
    figure_nudge_left = Atom.from("figure_nudge_left").value(),
    figure_nudge_right = Atom.from("figure_nudge_right").value(),
    figure_nudge_up = Atom.from("figure_nudge_up").value(),
    figure_nudge_down = Atom.from("figure_nudge_down").value(),
    figure_nudge_left_large = Atom.from("figure_nudge_left_large").value(),
    figure_nudge_right_large = Atom.from("figure_nudge_right_large").value(),
    figure_nudge_up_large = Atom.from("figure_nudge_up_large").value(),
    figure_nudge_down_large = Atom.from("figure_nudge_down_large").value(),
    figure_pointer_down = Atom.from("figure_pointer_down").value(),
    figure_pointer_move = Atom.from("figure_pointer_move").value(),
    figure_pointer_up = Atom.from("figure_pointer_up").value(),
    figure_pointer_cancel = Atom.from("figure_pointer_cancel").value(),
    figure_scroll = Atom.from("figure_scroll").value(),
    figure_menu_item = Atom.from("figure_menu_item").value(),
    figure_menu_dismiss = Atom.from("figure_menu_dismiss").value(),
    figure_scrub_move = Atom.from("figure_scrub_move").value(),
    figure_scrub_up = Atom.from("figure_scrub_up").value(),
    figure_chrome_info = Atom.from("figure_chrome_info").value(),
    figure_prompt_reply = Atom.from("figure_prompt_reply").value(),
    figure_information_frame = Atom.from("figure_information_frame").value(),
    figure_open_document = Atom.from("figure_open_document").value(),
    figure_outliner_tab = Atom.from("figure_outliner_tab").value(),
    figure_outliner_down = Atom.from("figure_outliner_down").value(),
    figure_outliner_up = Atom.from("figure_outliner_up").value(),
    figure_outliner_cancel = Atom.from("figure_outliner_cancel").value(),
    figure_select_item = Atom.from("figure_select_item").value(),
    figure_tool_option = Atom.from("figure_tool_option").value(),
    figure_inspector_field = Atom.from("figure_inspector_field").value(),
    figure_item_visible = Atom.from("figure_item_visible").value(),
    figure_item_lock = Atom.from("figure_item_lock").value(),
    figure_folder_collapse = Atom.from("figure_folder_collapse").value(),
    figure_layer_toggle_selection = Atom.from("figure_layer_toggle_selection").value(),
    figure_space_down = Atom.from("figure_space_down").value(),
    figure_space_up = Atom.from("figure_space_up").value(),
    _,
};

/// Its own messages and actions, and the pointer over the color popover.
fn claims(tag: Atom) bool {
    switch (tag.to(Msg)) {
        _ => {},
        else => return true,
    }
    switch (tag.to(sketches.Msg)) {
        _ => {},
        else => return true,
    }
    return switch (tag.to(color_picker.Msg)) {
        .figure_color_down, .figure_color_move, .figure_color_up, .figure_color_cancel => true,
        else => false,
    };
}

/// What the canvas writes depends on what it was sent. The pointer moving over the canvas
/// writes only where it is; a drag writes the editor's state and the rows the active tool
/// samples into; anything else may reach any table of the editor, as a press does through the
/// tools. Pruning the selection writes its rows only in a frame they name what is gone.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    // The host's publications the system's reads come from.
    watches.declareReads(&result);
    modes.declarePanelModes(&result, frame.tables, panel_modes_table_name);
    result.readAll(&table_groups.state);
    result.readAll(&table_groups.selected);
    result.read(Atom.from(panels_mod.nodes_table_name));
    result.read(Atom.from(panels_mod.state_table_name));
    // Which document the editor's open system asks for.
    const open_request = Atom.from(open.table_name);
    if (frame.tables.findByName(open_request) != null) result.read(open_request);
    // `figure_open` asks the text editor for the listing find-file opens on.
    if (frame.messages.len != 0) result.writeIfPresent(frame.tables, Atom.from(text_editor.commands_table_name));
    if (frame.messages.len != 0 or gesture.heldInput(frame.tables).count() != 0) result.writeIfPresent(frame.tables, Atom.from(resources.commands_table_name));
    result.writeAll(&.{ table_groups.editor, table_groups.observed, table_groups.draw });
    // A press may ask what lies under it, and input waits behind the answer; the clock ages
    // the questions.
    table_groups.declareAsking(&result, frame.tables);
    if (frame.tables.findByName(clock_table) != null) result.read(clock_table);
    // Held input goes on after the answers, as any message would.
    const replays = gesture.heldInput(frame.tables).count() != 0;
    // Opening the workspace, focus mode and the key panels ask the panels; clearing the
    // canvas hover asks the status bar. Opening the workspace also shows its fixed panels.
    result.writeIfPresent(frame.tables, Atom.from(plugin.panels.commands_table_name));
    result.writeIfPresent(frame.tables, Atom.from(workspaces.shown_panels_table_name));
    result.writeIfPresent(frame.tables, Atom.from(@import("../status_bar.zig").commands_table_name));
    var reads = session.ReadContext{ .tables = frame.tables, .atoms = frame.atoms };
    defer reads.deinit();
    if (selection.stale(&reads)) result.writeAll(&table_groups.selected);
    // A request may reach any table of the editor, as cancelling a tool does, and opening a
    // figure or a sketch sends the figure host system its load. Messages of the same frame are
    // taken after the requests and declare what they write below.
    const requests = Requests.of(frame.memory, frame.tables, commands_table_name);
    if (requests.count() != 0) {
        result.write(requests_table);
        table_groups.declareEditing(&result);
    }
    if (frame.messages.len == 0 and !replays) return result;
    const editor = session.get(frame.tables);
    if (replays or !onlyPointerMoves(frame)) {
        table_groups.declareEditing(&result);
        // A context menu's item invokes its action.
        result.writeIfPresent(frame.tables, Atom.from(plugin.action_api.commands_table_name));
    } else if (editor.gesture_active.* == 0) {
        result.writeAll(&.{ table_groups.feedback, table_groups.animation });
    } else {
        result.writeAll(&table_groups.state);
        table_groups.declareSampling(&result, frame.tables);
    }
    return result;
}

fn onlyPointerMoves(frame: *const sequencer.Frame) bool {
    for (frame.messages) |received| {
        if (received.tag.to(Msg) != .figure_pointer_move) return false;
    }
    return true;
}

/// The requests other systems appended this frame, before the canvas's input.
fn takeRequests(pass: *sequencer.Pass) !void {
    const requests = Requests.of(pass.frame.memory, pass.frame.tables, commands_table_name);
    if (requests.count() != 0) try requests.take(pass, pass, applyRequest);
}

fn applyRequest(pass: *sequencer.Pass, wanted: *const Request) !void {
    const frame = pass.frame;
    switch (wanted.*) {
        .leave_workspace => {
            cancel(frame.tables, frame.atoms);
            focusLost(frame.tables, frame.atoms);
            filmstrip.config(frame.tables).playing.* = 0;
        },
        .open_requested => try openRequested(frame.tables, frame.atoms, .open),
        .create_requested => try openRequested(frame.tables, frame.atoms, .create),
    }
}

/// Whether a request names a document's file to open or the path of one to make.
const RequestedFile = enum { open, create };

/// Opens the document `editor_open` names, or makes it new at its path, showing the figure
/// workspace for it.
fn openRequested(tables: *Table.Registry, atoms: *Atom.Registry, requested_file: RequestedFile) !void {
    const wanted = open.requested(tables) orelse return;
    openWorkspace(tables, atoms);
    finish(tables, atoms);
    // A request names its file; one with none (an older row) loads the catalog's.
    const path: ?[]const u8 = if (wanted.path.len == 0) null else wanted.path;
    // The id is the file's stem, a name typed or picked as a prompt's text is: it is
    // interned here, so the document is named even when its request is refused.
    if (path) |file_path| try atoms.tryInternAll(&.{open.documentStem(file_path)});
    switch (requested_file) {
        .open => switch (wanted.kind) {
            .none => {},
            .figure => prompts.load(tables, atoms, wanted.document, false, path),
            .sketch => try sketches.open(tables, atoms, wanted.document, path),
        },
        .create => {
            const file_path = path orelse return;
            if (try showRecorded(tables, atoms, wanted.kind, wanted.document, file_path)) return;
            const allocator = (try tables.memory.frameScratchAllocator()).allocator;
            const stem = open.documentStem(file_path);
            // A sketch's first member is a new figure too, `<sketch>_<member>`.
            const member_figure = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ stem, sketches.first_member });
            const names_made: []const []const u8 = if (wanted.kind == .sketch) &.{ stem, member_figure } else &.{stem};
            for (names_made) |name| {
                const refusal = prompts.newNameRefusal(tables, atoms, name) orelse continue;
                const kind_name = if (wanted.kind == .sketch) "sketch" else "figure";
                const sentence = switch (refusal) {
                    .invalid_name => try std.fmt.allocPrint(allocator, "No {s} was made at {s}: the name {s} is not a snake_case name.", .{ kind_name, file_path, name }),
                    .taken => try std.fmt.allocPrint(allocator, "No {s} was made at {s}: a figure or sketch named {s} is already open or saved.", .{ kind_name, file_path, name }),
                };
                prompts.status(session.table(tables), session.get(tables), session.feedback(tables), sentence);
                return;
            }
            switch (wanted.kind) {
                .none => {},
                .figure => try prompts.createAt(tables, atoms, wanted.document, file_path),
                .sketch => try sketches.createAt(tables, atoms, wanted.document, file_path),
            }
        },
    }
}

/// Shows the loaded figure or open sketch `id` when its file is already `file_path`, as find-file
/// of a new document's own path, not yet written, does; false when no document of `id` has it.
fn showRecorded(tables: *Table.Registry, atoms: *Atom.Registry, kind: open.DocumentKind, id: Atom, file_path: []const u8) !bool {
    switch (kind) {
        .none => return false,
        .figure => {
            const recorded = session.definitionPath(tables, atoms, id) orelse return false;
            if (!std.mem.eql(u8, recorded, file_path)) return false;
            prompts.load(tables, atoms, id, false, file_path);
            return true;
        },
        .sketch => {
            const open_sketches = tables.findByName(Atom.from(figure.sketches_table_name)) orelse return false;
            var rows = open_sketches.readQuery(figure.SketchView);
            while (rows.next()) |row| {
                if (row.view.sketch.* != id) continue;
                if (!std.mem.eql(u8, row.view.path, file_path)) return false;
                try sketches.open(tables, atoms, id, file_path);
                return true;
            }
            return false;
        },
    }
}

/// Each message the canvas claimed, in order, as `handle` takes it. The answers to its
/// questions were taken first.
fn takeInput(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    for (frame.messages) |received| {
        if (received.tag.to(asks.Msg) == .figure_answer) continue;
        _ = handle(frame.memory, frame.tables, frame.atoms, received);
    }
}

/// The answers to the canvas's questions, each going on with what its press or release
/// asked; then the questions that hold the pointer and have waited too long are given up
/// (`asks.answer_frames_max`), cancelling what they held; then the input held behind the
/// answered ones is applied, in order, until one asks again.
fn takeAnswers(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const tables = frame.tables;
    const atoms = frame.atoms;
    const asked = asks.rows(tables);
    for (frame.messages) |received| {
        const document = session.get(tables).doc.*;
        const answer = asks.take(asked, document, received) orelse continue;
        goOn(tables, atoms, answer) catch |err| switch (err) {
            error.NotReady, error.Busy, error.MissingDefinition => {},
            else => reject(session.table(tables), session.get(tables), session.feedback(tables), session.motion(tables), err),
        };
    }
    if (try clockFrame(pass)) |now| {
        asks.stamp(asked, now);
        if (asks.expire(asked, now)) |given_up| {
            cancel(tables, atoms);
            const text = asks.givenUpText(given_up);
            const feedback_table = session.feedbackTable(tables);
            const feedback = session.feedback(tables);
            prompts.inform(feedback_table, feedback, text);
        }
    }
    const held = gesture.heldInput(tables);
    const scratch = try frame.memory.frameScratchAllocator();
    while (true) {
        const holding = asks.holding(asked);
        const released = try gesture.release(held, holding, scratch.allocator) orelse break;
        _ = dispatch(frame.memory, tables, atoms, released.message, released.point);
    }
}

const clock_table = Atom.from(time.state_table_name);

/// The clock's frame, which ages the questions in flight; null without the clock, as in a test
/// of the figure editor alone, when nothing is given up.
fn clockFrame(pass: *sequencer.Pass) !?u64 {
    if (!pass.declares(clock_table)) return null;
    const clock = try pass.readSingleton(clock_table, time.FrameCountView);
    return clock.frame_index.*;
}

/// The second half of what asked `answer`'s question.
fn goOn(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    switch (answer.purpose) {
        .select_press => try selectPressAnswered(tables, atoms, answer),
        .point_edit_press => try pointEditPressAnswered(tables, atoms, answer),
        .marquee => try marqueeAnswered(tables, atoms, answer),
        .menu_press => try menuPressAnswered(tables, atoms, answer),
        .eyedropper_press => try drawing.eyedropperAnswered(tables, atoms, answer),
        .erase => drawing.eraseAnswered(tables, answer),
        .color_sample_press => try color_picker.sampleAnswered(tables, atoms, answer),
        .color_sample_paint => try color_picker.samplePaintAnswered(tables, atoms, answer),
        .eyedropper_paint => try drawing.eyedropperPaintAnswered(tables, atoms, answer),
        .gradient_start, .gradient_end => try drawing.gradientAnswered(tables, atoms, answer),
        .weight_press => try weight.pressAnswered(tables, atoms, answer),
        // The view's, the drawing system's and the gesture system's.
        .hover, .hover_paint, .paint_handles, .clipboard, .pose_press, .pose_drag, _ => {},
    }
}

/// Hears the time system's frames while information shows, a tool's tap is timed, or a question
/// that holds input or that a drag waits for is in flight, and the pointer and keys the figure
/// workspace takes. Run last, by the view, so it subscribes for the frame's final state, which a
/// subscription collected after the frame read.
///
/// Such a question is given up once it has waited `asks.answer_frames_max` frames
/// (`takeAnswers`), and frames come only when there is work: hearing the clock keeps them
/// coming while it waits, so a question whose answer is lost is given up, and the input held
/// behind it let go, without the person moving the pointer again.
pub fn subscribe(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const information_shows = session.feedback(tables).information_seconds.* > 0;
    const tool_timing = drawing.config(tables).tool_tap_remaining.* > 0;
    const asked = asks.rows(tables);
    const holds_input = asks.holding(asked) != .nothing;
    const question_waits = holds_input or asks.awaited(asked);
    if (information_shows or tool_timing or question_waits) {
        _ = try pass.append(time_subscriptions, .{ .kind = time.SubscriptionKind.frame, .inbox = sequencer.inboxOf(system()), .tag = Atom.from(Msg.figure_information_frame) });
    }
    try subscribeInput(pass);
}

/// A held pointer keeps it until release; otherwise the open popover or menu decides, and
/// the canvas hears motion anywhere and Space.
fn subscribeInput(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    if (workspaces.activeWorkspace(tables, atoms) != .figure) return;
    const pointer_moves = pointerMoves(session.get(tables));
    const observed = session.observed(tables);
    const held: session.PointerOwner = @enumFromInt(observed.pointer_owner.*);
    if (held != .none) {
        const button: input.MouseButton = @enumFromInt(observed.pointer_button.*);
        if (held == .canvas) {
            try appendInput(pass, .{ .mouse_move = .{ .moves = pointer_moves, .capture = true } }, .from(Msg.figure_pointer_move));
            try appendInput(pass, .{ .mouse_button_up = .{ .button = button, .capture = true } }, .from(Msg.figure_pointer_up));
            try appendInput(pass, .{ .pointer_cancel = .{} }, .from(Msg.figure_pointer_cancel));
        } else {
            try appendInput(pass, .{ .mouse_button_up = .{ .button = button, .capture = true } }, .from(Msg.figure_outliner_up));
            try appendInput(pass, .{ .pointer_cancel = .{} }, .from(Msg.figure_outliner_cancel));
        }
        return;
    }
    try scrub.subscribe(pass);
    if (context_menu.isOpen(context_menu.get(tables))) {
        try context_menu.subscribe(pass);
        return;
    }
    try color_picker.subscribe(pass);
    // Hover needs motion anywhere; a press comes from the region of the surface it landed on.
    try appendInput(pass, .{ .mouse_move = .{ .moves = pointer_moves, .scope = .global } }, .from(Msg.figure_pointer_move));
    // Text entry captures Space, so Space always means pan or play when it arrives here.
    try appendInput(pass, .{ .key_down = .{ .key = .space } }, .from(Msg.figure_space_down));
    try appendInput(pass, .{ .key_up = .{ .key = .space } }, .from(Msg.figure_space_up));
}

/// Subscribes to input for `tag`, which reaches the inbox of the figure system that claims it
/// (`claimingInbox`). The kernel's system declares `subscriptions.input`.
pub fn appendInput(pass: *sequencer.Pass, subscription: input.Subscription, tag: Atom) !void {
    const row = input.subscriptionRow(subscription, tag, .plugin, claimingInbox(tag));
    try input.appendSubscription(try pass.writeTable(input_subscriptions), row);
}

fn claimingInbox(tag: Atom) Atom {
    // Every tag the editor subscribes for is claimed; the canvas takes any other.
    const claiming = claimant(tag) orelse system();
    return sequencer.inboxOf(claiming);
}

/// The figure system that claims `tag`, the first in run order.
fn claimant(tag: Atom) ?sequencer.System {
    const authoring = figureAuthoring();
    for (authoring.steps) |step| switch (step) {
        .system => |candidate| if (candidate.claims(tag)) return candidate,
        .sequencer, .call => {},
    };
    return null;
}

/// The figure system that runs the action with `tag`, or the canvas's, which takes the rest.
pub fn actionSystem(tag: Atom) sequencer.System {
    return claimant(tag) orelse system();
}

/// Where a click or the wheel over the figure editor's drawing in `tree` goes: the figure
/// system that claims `tag`, or else the editor's messages system, which hands the rest to
/// `handle`.
pub fn to(tree: *ui.Tree, tag: Atom, data: anytype) ui.Target {
    if (claimant(tag)) |claiming| return editor_sequencer.to(tree, claiming, tag, data);
    const editor_messages = @import("../editor.zig").messagesSystem();
    return editor_sequencer.to(tree, editor_messages, tag, data);
}

/// Drops selected items, and collapsed folders, the document no longer has.
fn pruneSelection(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    if (selection.stale(&reads)) {
        // Input this frame may have left rows stale after the frame's access was declared, as
        // a delete does; they are pruned next frame, when it declares them.
        if (!pass.writes(table_groups.selected[0])) return;
    }
    selection.pruneWithReads(&reads);
}

// ---- tool families --------------------------------------------------------------------------

/// A tool family's action: its handler, after the checks every figure action passes.
pub const ToolAction = fn (frame: *const sequencer.Frame, received: sequencer.Message) anyerror!void;

/// A tool family's kernel for the actions it claimed this frame: those `is_action` names.
/// Each is admitted as the canvas admits its own; a refused or failed action is reported in
/// the status, as before kernels, and leaves the others to run.
pub fn takeToolActions(pass: *sequencer.Pass, comptime is_action: fn (Atom) bool, comptime run: ToolAction) !void {
    const frame = pass.frame;
    for (frame.messages) |received| takeToolAction(frame, is_action, run, received);
}

fn takeToolAction(frame: *const sequencer.Frame, comptime is_action: fn (Atom) bool, comptime run: ToolAction, received: sequencer.Message) void {
    if (!is_action(received.tag)) return;
    const admitted = admitToolAction(frame.tables, frame.atoms, received.tag) catch |err| {
        reject(session.table(frame.tables), session.get(frame.tables), session.feedback(frame.tables), session.motion(frame.tables), err);
        return;
    };
    if (!admitted) return;
    run(frame, received) catch |err| reject(session.table(frame.tables), session.get(frame.tables), session.feedback(frame.tables), session.motion(frame.tables), err);
}

/// The checks a tool family's action passes before its handler, as the canvas makes them
/// before its own: no prompt open, nothing settling, the figure editor holding the keys, and a
/// tool change only between drags. False when the action is not for now.
fn admitToolAction(tables: *Table.Registry, atoms: *Atom.Registry, tag: Atom) !bool {
    if (action_palette.requestOpen(tables, atoms)) return false;
    // A key acts as it would without the menu, and the menu gets out of its way.
    _ = context_menu.close(context_menu.get(tables));
    try refuseUnsettled(drawing.config(tables), session.get(tables), gesture.get(tables));
    revealTools(session.observed(tables), tag);
    if (!figureHasKeys(tables, atoms)) return false;
    try pose.guardRigAction(session.get(tables), tag);
    return prepareToolChange(tables, atoms, tag);
}

/// A figure action other than the pointer's own lifecycle waits for edits the host has not
/// settled: a shape being created, a drag being flushed, or an animation or pose edit.
fn refuseUnsettled(draw_settings: drawing.ConfigView, editor: session.View, gesture_state: gesture.View) !void {
    if (draw_settings.creation_request.* != 0) return error.CreationSettling;
    const drag_busy = gesture.busy(gesture_state);
    const animation_or_pose = filmstrip.enabled(editor) or gesture.activeKind(gesture_state) == .pose;
    if (animation_or_pose and (editor.tx_active.* != 0 or drag_busy)) return error.AnimationEditSettling;
    if (drag_busy) return error.GestureSettling;
}

/// A tool or mode change brings the tool dock's choices into view.
fn revealTools(observed: session.ObservedView, tag: Atom) void {
    if (!changesTool(tag)) return;
    observed.tools_reveal.* = 1;
}

/// Whether the figure editor's workspace is shown and one of its panels has the keys.
fn figureHasKeys(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    const focus = editor_state.viewFocus(tables, atoms).id.*;
    return workspaces.activeWorkspace(tables, atoms) == .figure and isFigureView(focus);
}

/// A tool or mode change, or editing points, waits for the drag to end; then it closes the
/// color popover and finishes a pen path before the next tool is recorded. False when it must
/// wait.
fn prepareToolChange(tables: *Table.Registry, atoms: *Atom.Registry, tag: Atom) !bool {
    const editor = session.get(tables);
    const tool_change = changesTool(tag);
    if ((tool_change or tag.to(drawing.Msg) == .figure_edit_points) and editor.gesture_active.* != 0) {
        prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Finish the drag first");
        return false;
    }
    if (!tool_change) return true;
    color_picker.dismiss(color_picker.config(tables), gesture.get(tables));
    if (editor.tool.* == names.pen) try drawing.finish(tables, atoms);
    const next_tool = toolOf(tag) orelse session.none;
    drawing.recordToolChoice(session.get(tables), drawing.config(tables), next_tool);
    return true;
}

/// A figure action that failed: why, in the status, with the attention it draws.
pub fn reject(session_table: *Table, editor: session.View, feedback: session.FeedbackView, motion_view: session.MotionView, err: anyerror) void {
    prompts.status(session_table, editor, feedback, @errorName(err));
    motion.announceRejection(motion_view);
}

// ---- the editor's tables, as its systems declare them ---------------------------------------

pub const table_groups = struct {
    pub const editor = Atom.from(session.name);
    pub const observed = Atom.from(session.observed_name);
    pub const feedback = Atom.from(session.feedback_name);
    pub const draw = Atom.from(drawing.config_name);
    pub const animation = Atom.from(filmstrip.name);
    /// The requests the editor has sent the figure host and not yet heard back about.
    pub const commands = Atom.from(session.pending_name);
    /// Where those requests go: the figure host system's `commands.figure`.
    pub const figure_requests = Atom.from(figure.commands_table_name);
    pub const draft = Atom.from(session.draft_name);
    pub const erased = Atom.from(drawing.erased_name);
    /// What the editor asks of the action palette; the palette's own row it only reads.
    pub const palette_requests = Atom.from(action_palette.requests_table_name);
    /// The questions the editor asked the figure host, and the pointer's messages held behind
    /// them.
    pub const asking = [_]Atom{ Atom.from(asks.name), Atom.from(gesture.held_name) };
    /// Where those questions go: the figure host system's `commands.figure_queries`.
    pub const figure_queries = Atom.from(figure.queries_table_name);

    /// Every one-row table of the editor.
    pub const state = [_]Atom{
        editor,                              observed,                       feedback,
        draw,                                animation,                      Atom.from(session.outliner_tab_name),
        Atom.from(session.rig_options_name), Atom.from(session.motion_name), Atom.from(gesture.name),
        Atom.from(preview.name),             Atom.from(weight.config_name),  Atom.from(weight.stroke_name),
        Atom.from(pose.config_name),         Atom.from(color_picker.name),   Atom.from(scrub.name),
        Atom.from(context_menu.name),
    };
    /// What is selected, and which folders are collapsed: up to 4096 rows each.
    pub const selected = [_]Atom{ Atom.from(session.selection_name), Atom.from(session.collapse_name) };
    /// The drawing tools' rows.
    pub const drawing_rows = [_]Atom{ draft, erased, Atom.from(drawing.clipboard_name), Atom.from(drawing.copied_name), Atom.from(drawing.recent_colors_name), Atom.from(color_picker.targets_name) };
    /// Weight painting's rows, the stroke's among them.
    pub const weight_stroke_rows = [_]Atom{ Atom.from(weight.targets_name), Atom.from(weight.samples_name), Atom.from(weight.shapes_name), Atom.from(weight.locks_name) };
    pub const weight_rows = weight_stroke_rows ++ [_]Atom{Atom.from(weight.bones_name)};
    /// Posing's rows.
    pub const pose_rows = [_]Atom{ Atom.from(pose.clipboard_bones_name), Atom.from(pose.clipboard_ik_name), Atom.from(pose.drag_chain_name) };

    /// Every table of the editor, for a kernel whose handlers may reach any of them, but its
    /// questions (`declareAsking`).
    pub fn declareEditing(result: *sequencer.Access) void {
        result.writeAll(&state);
        result.writeAll(&selected);
        result.writeAll(&drawing_rows);
        result.writeAll(&weight_rows);
        result.writeAll(&pose_rows);
        result.writeAll(&.{ commands, figure_requests, palette_requests });
    }

    /// The questions to the figure host and the input held behind them, for a system that asks
    /// or takes answers, or cancels (`cancel`, `focusLost`); and where questions go when the host
    /// has made it.
    pub fn declareAsking(result: *sequencer.Access, tables: *Table.Registry) void {
        result.writeAll(&asking);
        result.writeIfPresent(tables, figure_queries);
    }

    /// The rows a drag samples into with the editor's tool and mode as they are, and the
    /// requests its previews send.
    pub fn declareSampling(result: *sequencer.Access, tables: *Table.Registry) void {
        const editor_row = session.get(tables);
        result.writeAll(&.{ commands, figure_requests });
        if (editor_row.tool.* == names.weight) result.writeAll(&weight_stroke_rows);
        if (editor_row.mode.* == names.animate) result.write(Atom.from(pose.drag_chain_name));
        if (editor_row.tool.* == names.eraser) {
            result.write(erased);
            declareAsking(result, tables);
        }
        if (editor_row.tool.* == names.pen or editor_row.tool.* == names.joint_fill) result.write(draft);
    }
};

/// The figure editor's stage, which holds its canvas and is its focus id.
pub const canvas_id = "figure_stage";
pub const outliner_id = "figure_outliner";
pub const inspector_id = "figure_inspector";
/// The Animate timeline's panel, open while the editor animates.
pub const sequencer_id = "figure_sequencer";

/// The figure editor's panels beside its stage: Layers left of it, Properties below Layers.
/// Constants, so an arrangement listing them is static data.
pub const outliner_panel: plugin.panels.Open = .{ .id = Atom.from(outliner_id), .root = figure_root, .title = "Layers", .beside = Atom.from(canvas_id), .side = .left, .share = 0.2, .focus = .keep };
pub const inspector_panel: plugin.panels.Open = .{ .id = Atom.from(inspector_id), .root = figure_root, .title = "Properties", .beside = Atom.from(outliner_id), .side = .bottom, .share = 0.55, .focus = .keep };
/// The sequencer, below the figure stage: shown while the editor animates (`view.syncSequencer`).
pub const sequencer_panel: plugin.panels.Open = .{ .id = Atom.from(sequencer_id), .root = figure_root, .title = "Sequencer", .beside = Atom.from(canvas_id), .side = .bottom, .share = 0.32, .focus = .keep };
/// A scroll route's data: which surface the wheel is over. Canvas is zero.
pub const ScrollSurface = enum(u8) { canvas, outliner, properties, timeline, dock };

const nudges = [_]struct { message: Msg, doc: []const u8, delta: session.Vec2 }{
    .{ .message = .figure_nudge_left, .doc = "Nudge artwork left 1 px", .delta = .{ .x = -1, .y = 0 } },
    .{ .message = .figure_nudge_right, .doc = "Nudge artwork right 1 px", .delta = .{ .x = 1, .y = 0 } },
    .{ .message = .figure_nudge_up, .doc = "Nudge artwork up 1 px / increase Polygon sides", .delta = .{ .x = 0, .y = -1 } },
    .{ .message = .figure_nudge_down, .doc = "Nudge artwork down 1 px / decrease Polygon sides", .delta = .{ .x = 0, .y = 1 } },
    .{ .message = .figure_nudge_left_large, .doc = "Nudge artwork left 10 px", .delta = .{ .x = -10, .y = 0 } },
    .{ .message = .figure_nudge_right_large, .doc = "Nudge artwork right 10 px", .delta = .{ .x = 10, .y = 0 } },
    .{ .message = .figure_nudge_up_large, .doc = "Nudge artwork up 10 px", .delta = .{ .x = 0, .y = -10 } },
    .{ .message = .figure_nudge_down_large, .doc = "Nudge artwork down 10 px", .delta = .{ .x = 0, .y = 10 } },
};

/// The canvas's own actions; the tool families claim theirs. All are of the mode `modes.figure`
/// but `figure_open` and `figure_new`, which are global: they are offered whatever has the focus.
const canvas_actions = [_]plugin.action_api.Def{
    .{ .name = "figure_open", .tag = @tagName(Msg.figure_open), .doc = "Open a figure or sketch file by typing its path; a new one when nothing is there" },
    .{ .name = "switch_document", .tag = @tagName(Msg.figure_switch_document), .doc = "Show another loaded figure or open sketch" },
    .{ .name = "figure_new", .tag = @tagName(Msg.figure_new), .doc = "Create a figure document" },
    .{ .name = "save", .tag = @tagName(Msg.figure_save), .doc = "Save figure" },
    .{ .name = "save_as", .tag = @tagName(Msg.figure_save_as), .doc = "Save figure as" },
    .{ .name = "close", .tag = @tagName(Msg.figure_close), .doc = "Close figure, asking about unsaved changes" },
    .{ .name = "reload", .tag = @tagName(Msg.figure_reload), .doc = "Reload figure from disk" },
    .{ .name = "undo", .tag = @tagName(Msg.figure_undo), .doc = "Undo" },
    .{ .name = "redo", .tag = @tagName(Msg.figure_redo), .doc = "Redo" },
    .{ .name = "select_next", .tag = @tagName(Msg.figure_select_next), .doc = "Select the next item" },
    .{ .name = "select_previous", .tag = @tagName(Msg.figure_select_previous), .doc = "Select the previous item" },
    .{ .name = "tool_select", .tag = @tagName(Msg.figure_tool_select), .doc = "Select and transform" },
    .{ .name = "tool_hand", .tag = @tagName(Msg.figure_tool_hand), .doc = "Pan the canvas by dragging" },
    .{ .name = "tool_bone", .tag = @tagName(Msg.figure_tool_bone), .doc = "Draw bones" },
    .{ .name = "tool_stick", .tag = @tagName(Msg.figure_tool_stick), .doc = "Draw bones with linked artwork" },
    .{ .name = "rig_connected", .tag = @tagName(Msg.figure_rig_connected), .doc = "Toggle connected bone construction" },
    .{ .name = "stick_head", .tag = @tagName(Msg.figure_stick_head), .doc = "Toggle filled head construction with Stick" },
    .{ .name = "snap_joints", .tag = @tagName(Msg.figure_snap_joints), .doc = "Toggle rig endpoint snapping to joints" },
    .{ .name = "snap_midpoints", .tag = @tagName(Msg.figure_snap_midpoints), .doc = "Toggle rig endpoint snapping to midpoints" },
    .{ .name = "snap_axes", .tag = @tagName(Msg.figure_snap_axes), .doc = "Toggle rig endpoint snapping to 45-degree axes" },
    .{ .name = "snap_lengths", .tag = @tagName(Msg.figure_snap_lengths), .doc = "Toggle rig snapping to existing bone lengths" },
    .{ .name = "snap_grid", .tag = @tagName(Msg.figure_snap_grid), .doc = "Toggle rig endpoint grid snapping" },
    .{ .name = "chain_finish", .tag = @tagName(Msg.figure_chain_finish), .doc = "Finish the chain or edit the selected path" },
    .{ .name = "gesture_cancel", .tag = @tagName(Msg.figure_gesture_cancel), .doc = "Cancel the gesture and roll back an unfinished chain" },
    .{ .name = "view_fit", .tag = @tagName(Msg.figure_view_fit), .doc = "Zoom to fit the figure" },
    .{ .name = "view_selection", .tag = @tagName(Msg.figure_view_selection), .doc = "Zoom to the selection" },
    .{ .name = "view_reset", .tag = @tagName(Msg.figure_view_reset), .doc = "Zoom to 100%" },
    .{ .name = "zoom_in", .tag = @tagName(Msg.figure_zoom_in), .doc = "Zoom in" },
    .{ .name = "zoom_out", .tag = @tagName(Msg.figure_zoom_out), .doc = "Zoom out" },
    .{ .name = "folder_add", .tag = @tagName(Msg.figure_folder_add), .doc = "New isolated folder" },
    .{ .name = "folder_group", .tag = @tagName(Msg.figure_folder_group), .doc = "Group selected layers" },
    .{ .name = "folder_ungroup", .tag = @tagName(Msg.figure_folder_ungroup), .doc = "Ungroup folder, keeping artwork" },
    .{ .name = "toggle_grid", .tag = @tagName(Msg.figure_toggle_grid), .doc = "Toggle grid" },
    .{ .name = "toggle_bones", .tag = @tagName(Msg.figure_toggle_bones), .doc = "Toggle bone overlays" },
    .{ .name = "select_all", .tag = @tagName(Msg.figure_select_all), .doc = "Select all artwork" },
    .{ .name = "deselect", .tag = @tagName(Msg.figure_deselect), .doc = "Clear the selection" },
    .{ .name = "focus_mode", .tag = @tagName(Msg.figure_focus_mode), .doc = "Toggle focus mode: the canvas fills the stage" },
    .{ .name = "key_panel_next", .tag = @tagName(Msg.figure_key_panel_next), .doc = "Move arrow keys between the canvas, Layers and Properties" },
    .{ .name = "mode_design", .tag = @tagName(Msg.figure_mode_design), .doc = "Design: draw and edit artwork" },
    .{ .name = "mode_rig", .tag = @tagName(Msg.figure_mode_rig), .doc = "Rig: build bones, bind artwork and paint weights" },
    .{ .name = "mode_draw", .tag = @tagName(Msg.figure_mode_draw), .doc = "Design mode (legacy Draw alias)" },
    .{ .name = "rename", .tag = @tagName(Msg.figure_rename), .doc = "Rename the selection" },
    .{ .name = "bone_values", .tag = @tagName(Msg.figure_bone_values), .doc = "Edit angle:length (degrees; omitted values preserved)" },
    .{ .name = "reparent", .tag = @tagName(Msg.figure_reparent), .doc = "Pick a new parent, keeping world transform" },
    .{ .name = "delete_bone", .tag = @tagName(Msg.figure_delete_bone), .doc = "Delete the selection, preserving a bone's children and artwork" },
    .{ .name = "delete_branch", .tag = @tagName(Msg.figure_delete_branch), .doc = "Delete branch, preserving artwork" },
    .{ .name = "mirror_branch", .tag = @tagName(Msg.figure_mirror_branch), .doc = "Mirror branch about its root" },
    .{ .name = "toggle_visible", .tag = @tagName(Msg.figure_toggle_visible), .doc = "Toggle selected layer/shape visibility" },
    .{ .name = "toggle_lock", .tag = @tagName(Msg.figure_toggle_lock), .doc = "Toggle selected layer lock" },
} ++ blk: {
    var definitions: [nudges.len]plugin.action_api.Def = undefined;
    for (nudges, 0..) |nudge, index| definitions[index] = .{ .name = modes.shortName("figure", @tagName(nudge.message)), .tag = @tagName(nudge.message), .doc = nudge.doc };
    break :blk definitions;
};

pub const actions = canvas_actions ++ sketches.actions ++ drawing.actions ++ color_picker.actions ++ weight.actions ++ pose.actions ++ filmstrip.actions;

/// The figure editor's keys, of the mode `figure`, over `global`'s. Its `C-x` hides `global`'s
/// chords that begin with it while a figure panel has the focus.
pub const figure_keys = [_]mesha.keybinds.KeyDef{
    .{ .chord = "v", .action = .{ "figure", "tool_select" } },
    .{ .chord = "h", .action = .{ "figure", "tool_hand" } },
    .{ .chord = "b", .action = .{ "figure", "tool_bone" } },
    .{ .chord = "k", .action = .{ "figure", "tool_stick" } },
    .{ .chord = "p", .action = .{ "figure", "tool_pencil" } },
    .{ .chord = "S-p", .action = .{ "figure", "tool_pen" } },
    .{ .chord = "r", .action = .{ "figure", "tool_rect" } },
    .{ .chord = "o", .action = .{ "figure", "tool_ellipse" } },
    .{ .chord = "l", .action = .{ "figure", "tool_line" } },
    .{ .chord = "y", .action = .{ "figure", "tool_polygon" } },
    .{ .chord = "j", .action = .{ "figure", "tool_joint_fill" } },
    .{ .chord = "g", .action = .{ "figure", "tool_gradient" } },
    .{ .chord = "i", .action = .{ "figure", "tool_eyedropper" } },
    .{ .chord = "S-i", .action = .{ "figure", "tool_ik" } },
    .{ .chord = "e", .action = .{ "figure", "tool_eraser" } },
    .{ .chord = "x", .action = .{ "figure", "color_target_toggle" } },
    .{ .chord = "C-z", .action = .{ "figure", "undo" } },
    .{ .chord = "C-S-z", .action = .{ "figure", "redo" } },
    .{ .chord = "C-c", .action = .{ "figure", "copy" } },
    .{ .chord = "C-x", .action = .{ "figure", "cut" } },
    .{ .chord = "C-v", .action = .{ "figure", "paste" } },
    .{ .chord = "C-d", .action = .{ "figure", "duplicate" } },
    .{ .chord = "C-a", .action = .{ "figure", "select_all" } },
    .{ .chord = "M-a", .action = .{ "figure", "deselect" } },
    .{ .chord = "page_down", .action = .{ "figure", "select_next" } },
    .{ .chord = "page_up", .action = .{ "figure", "select_previous" } },
    .{ .chord = "delete", .action = .{ "figure", "delete_bone" } },
    .{ .chord = "backspace", .action = .{ "figure", "delete_bone" } },
    .{ .chord = "C-delete", .action = .{ "figure", "delete_branch" } },
    .{ .chord = "C-g", .action = .{ "figure", "folder_group" } },
    .{ .chord = "C-S-g", .action = .{ "figure", "folder_ungroup" } },
    .{ .chord = "C-S-n", .action = .{ "figure", "layer_add" } },
    .{ .chord = "C-right_bracket", .action = .{ "figure", "shape_forward" } },
    .{ .chord = "C-left_bracket", .action = .{ "figure", "shape_backward" } },
    .{ .chord = "M-C-right_bracket", .action = .{ "figure", "shape_front" } },
    .{ .chord = "M-C-left_bracket", .action = .{ "figure", "shape_back" } },
    .{ .chord = "C-S-h", .action = .{ "figure", "toggle_visible" } },
    .{ .chord = "C-S-l", .action = .{ "figure", "toggle_lock" } },
    .{ .chord = "f2", .action = .{ "figure", "rename" } },
    .{ .chord = "m", .action = .{ "figure", "mirror_branch" } },
    .{ .chord = "left", .action = .{ "figure", "nudge_left" } },
    .{ .chord = "right", .action = .{ "figure", "nudge_right" } },
    .{ .chord = "up", .action = .{ "figure", "nudge_up" } },
    .{ .chord = "down", .action = .{ "figure", "nudge_down" } },
    .{ .chord = "S-left", .action = .{ "figure", "nudge_left_large" } },
    .{ .chord = "S-right", .action = .{ "figure", "nudge_right_large" } },
    .{ .chord = "S-up", .action = .{ "figure", "nudge_up_large" } },
    .{ .chord = "S-down", .action = .{ "figure", "nudge_down_large" } },
    .{ .chord = "enter", .action = .{ "figure", "chain_finish" } },
    .{ .chord = "escape", .action = .{ "figure", "gesture_cancel" } },
    .{ .chord = "S-1", .action = .{ "figure", "view_fit" } },
    .{ .chord = "home", .action = .{ "figure", "view_fit" } },
    .{ .chord = "S-2", .action = .{ "figure", "view_selection" } },
    .{ .chord = "kp_decimal", .action = .{ "figure", "view_selection" } },
    .{ .chord = "C-0", .action = .{ "figure", "view_reset" } },
    .{ .chord = "C-equal", .action = .{ "figure", "zoom_in" } },
    .{ .chord = "C-minus", .action = .{ "figure", "zoom_out" } },
    .{ .chord = "C-apostrophe", .action = .{ "figure", "toggle_grid" } },
    .{ .chord = "C-semicolon", .action = .{ "figure", "toggle_bones" } },
    .{ .chord = "C-s", .action = .{ "figure", "save" } },
    .{ .chord = "C-S-s", .action = .{ "figure", "save_as" } },
    .{ .chord = "C-w", .action = .{ "figure", "close" } },
    .{ .chord = "tab", .action = .{ "figure", "focus_mode" } },
    .{ .chord = "f6", .action = .{ "figure", "key_panel_next" } },
    .{ .chord = "1", .action = .{ "figure", "mode_design" } },
    .{ .chord = "comma", .action = .{ "figure", "frame_previous" } },
    .{ .chord = "period", .action = .{ "figure", "frame_next" } },
    .{ .chord = "insert", .action = .{ "figure", "key_add" } },
    .{ .chord = "S-f6", .action = .{ "figure", "key_delete" } },
    .{ .chord = "S-o", .action = .{ "figure", "toggle_onion" } },
    .{ .chord = "M-r", .action = .{ "figure", "pose_reset" } },
    .{ .chord = "2", .action = .{ "figure", "mode_rig" } },
    .{ .chord = "3", .action = .{ "figure", "mode_animate" } },
    .{ .chord = "w", .action = .{ "figure", "mode_weight" } },
};

/// A tool's action and the tool it chooses: `figure_tool_<tool>`.
pub const ToolChoice = struct { tag: Atom, tool: Atom };

const tool_prefix = "figure_tool_";
const mode_prefix = "figure_mode_";

/// Every tool action the editor defines.
pub const tool_actions = blk: {
    @setEvalBranchQuota(100_000);
    var count: usize = 0;
    for (actions) |action| {
        if (std.mem.startsWith(u8, action.tag, tool_prefix)) count += 1;
    }
    var tools: [count]ToolChoice = undefined;
    var index: usize = 0;
    for (actions) |action| {
        if (!std.mem.startsWith(u8, action.tag, tool_prefix)) continue;
        tools[index] = .{ .tag = Atom.from(action.tag), .tool = Atom.from(action.tag[tool_prefix.len..]) };
        index += 1;
    }
    break :blk tools;
};

/// Every mode action the editor defines: `figure_mode_<mode>`.
const mode_tags = blk: {
    @setEvalBranchQuota(100_000);
    var count: usize = 0;
    for (actions) |action| {
        if (std.mem.startsWith(u8, action.tag, mode_prefix)) count += 1;
    }
    var tags: [count]Atom = undefined;
    var index: usize = 0;
    for (actions) |action| {
        if (!std.mem.startsWith(u8, action.tag, mode_prefix)) continue;
        tags[index] = Atom.from(action.tag);
        index += 1;
    }
    break :blk tags;
};

/// The tool a tool action chooses, or null for any other tag.
pub fn toolOf(tag: Atom) ?Atom {
    for (tool_actions) |action| {
        if (action.tag == tag) return action.tool;
    }
    return null;
}

/// Whether `tag` changes the tool or the mode.
fn changesTool(tag: Atom) bool {
    return toolOf(tag) != null or std.mem.indexOfScalar(Atom, &mode_tags, tag) != null;
}

pub fn ensure(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    // The editor's systems name atoms by constant from here on; reading them back needs this.
    try atoms.tryInternAll(&vocabulary);
    try Requests.ensure(try mem.tableScratchAllocator(), atoms, tables, commands_table_name);
    try session.ensure(mem, atoms, tables);
    try gesture.ensure(mem, atoms, tables);
    try scrub.ensure(mem, atoms, tables);
    try context_menu.ensure(mem, atoms, tables);
    try preview.ensure(tables, atoms);
    try asks.ensure(mem, atoms, tables);
    try gesture.ensureHeld(mem, atoms, tables);
    try drawing.ensure(mem, atoms, tables);
    try color_picker.ensure(mem, atoms, tables);
    try weight.ensure(mem, atoms, tables);
    try pose.ensure(mem, atoms, tables);
    try filmstrip.ensure(mem, atoms, tables);
    const modes_scratch = try mem.tableScratchAllocator();
    try modes.ensurePanelModes(modes_scratch, atoms, tables, panel_modes_table_name);
}

/// Points the arrow keys at the figure panel that took the focus: Layers, Properties, or the
/// canvas for the stage and the sequencer. Other panels leave them where they were.
pub fn followPanelFocus(tables: *Table.Registry, id: Atom) void {
    if (!isFigureView(id)) return;
    if (tables.findByName(Atom.from(session.observed_name)) == null) return;
    const keys = session.observed(tables).key_panel;
    keys.* = if (id == Atom.from(outliner_id) or id == Atom.from(inspector_id)) id else session.none;
}

/// Whether keyboard focus is on one of the figure editor's panels rather than another panel.
pub fn isFigureView(id: Atom) bool {
    for ([_][]const u8{ canvas_id, outliner_id, inspector_id, sequencer_id }) |name| {
        if (id == Atom.from(name)) return true;
    }
    return false;
}

/// Where the figure stage's content is in the window, or null while it is not shown.
pub fn stageViewport(tables: *Table.Registry, atoms: *Atom.Registry) ?panels_mod.Rect {
    if (tables.findByName(Atom.from(panels_mod.state_table_name)) == null) return null;
    return panel_frame.contentRect(tables, atoms, Atom.from(canvas_id));
}

pub fn stageChrome(observed: session.ObservedView) geometry.StageChrome {
    return .{ .focus = if (observed.focus_mode.* != 0) .on else .off };
}

/// Where one of the editor's panels shows its content, or null while it is closed or hidden.
fn panelViewport(tables: *Table.Registry, atoms: *Atom.Registry, id: []const u8) ?panels_mod.Rect {
    if (tables.findByName(Atom.from(panels_mod.state_table_name)) == null) return null;
    return panel_frame.contentRect(tables, atoms, Atom.from(id));
}

fn timelineViewport(tables: *Table.Registry, atoms: *Atom.Registry) ?panels_mod.Rect {
    return panelViewport(tables, atoms, sequencer_id);
}

pub fn canvasViewport(tables: *Table.Registry, atoms: *Atom.Registry) ?panels_mod.Rect {
    const stage = stageViewport(tables, atoms) orelse return null;
    const layout = geometry.stageLayout(stage, stageChrome(session.observed(tables)));
    if (layout.canvas.w <= 0 or layout.canvas.h <= 0) return null;
    return layout.canvas;
}

/// The transform `canvas.render` will draw the figure under at `center` and `zoom`, as a kernel
/// knows it before the drawing: the stage panel's target begins at the panel's corner, its content
/// is offset in it (`panel_frame.beginContent`), and the camera is over the canvas laid out in
/// that content (`geometry.drawTransform`). Null while the stage panel is not laid out.
pub fn canvasDrawTransform(tables: *Table.Registry, atoms: *Atom.Registry, center: session.Vec2, zoom: f32) ?math.Affine2f {
    if (tables.findByName(Atom.from(panels_mod.state_table_name)) == null) return null;
    const stage_id = Atom.from(canvas_id);
    const panel = panels_mod.panelFor(tables, atoms, stage_id) orelse return null;
    const content = panel_frame.contentRect(tables, atoms, stage_id) orelse return null;
    const local_stage = panels_mod.Rect{ .w = content.w, .h = content.h };
    const layout = geometry.stageLayout(local_stage, stageChrome(session.observed(tables)));
    const content_offset: math.Affine2f = .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = content.x - panel.frame.x, .ty = content.y - panel.frame.y };
    return geometry.drawTransform(content_offset, layout.canvas, center, zoom);
}

pub fn screenToDocument(tables: *Table.Registry, atoms: *Atom.Registry, x: f32, y: f32) ?session.Vec2 {
    const rect = canvasViewport(tables, atoms) orelse return null;
    const editor = session.get(tables);
    if (!std.math.isFinite(editor.view_zoom.*) or editor.view_zoom.* <= 0) return null;
    return geometry.toDocument(rect, editor.view_center.*, editor.view_zoom.*, .{ .x = x, .y = y });
}

pub fn openWorkspace(tables: *Table.Registry, atoms: *Atom.Registry) void {
    workspaces.arrange(tables, atoms, .figure);
}

fn figureBoundsSettled(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    const editor = session.get(tables);
    const info = session.definitionInfo(tables, atoms, editor.doc.*) orelse return false;
    const capture = session.observed(tables);
    return capture.bounds_doc.* == editor.doc.* and capture.bounds_revision.* == info.authored_revision;
}

/// Mid-gesture the frame keeps its last extent and catches up when the drag settles.
pub fn syncFigureBounds(tables: *Table.Registry, atoms: *Atom.Registry) void {
    if (figureBoundsSettled(tables, atoms)) return;
    const editor = session.get(tables);
    if (editor.gesture_active.* != 0 or gesture.busy(gesture.get(tables))) return;
    const info = session.definitionInfo(tables, atoms, editor.doc.*) orelse return;
    if (info.state != .ready) return;
    const capture = session.observed(tables);
    // Until the editor's watch of the document is answered, there is nothing to settle.
    const measured = watches.extent(tables, editor.doc.*) orelse return;
    const extent = if (measured.failure.check()) measured.bounds else |err| no_extent: {
        // Not ready may pass by itself, unless this revision was rejected outright. Anything
        // else is final for the revision: it shows no frame, and a pending fit can still finish.
        const rejected = info.rejected_revision == info.authored_revision;
        if (err == error.NotReady and !rejected) return;
        break :no_extent null;
    };
    capture.bounds_doc.* = editor.doc.*;
    capture.bounds_revision.* = info.authored_revision;
    capture.bounds_present.* = @intFromBool(extent != null);
    if (extent) |found| {
        capture.bounds_min.* = found.min;
        capture.bounds_max.* = found.max;
    }
}

/// What the view frames for "zoom to selection": selected artwork as drawn, plus selected bones.
fn selectionExtent(tables: *Table.Registry, atoms: *Atom.Registry) !?geometry.Bounds {
    const editor = session.get(tables);
    var result: ?geometry.Bounds = null;
    if (session.atRest(editor)) result = try drawing.selectionBounds(tables, atoms);
    const evaluated_bones = (try preview.evaluation(tables, atoms)).bones;
    var rows = session.selections(tables).query();
    while (rows.next()) |row| {
        if (row.view.doc.* != editor.doc.* or row.view.kind.* != names.bone) continue;
        const bone = session.findById(session.api.EvaluatedBone, evaluated_bones, row.view.id.*) orelse continue;
        const joints = geometry.bounds(&.{ bone.origin, bone.tip }).?;
        result = if (result) |existing| .{
            .min = .{ .x = @min(existing.min.x, joints.min.x), .y = @min(existing.min.y, joints.min.y) },
            .max = .{ .x = @max(existing.max.x, joints.max.x), .y = @max(existing.max.y, joints.max.y) },
        } else joints;
    }
    return result;
}

pub fn fitCanvas(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const editor = session.get(tables);
    // A pending fit waits for its document's extent rather than framing the previous one.
    if (session.observed(tables).bounds_doc.* != editor.doc.*) return;
    const camera = fittedCamera(tables, atoms, session.figureExtent(session.observed(tables), session.get(tables))) orelse return;
    editor.view_center.* = camera.center;
    editor.view_zoom.* = camera.zoom;
    editor.fit_pending.* = 0;
}

/// Frames `extent` in the canvas above the floating dock, so nothing fitted sits under it.
pub fn fittedCamera(tables: *Table.Registry, atoms: *Atom.Registry, extent: ?session.api.Bounds) ?geometry.Camera {
    const rect = canvasViewport(tables, atoms) orelse return null;
    const editor = session.get(tables);
    const dock = chrome.dockRect(editor.mode.*, rect);
    const covered = if (dock.h > 0) rect.y + rect.h - dock.y else 0;
    var clear = rect;
    clear.h = @max(1, rect.h - covered);
    var camera = geometry.fit(clear, extent);
    // The view center is the whole canvas's, half the covered band below the clear area's.
    camera.center.y += covered * 0.5 / camera.zoom;
    return camera;
}

pub fn activate(tables: *Table.Registry, atoms: *Atom.Registry, doc: Atom) void {
    view.clearCanvasHover(tables);
    preview.reopen(preview.state(tables));
    const editor = session.get(tables);
    // A fresh load restarts at the same revision, so the revision alone cannot show this is stale.
    session.observed(tables).bounds_doc.* = session.none;
    weight.discard(weight.config(tables), weight.boneStates(tables));
    drawing.clearPointEditing(session.get(tables), drawing.config(tables));
    drawing.clearCreation(drawing.config(tables));
    drawing.config(tables).tool_tap_remaining.* = 0;
    prompts.dismissError(session.get(tables), session.feedback(tables));
    prompts.inform(session.feedbackTable(tables), session.feedback(tables), "");
    editor.doc.* = doc;
    editor.pending_doc.* = session.none;
    editor.active_id.* = 0;
    editor.active_bone.* = 0;
    editor.active_kind.* = session.none;
    editor.fit_pending.* = 1;
    editor.inspector_field.* = 0;
    editor.outliner_scroll.* = 0;
    session.observed(tables).outliner_reveal.* = 1;
    editor.outliner_drag.* = 0;
    pose.config(tables).selected_pose.* = 0;
    pose.config(tables).ik_end.* = 0;
    drawing.config(tables).custom_pivot.* = 0;
    drawing.config(tables).pending_delete_layer.* = 0;
    editor.chain_mode.* = 0;
    editor.chain_parent.* = 0;
    editor.gesture_active.* = 0;
    editor.tx_active.* = 0;
    editor.active_layer.* = 0;
    if (session.readDefinition(tables, atoms, doc)) |definition| {
        if (definition.layers.len != 0) editor.active_layer.* = definition.layers[0].id;
    } else |_| {}
    var query = session.selections(tables).read();
    while (query.next()) |row| if (row.view.doc.* == doc and row.view.primary.* != 0) {
        selection.select(tables, atoms, row.view.kind.*, row.view.id.*, true, false);
        break;
    };
    openWorkspace(tables, atoms);
}

fn releasePointer(observed: session.ObservedView) void {
    observed.pointer_owner.* = @intFromEnum(session.PointerOwner.none);
}

fn rememberSelection(editor: session.View, observed: session.ObservedView, draft_table: session.DraftRows, selected: session.SelectionRows) void {
    observed.grouped_folder.* = 0;
    session.removeRows(draft_table.table, editor.doc.*);
    var query = selected.read();
    var index: u32 = 0;
    while (query.next()) |row| if (row.view.doc.* == editor.doc.*) {
        _ = draft_table.insert(session.Draft{
            .doc = editor.doc.*,
            .index = index,
            .ref_kind = row.view.kind.*,
            .ref_id = row.view.id.*,
            .p = .{ .x = @floatFromInt(row.view.primary.*), .y = 0 },
        }) catch return;
        index += 1;
    };
}

fn restoreRememberedSelection(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const editor = session.get(tables);
    selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
    const draft_table = session.drafts(tables);
    var primary: ?struct { kind: Atom, id: u32 } = null;
    var query = draft_table.read();
    while (query.next()) |row| if (row.view.doc.* == editor.doc.*) {
        selection.select(tables, atoms, row.view.ref_kind.*, row.view.ref_id.*, true, false);
        if (row.view.p.x != 0) primary = .{ .kind = row.view.ref_kind.*, .id = row.view.ref_id.* };
    };
    if (primary) |primary_item| selection.select(tables, atoms, primary_item.kind, primary_item.id, true, false);
}

/// Forgets the questions that hold input and the input held behind them: a press waiting for what
/// lies under it is dropped with what came after it.
fn dropHeldInput(tables: *Table.Registry) void {
    const asked = asks.rows(tables);
    asks.forgetHolding(asked);
    const held = gesture.heldInput(tables);
    held.clear();
}

pub fn cancel(tables: *Table.Registry, atoms: *Atom.Registry) void {
    dropHeldInput(tables);
    if (context_menu.close(context_menu.get(tables))) return;
    if (scrub.cancel(scrub.get(tables), drawing.config(tables), gesture.get(tables))) return;
    if (color_picker.cancel(color_picker.config(tables), gesture.get(tables))) return;
    const editor = session.get(tables);
    session.observed(tables).click_toggle_id.* = 0;
    if (editor.outliner_drag.* != 0) {
        editor.outliner_drag.* = 0;
        releasePointer(session.observed(tables));
        return;
    }
    const active = editor.tx_active.* != 0 or editor.gesture_active.* != 0 or editor.chain_mode.* != 0;
    const animation_edit = filmstrip.end(filmstrip.config(tables), .cancel);
    if (filmstrip.endScrub(filmstrip.config(tables))) editor.gesture_active.* = 0;
    const drag_state_before_cancel = gesture.get(tables);
    const drag_kind = gesture.kindOf(drag_state_before_cancel);
    const failed_drag = gesture.intentOf(drag_state_before_cancel) == .failure;
    const owned_drag = gesture.end(gesture.get(tables), .cancel);
    const pose_drag = owned_drag and drag_kind == .pose;
    if (pose_drag) {
        const drag_state = gesture.get(tables);
        const cancel_accepted = gesture.phaseOf(drag_state) == .draining and gesture.intentOf(drag_state) == .cancel;
        if (cancel_accepted) prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Cancelled with Esc");
    }
    pose.config(tables).ik_end.* = 0;
    weight.endTestRotation(session.get(tables), weight.config(tables), weight.boneStates(tables), .cancel);
    drawing.cancelSelectPivot(session.get(tables), drawing.config(tables));
    const weight_stroke = owned_drag and drag_kind == .weight;
    const transaction_owned = animation_edit or owned_drag;
    if (!transaction_owned and editor.tx_active.* != 0) transport.send(tables, atoms, .{ .cancel = .{ .doc = editor.doc.* } }) catch |err| {
        prompts.status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
        return;
    };
    // Only select and bone-tool presses snapshot the selection; pose, weight,
    // Animate and drawing-tool presses return before rememberSelection.
    // Handle drags leave the selection unchanged; restoring it would expire its pivot.
    const select_handle_drag = editor.gesture_kind.* == names.select_scale or editor.gesture_kind.* == names.select_rotate or editor.gesture_kind.* == names.select_pivot;
    const restores_selection = active and !animation_edit and !weight_stroke and !pose_drag and !select_handle_drag and
        editor.tool.* != names.weight and !drawing.owns(editor.tool.*);
    if (restores_selection) {
        restoreRememberedSelection(tables, atoms);
    }
    drawing.cancelDraft(tables);
    drawing.config(tables).pending_delete_layer.* = 0;
    releasePointer(session.observed(tables));
    if (select_handle_drag) {
        view.setCanvasCursor(session.feedback(tables), .arrow);
    }
    if (owned_drag) gesture.settle(tables, atoms);
    if (animation_edit) filmstrip.settle(tables, atoms);
    if (!transaction_owned) editor.tx_active.* = 0;
    editor.gesture_active.* = 0;
    editor.chain_mode.* = 0;
    editor.chain_parent.* = 0;
    editor.reparent_active.* = 0;
    editor.snap_kind.* = session.none;
    if (!pose_drag and !failed_drag and active) prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Cancelled with Esc");
    // An idle explicit Escape dismisses the current error. Successful asynchronous
    // replies never dismiss it, and cancellation of a failed drag preserves it.
    if (!active and !owned_drag and !animation_edit) prompts.dismissError(session.get(tables), session.feedback(tables));
}

pub fn finish(tables: *Table.Registry, atoms: *Atom.Registry) void {
    color_picker.dismiss(color_picker.config(tables), gesture.get(tables));
    const editor = session.get(tables);
    session.observed(tables).click_toggle_id.* = 0;
    const animation_edit = filmstrip.end(filmstrip.config(tables), .commit);
    const owned_drag = gesture.end(gesture.get(tables), .commit);
    weight.endTestRotation(session.get(tables), weight.config(tables), weight.boneStates(tables), .commit);
    const transaction_owned = animation_edit or owned_drag;
    if (drawing.owns(editor.tool.*)) drawing.clear(session.drafts(tables), session.get(tables));
    if (!transaction_owned and editor.tx_active.* != 0) transport.send(tables, atoms, .{ .commit = .{ .doc = editor.doc.* } }) catch |err| {
        prompts.status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
        return;
    };
    releasePointer(session.observed(tables));
    if (owned_drag) gesture.settle(tables, atoms);
    if (!transaction_owned) editor.tx_active.* = 0;
    if (animation_edit) filmstrip.settle(tables, atoms);
    editor.gesture_active.* = 0;
    editor.chain_mode.* = 0;
    editor.chain_parent.* = 0;
    editor.snap_kind.* = session.none;
}

pub fn focusLost(tables: *Table.Registry, atoms: *Atom.Registry) void {
    view.clearCanvasHover(tables);
    // A press still waiting for its answer, which may have set nothing yet, ends here too.
    dropHeldInput(tables);
    const editor = session.get(tables);
    const drag_state = gesture.get(tables);
    const pose_drag = gesture.kindOf(drag_state) == .pose;
    const terminal_submitted = gesture.phaseOf(drag_state) == .awaiting_terminal;
    const rejected = gesture.intentOf(drag_state) == .failure;
    // A rejection keeps its own feedback; a submitted terminal can no longer be cancelled.
    const cancels_pose = editor.gesture_active.* != 0 and pose_drag and !terminal_submitted and !rejected;
    if (editor.gesture_active.* != 0 or gesture.busy(gesture.get(tables)) or filmstrip.config(tables).transaction.* != filmstrip.Transaction.none) cancel(tables, atoms) else if (editor.chain_mode.* != 0) finish(tables, atoms);
    if (cancels_pose) prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Cancelled: focus lost");
    editor.space_held.* = 0;
    view.setCanvasCursor(session.feedback(tables), .arrow);
}

fn begin(tables: *Table.Registry, atoms: *Atom.Registry, label: Atom) !void {
    const editor = session.get(tables);
    if (editor.tx_active.* != 0) return;
    try transport.send(tables, atoms, .{ .begin = .{ .doc = editor.doc.*, .label = label } });
    editor.tx_active.* = 1;
}

/// The frontmost of the shapes a hit test at `document_point` found, as a pick.
pub fn pickShape(found: []const figure.Hit, document_point: session.Vec2) ?geometry.Hit {
    if (found.len == 0) return null;
    return .{ .kind = names.shape, .id = found[0].object.id, .point = document_point };
}

// Selection hover and presses share the same visual stacking policy.
/// The bone Select picks at rest before artwork: in Rig, by its joints and then its shaft,
/// before the artwork under it, which is chosen there only to be bound. None in Design, which
/// picks artwork alone (`pickShape`).
pub fn pickBoneAtRest(editor: session.View, bones: []const session.api.EvaluatedBone, point: session.Vec2) ?geometry.Hit {
    if (editor.mode.* != names.rig) return null;
    return geometry.pickBone(bones, point, editor.view_zoom.*);
}

pub fn followsBone(shape: session.api.read.Shape) bool {
    return shape.kind == names.joint_fill or shape.kind == names.bone_stroke;
}

/// A press over the figure editor, at `held_point` in the document when it was held, else
/// where its screen point lies now.
fn pointerDown(tables: *Table.Registry, atoms: *Atom.Registry, event: input.MouseButtonMsg, held_point: ?session.Vec2) !void {
    session.feedback(tables).hover_pending.* = 0;
    const trace_zone = Zones.zone(Zone.pointer_down);
    defer trace_zone.end();
    const editor = session.get(tables);
    const screen_point = session.Vec2{ .x = event.x, .y = event.y };
    editor.gesture_button.* = @intFromEnum(event.button);
    if (timelineViewport(tables, atoms)) |timeline| {
        if (event.button == .left and try filmstrip.pointerDown(tables, atoms, timeline, screen_point)) return;
    }
    const rect = canvasViewport(tables, atoms) orelse return;
    if (geometry.contains(rect, screen_point)) session.observed(tables).key_panel.* = session.none;
    if (!geometry.contains(rect, screen_point) or session.definitionInfo(tables, atoms, editor.doc.*) == null) return;
    const document_point = held_point orelse screenToDocument(tables, atoms, event.x, event.y) orelse return;
    if (event.button == .left and try color_picker.pick(tables, atoms, document_point)) return;
    if (color_picker.isOpen(tables)) {
        color_picker.dismiss(color_picker.config(tables), gesture.get(tables));
        return;
    }
    const observed = session.observed(tables);
    observed.click_toggle_id.* = 0;
    editor.gesture_button.* = @intFromEnum(event.button);
    editor.gesture_start_screen.* = screen_point;
    editor.gesture_start.* = document_point;
    editor.gesture_current.* = document_point;
    editor.gesture_modifiers.* = @as(u8, if (event.modifiers.shift) 1 else 0) | @as(u8, if (event.modifiers.alt) 2 else 0);
    const hand_tool = editor.tool.* == names.hand;
    if (event.button == .middle or (event.button == .left and (editor.space_held.* != 0 or hand_tool))) {
        editor.fit_pending.* = 0;
        editor.gesture_active.* = 1;
        editor.gesture_kind.* = names.pan;
        editor.pan_center.* = editor.view_center.*;
        return;
    }
    if (event.button != .left) return;
    preview.ready(tables, atoms) catch |err| switch (err) {
        error.NotReady, error.Busy => return,
    };
    const evaluation = try preview.evaluation(tables, atoms);
    const evaluated_bones = evaluation.bones;
    const visible_bones = if (session.bonesShown(editor)) evaluated_bones else &.{};
    if (try pose.pointerDown(tables, atoms, document_point, event.modifiers.alt, event.modifiers.control)) return;
    const weight_pointer = gesture.Pointer{
        .point = document_point,
        .screen = screen_point,
        .modifiers = gesture.modifierBits(event.modifiers),
    };
    if (try weight.pointerDown(tables, atoms, weight_pointer)) return;
    if (try drawing.pointerDown(tables, atoms, document_point, event.modifiers.shift, event.modifiers.alt, event.modifiers.control, event.clicks, visible_bones)) return;
    if (editor.reparent_active.* != 0) {
        if (!session.bonesShown(editor)) {
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Show bones to choose a parent");
            return;
        }
        const parent = geometry.pickBone(visible_bones, document_point, editor.view_zoom.*);
        try transport.send(tables, atoms, .{ .reparent_bone = .{ .doc = editor.doc.*, .id = editor.active_bone.*, .parent = if (parent) |p| p.id else 0 } });
        editor.reparent_active.* = 0;
        return;
    }
    if (editor.tool.* == names.bone or editor.tool.* == names.stick) {
        if (editor.chain_mode.* == 0) rememberSelection(session.get(tables), session.observed(tables), session.drafts(tables), session.selections(tables));
        var parent: u32 = 0;
        var start = document_point;
        var connected = false;
        const options = session.rigOptions(tables);
        if (editor.chain_mode.* != 0 and editor.chain_parent.* != 0) {
            if (session.findById(session.api.EvaluatedBone, evaluated_bones, editor.chain_parent.*)) |bone| {
                parent = bone.id;
                if (options.connected.* != 0) {
                    start = bone.tip;
                    connected = true;
                }
            }
        } else if (!event.modifiers.alt and geometry.pickJoint(visible_bones, document_point, editor.view_zoom.*) != null) {
            const joint = geometry.pickJoint(visible_bones, document_point, editor.view_zoom.*).?;
            parent = joint.id;
            start = joint.point;
            connected = options.connected.* != 0 and joint.sub == 1;
        } else if (geometry.pickBone(visible_bones, document_point, editor.view_zoom.*)) |bone| {
            parent = bone.id;
        }
        editor.gesture_start.* = start;
        editor.gesture_current.* = start;
        editor.gesture_parent.* = parent;
        editor.gesture_connected.* = @intFromBool(connected);
        editor.snap_kind.* = session.none;
        editor.snap_id.* = 0;
        editor.snap_point.* = start;
        editor.gesture_kind.* = names.construct;
        editor.gesture_active.* = 1;
        editor.chain_mode.* = 1;
        try begin(tables, atoms, names.bone_chain);
        return;
    }
    const press = gesture.Pointer{
        .point = document_point,
        .screen = screen_point,
        .modifiers = gesture.modifierBits(event.modifiers),
    };
    // A double-click edits the points of the artwork under it, which the host is asked for.
    if (editor.tool.* == names.select and editor.mode.* == names.design and event.clicks >= 2) {
        try asks.hitTest(tables, atoms, system(), .{ .purpose = .point_edit_press, .point = document_point, .value = press.modifiers });
        return;
    }
    try beginSelectPress(tables, atoms, press, null);
}

/// A Select press that no other tool took: a handle of the selection's, else a bone in Rig,
/// else what the host finds under it, `found` when already asked, else asked for
/// (`selectPressAnswered` goes on).
fn beginSelectPress(tables: *Table.Registry, atoms: *Atom.Registry, press: gesture.Pointer, found: ?[]const figure.Hit) !void {
    const editor = session.get(tables);
    rememberSelection(session.get(tables), session.observed(tables), session.drafts(tables), session.selections(tables));
    const select_transform = try drawing.beginSelectTransform(tables, atoms, press);
    editor.gesture_active.* = 1;
    if (select_transform) return;
    const evaluation = try preview.evaluation(tables, atoms);
    if (pickBoneAtRest(editor, evaluation.bones, press.point)) |bone| {
        try pressPicked(tables, atoms, press, bone);
        return;
    }
    const hits = found orelse {
        // Until the answer, a release has no gesture of an earlier press's to end.
        editor.gesture_kind.* = session.none;
        try asks.hitTest(tables, atoms, system(), .{ .purpose = .select_press, .point = press.point, .value = press.modifiers });
        return;
    };
    try pressPicked(tables, atoms, press, pickShape(hits, press.point));
}

/// The press of `answer` as the canvas took it.
fn answeredPress(editor: session.View, answer: asks.Answer) gesture.Pointer {
    return .{ .point = answer.point, .screen = editor.gesture_start_screen.*, .modifiers = @truncate(answer.value) };
}

/// A double-click edits the points of the artwork the host found under it; anywhere else it is
/// a Select press.
fn pointEditPressAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    const editor = session.get(tables);
    if (editor.tool.* != names.select or editor.mode.* != names.design) return;
    try answer.failure.check();
    const found = answer.hits();
    if (pickShape(found, answer.point)) |hit| {
        const entered = try drawing.beginPointEditing(tables, atoms, hit.id);
        if (entered) {
            view.clearCanvasHover(tables);
            return;
        }
    }
    const press = answeredPress(editor, answer);
    try beginSelectPress(tables, atoms, press, found);
}

/// A Select press goes on with the artwork the host found under it, unless it was cancelled.
fn selectPressAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    const editor = session.get(tables);
    if (editor.tool.* != names.select or editor.gesture_active.* == 0) return;
    answer.failure.check() catch |err| {
        editor.gesture_active.* = 0;
        return err;
    };
    const press = answeredPress(editor, answer);
    const picked = pickShape(answer.hits(), answer.point);
    try pressPicked(tables, atoms, press, picked);
}

/// Selects what a Select press picked, and starts dragging it: a bone's joint, or artwork in
/// Design. Nothing picked starts a marquee.
fn pressPicked(tables: *Table.Registry, atoms: *Atom.Registry, press: gesture.Pointer, picked: ?geometry.Hit) !void {
    const editor = session.get(tables);
    const observed = session.observed(tables);
    const shift = press.modifiers & gesture.Modifiers.shift != 0;
    const alt = press.modifiers & gesture.Modifiers.alt != 0;
    const hit = picked orelse {
        editor.gesture_kind.* = names.marquee;
        if (!shift and !alt) selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
        return;
    };
    const already = selection.contains(session.get(tables), session.selections(tables), hit.kind, hit.id);
    const subtract = alt and hit.kind != names.shape;
    const add = shift or (already and !subtract);
    selection.select(tables, atoms, hit.kind, hit.id, add, subtract);
    if (shift and already and !alt) {
        observed.click_toggle_kind.* = hit.kind;
        observed.click_toggle_id.* = hit.id;
    }
    editor.gesture_kind.* = names.selection;
    if (subtract) return;
    const definition = try session.readDefinition(tables, atoms, editor.doc.*);
    if (hit.kind == names.bone) {
        if (hit.sub > 1) return;
        const bone = session.findById(session.api.read.Bone, definition.bones, hit.id) orelse return error.MissingBone;
        const evaluation = try preview.evaluation(tables, atoms);
        const transformed = session.findById(session.api.EvaluatedBone, evaluation.bones, hit.id) orelse return error.MissingBone;
        const joint_kind: gesture.Kind = if (hit.sub == 0) .bone_root else .bone_tip;
        editor.gesture_kind.* = if (hit.sub == 0) names.bone_root else names.bone_tip;
        editor.gesture_origin.* = transformed.origin;
        editor.gesture_parent.* = bone.parent;
        editor.gesture_local.* = bone.local;
        editor.gesture_rotation.* = bone.rotation;
        editor.gesture_length.* = bone.length;
        editor.gesture_scale.* = bone.scale;
        try gesture.begin(gesture.get(tables), .{ .kind = joint_kind, .doc = editor.doc.*, .pointer = press });
    } else {
        const shape = session.findById(session.api.read.Shape, definition.shapes, hit.id) orelse return error.MissingShape;
        if (followsBone(shape)) {
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "This artwork follows its bones; move a bone instead");
            return;
        }
        // Rig selects artwork to bind it; Design moves it.
        if (editor.mode.* != names.design) return;
        const kind: gesture.Kind = if (alt) .duplicate_shapes else .move_shapes;
        try gesture.begin(gesture.get(tables), .{ .kind = kind, .doc = editor.doc.*, .pointer = press });
        const kind_name = if (kind == .duplicate_shapes) "duplicate_shapes" else "move_shapes";
        editor.gesture_kind.* = Atom.from(kind_name);
    }
}

/// The pointer moving, at `held_point` in the document when it was held, else where its screen
/// point lies now.
fn pointerMove(tables: *Table.Registry, atoms: *Atom.Registry, event: input.MouseMoveMsg, held_point: ?session.Vec2) !void {
    const trace_zone = Zones.zone(Zone.pointer_move);
    defer trace_zone.end();
    const editor = session.get(tables);
    if (try filmstrip.pointerMove(tables, atoms, event.x)) return;
    if (editor.gesture_active.* == 0) {
        // Over the timeline, the pointer shows what a key changes rather than picking artwork.
        if (filmstrip.hover(filmstrip.config(tables), session.get(tables), timelineViewport(tables, atoms), .{ .x = event.x, .y = event.y })) return;
        const feedback = session.feedback(tables);
        feedback.hover_screen.* = .{ .x = event.x, .y = event.y };
        feedback.hover_shift.* = @intFromBool(event.modifiers.shift);
        view.requestCanvasHover(tables);
        return;
    }
    const document_point = held_point orelse screenToDocument(tables, atoms, event.x, event.y) orelse return;
    editor.hover_point.* = document_point;
    const kind = editor.gesture_kind.*;
    const observed = session.observed(tables);
    if (observed.click_toggle_id.* != 0) {
        const screen_point = session.Vec2{ .x = event.x, .y = event.y };
        const distance = geometry.distance(editor.gesture_start_screen.*, screen_point);
        if (distance >= 3) observed.click_toggle_id.* = 0;
    }
    const pointer = gesture.Pointer{
        .point = document_point,
        .screen = .{ .x = event.x, .y = event.y },
        .modifiers = gesture.modifierBits(event.modifiers),
    };
    if (try weight.pointerMove(tables, atoms, pointer)) {
        editor.gesture_current.* = document_point;
        return;
    }
    drawing.sweepEraser(tables, atoms, document_point);
    if (gesture.record(gesture.get(tables), pointer)) {
        editor.gesture_current.* = document_point;
        return;
    }
    editor.gesture_current.* = document_point;
    if (drawing.moveSelectPivot(session.get(tables), drawing.config(tables), document_point)) return;
    if (kind == names.pan) {
        const delta = math.Vec2f.sub(.{ .x = event.x, .y = event.y }, editor.gesture_start_screen.*);
        editor.view_center.* = math.Vec2f.sub(editor.pan_center.*, math.Vec2f.scale(delta, 1 / editor.view_zoom.*));
        return;
    }
    if (try drawing.pointerMove(tables, document_point, event.modifiers.shift, event.modifiers.alt, event.modifiers.control)) return;
    if (kind == names.construct) {
        const result: geometry.Snap = snapped: {
            const evaluation = preview.evaluation(tables, atoms) catch break :snapped .{ .point = document_point };
            const visible_bones = if (session.bonesShown(editor)) evaluation.bones else &.{};
            const previous = geometry.Snap{
                .kind = session.enumFromAtom(geometry.SnapKind, editor.snap_kind.*) orelse .none,
                .id = editor.snap_id.*,
                .point = editor.snap_point.*,
            };
            const options = session.rigOptions(tables);
            const snap_options = geometry.SnapOptions{
                .joints = options.snap_joints.* != 0,
                .midpoints = options.snap_midpoints.* != 0,
                .axes = options.snap_axes.* != 0,
                .lengths = options.snap_lengths.* != 0,
                .grid = if (options.snap_grid.* != 0) geometry.gridStep(editor.view_zoom.*) else null,
            };
            const snap_mode: geometry.SnapMode = if (event.modifiers.alt) .bypass else .enabled;
            break :snapped geometry.snapEndpoint(editor.gesture_start.*, document_point, editor.view_zoom.*, visible_bones, snap_options, previous, snap_mode);
        };
        editor.gesture_current.* = result.point;
        editor.snap_kind.* = Atom.from(@tagName(result.kind));
        editor.snap_id.* = result.id;
        editor.snap_point.* = result.point;
        return;
    }
}

/// Select-move and joint drags wait for 3 screen pixels before their first preview.
fn dragStarted(editor: session.View, drag: gesture.Drag) bool {
    if (editor.tx_active.* != 0) return true;
    const screen_distance = geometry.distance(drag.latest.screen, drag.origin_screen);
    return screen_distance >= 3;
}

/// Parent-local frame of a bone's authored channels; identity for roots.
fn parentInverse(evaluated_bones: []const session.api.EvaluatedBone, parent: u32) !math.Affine2f {
    if (parent == 0) return math.Affine2f.identity;
    const parent_bone = session.findById(session.api.EvaluatedBone, evaluated_bones, parent) orelse return error.MissingParent;
    return parent_bone.world.inverse() orelse error.InvalidTransform;
}

pub const MoveOperation = enum { move, duplicate };

/// Restores the press-time document, then moves or duplicates by the whole drag delta.
pub fn previewMoveShapes(tables: *Table.Registry, atoms: *Atom.Registry, drag: gesture.Drag, operation: MoveOperation) !void {
    const editor = session.get(tables);
    if (!dragStarted(editor, drag)) return;
    const frame_scratch = try tables.memory.frameScratchAllocator();
    const frame_allocator = frame_scratch.allocator;
    var items: std.ArrayListUnmanaged(plugin.figure_api.Selection) = .empty;
    const definition = try session.readDefinition(tables, atoms, drag.doc);
    const selection_table = session.selections(tables);
    var query = selection_table.read();
    while (query.next()) |row| {
        if (row.view.doc.* != drag.doc or row.view.kind.* != names.shape) continue;
        const shape = session.findById(session.api.read.Shape, definition.shapes, row.view.id.*) orelse return error.MissingShape;
        if (followsBone(shape)) {
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Bone-linked artwork stays with its bones");
            continue;
        }
        const item = plugin.figure_api.Selection{ .kind = row.view.kind.*, .id = row.view.id.* };
        try items.append(frame_allocator, item);
    }
    if (items.items.len == 0) return;
    const constraint: geometry.MoveConstraint = if (drag.latest.modifiers & gesture.Modifiers.shift != 0) .axis else .none;
    const delta = geometry.moveDelta(drag.origin, drag.latest.point, constraint);
    const label = if (operation == .duplicate) names.duplicate_selection else names.move_selection;
    try gesture.openTransaction(tables, atoms, label);
    if (operation == .duplicate) {
        const ids = try frame_allocator.alloc(u32, items.items.len);
        for (items.items, ids) |item, *id| id.* = item.id;
        try gesture.submitPreview(tables, atoms, .absolute, &.{.{ .duplicate_shapes = .{ .doc = drag.doc, .ids = ids, .delta = delta } }});
        gesture.get(tables).duplicate_count.* = @intCast(ids.len);
    } else {
        try gesture.submitPreview(tables, atoms, .absolute, &.{.{ .move_selection = .{ .doc = drag.doc, .items = items.items, .delta = delta, .coordinate_policy = .bind } }});
    }
}

pub const JointHandle = enum { root, tip };

/// Absolute joint edits share the press-time document baseline.
pub fn previewJoint(tables: *Table.Registry, atoms: *Atom.Registry, drag: gesture.Drag, joint: JointHandle) !void {
    const editor = session.get(tables);
    if (!dragStarted(editor, drag)) return;
    const evaluation = try preview.evaluation(tables, atoms);
    const inverse = try parentInverse(evaluation.bones, editor.gesture_parent.*);
    const edit: plugin.figure_api.SetBone = switch (joint) {
        .root => root: {
            const pointer_delta = math.Vec2f.sub(drag.latest.point, drag.origin);
            const local_delta = inverse.applyVector(pointer_delta);
            const local = math.Vec2f.add(editor.gesture_local.*, local_delta);
            break :root .{ .doc = drag.doc, .id = editor.active_bone.*, .local = local };
        },
        .tip => tip: {
            const world_delta = math.Vec2f.sub(drag.latest.point, editor.gesture_origin.*);
            const delta = inverse.applyVector(world_delta);
            const length = @sqrt(delta.x * delta.x + delta.y * delta.y) / @abs(editor.gesture_scale.x);
            // A negative x scale mirrors the bone, so its tip points along -x.
            const mirror_offset: f32 = if (editor.gesture_scale.x < 0) std.math.pi else 0;
            const rotation = std.math.atan2(delta.y, delta.x) - mirror_offset;
            break :tip .{ .doc = drag.doc, .id = editor.active_bone.*, .rotation = rotation, .length = length };
        },
    };
    try gesture.openTransaction(tables, atoms, names.move_joint);
    try gesture.submitPreview(tables, atoms, .absolute, &.{.{ .set_bone = edit }});
}

/// Opens on release, because opening removes the captures that a held press still owns.
/// As in Figma, an object outside the selection replaces it, and empty canvas clears it: a bone
/// in Rig at once, artwork once the host has said what lies there (`menuPressAnswered`), which
/// is before the menu can be used.
fn openCanvasMenu(tables: *Table.Registry, atoms: *Atom.Registry, event: input.MouseButtonMsg, held_point: ?session.Vec2) !void {
    const editor = session.get(tables);
    const rect = canvasViewport(tables, atoms) orelse return;
    if (!geometry.contains(rect, .{ .x = event.x, .y = event.y })) return;
    if (session.atRest(editor) and editor.tool.* == names.select) {
        const document_point = held_point orelse screenToDocument(tables, atoms, event.x, event.y) orelse return;
        const evaluation = try preview.evaluation(tables, atoms);
        if (pickBoneAtRest(editor, evaluation.bones, document_point)) |bone| {
            selectForMenu(tables, atoms, bone);
        } else {
            try asks.hitTest(tables, atoms, system(), .{ .purpose = .menu_press, .point = document_point });
        }
    }
    context_menu.open(context_menu.get(tables), .canvas, event.x, event.y);
}

/// The canvas menu acts on what was right-clicked: an object outside the selection replaces it,
/// and empty canvas clears it.
fn selectForMenu(tables: *Table.Registry, atoms: *Atom.Registry, picked: ?geometry.Hit) void {
    const hit = picked orelse {
        selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
        return;
    };
    if (!selection.contains(session.get(tables), session.selections(tables), hit.kind, hit.id)) selection.select(tables, atoms, hit.kind, hit.id, false, false);
}

/// The canvas menu opened over the artwork the host found under the right-click, or none.
fn menuPressAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    const editor = session.get(tables);
    if (!session.atRest(editor) or editor.tool.* != names.select) return;
    try answer.failure.check();
    const picked = pickShape(answer.hits(), answer.point);
    selectForMenu(tables, atoms, picked);
}

/// A release, at `held_point` in the document when it was held, else where its screen point lies
/// now.
fn pointerUp(tables: *Table.Registry, atoms: *Atom.Registry, event: input.MouseButtonMsg, held_point: ?session.Vec2) !void {
    const trace_zone = Zones.zone(Zone.pointer_up);
    defer trace_zone.end();
    if (event.button == .right) {
        try openCanvasMenu(tables, atoms, event, held_point);
        return;
    }
    const editor = session.get(tables);
    if (editor.gesture_active.* == 0 or @intFromEnum(event.button) != editor.gesture_button.*) return;
    const release_move: input.MouseMoveMsg = .{ .x = event.x, .y = event.y, .modifiers = event.modifiers };
    try pointerMove(tables, atoms, release_move, held_point);
    const observed = session.observed(tables);
    if (observed.click_toggle_id.* != 0) {
        selection.select(tables, atoms, observed.click_toggle_kind.*, observed.click_toggle_id.*, true, true);
        observed.click_toggle_id.* = 0;
    }
    if (editor.gesture_kind.* == names.filmstrip_scrub) {
        _ = filmstrip.endScrub(filmstrip.config(tables));
        editor.gesture_active.* = 0;
        return;
    }
    if (editor.gesture_kind.* == names.filmstrip_hold) {
        _ = filmstrip.end(filmstrip.config(tables), .commit);
        editor.gesture_active.* = 0;
        filmstrip.settle(tables, atoms);
        return;
    }
    // The release sample recorded above is flushed by the next update before the commit.
    if (gesture.end(gesture.get(tables), .commit)) {
        editor.gesture_active.* = 0;
        gesture.settle(tables, atoms);
        return;
    }
    weight.endTestRotation(session.get(tables), weight.config(tables), weight.boneStates(tables), .commit);
    editor.gesture_active.* = 0;
    const kind = editor.gesture_kind.*;
    if (kind == names.select_pivot) return;
    if (kind == names.test_rotation) return;
    if (kind == names.pan) return;
    if (try drawing.pointerUp(tables, atoms)) return;
    if (kind == names.construct) {
        const end = editor.gesture_current.*;
        const start = editor.gesture_start.*;
        if (geometry.distance(start, end) * editor.view_zoom.* < 3) return;
        const evaluation = try preview.evaluation(tables, atoms);
        const inverse = try parentInverse(evaluation.bones, editor.gesture_parent.*);
        const delta = inverse.applyVector(math.Vec2f.sub(end, start));
        const rig_options = session.rigOptions(tables);
        const stroke_kind = if (rig_options.head.* != 0) names.circle_fill else names.line;
        try transport.send(
            tables,
            atoms,
            .{ .add_bone = .{
                .doc = editor.doc.*,
                .parent = editor.gesture_parent.*,
                .local = inverse.apply(start),
                .rotation = std.math.atan2(delta.y, delta.x),
                .length = @sqrt(delta.x * delta.x + delta.y * delta.y),
                .connected = editor.gesture_connected.* != 0,
                .make_stroke = editor.tool.* == names.stick,
                .layer = editor.active_layer.*,
                .stroke_kind = stroke_kind,
            } },
        );
    } else if (kind == names.marquee) {
        const rect = geometry.Bounds{
            .min = .{ .x = @min(editor.gesture_start.x, editor.gesture_current.x), .y = @min(editor.gesture_start.y, editor.gesture_current.y) },
            .max = .{ .x = @max(editor.gesture_start.x, editor.gesture_current.x), .y = @max(editor.gesture_start.y, editor.gesture_current.y) },
        };
        const evaluated_bones = (try preview.evaluation(tables, atoms)).bones;
        const subtract = editor.gesture_modifiers.* & 2 != 0;
        const bone_kind = names.bone;
        // A marquee gathers what its tab edits: bones in Rig, artwork elsewhere.
        if (editor.mode.* == names.rig) {
            for (evaluated_bones) |bone| {
                const bounds = geometry.bounds(&.{ bone.origin, bone.tip }).?;
                if (bounds.intersects(rect)) selection.select(tables, atoms, bone_kind, bone.id, true, subtract);
            }
        } else {
            // The host finds the artwork it touches; `marqueeAnswered` selects it.
            try asks.hitTest(tables, atoms, system(), .{ .purpose = .marquee, .point = rect.min, .rectangle = .{ .min = rect.min, .max = rect.max }, .value = @intFromBool(subtract) });
        }
    }
    editor.snap_kind.* = session.none;
}

/// Adds the artwork a released marquee touched to the selection, or takes it away.
fn marqueeAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    try answer.failure.check();
    const subtract = answer.value != 0;
    for (answer.hits()) |item| selection.select(tables, atoms, names.shape, item.object.id, true, subtract);
}

fn selectOutlinerItem(tables: *Table.Registry, atoms: *Atom.Registry, item: session.ItemEvent, extend: OutlinerExtend) !void {
    const editor = session.get(tables);
    if (extend == .keep_selected and selection.contains(session.get(tables), session.selections(tables), item.kind, item.id)) return;
    finish(tables, atoms);
    drawing.clearPointEditing(session.get(tables), drawing.config(tables));
    const selectable = item.kind == names.shape or item.kind == names.layer or item.kind == names.bone;
    if (extend == .toggle and selectable) {
        selection.select(tables, atoms, item.kind, item.id, true, selection.contains(session.get(tables), session.selections(tables), item.kind, item.id));
        return;
    }
    if (item.kind == names.clip) {
        try filmstrip.selectClip(tables, atoms, item.id);
        selection.select(tables, atoms, item.kind, item.id, false, false);
        return;
    }
    if (item.kind == names.pose) {
        pose.config(tables).selected_pose.* = item.id;
        selection.select(tables, atoms, item.kind, item.id, false, false);
        try filmstrip.editPose(tables, atoms, .{ .apply_pose = .{ .doc = editor.doc.*, .id = item.id } });
        return;
    }
    if (editor.tool.* == names.weight and item.kind == names.bone) {
        weight.pickBone(weight.config(tables), session.get(tables), item.id);
        return;
    }
    // Design edits no bones, so choosing one in Layers shows the tab that does.
    if (item.kind == names.bone and editor.mode.* == names.design) showAtRest(tables, atoms, names.rig, names.select);
    selection.select(tables, atoms, item.kind, item.id, false, false);
}

/// Shows Design or Rig with `tool`, letting go of what the tab before had in hand.
pub fn showAtRest(tables: *Table.Registry, atoms: *Atom.Registry, mode: Atom, tool: Atom) void {
    const editor = session.get(tables);
    finish(tables, atoms);
    if (editor.tool.* == names.edit_points) drawing.finishPointEditing(tables, atoms);
    weight.discard(weight.config(tables), weight.boneStates(tables));
    editor.mode.* = mode;
    editor.tool.* = tool;
    editor.reparent_active.* = 0;
    editor.hover_kind.* = session.none;
    editor.hover_id.* = 0;
}
/// Shift or Ctrl on a Layers row adds to or removes from the selection, as in Figma.
const OutlinerExtend = enum { replace, toggle, keep_selected };

/// Explicit tab clicks only filter the outliner view: no selection change,
/// clip preview, pose application or mode switch. The clicked category starts
/// from the top of its list; the one-shot `browsed` marker stops that render
/// from re-revealing the selected row through the previous category's
/// recorded row index or folder-tools offset.
pub fn browseOutlinerCategory(editor: session.View, outliner_tab: session.OutlinerTabView, observed: session.ObservedView, category: selection.Category) void {
    selection.setOutlinerTab(outliner_tab, category);
    editor.outliner_scroll.* = 0;
    observed.outliner_reveal.* = 0;
    outliner_tab.browsed.* = 1;
}

fn outlinerPointer(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, screen_point: session.Vec2, down: bool, extend: OutlinerExtend) !void {
    const editor = session.get(tables);
    const viewport = panelViewport(tables, atoms, outliner_id) orelse return;
    const category = selection.outlinerCategory(session.outlinerTab(tables));
    const folder_tools = category == .art;
    const x = screen_point.x - viewport.x;
    const y = screen_point.y - viewport.y - list.top(viewport.w, folder_tools);
    if (down) {
        editor.outliner_drag.* = 0;
        session.observed(tables).key_panel.* = Atom.from(outliner_id);
    }
    if (x < list.capture_left or x > viewport.w - list.capture_right or y < 0 or screen_point.y >= viewport.y + viewport.h) return;
    const frame_allocator = (try mem.frameScratchAllocator()).allocator;
    const outliner_nodes = try selection.categoryNodes(frame_allocator, tables, atoms, category);
    var row_y: f32 = 0;
    var row_index: usize = @min(editor.outliner_scroll.*, outliner_nodes.len);
    const visible_end = list.visibleEnd(outliner_nodes, row_index, viewport.h, list.top(viewport.w, folder_tools));
    while (row_index < visible_end) : (row_index += 1) {
        if (y < row_y) return;
        if (y < row_y + list.row_height) break;
        row_y += list.row_step;
    }
    if (row_index == visible_end) row_index = outliner_nodes.len;
    if (down) {
        if (row_index < outliner_nodes.len and outliner_nodes[row_index].kind == names.layer and !outliner_nodes[row_index].locked) {
            editor.outliner_drag.* = outliner_nodes[row_index].id;
            editor.outliner_drag_start.* = screen_point;
        } else if (row_index < outliner_nodes.len) {
            try selectOutlinerItem(tables, atoms, .{ .kind = outliner_nodes[row_index].kind, .id = outliner_nodes[row_index].id }, extend);
        }
        return;
    }
    const id = editor.outliner_drag.*;
    if (id == 0) return;
    if ((screen_point.x - editor.outliner_drag_start.x) * (screen_point.x - editor.outliner_drag_start.x) + (screen_point.y - editor.outliner_drag_start.y) * (screen_point.y - editor.outliner_drag_start.y) < 25) {
        try selectOutlinerItem(tables, atoms, .{ .kind = names.layer, .id = id }, extend);
        return;
    }
    var parent: u32 = 0;
    var before: u32 = 0;
    if (row_index < outliner_nodes.len) {
        const node = outliner_nodes[row_index];
        if (node.kind != names.layer or node.id == id or node.locked) return;
        const definition = try session.readDefinition(tables, atoms, editor.doc.*);
        const target = session.findById(session.api.read.Layer, definition.layers, node.id) orelse return;
        // Center of a folder enters it; its top edge inserts a root sibling.
        if (node.folder and y - row_y >= 8) parent = node.id else {
            parent = target.parent;
            before = node.id;
        }
    }
    try transport.send(tables, atoms, .{ .set_layer = .{ .doc = editor.doc.*, .id = id, .parent = parent, .before = before } });
}

fn pointerMoves(editor: session.View) input.MovePolicy {
    const samples_every_move = editor.tool.* == names.pencil or editor.tool.* == names.eraser or editor.tool.* == names.weight;
    return if (samples_every_move) .all else .latest;
}

/// Follows held presses before anything else can drop their messages, such as an open prompt.
fn trackPointerOwner(observed: session.ObservedView, received: sequencer.Message) void {
    const message = received.tag.to(Msg);
    const canvas_press = message == .figure_pointer_down;
    if (canvas_press or message == .figure_outliner_down) {
        const event = received.payloadAs(input.MouseButtonMsg) catch return;
        const owner: session.PointerOwner = if (canvas_press) .canvas else .outliner;
        observed.pointer_owner.* = @intFromEnum(owner);
        observed.pointer_button.* = @intFromEnum(event.button);
    }
    const ended = message == .figure_pointer_up or message == .figure_pointer_cancel or
        message == .figure_outliner_up or message == .figure_outliner_cancel;
    if (ended) observed.pointer_owner.* = @intFromEnum(session.PointerOwner.none);
}

pub fn contextMenuOpen(menu: context_menu.View) bool {
    return context_menu.isOpen(menu);
}

pub fn reconcileResult(tables: *Table.Registry, atoms: *Atom.Registry, metadata: session.Metadata, result: anyerror!?u32) void {
    const editor = session.get(tables);
    const doc = metadata.doc;
    // Attribution is read before reconciliation releases the request.
    const request_owner = gesture.requestOwner(gesture.get(tables), doc, metadata.request);
    const pose_owned = request_owner == .pose;
    const duplicate_owned = request_owner == .duplicate_shapes;
    const drag = gesture.get(tables);
    if (duplicate_owned and metadata.operation == .preview) {
        if (result) |created| {
            drag.duplicate_first.* = created orelse 0;
        } else |_| {}
    }
    // Keep source selection stable through previews. IDs advance on every reset;
    // only the last acknowledged range belongs to the successful commit.
    const duplicate_first = drag.duplicate_first.*;
    const duplicate_count = drag.duplicate_count.*;
    filmstrip.reconcileResult(tables, atoms, metadata, result);
    drawing.reconcileCreation(drawing.config(tables), session.get(tables), metadata, result);
    const failed = if (result) |_| false else |_| true;
    gesture.reconcileResult(tables, atoms, metadata, failed);
    weight.reconcileResult(weight.config(tables), session.get(tables), metadata, failed);
    const created = result catch |err| {
        if (doc == editor.doc.* or metadata.operation == .new_doc) {
            var error_buffer: [160]u8 = undefined;
            prompts.status(session.table(tables), session.get(tables), session.feedback(tables), if (pose_owned)
                std.fmt.bufPrint(&error_buffer, "Pose edit rejected: {s}", .{@errorName(err)}) catch @errorName(err)
            else if (editor.tool.* == names.weight)
                weight.describeRejection(err) orelse @errorName(err)
            else
                @errorName(err));
            if (editor.prompt_kind.* != session.none and !action_palette.requestOpen(tables, atoms)) prompts.reopen(tables.memory, tables, atoms);
        }
        if (doc == editor.doc.* and !(if (session.definitionInfo(tables, atoms, doc)) |info| info.transaction_open else false)) {
            editor.tx_active.* = 0;
            editor.gesture_active.* = 0;
            editor.chain_mode.* = 0;
            editor.chain_parent.* = 0;
        }
        return;
    };
    if (metadata.operation == .new_doc) {
        editor.prompt_kind.* = session.none;
        if (doc == session.none) return;
        activate(tables, atoms, doc);
        editor.tool.* = names.stick;
        return;
    }
    if (metadata.operation == .close_doc and doc == editor.doc.*) {
        drawing.clearCreation(drawing.config(tables));
        drawing.clearPointEditing(session.get(tables), drawing.config(tables));
        session.removeRows(session.selections(tables).table, doc);
        editor.doc.* = session.none;
        editor.active_id.* = 0;
        editor.active_bone.* = 0;
        editor.pending_doc.* = session.none;
        const documents = session.listDefinitions(tables, atoms) catch return;
        for (documents) |entry| {
            if (entry.info.state != .ready or !entry.info.editor_open) continue;
            activate(tables, atoms, entry.info.definition);
            return;
        }
        // Closing a document leaves the Figure workspace available for New/Open.
        return;
    }
    if (doc != editor.doc.*) return;
    if (duplicate_owned and metadata.operation == .commit and duplicate_first != 0) {
        selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
        const shape_kind = names.shape;
        for (0..duplicate_count) |index| {
            const id = duplicate_first + @as(u32, @intCast(index));
            selection.select(tables, atoms, shape_kind, id, true, false);
        }
    }
    switch (metadata.operation) {
        .add_ik, .set_ik => {
            pose.config(tables).ik_end.* = 0;
            editor.prompt_kind.* = session.none;
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "IK controller updated");
        },
        .save_pose => {
            if (created) |id| pose.config(tables).selected_pose.* = id;
            editor.prompt_kind.* = session.none;
        },
        .set_pose_channels, .set_pose, .set_ik_target, .pin_ik, .unpin_ik, .reset_pose, .apply_pose, .mirror_pose => {
            editor.prompt_kind.* = session.none;
        },
        .add_bone => {
            if (created) |id| {
                selection.select(tables, atoms, names.bone, id, false, false);
                editor.chain_parent.* = id;
                editor.chain_origin.* = editor.gesture_current.*;
            }
        },
        .add_shape, .paste_shapes => {
            if (created) |id| selection.select(tables, atoms, names.shape, id, false, false);
        },
        .add_layer => {
            if (created) |id| selection.select(tables, atoms, names.layer, id, false, false);
        },
        .group_layers => {
            if (created) |id| {
                selection.select(tables, atoms, names.layer, id, false, false);
                session.observed(tables).grouped_folder.* = id;
            }
        },
        .mirror_branch => {
            if (created) |id| selection.select(tables, atoms, names.bone, id, false, false);
        },
        .delete_bone => {
            editor.chain_mode.* = 0;
            editor.chain_parent.* = 0;
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Removed bones; their bound artwork was baked in place");
        },
        .set_bone, .set_shape, .set_layer, .reparent_bone => {
            editor.prompt_kind.* = session.none;
        },
        .undo, .redo => {
            // The selection moves with a group through its undo and redo.
            const grouped = session.observed(tables).grouped_folder.*;
            if (grouped != 0) {
                if (session.isValidObject(tables, atoms, doc, names.layer, grouped)) {
                    selection.select(tables, atoms, names.layer, grouped, false, false);
                } else restoreRememberedSelection(tables, atoms);
            }
            // Undo may undo a key load itself. Never auto-key a saved pose from
            // an unrelated restored working pose; a card click explicitly reloads it.
            const animation_settings = filmstrip.config(tables);
            animation_settings.playing.* = 0;
            animation_settings.key_selected.* = 0;
            animation_settings.loaded_pose.* = 0;
            animation_settings.preview.* = 1;
            editor.gesture_active.* = 0;
            editor.chain_mode.* = 0;
            editor.chain_parent.* = 0;
            editor.tx_active.* = 0;
        },
        else => {},
    }
    selection.prune(tables, atoms);
}
/// Applied synchronously after resource publication, before selection pruning.
/// Both UI and external MCP Save As operations use this result path.
pub fn renameDocument(tables: *Table.Registry, old: Atom, new: Atom) void {
    color_picker.renameDocument(color_picker.config(tables), color_picker.colorTargets(tables), old, new);
    const editor = session.get(tables);
    const observed = session.observed(tables);
    if (observed.doc.* == old) observed.doc.* = new;
    if (observed.bounds_doc.* == old) observed.bounds_doc.* = new;
    var pending = session.pendingCommands(tables).query();
    while (pending.next()) |row| if (row.view.current_doc.* == old) {
        row.view.current_doc.* = new;
        row.view.rename_observed.* = 1;
    };
    if (editor.pending_doc.* == old) editor.pending_doc.* = new;
    if (editor.pending_target.* == old) editor.pending_target.* = new;
    if (editor.doc.* == old) editor.doc.* = new;
    const animation_settings = filmstrip.config(tables);
    if (animation_settings.doc.* == old) animation_settings.doc.* = new;
    if (animation_settings.edit_doc.* == old) animation_settings.edit_doc.* = new;
    const weight_settings = weight.config(tables);
    if (weight_settings.doc.* == old) weight_settings.doc.* = new;
    const drawing_settings = drawing.config(tables);
    if (drawing_settings.edit_doc.* == old) drawing_settings.edit_doc.* = new;
    if (drawing_settings.creation_doc.* == old) drawing_settings.creation_doc.* = new;
    const drag_state = gesture.get(tables);
    if (drag_state.doc.* == old) drag_state.doc.* = new;
    const table_names = [_][]const u8{ session.draft_name, session.collapse_name, weight.bones_name };
    for (table_names) |name| {
        var owned_rows = tables.findByName(Atom.from(name)).?.query(struct { doc: *Atom });
        while (owned_rows.next()) |row| if (row.view.doc.* == old) {
            row.view.doc.* = new;
        };
    }
    if (editor.prompt_doc.* == old) editor.prompt_doc.* = new;
    var rows = session.selections(tables).query();
    while (rows.next()) |row| {
        if (row.view.doc.* == old) row.view.doc.* = new;
    }
}

/// A time frame: the information's and a tool tap's timers move.
fn takeInformationFrame(tables: *Table.Registry, received: sequencer.Message) !void {
    const frame = try received.payloadAs(time.FrameMsg);
    prompts.tickInformation(session.feedback(tables), frame.dt);
    if (std.math.isFinite(frame.dt) and frame.dt > 0) {
        const settings = drawing.config(tables);
        settings.tool_tap_remaining.* = @max(0, settings.tool_tap_remaining.* - frame.dt);
    }
}

/// One message the canvas or the editor hands it, `received`. False for one it does not take.
///
/// Input the canvas takes waits while a question decides what an earlier press does
/// (`gesture.hold`, `heldKind`), and is applied after the answer in the order it came, a press,
/// movement or release at the document point it had when it came. Input other systems take is
/// not ordered against it: the tool families' actions (`drawing`, `pose`, `weight`,
/// `filmstrip`), and what the editor hands here itself (Escape's `cancel`, the inspector's
/// fields), which reach their own systems' inboxes before the canvas could hold them. A message
/// that cannot be held cancels the gesture rather than be lost.
pub fn handle(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message) bool {
    trackPointerOwner(session.observed(tables), received);
    const held = gesture.heldInput(tables);
    const asked = asks.rows(tables);
    const holding = asks.holding(asked);
    const kind = heldKind(received.tag);
    if (!gesture.holds(held, holding, kind)) return dispatch(mem, tables, atoms, received, null);
    const point = heldPoint(tables, atoms, received, kind);
    gesture.hold(held, received, kind, point) catch |err| {
        prompts.status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
        cancel(tables, atoms);
    };
    return true;
}

/// How a message with `tag` waits behind a question: the canvas's own input waits, but not
/// what cancels what waits, nor what is not input (the clock, a listing, the chrome's report).
fn heldKind(tag: Atom) gesture.HeldKind {
    if (tag.to(asks.Msg) == .figure_answer) return .never;
    if (!claims(tag)) return .never;
    return switch (tag.to(Msg)) {
        .figure_pointer_move => .movement,
        .figure_pointer_down, .figure_pointer_up => .end,
        .figure_pointer_cancel, .figure_gesture_cancel, .figure_information_frame, .figure_chrome_info => .never,
        else => .other,
    };
}

/// Where in the document a press, movement or release held now lies; null for other input,
/// or for a pointer off the canvas's view.
fn heldPoint(tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message, kind: gesture.HeldKind) ?session.Vec2 {
    switch (kind) {
        .movement => {
            const event = received.payloadAs(input.MouseMoveMsg) catch return null;
            return screenToDocument(tables, atoms, event.x, event.y);
        },
        .end => {
            const event = received.payloadAs(input.MouseButtonMsg) catch return null;
            return screenToDocument(tables, atoms, event.x, event.y);
        },
        .never, .other => return null,
    }
}

/// What `handle` does with a message that does not wait, or with one held that waits no more,
/// `held_point` the document point a held press, movement or release had when it came.
fn dispatch(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message, held_point: ?session.Vec2) bool {
    const tag = received.tag;
    const message = tag.to(Msg);
    if (message == .figure_information_frame) {
        takeInformationFrame(tables, received) catch |err| received.unreadable(err);
        return true;
    }
    if (message == .figure_chrome_info) return true;
    if (prompts.handleMessage(mem, tables, atoms, received)) return true;
    if (message == .figure_scrub_up and action_palette.requestOpen(tables, atoms)) {
        _ = scrub.cancel(scrub.get(tables), drawing.config(tables), gesture.get(tables));
        return true;
    }
    const color_pointer = color_picker.handlePointer(tables, atoms, received) catch |err| {
        prompts.status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
        return true;
    };
    if (color_pointer) return true;
    if (action_palette.requestOpen(tables, atoms)) return false;
    handleAction(mem, tables, atoms, received, held_point) catch |err| {
        reject(session.table(tables), session.get(tables), session.feedback(tables), session.motion(tables), err);
        return true;
    };
    return claims(tag) or (tag == names.cancel and isFigureView(editor_state.viewFocus(tables, atoms).id.*));
}

/// What the pointer does as it moves and lets go, and controls that come and go with it:
/// messages that are not figure actions, so they leave the context menu and settling edits be.
fn isPassive(message: Msg) bool {
    return switch (message) {
        .figure_pointer_move, .figure_pointer_up, .figure_pointer_cancel, .figure_scroll, .figure_scrub_move, .figure_scrub_up, .figure_menu_dismiss, .figure_menu_item => true,
        else => false,
    };
}

fn handleAction(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message, held_point: ?session.Vec2) !void {
    const tag = received.tag;
    const message = tag.to(Msg);
    const editor = session.get(tables);
    const frame_allocator = (try mem.frameScratchAllocator()).allocator;
    // Block conflicting figure edits, not global window navigation: focus loss must
    // still reach the normal layout path so an in-flight gesture can be cancelled.
    // A press is checked by identity because route tags need not be interned, and
    // it must not overwrite press-time state that a settling drag still reads.
    // The editor hands this handler its own messages too, such as `cancel` and the inspector's:
    // only the canvas's own are figure actions.
    const figure_action = claims(tag) and !isPassive(message);
    const pointer_lifecycle = message == .figure_pointer_move or message == .figure_pointer_up or message == .figure_pointer_cancel or message == .figure_gesture_cancel or message == .figure_space_up or message == .figure_scrub_move or message == .figure_scrub_up or message == .figure_menu_dismiss;
    // A key acts as it would without the menu, and the menu gets out of its way.
    if (figure_action and message != .figure_scrub_up and message != .figure_menu_item) _ = context_menu.close(context_menu.get(tables));
    if (message == .figure_pointer_down) {
        const pending_table = session.pendingCommands(tables);
        var pending = pending_table.read();
        while (pending.next()) |row| {
            const operation = row.view.operation.*;
            if (operation == @intFromEnum(std.meta.Tag(session.api.Payload).new_doc) or operation == @intFromEnum(std.meta.Tag(session.api.Payload).load_doc)) return error.DocumentActivating;
        }
    }
    const creating = drawing.config(tables).creation_request.* != 0;
    if (creating and (message == .figure_pointer_cancel or message == .figure_gesture_cancel or tag == names.cancel)) {
        prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Shape is finishing; Undo after creation");
        return;
    }
    if (figure_action and !pointer_lifecycle) try refuseUnsettled(drawing.config(tables), session.get(tables), gesture.get(tables));
    revealTools(session.observed(tables), tag);
    if (try sketches.handleAction(mem, tables, atoms, received)) return;
    if (message == .figure_open) {
        // The workspace stays as it is until a figure or a sketch is chosen (`openRequested`).
        finish(tables, atoms);
        // Find-file opens on the directory of the figure shown, when the figure workspace is
        // showing and its figure has a file; else on the working directory.
        const directory = findFileDirectory(tables, atoms);
        open.requestFindFile(tables, directory);
        return;
    }
    if (message == .figure_switch_document) {
        finish(tables, atoms);
        try prompts.show(mem, tables, atoms, names.switch_document, "");
        return;
    }
    if (message == .figure_new) {
        openWorkspace(tables, atoms);
        finish(tables, atoms);
        try prompts.show(mem, tables, atoms, names.new, try prompts.newName(frame_allocator, tables, atoms));
        return;
    }
    if (message == .figure_open_document) {
        const doc = (try received.userDataAs(Atom)).*;
        finish(tables, atoms);
        prompts.load(tables, atoms, doc, false, null);
        return;
    }
    if (message == .figure_menu_dismiss) {
        _ = context_menu.close(context_menu.get(tables));
        return;
    }
    if (message == .figure_menu_item) {
        _ = context_menu.close(context_menu.get(tables));
        const action = (try received.userDataAs(plugin.action_api.ActionId)).*;
        plugin.action_api.requestInvoke(tables, action);
        return;
    }
    if (message == .figure_scrub_move) {
        try scrub.move(scrub.get(tables), session.get(tables), gesture.get(tables), drawing.config(tables), (try received.payloadAs(input.MouseMoveMsg)).*);
        return;
    }
    if (message == .figure_scrub_up) {
        if (!scrub.active(scrub.get(tables))) return;
        if (scrub.release(scrub.get(tables), gesture.get(tables))) |clicked| {
            if (clicked.kind == prompts.tool_option_kind) {
                const option = std.enums.values(drawing.ToolOption)[clicked.field];
                try prompts.showDrawingOption(mem, tables, atoms, option);
                return;
            }
            const edits_defaults = clicked.kind == prompts.defaults_kind;
            if (!edits_defaults) finish(tables, atoms);
            try prompts.editTarget(mem, tables, atoms, clicked.kind, clicked.id, clicked.field, clicked.part, null);
        }
        return;
    }
    // The wheel follows the pointer, so it comes before the check for what has focus.
    if (message == .figure_scroll) {
        const event = try received.payloadAs(input.MouseScrollMsg);
        if (editor.gesture_active.* != 0 or editor.outliner_drag.* != 0) return;
        const surface = (try received.userDataAs(ScrollSurface)).*;
        switch (surface) {
            .outliner => {
                const category = selection.outlinerCategory(session.outlinerTab(tables));
                const nodes = try selection.categoryNodes(frame_allocator, tables, atoms, category);
                editor.outliner_scroll.* = list.wheel(editor.outliner_scroll.*, event.y, nodes.len -| 1);
                session.observed(tables).outliner_reveal.* = 0;
            },
            .dock => {
                if (!std.math.isFinite(event.y)) return;
                const stage = stageViewport(tables, atoms) orelse return;
                const layout = geometry.stageLayout(stage, stageChrome(session.observed(tables)));
                const dock = chrome.dockRect(editor.mode.*, layout.canvas);
                const scroll = session.observed(tables).tools_scroll;
                const maximum = chrome.maxDockScroll(editor.mode.*, dock.w);
                const next_scroll = scroll.* - event.y * 40;
                scroll.* = std.math.clamp(next_scroll, 0, maximum);
            },
            .properties => {
                if (session.atRest(editor)) {
                    const target = prompts.inspectorTarget(session.get(tables), drawing.config(tables));
                    const fields = prompts.inspectorFields(target.kind);
                    editor.inspector_field.* = list.wheel(editor.inspector_field.*, event.y, fields.len -| 1);
                }
            },
            .timeline => {
                if (filmstrip.enabled(session.get(tables))) {
                    // Ctrl and the wheel zoom the timeline at the pointer; Shift, or a trackpad
                    // swiped mostly sideways, moves it along the clip; the wheel alone scrolls
                    // its lanes.
                    const rect = timelineViewport(tables, atoms) orelse return;
                    const sideways = @abs(event.x) > @abs(event.y);
                    if (event.modifiers.control) {
                        filmstrip.wheelZoom(tables, atoms, rect, event.pointer_x, event.y);
                    } else if (event.modifiers.shift) {
                        filmstrip.wheelPan(tables, atoms, rect, event.y);
                    } else if (sideways) {
                        filmstrip.wheelPan(tables, atoms, rect, event.x);
                    } else {
                        const settings = filmstrip.config(tables);
                        settings.scroll.* = list.wheel(settings.scroll.*, event.y, filmstrip.laneCount(tables, atoms) -| 1);
                    }
                }
            },
            .canvas => {
                const rect = canvasViewport(tables, atoms) orelse return;
                if (!std.math.isFinite(event.x) or !std.math.isFinite(event.y)) return;
                if (event.x == 0 and event.y == 0) return;
                editor.fit_pending.* = 0;
                if (!event.modifiers.control) {
                    // Figma's wheel: pan, sideways with Shift. A trackpad's own x always pans sideways.
                    const notch_pixels: f32 = 40;
                    const wheel_x = if (event.modifiers.shift) event.y else event.x;
                    const wheel_y = if (event.modifiers.shift) @as(f32, 0) else event.y;
                    const screen_delta = session.Vec2{ .x = -wheel_x * notch_pixels, .y = -wheel_y * notch_pixels };
                    const document_delta = math.Vec2f.scale(screen_delta, 1 / editor.view_zoom.*);
                    editor.view_center.* = math.Vec2f.add(editor.view_center.*, document_delta);
                    return;
                }
                const previous_zoom = editor.view_zoom.*;
                const factor = std.math.pow(f32, 1.1, event.y);
                const requested_zoom = previous_zoom * factor;
                const zoom = std.math.clamp(requested_zoom, geometry.minimum_zoom, geometry.maximum_zoom);
                const screen_point = session.Vec2{ .x = event.pointer_x, .y = event.pointer_y };
                editor.view_center.* = geometry.zoomAt(rect, editor.view_center.*, previous_zoom, zoom, screen_point);
                editor.view_zoom.* = zoom;
            },
        }
        return;
    }
    if (!figureHasKeys(tables, atoms)) return;
    if (message == .figure_focus_mode) {
        session.observed(tables).focus_mode.* = @intFromBool(session.observed(tables).focus_mode.* == 0);
        // Focus mode fills the window with the figure stage, as maximizing it does; leaving it
        // restores the arrangement.
        const stage = Atom.from(canvas_id);
        const focusing = session.observed(tables).focus_mode.* != 0;
        if (focusing != panels_mod.isMaximized(tables, atoms, stage)) {
            plugin.panels.request(tables.memory, tables, .{ .focus = .{ .id = stage } });
            plugin.panels.request(tables.memory, tables, .toggle_maximize);
        }
        // Hidden panels cannot keep the arrow keys, and what they showed under the pointer is gone.
        if (session.observed(tables).focus_mode.* != 0) session.observed(tables).key_panel.* = session.none;
        view.clearCanvasHover(tables);
        return;
    }
    if (message == .figure_key_panel_next) {
        const outliner = Atom.from(outliner_id);
        const properties = Atom.from(inspector_id);
        if (session.observed(tables).focus_mode.* != 0) return;
        const next = if (session.observed(tables).key_panel.* == session.none) outliner else if (session.observed(tables).key_panel.* == outliner) properties else session.none;
        session.observed(tables).key_panel.* = next;
        // The keys follow the panel that has the focus, so the focus moves with them.
        const panel = if (next == session.none) Atom.from(canvas_id) else next;
        plugin.panels.request(tables.memory, tables, .{ .focus = .{ .id = panel } });
        return;
    }
    if (message == .figure_select_all) {
        if (editor.mode.* != names.design or editor.gesture_active.* != 0) return;
        if (editor.tool.* == names.edit_points) drawing.finishPointEditing(tables, atoms);
        // From the definition, not the Layers rows: a collapsed folder's art is still on the canvas.
        const definition = try session.readDefinition(tables, atoms, editor.doc.*);
        const shape_kind = names.shape;
        for (definition.shapes) |shape| {
            if (shape.visible == 0 or !session.editableLayer(definition, shape.layer)) continue;
            selection.select(tables, atoms, shape_kind, shape.id, true, false);
        }
        return;
    }
    if (message == .figure_deselect) {
        if (editor.gesture_active.* != 0) return;
        if (editor.tool.* == names.edit_points) drawing.finishPointEditing(tables, atoms);
        selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
        return;
    }
    try pose.guardRigAction(session.get(tables), tag);
    if (!try prepareToolChange(tables, atoms, tag)) return;
    if (message == .figure_outliner_tab) {
        const item = (try received.userDataAs(session.ItemEvent)).*;
        if (selection.categoryOfAtom(item.kind)) |category| browseOutlinerCategory(session.get(tables), session.outlinerTab(tables), session.observed(tables), category);
        return;
    }
    if (message == .figure_outliner_down or message == .figure_outliner_up) {
        const event = (try received.payloadAs(input.MouseButtonMsg)).*;
        const down = message == .figure_outliner_down;
        // On release, once the press no longer holds input, so the menu sees the next one.
        if (event.button == .right and !down) {
            const point = session.Vec2{ .x = event.x, .y = event.y };
            try outlinerPointer(mem, tables, atoms, point, true, .keep_selected);
            try outlinerPointer(mem, tables, atoms, point, false, .keep_selected);
            editor.outliner_drag.* = 0;
            context_menu.open(context_menu.get(tables), .layers, event.x, event.y);
            return;
        }
        if (event.button != .left) return;
        defer {
            if (!down) editor.outliner_drag.* = 0;
        }
        const extend: OutlinerExtend = if (event.modifiers.shift or event.modifiers.control) .toggle else .replace;
        try outlinerPointer(mem, tables, atoms, .{ .x = event.x, .y = event.y }, down, extend);
        return;
    }
    if (message == .figure_outliner_cancel) editor.outliner_drag.* = 0;
    if (message == .figure_outliner_cancel) return;
    if (message == .figure_pointer_down) {
        const event = try received.payloadAs(input.MouseButtonMsg);
        try pointerDown(tables, atoms, event.*, held_point);
        return;
    }
    if (message == .figure_pointer_move) {
        const event = try received.payloadAs(input.MouseMoveMsg);
        try pointerMove(tables, atoms, event.*, held_point);
        return;
    }
    if (message == .figure_pointer_up) {
        const event = try received.payloadAs(input.MouseButtonMsg);
        try pointerUp(tables, atoms, event.*, held_point);
        return;
    }
    if (message == .figure_pointer_cancel or message == .figure_gesture_cancel or tag == names.cancel) {
        const idle_pen = message != .figure_pointer_cancel and editor.tool.* == names.pen and
            editor.gesture_active.* == 0 and !gesture.busy(gesture.get(tables)) and editor.tx_active.* == 0 and
            editor.outliner_drag.* == 0 and !color_picker.isOpen(tables);
        if (idle_pen) try drawing.finish(tables, atoms);
        const idle_points = message != .figure_pointer_cancel and editor.tool.* == names.edit_points and
            editor.gesture_active.* == 0 and !gesture.busy(gesture.get(tables)) and editor.tx_active.* == 0 and
            editor.outliner_drag.* == 0 and !color_picker.isOpen(tables);
        const idle_select = message != .figure_pointer_cancel and session.atRest(editor) and
            editor.tool.* == names.select and editor.gesture_active.* == 0 and !gesture.busy(gesture.get(tables)) and
            editor.tx_active.* == 0 and editor.chain_mode.* == 0 and editor.reparent_active.* == 0 and
            editor.outliner_drag.* == 0 and !color_picker.isOpen(tables);
        cancel(tables, atoms);
        if (idle_points) drawing.finishPointEditing(tables, atoms);
        if (idle_select) selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
        return;
    }
    if (message == .figure_chain_finish) {
        if (editor.gesture_active.* != 0) return;
        if (editor.mode.* == names.design and session.observed(tables).key_panel.* != Atom.from(inspector_id)) {
            if (editor.tool.* == names.edit_points) {
                drawing.finishPointEditing(tables, atoms);
                view.clearCanvasHover(tables);
                return;
            }
            if (editor.tool.* == names.select) {
                if (editor.active_kind.* != names.shape or !try drawing.beginPointEditing(tables, atoms, editor.active_id.*)) {
                    prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Select an editable path first");
                }
                view.clearCanvasHover(tables);
                return;
            }
        }
        if (editor.tool.* == names.ik and pose.config(tables).ik_end.* != 0) {
            try pose.commitIK(tables, atoms);
            return;
        }
        if (session.observed(tables).key_panel.* == Atom.from(inspector_id)) try prompts.editField(mem, tables, atoms, null) else {
            try drawing.finish(tables, atoms);
            const incomplete_fill = editor.tool.* == names.joint_fill and drawing.draftCount(session.get(tables), session.drafts(tables)) != 0;
            if (!incomplete_fill) finish(tables, atoms);
        }
        return;
    }
    if (message == .figure_space_down or message == .figure_space_up) {
        if (filmstrip.enabled(session.get(tables))) {
            if (message == .figure_space_down) _ = try filmstrip.handleAction(tables, atoms, .from(filmstrip.Msg.figure_play_pause));
            editor.space_held.* = 0;
        } else editor.space_held.* = @intFromBool(message == .figure_space_down);
        return;
    }
    const rig_options = session.rigOptions(tables);
    const rig_toggle: ?*u8 = switch (message) {
        .figure_rig_connected => rig_options.connected,
        .figure_stick_head => rig_options.head,
        .figure_snap_joints => rig_options.snap_joints,
        .figure_snap_midpoints => rig_options.snap_midpoints,
        .figure_snap_axes => rig_options.snap_axes,
        .figure_snap_lengths => rig_options.snap_lengths,
        .figure_snap_grid => rig_options.snap_grid,
        else => null,
    };
    if (rig_toggle) |value| {
        if (editor.gesture_active.* != 0) {
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Finish the drag first");
            return;
        }
        value.* ^= 1;
        return;
    }
    if (message == .figure_layer_toggle_selection) {
        const item = (try received.userDataAs(session.ItemEvent)).*;
        if (editor.tool.* == names.edit_points) drawing.finishPointEditing(tables, atoms);
        selection.select(tables, atoms, item.kind, item.id, true, selection.contains(session.get(tables), session.selections(tables), item.kind, item.id));
        return;
    }
    if (message == .figure_folder_collapse) {
        const item = (try received.userDataAs(session.ItemEvent)).*;
        try selection.toggleCollapse(session.collapsedFolders(tables), session.get(tables), item.id);
        return;
    }
    if (message == .figure_folder_add) {
        try transport.send(tables, atoms, .{ .add_layer = .{ .doc = editor.doc.*, .kind = names.folder } });
        return;
    }
    if (message == .figure_folder_group) {
        var ids: std.ArrayListUnmanaged(u32) = .empty;
        var query = session.selections(tables).read();
        while (query.next()) |row| if (row.view.doc.* == editor.doc.* and row.view.kind.* == names.layer) try ids.append(frame_allocator, row.view.id.*);
        if (ids.items.len != 0) {
            rememberSelection(session.get(tables), session.observed(tables), session.drafts(tables), session.selections(tables));
            try transport.send(tables, atoms, .{ .group_layers = .{ .doc = editor.doc.*, .ids = ids.items } });
        }
        return;
    }
    if (message == .figure_folder_ungroup) {
        if (editor.active_kind.* == names.layer) try transport.send(tables, atoms, .{ .ungroup_layer = .{ .doc = editor.doc.*, .id = editor.active_id.* } });
        return;
    }
    if (message == .figure_select_item) {
        const item = (try received.userDataAs(session.ItemEvent)).*;
        try selectOutlinerItem(tables, atoms, item, .replace);
        return;
    }
    if (message == .figure_tool_option) {
        if (editor.gesture_active.* != 0) {
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Finish the drag first");
            return;
        }
        const item = (try received.userDataAs(session.ItemEvent)).*;
        const event = (try received.payloadAs(input.MouseButtonMsg)).*;
        try scrub.arm(mem, tables, atoms, item, .{ .x = event.x, .y = event.y });
        return;
    }
    if (message == .figure_inspector_field) {
        session.observed(tables).key_panel.* = Atom.from(inspector_id);
        const item = (try received.userDataAs(session.ItemEvent)).*;
        const edits_defaults = item.kind == prompts.defaults_kind and drawing.createsArtwork(editor.tool.*);
        if (edits_defaults and editor.gesture_active.* != 0) {
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Finish the drag first");
            return;
        }
        editor.inspector_field.* = item.field;
        const fields = prompts.inspectorFields(item.kind);
        if (item.field < fields.len) {
            const field = fields[item.field].name;
            const fill = std.mem.eql(u8, field, "fill_color");
            const stroke = std.mem.eql(u8, field, "stroke_color");
            if (fill or stroke) {
                try color_picker.open(tables, atoms, if (fill) .fill else .stroke, item);
                return;
            }
            if (fields[item.field].isToggle() or fields[item.field].choices.len != 0) {
                if (!edits_defaults) finish(tables, atoms);
                try prompts.stepField(mem, tables, atoms, item.kind, item.id, fields[item.field]);
                return;
            }
            // An animation key edit stays on the prompt, which owns its clip checks.
            if (fields[item.field].scrub != null and !filmstrip.enabled(session.get(tables))) {
                const event = (try received.payloadAs(input.MouseButtonMsg)).*;
                try scrub.arm(mem, tables, atoms, item, .{ .x = event.x, .y = event.y });
                return;
            }
        }
        if (!edits_defaults) finish(tables, atoms);
        try prompts.editTarget(mem, tables, atoms, item.kind, item.id, item.field, item.part, null);
        return;
    }
    if (message == .figure_select_next or message == .figure_select_previous) {
        const forward = message == .figure_select_next;
        if (session.observed(tables).key_panel.* == Atom.from(inspector_id)) {
            const target = prompts.inspectorTarget(session.get(tables), drawing.config(tables));
            const fields = prompts.inspectorFields(target.kind);
            if (fields.len != 0) {
                const active = @min(editor.inspector_field.*, fields.len - 1);
                editor.inspector_field.* = @intCast(if (forward) (active + 1) % fields.len else (active + fields.len - 1) % fields.len);
            }
        } else {
            if (editor.tool.* == names.edit_points) drawing.finishPointEditing(tables, atoms);
            const direction: selection.TraversalDirection = if (forward) .forward else .backward;
            const scope: selection.TraversalScope = if (session.observed(tables).key_panel.* == Atom.from(outliner_id)) .outliner_category else .canvas_mode;
            try selection.selectRelative(frame_allocator, tables, atoms, direction, scope);
        }
        return;
    }
    for (nudges) |nudge| {
        if (message != nudge.message) continue;
        if (!session.atRest(editor)) return;
        if (editor.tool.* == names.polygon) {
            const polygon_message: drawing.Msg = if (message == .figure_nudge_up)
                .figure_polygon_more
            else if (message == .figure_nudge_down)
                .figure_polygon_less
            else
                return;
            const polygon_action = Atom.from(polygon_message);
            _ = try drawing.handleAction(tables, atoms, polygon_action);
            return;
        }
        if (editor.tool.* == names.ik) {
            const ik_message: pose.Msg = if (message == .figure_nudge_up)
                .figure_ik_more
            else if (message == .figure_nudge_down)
                .figure_ik_less
            else
                return;
            const ik_action = Atom.from(ik_message);
            _ = try pose.handleAction(tables, atoms, ik_action);
            return;
        }
        const nudge_tool = editor.tool.* == names.select or editor.tool.* == names.edit_points;
        const can_nudge = editor.mode.* == names.design and nudge_tool;
        if (!can_nudge or editor.gesture_active.* != 0 or editor.tx_active.* != 0) return;
        const items = try selection.artworkItems(tables);
        if (items.len == 0) return;
        if (editor.tool.* == names.edit_points) {
            try transport.send(tables, atoms, .{ .transform_selection = .{ .doc = editor.doc.*, .items = items, .pivot = session.zero, .translation = nudge.delta } });
        } else {
            try transport.send(tables, atoms, .{ .move_selection = .{ .doc = editor.doc.*, .items = items, .delta = nudge.delta, .coordinate_policy = .bind } });
        }
        return;
    }
    if (message == .figure_view_fit) {
        editor.fit_pending.* = 1;
        fitCanvas(tables, atoms);
        return;
    }
    if (message == .figure_view_selection) {
        const selected = try selectionExtent(tables, atoms) orelse {
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Select something to zoom to");
            return;
        };
        const camera = fittedCamera(tables, atoms, .{ .min = selected.min, .max = selected.max }) orelse return;
        editor.fit_pending.* = 0;
        editor.view_center.* = camera.center;
        editor.view_zoom.* = camera.zoom;
        return;
    }
    if (message == .figure_view_reset) {
        editor.fit_pending.* = 0;
        editor.view_zoom.* = 1;
        return;
    }
    if (message == .figure_zoom_in or message == .figure_zoom_out) {
        editor.fit_pending.* = 0;
        const increase = message == .figure_zoom_in;
        const factor: f32 = if (increase) 1.25 else 0.8;
        const requested_zoom = editor.view_zoom.* * factor;
        editor.view_zoom.* = std.math.clamp(requested_zoom, geometry.minimum_zoom, geometry.maximum_zoom);
        return;
    }
    if (message == .figure_toggle_grid) {
        editor.flags.* ^= 1;
        return;
    }
    if (message == .figure_toggle_bones) {
        editor.flags.* ^= 2;
        return;
    }
    if (message == .figure_tool_hand) {
        finish(tables, atoms);
        if (editor.tool.* == names.edit_points) drawing.finishPointEditing(tables, atoms);
        editor.reparent_active.* = 0;
        editor.hover_kind.* = session.none;
        editor.hover_id.* = 0;
        editor.tool.* = names.hand;
        return;
    }
    if (message == .figure_tool_select and filmstrip.enabled(editor)) {
        // Leaving Hand in Animate must not abandon the tab.
        finish(tables, atoms);
        editor.tool.* = names.select;
        return;
    }
    if (message == .figure_tool_select) {
        // Select belongs to every tab, so it stays on the one shown.
        showAtRest(tables, atoms, editor.mode.*, names.select);
        return;
    }
    if (message == .figure_tool_bone or message == .figure_tool_stick) {
        showAtRest(tables, atoms, names.rig, if (message == .figure_tool_bone) names.bone else names.stick);
        return;
    }
    if (message == .figure_mode_rig) {
        // Artwork chosen in Design stays chosen, ready to bind.
        showAtRest(tables, atoms, names.rig, names.select);
        return;
    }
    if (message == .figure_mode_design or message == .figure_mode_draw) {
        showAtRest(tables, atoms, names.design, names.select);
        selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
        return;
    }
    if (message == .figure_undo or message == .figure_redo) {
        finish(tables, atoms);
        try transport.send(
            tables,
            atoms,
            if (message == .figure_undo) .{ .undo = .{ .doc = editor.doc.* } } else .{ .redo = .{ .doc = editor.doc.* } },
        );
        return;
    }
    if (message == .figure_save) {
        finish(tables, atoms);
        try prompts.save(tables, atoms, null, false);
        return;
    }
    if (message == .figure_save_as) {
        finish(tables, atoms);
        try prompts.show(mem, tables, atoms, names.save_as, atoms.lookup(editor.doc.*) orelse "figure");
        return;
    }
    if (message == .figure_close) {
        finish(tables, atoms);
        try prompts.requestClose(mem, tables, atoms);
        return;
    }
    if (message == .figure_reload) {
        finish(tables, atoms);
        prompts.load(tables, atoms, editor.doc.*, true, null);
        return;
    }
    if (message == .figure_rename) {
        finish(tables, atoms);
        try prompts.show(mem, tables, atoms, names.rename, try prompts.valueText(frame_allocator, tables, atoms, editor.active_kind.*, editor.active_id.*, "name"));
        return;
    }
    if (message == .figure_bone_values) {
        finish(tables, atoms);
        if (editor.active_bone.* == 0) return;
        const definition = try session.readDefinition(tables, atoms, editor.doc.*);
        const bone = session.findById(session.api.read.Bone, definition.bones, editor.active_bone.*) orelse return;
        try prompts.showTarget(
            mem,
            tables,
            atoms,
            names.bone_values,
            if (filmstrip.enabled(editor)) try pose.numericText(tables, atoms, editor.active_bone.*) else try std.fmt.allocPrint(frame_allocator, "{d}:{d}", .{ bone.rotation * 180 / std.math.pi, bone.length }),
            names.bone,
            editor.active_bone.*,
        );
        return;
    }
    if (message == .figure_reparent) {
        finish(tables, atoms);
        if (editor.active_bone.* != 0) {
            editor.reparent_active.* = 1;
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Pick the new parent on the canvas; empty space makes a root. Esc cancels.");
        }
        return;
    }
    if (message == .figure_delete_bone and session.atRest(editor)) {
        if (editor.tool.* == names.pen or editor.tool.* == names.joint_fill) {
            _ = try drawing.handleAction(tables, atoms, .from(drawing.Msg.figure_draft_backspace));
            return;
        }
        finish(tables, atoms);
        const designing = editor.mode.* == names.design;
        if (designing and (editor.active_kind.* == names.layer or editor.tool.* == names.edit_points)) {
            const drawing_message: drawing.Msg = if (editor.active_kind.* == names.layer) .figure_layer_delete else .figure_point_delete;
            const action_tag = Atom.from(drawing_message);
            _ = try drawing.handleAction(tables, atoms, action_tag);
            return;
        }
        var items: std.ArrayListUnmanaged(plugin.figure_api.Selection) = .empty;
        var rows = session.selections(tables).read();
        while (rows.next()) |row| {
            if (row.view.doc.* != editor.doc.*) continue;
            // Each tab deletes what it edits: artwork in Design, bones in Rig.
            const deleted_kind = if (designing) names.shape else names.bone;
            if (row.view.kind.* != deleted_kind) continue;
            try items.append(frame_allocator, .{ .kind = row.view.kind.*, .id = row.view.id.*, .sub = row.view.sub.* });
        }
        if (items.items.len != 0) try transport.send(tables, atoms, .{ .delete_selection = .{ .doc = editor.doc.*, .items = items.items } });
        return;
    }
    if (message == .figure_delete_bone or message == .figure_delete_branch) {
        finish(tables, atoms);
        if (editor.active_kind.* != names.bone) return;
        if (editor.active_bone.* != 0) try transport.send(
            tables,
            atoms,
            .{ .delete_bone = .{ .doc = editor.doc.*, .id = editor.active_bone.*, .delete_branch = message == .figure_delete_branch } },
        );
        return;
    }
    if (message == .figure_mirror_branch) {
        finish(tables, atoms);
        if (editor.active_bone.* != 0) try transport.send(tables, atoms, .{ .mirror_branch = .{ .doc = editor.doc.*, .id = editor.active_bone.* } });
        return;
    }
    if (message == .figure_toggle_visible or message == .figure_toggle_lock or message == .figure_item_visible or message == .figure_item_lock) {
        if (message == .figure_item_visible or message == .figure_item_lock) {
            const item = (try received.userDataAs(session.ItemEvent)).*;
            selection.select(tables, atoms, item.kind, item.id, false, false);
        }
        const lock = message == .figure_toggle_lock or message == .figure_item_lock;
        const definition = try session.readDefinition(tables, atoms, editor.doc.*);
        if (editor.active_kind.* == names.layer) {
            if (session.findById(session.api.read.Layer, definition.layers, editor.active_id.*)) |authored| {
                const layer = filmstrip.posedRow(session.get(tables), .layer, definition, authored);
                try filmstrip.editLook(
                    tables,
                    atoms,
                    .{ .set_layer = .{
                        .doc = editor.doc.*,
                        .id = editor.active_id.*,
                        .visible = if (!lock) 1 - layer.visible else null,
                        .locked = if (lock) 1 - layer.locked else null,
                    } },
                );
            }
        } else if (editor.active_kind.* == names.shape and !lock) {
            if (session.findById(session.api.read.Shape, definition.shapes, editor.active_id.*)) |authored| {
                const shape = filmstrip.posedRow(session.get(tables), .shape, definition, authored);
                try filmstrip.editLook(tables, atoms, .{ .set_shape = .{
                    .doc = editor.doc.*,
                    .id = editor.active_id.*,
                    .visible = 1 - shape.visible,
                } });
            }
        }
        return;
    }
}

pub const InitCheckpoint = enum { session, drawing, weight, pose, filmstrip, prompts };

pub fn prepareInit(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry, reject_after: ?InitCheckpoint) !void {
    // The editor's systems name atoms by constant from here on; reading them back needs this.
    try atoms.tryInternAll(&vocabulary);
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    try Requests.ensure(try mem.tableScratchAllocator(), atoms, tables, commands_table_name);
    try session.prepareInit(mem, atoms, tables);
    try gesture.prepareInit(mem, atoms, tables);
    try scrub.prepareInit(mem, atoms, tables);
    try context_menu.prepareInit(mem, atoms, tables);
    try preview.ensure(tables, atoms);
    try asks.prepareInit(mem, atoms, tables);
    try gesture.prepareHeld(mem, atoms, tables);
    if (reject_after == .session) return error.EditorInitInjectedFailure;
    try drawing.prepareInit(mem, atoms, tables);
    try color_picker.ensure(mem, atoms, tables);
    if (reject_after == .drawing) return error.EditorInitInjectedFailure;
    try weight.prepareInit(mem, atoms, tables);
    if (reject_after == .weight) return error.EditorInitInjectedFailure;
    try pose.prepareInit(mem, atoms, tables);
    if (reject_after == .pose) return error.EditorInitInjectedFailure;
    try filmstrip.prepareInit(mem, atoms, tables);
    const modes_scratch = try mem.tableScratchAllocator();
    try modes.ensurePanelModes(modes_scratch, atoms, tables, panel_modes_table_name);
    if (reject_after == .filmstrip) return error.EditorInitInjectedFailure;
    if (reject_after == .prompts) return error.EditorInitInjectedFailure;
}
