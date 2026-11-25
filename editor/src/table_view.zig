//! The editor's side of the grid a table window shows (`mesha.ui.grid`): what needs an editor
//! system. The grid's `update` answers an `Outcome` for what it does not do itself, and `update`
//! here asks for it: a column's menu in the action palette, the clipboard through the OS
//! system, the edit of a cell through the inspector's shared text editor. Here too are the
//! grid's actions and their keys, the input a grid subscribes to, and `rowsInOrder`, which a
//! publisher writes a list into a table in order with.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const plugin = mesha.plugin;
const sequencer = mesha.sequencer;
const Atom = mesha.Atom;
const Table = mesha.Table;
const input = mesha.input;
const os = mesha.os;
const filter_field = ui.filter_field;
const action_palette = @import("action_palette.zig");
const modes = @import("modes.zig");

const editor_sequencer = @import("editor_sequencer.zig");

/// The most bytes of the clipboard a paste over a cell takes.
const max_clipboard_bytes: usize = 4096;

/// The inspector's one text editor, which holds the edit of whichever cell or form field has
/// the keyboard; see `windows` for how it moves between them.
pub const inspector_editor = Atom.from("inspector_text");

/// Whose a grid's messages are: the system whose inbox takes them, subscribing and declaring
/// actions from `tables` and `atoms`.
pub const Owner = struct {
    tables: *Table.Registry,
    atoms: *Atom.Registry,
    system: sequencer.System,
    /// The mode the grid's actions are declared under (`declareActions`): `table` for a table
    /// window, the owner's own mode for a grid in a panel of its own.
    mode: Atom = modes.table,
    /// How the grid is presented: what `subscribeInput` listens for and `declareActions`
    /// offers, the columns drawn and the row numbers.
    presentation: ui.grid.Presentation = .{},

    fn orderContext(owner: Owner, allocator: std.mem.Allocator) ui.grid.OrderContext {
        return .{ .atoms = owner.atoms, .allocator = allocator, .presentation = owner.presentation };
    }

    pub fn inbox(owner: Owner) Atom {
        return sequencer.inboxOf(owner.system);
    }
};

/// What `update` needs: the grid's own `ui.grid.UpdateContext` (`gridContext`), and the tables
/// the requests it asks for go through, with the inbox their answers come back to.
pub const UpdateContext = struct {
    viewport_w: f32,
    viewport_h: f32,
    incarnation: u32 = 0,

    tables: *Table.Registry,
    atoms: *Atom.Registry,
    /// Whether the inspector's text editor holds this window's current edit, so typing and
    /// commits go through it.
    editor_loaded: bool = false,
    /// The inbox of the system that takes the grid's messages, which its replies go to.
    reply_inbox: Atom = sequencer.no_inbox,
    /// How the grid is presented: with `read` access nothing edits, clears, flips or pastes over
    /// a cell, and a row is chosen. The owner's `Owner.presentation`.
    presentation: ui.grid.Presentation = .{},

    /// The grid's context, its memory the frame's; null when the frame has none.
    pub fn gridContext(ctx: UpdateContext) ?ui.grid.UpdateContext {
        const scratch = ctx.tables.memory.frameScratchAllocator() catch return null;
        return .{
            .viewport_w = ctx.viewport_w,
            .viewport_h = ctx.viewport_h,
            .incarnation = ctx.incarnation,
            .atoms = ctx.atoms,
            .allocator = scratch.allocator,
            .editor_loaded = ctx.editor_loaded,
            .presentation = ctx.presentation,
        };
    }
};

/// Takes one of the grid's messages, `received`, for the grid `instance`, which its owner found
/// it is for, and asks for what the grid's answer needs of the editor's systems: the column
/// menu, the clipboard, the inspector's text editor. The grid's answer, which the owner acts
/// on for what is left (`mutated`, `invalidated`, `chosen`). An error is the message's that
/// could not be read.
pub fn update(state: ui.grid.State, instance: Atom, target: ui.grid.Target, message: ui.grid.Msg, received: sequencer.Message, table: *Table, ctx: UpdateContext) !ui.grid.Outcome {
    const grid_context = ctx.gridContext() orelse return .ignored;
    const outcome = try ui.grid.update(state, instance, target, message, received, table, grid_context);
    switch (outcome) {
        .column_menu => |menu| openColumnMenu(state, instance, table, menu.field, ctx),
        .copy => |copy| os.request(ctx.tables.memory, ctx.tables, .{ .set_clipboard = .{ .text = copy.text } }),
        .paste_wanted => |clipboard_target| requestPaste(clipboard_target, ctx),
        .edit => |edit| requestEdit(edit, ctx.tables),
        // A grid over a slice of a larger set asks its owner to filter or sort; the editor's
        // grids hold all their rows.
        .ignored, .handled, .invalidated, .mutated, .chosen, .filter_changed, .sort_wanted => {},
    }
    return outcome;
}

/// Runs one of the grid's messages that carries nothing but its instance, such as a cell
/// action's commit, as `update` does.
pub fn updateMessage(state: ui.grid.State, instance: Atom, target: ui.grid.Target, message: ui.grid.Msg, table: *Table, ctx: UpdateContext) ui.grid.Outcome {
    const received: sequencer.Message = .{ .tag = Atom.from(message), .user_data = std.mem.asBytes(&instance) };
    // Nothing is read from a message that carries only its instance.
    return update(state, instance, target, message, received, table, ctx) catch unreachable;
}

/// Asks the clipboard for its text, which comes back to the owner's inbox as the grid's
/// `paste_reply`, carrying `clipboard_target`.
fn requestPaste(clipboard_target: ui.grid.ClipboardTarget, ctx: UpdateContext) void {
    const asking: sequencer.ReplyTo = .{ .inbox = ctx.reply_inbox, .tag = .from(ui.grid.Msg.paste_reply) };
    const reply = asking.with(.of(&clipboard_target));
    os.request(ctx.tables.memory, ctx.tables, .{ .get_clipboard = .{ .max_bytes = max_clipboard_bytes, .reply = reply } });
}

/// Asks the inspector's text editor, which holds the cell's edit, to do what the grid answered;
/// its report of its text comes back through `ui.grid.editorReport`.
fn requestEdit(edit: ui.grid.Edit, tables: *Table.Registry) void {
    const memory = tables.memory;
    switch (edit.kind) {
        .insert => plugin.text_editor_api.request(memory, tables, .{ .insert = .{ .buffer = inspector_editor, .utf8 = edit.text } }),
        .paste => plugin.text_editor_api.request(memory, tables, .{ .paste = .{ .buffer = inspector_editor, .utf8 = edit.text } }),
        // The editor selects the cell's text and deletes it.
        .clear => {
            plugin.text_editor_api.request(memory, tables, .{ .run = .{ .buffer = inspector_editor, .command = .select_all } });
            plugin.text_editor_api.request(memory, tables, .{ .run = .{ .buffer = inspector_editor, .command = .delete_back } });
        },
        .mark_saved => plugin.text_editor_api.request(memory, tables, .{ .mark_saved = inspector_editor }),
    }
}

const column_menu_owner = Atom.from("editor.table_view.column_menu");

/// Offers what can be done with a column, as the action palette's dialog: the grid's choices
/// for it (`ui.grid.columnMenuChoices`), each carrying its action in the completion's first
/// byte and the field in the next four. The answer comes back as the grid's
/// `table_column_menu_reply`, for `takeColumnMenuReply`.
fn openColumnMenu(state: ui.grid.State, instance: Atom, table: *const Table, field: u32, ctx: UpdateContext) void {
    const fields = table.getSchema().fields;
    const memory = ctx.tables.memory;
    const allocator = action_palette.completionAllocator(memory, .table_view) catch return;
    action_palette.resetCompletionArena(memory, .table_view);
    var choice_buffer: [ui.grid.max_column_choices]ui.grid.ColumnChoice = undefined;
    const choices = ui.grid.columnMenuChoices(state, field, &choice_buffer);
    const entries = allocator.alloc(action_palette.Completion, choices.len) catch return;
    for (choices, entries) |choice, *entry| {
        var data = std.mem.zeroes([action_palette.kCompletionDataSize]u8);
        data[0] = @intFromEnum(choice.action);
        @memcpy(data[1..5], std.mem.asBytes(&field));
        entry.* = .{ .label = choice.label, .detail = "", .data = data };
    }
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = .{
        .owner = column_menu_owner,
        // A menu of a few choices: buttons to click, not a list to search.
        .presentation = .dialog,
        .title = fields[field].name,
        // Freezing columns keeps those through this one; freezing rows, those through the selection.
        .body = "Freeze keeps columns through this one, or rows through the selected row, in place",
        .entries = entries,
    };
    action_palette.ownRequestText(allocator, completions) catch return;
    const asking: sequencer.ReplyTo = .{ .inbox = ctx.reply_inbox, .tag = .from(ui.grid.Msg.table_column_menu_reply) };
    const reply = asking.with(.of(&instance));
    action_palette.request(ctx.tables.memory, ctx.tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

/// The column menu's choice, the palette's event `received` in reply to `openColumnMenu`,
/// applied to the grid (`ui.grid.applyColumnAction`).
pub fn takeColumnMenuReply(state: ui.grid.State, table: *const Table, received: sequencer.Message, ctx: UpdateContext) void {
    defer {
        if (action_palette.currentOwner(ctx.tables, ctx.atoms) != column_menu_owner) action_palette.resetCompletionArena(ctx.tables.memory, .table_view);
        action_palette.request(ctx.tables.memory, ctx.tables, .{ .acknowledge = .{ .owner = column_menu_owner } });
    }
    const event = action_palette.eventOf(received) catch |err| return received.unreadable(err);
    if (event.kind != .completed) return;
    const completion = event.completion orelse return;
    const action = std.enums.fromInt(ui.grid.ColumnAction, completion.data[0]) orelse return;
    const field = std.mem.bytesToValue(u32, completion.data[1..5]);
    const grid_context = ctx.gridContext() orelse return;
    ui.grid.applyColumnAction(state, table, field, action, grid_context.orderContext());
}

/// A grid's own actions while it browses its cells, `{ table, <name> }`: each delivers its tag,
/// one of `ui.grid.Msg`, to the grid's owner with the grid's instance in its user data, but
/// `sort_column`, whose user data is the selected cell's `ui.grid.ColumnRef`. Their keys are the
/// editor's `table_keys`, Org mode's table keys with Emacs's for moving.
pub const actions = [_]plugin.action_api.Def{
    .{ .name = "next_cell", .tag = "tab", .doc = "Select the next cell, or the next row's first" },
    .{ .name = "previous_cell", .tag = "backtab", .doc = "Select the previous cell, or the previous row's last" },
    .{ .name = "next_row", .tag = "nav_down", .doc = "Select the cell below" },
    .{ .name = "previous_row", .tag = "nav_up", .doc = "Select the cell above" },
    .{ .name = "next_column", .tag = "nav_right", .doc = "Select the cell to the right" },
    .{ .name = "previous_column", .tag = "nav_left", .doc = "Select the cell to the left" },
    .{ .name = "row_start", .tag = "home", .doc = "Select the row's first cell" },
    .{ .name = "row_end", .tag = "end", .doc = "Select the row's last cell" },
    .{ .name = "page_up", .tag = "page_up", .doc = "Select the cell a page up" },
    .{ .name = "page_down", .tag = "page_down", .doc = "Select the cell a page down" },
    .{ .name = "first_cell", .tag = "first_cell", .doc = "Select the table's first cell" },
    .{ .name = "last_cell", .tag = "last_cell", .doc = "Select the table's last cell" },
    .{ .name = "edit_cell", .tag = "begin_edit", .doc = "Edit the selected cell, keeping its text" },
    .{ .name = "clear_cell", .tag = "delete", .doc = "Clear the selected cell" },
    .{ .name = "sort_column", .tag = "table_header_sort", .doc = "Sort by the selected cell's column, then the other way, then not" },
    .{ .name = "toggle", .tag = "toggle", .doc = "Flip the selected checkbox cell" },
    .{ .name = "copy", .tag = "copy", .doc = "Copy the selected cell" },
    .{ .name = "paste", .tag = "paste", .doc = "Paste over the selected cell" },
};

/// Whether the grid offers the action `def`, one of `actions`, under `access`: read only, none
/// that edits, clears, flips or pastes over a cell.
pub fn offers(access: ui.grid.Access, def: plugin.action_api.Def) bool {
    if (access == .edit) return true;
    const edits = [_]ui.grid.Msg{ .begin_edit, .delete, .toggle, .paste };
    const tag = Atom.from(def.tag);
    for (edits) |message| {
        if (tag == Atom.from(message)) return false;
    }
    return true;
}

/// What a grid listens for now (`ui.grid.listening`), browsing when the frame has no memory.
fn listening(state: ui.grid.State, target: ui.grid.Target, table: *const Table, owner: Owner) ui.grid.Listening {
    const scratch = owner.tables.memory.frameScratchAllocator() catch return .browsing;
    return ui.grid.listening(state, target, table, owner.orderContext(scratch.allocator));
}

/// Subscribes the grid to its keys and typing, through the owner's input subscriber.
pub fn subscribeInput(state: ui.grid.State, instance: Atom, target: ui.grid.Target, table: *const Table, owner: Owner, inputs: editor_sequencer.InputSubscriber) ui.grid.Status {
    switch (listening(state, target, table, owner)) {
        .invalidated => return .invalidated,
        .filtering => {
            // The filter takes the typing and its keys; no cell's keys are listened to meanwhile.
            filter_field.subscribe(inputs, .from(ui.grid.Msg.table_filter_text), .from(ui.grid.Msg.table_filter_key), .of(&instance));
            return .ready;
        },
        .editing => {
            // Every other key is an action's: the text editor's, and the cell's own (commit and
            // move, cancel), listed while a cell edits; see `windows.pushCellEditorActions`.
            const text_filter: input.ModifierFilter = .{ .control = .forbidden, .alt = .forbidden, .super = .forbidden };
            inputs.push(.{ .text_input = .{ .capture = true, .modifiers = text_filter, .tag = .from(ui.grid.Msg.char) } }, .of(&instance));
            return .ready;
        },
        .browsing => {
            // Read only, typing starts nothing: the keys are the owner's actions.
            if (owner.presentation.access == .read) return .ready;
            // Typing over the selected cell starts its edit; every key is an action's, the
            // grid's own (`actions`), which `declareActions` offers.
            inputs.push(.{ .text_input = .{
                .modifiers = .{ .control = .forbidden, .alt = .forbidden, .super = .forbidden },
                .tag = .from(ui.grid.Msg.char),
            } }, .of(&instance));
            return .ready;
        },
    }
}

/// Whether the grid browses its cells, when it offers its `actions`.
pub fn isBrowsing(state: ui.grid.State, target: ui.grid.Target, table: *const Table, owner: Owner) bool {
    return listening(state, target, table, owner) == .browsing;
}

/// Offers the grid's `actions` for the grid `instance`, while it browses its cells, under the
/// owner's mode, those its access `offers`. `sort_column` is offered only while a cell is
/// selected, for that cell's column.
pub fn declareActions(state: ui.grid.State, instance: Atom, target: ui.grid.Target, table: *const Table, owner: Owner, sink: plugin.ActionSink) void {
    if (!isBrowsing(state, target, table, owner)) return;
    const selected_column: ui.grid.ColumnRef = .{ .instance = instance, .field = state.edit_field.* };
    const sort_tag = Atom.from(ui.grid.Msg.table_header_sort);
    for (actions) |def| {
        if (!offers(owner.presentation.access, def)) continue;
        const tag = Atom.from(def.tag);
        const sorts = tag == sort_tag;
        if (sorts and state.selected_present.* == 0) continue;
        const user_data: sequencer.UserData = if (sorts) .of(&selected_column) else .of(&instance);
        sink.declare(.{
            .id = .{ owner.mode, Atom.from(def.name) },
            .doc = def.doc,
            .inbox = owner.inbox(),
            .tag = tag,
            .user_data = user_data,
        });
    }
}

// ---- a list written in order ----------------------------------------------------------------------

/// Keeps exactly `count` rows live in `table`, freeing its last or adding empty ones, and returns
/// their handles in the table's own order, the order a grid shows unsorted, in `allocator`: what
/// an owner writes a list into in order, whatever rows the table hands out, which in a run that
/// freed some are not in the order they are added.
pub fn rowsInOrder(table: *Table, count: u32, allocator: std.mem.Allocator) ![]Table.RowHandle {
    var live: std.ArrayList(Table.RowHandle) = .empty;
    var rows = table.readQuery(struct {});
    while (rows.next()) |found| try live.append(allocator, found.handle);
    sortByRow(live.items);
    while (live.items.len > count) {
        const last = live.pop().?;
        table.free(last);
    }
    while (live.items.len < count) {
        const added = try table.tryInsert(.{});
        try live.append(allocator, added);
    }
    sortByRow(live.items);
    return live.items;
}

fn sortByRow(handles: []Table.RowHandle) void {
    std.mem.sort(Table.RowHandle, handles, {}, struct {
        fn less(_: void, a: Table.RowHandle, b: Table.RowHandle) bool {
            return a.row < b.row;
        }
    }.less);
}

test "a read only grid offers no action that edits" {
    for (actions) |def| {
        const edits = std.mem.eql(u8, def.name, "edit_cell") or std.mem.eql(u8, def.name, "clear_cell") or
            std.mem.eql(u8, def.name, "toggle") or std.mem.eql(u8, def.name, "paste");
        try std.testing.expectEqual(!edits, offers(.read, def));
        try std.testing.expect(offers(.edit, def));
    }
}
