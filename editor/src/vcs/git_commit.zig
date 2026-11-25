//! vcs-git's commits: the commit menu (`c` in mode `vcs_git`, and in the menu of menus) and the
//! message buffer a commit is written in. A part of the panel's system (`git_status.zig`): the
//! pending commit and the messages written are this file's tables, while the jobs, how their ends
//! refresh and what is told on the message line are the panel's (`git_status.Work`), which these
//! functions are handed.
//!
//! - The menu's switches (`--all`, `--allow-empty`, `--no-verify`, `--signoff`,
//!   `--reset-author`) start off at each showing and are spliced into whichever commit is chosen.
//! - `c` commits what is staged, `a` amends `HEAD` with it, `w` rewords `HEAD` alone (`--amend
//!   --only`, what is staged left out and staged): each opens `*vcs-git: message*` in the other
//!   text window, which takes the focus, empty for `c` and filled with `HEAD`'s message for `a`
//!   and `w` (one `log -1 --format=%B`, the spinner turning while it runs). `e` extends `HEAD`
//!   with what is staged keeping its message, and `f` makes a fixup of the commit at the cursor
//!   (a line of the recent commits): each runs at once, with no buffer and nothing on its input,
//!   and tells `Extended HEAD` or `Made a fixup of <short hash>` as it ends well. A reword leaves
//!   `--all` out, which git refuses with `--only`, and says so.
//! - The message is the buffer's text as it is: its first line is the summary, no comment line is
//!   added or taken out, and git's `whitespace` cleanup (`-F -`) drops only blank lines at its
//!   ends and spaces at its lines' ends.
//! - In the buffer, whose windows have the major mode `vcs_message` under `buffer`, `C-c C-c`
//!   commits the text with it on the job's input, and `C-c C-k` gives the commit up. An empty
//!   message is refused on the message line. An amend or a reword keeps the commit `HEAD` was at
//!   as it began (`PendingRow.head`): `C-c C-c` refuses when the status says `HEAD` is elsewhere
//!   now, and otherwise reads the status again first (`verifying`), the commit running only when
//!   a refresh that ends with no command of the panel's running finds `HEAD` still there
//!   (`refreshEnded`), so a pull, a switch or a commit made meanwhile never has the message put
//!   on another commit; refused, the buffer is kept. The buffer stays until the commit ends
//!   well: a commit git refuses (a hook, nothing to commit) keeps it and its text, and `C-c C-c` tries
//!   again. A commit that ended well or was given up closes the buffer, and its window shows
//!   again what it showed before, or closes when it was made for the message
//!   (`text_panel.showBuffer`); the focus comes back to vcs-git while it is shown. A commit
//!   ended well tells `Committed: <summary>`, and the panel refreshes asking for the operation in
//!   progress, as a commit ends a merge.
//! - `M-p` and `M-n` go through the last `max_messages` messages committed or given up this
//!   session, the text being written before the first `M-p` coming back last.
//! - Under the common keys (`cua`) `C-c` copies, which hides `C-c C-c` and `C-c C-k`: `M-x`
//!   lists `vcs_message.finish` and `vcs_message.cancel` while the message buffer has the focus.
//! - `C-x k` in the buffer gives the commit up as `C-c C-k` does, its text kept. A change of
//!   project gives up the commit being written; a give-up (`C-g`) of the panel's jobs gives it up
//!   only while its own job runs, `HEAD`'s message asked for or the commit itself, which may have
//!   been made already: the refresh shows. A buffer that could not be made, or was killed
//!   otherwise, gives it up too.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const keybinds = mesha.keybinds;
const process = mesha.process;
const text_editor = plugin.text_editor_api;
const git = @import("git.zig");
const status = @import("git_status.zig");
const transient = @import("../transient.zig");
const text_panel = @import("../text_panel.zig");
const shared = @import("../text_editor.zig");
const modes = @import("../modes.zig");
const Log = mesha.log.scope("vcs_git_commit");

// ---- the messages, the actions and their keys --------------------------------------------------

/// What the panel's system takes for commits: the actions below and the menu's answer.
pub const Msg = enum(u64) {
    /// `c`: shows the commit menu.
    vcs_git_commit_menu = Atom.from("vcs_git_commit_menu").value(),
    /// The commit menu's answer, a `transient.Chosen`.
    vcs_git_commit_chosen = Atom.from("vcs_git_commit_chosen").value(),
    /// `C-c C-c` in the message buffer: commits its text.
    vcs_message_finish = Atom.from("vcs_message_finish").value(),
    /// `C-c C-k` in the message buffer: gives the commit up.
    vcs_message_cancel = Atom.from("vcs_message_cancel").value(),
    /// `M-p` and `M-n` in the message buffer: an earlier message, and a later one.
    vcs_message_previous_message = Atom.from("vcs_message_previous_message").value(),
    vcs_message_next_message = Atom.from("vcs_message_next_message").value(),
    _,
};

/// Whether `tag` is one of `Msg`'s.
pub fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// The action of mode `vcs_git` that shows the commit menu; its key is `c`.
pub const commit_action: plugin.action_api.Def = .{ .name = "commit", .tag = @tagName(Msg.vcs_git_commit_menu), .doc = "Show the menu of commit commands" };

/// The actions of mode `vcs_message`, the message buffer's.
pub const message_actions = [_]plugin.action_api.Def{
    .{ .name = "finish", .tag = @tagName(Msg.vcs_message_finish), .doc = "Commit with this message" },
    .{ .name = "cancel", .tag = @tagName(Msg.vcs_message_cancel), .doc = "Give up the commit, keeping the message for M-p" },
    .{ .name = "previous_message", .tag = @tagName(Msg.vcs_message_previous_message), .doc = "Put an earlier commit message in place of this one" },
    .{ .name = "next_message", .tag = @tagName(Msg.vcs_message_next_message), .doc = "Put a later commit message in place of this one" },
};

/// The keys of mode `vcs_message`, over `buffer`'s.
pub const message_keys = [_]keybinds.KeyDef{
    .{ .chord = "C-c C-c", .action = .{ "vcs_message", "finish" } },
    .{ .chord = "C-c C-k", .action = .{ "vcs_message", "cancel" } },
    // Killing the buffer would lose the text: it gives the commit up, keeping it.
    .{ .chord = "C-x k", .action = .{ "vcs_message", "cancel" } },
    .{ .chord = "M-p", .action = .{ "vcs_message", "previous_message" } },
    .{ .chord = "M-n", .action = .{ "vcs_message", "next_message" } },
};

// ---- the menu ------------------------------------------------------------------------------------

/// The commit menu's items, by their ids.
pub const MenuItem = enum(u32) {
    commit = 1,
    amend,
    extend,
    reword,
    fixup,
    all,
    allow_empty,
    no_verify,
    signoff,
    reset_author,
};

/// The commit menu: its switches, then its commands by what they make.
pub const menu: ui.transient.Menu = .{
    .title = "Commit",
    .groups = &.{
        .{ .title = "Arguments", .items = &.{
            ui.transient.Item.toggle("-a", "Stage all modified and deleted files", "--all", @intFromEnum(MenuItem.all)),
            ui.transient.Item.toggle("-e", "Allow empty commit", "--allow-empty", @intFromEnum(MenuItem.allow_empty)),
            ui.transient.Item.toggle("-n", "Disable hooks", "--no-verify", @intFromEnum(MenuItem.no_verify)),
            ui.transient.Item.toggle("-s", "Add Signed-off-by line", "--signoff", @intFromEnum(MenuItem.signoff)),
            ui.transient.Item.toggle("-R", "Claim authorship and reset author date", "--reset-author", @intFromEnum(MenuItem.reset_author)),
        } },
        .{ .title = "Create", .items = &.{
            ui.transient.Item.command("c", "Commit", @intFromEnum(MenuItem.commit)),
        } },
        .{ .title = "Edit HEAD", .items = &.{
            ui.transient.Item.command("e", "Extend", @intFromEnum(MenuItem.extend)),
            ui.transient.Item.command("w", "Reword", @intFromEnum(MenuItem.reword)),
            ui.transient.Item.command("a", "Amend", @intFromEnum(MenuItem.amend)),
        } },
        .{ .title = "Edit", .items = &.{
            ui.transient.Item.command("f", "Fixup", @intFromEnum(MenuItem.fixup)),
        } },
    },
};

/// Shows the commit menu, its switches off; its answer comes as `vcs_git_commit_chosen`.
pub fn presentMenu(work: status.Work) void {
    const reply = sequencer.ReplyTo.of(status.system(), .from(Msg.vcs_git_commit_chosen));
    transient.present(work.pass.frame.memory, work.pass.frame.tables, .{ .menu = &menu, .reply = reply });
}

// ---- the tables ----------------------------------------------------------------------------------

/// `editor_vcs_git_commit`: the commit being written, one row (`PendingRow`).
pub const pending_table_name = "editor_vcs_git_commit";
/// `editor_vcs_git_messages`: the messages committed or given up this session, a row each, at
/// most `max_messages` (`MessageRow`). The table is durable, never saved: it lasts the session,
/// through a reload of the editor, and is empty at the next start.
pub const messages_table_name = "editor_vcs_git_messages";
/// How many messages `M-p` goes back through.
pub const max_messages = 32;

/// The buffer a commit's message is written in, made the first time and closed as the commit
/// ends or is given up.
pub const message_name = "*vcs-git: message*";
/// The message buffer's id.
pub const message_buffer = Atom.from(message_name);

/// How far the commit being written has got.
pub const Phase = enum(u8) {
    /// None is being written.
    none,
    /// `HEAD`'s message is asked for, to fill the buffer with.
    loading,
    /// The buffer is shown for its message to be written.
    editing,
    /// The commit runs with the message the buffer held.
    running,
    /// `C-c C-c` on an amend or a reword: the status is read again, and the commit runs when that
    /// refresh ends with `HEAD` where it was as the message was begun (`refreshEnded`).
    verifying,
};

/// The row of `editor_vcs_git_commit`. Text is in its text cells.
pub const PendingRow = struct {
    /// A `Phase`.
    phase: *u8,
    /// A `git.CommitKind`: `new`, `amend` or `reword`.
    kind: *u8,
    /// The menu's arguments as it closed, each followed by `process.argument_separator`.
    arguments: *Table.String,
    /// The repository's root the commit was asked in; it is given up in another.
    root: *Table.String,
    /// The panel's generation as the commit's own job, `HEAD`'s message or the commit, was
    /// queued: a give-up moves it on, which gives the commit up while that job runs.
    generation: *u32,
    /// 1 once the message buffer was seen open: its closing after that gives the commit up.
    buffer_seen: *u8,
    /// The runs the buffer, asked for, has not been open; at `max_open_waits` it could not be
    /// made, and the commit is given up.
    open_waits: *u8,
    /// The message committed, while the commit runs and after git refused it.
    message: *Table.String,
    /// How far back `M-p` has gone among the messages kept: 0 at the text being written.
    ring_position: *u32,
    /// The text being written as the first `M-p` took its place, which `M-n` comes back to.
    draft: *Table.String,
    /// For an amend or a reword, the commit `HEAD` was at, whole, as the status held it when the
    /// message was begun: the commit runs only while `HEAD` is still there. Empty for a new
    /// commit.
    head: *Table.String,
};

/// `PendingRow` read, its text as slices of the table's.
const PendingRead = struct {
    phase: *u8,
    kind: *u8,
    arguments: []const u8,
    root: []const u8,
    generation: *u32,
    buffer_seen: *u8,
    open_waits: *u8,
    message: []const u8,
    ring_position: *u32,
    draft: []const u8,
    head: []const u8,
};

/// How many runs of the panel's system the message buffer may take to open once asked for: as
/// many as the text panels wait to show it, so it is shown, with its mode, whenever it opens
/// before the commit gives up.
pub const max_open_waits = text_panel.max_show_waits;

/// A row of `editor_vcs_git_messages`.
const MessageRow = struct {
    /// Counts up: the latest message has the highest.
    order: *u32,
    /// The message.
    text: []const u8,
};

const pending_table = Atom.from(pending_table_name);
const messages_table = Atom.from(messages_table_name);
const buffer_modes_table = Atom.from(text_panel.buffer_modes_table_name);
const show_requests_table = Atom.from(text_panel.show_requests_table_name);

/// Makes the commits' tables unless they are there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ pending_table_name, messages_table_name, message_name });
    var pending: Table.Schema = undefined;
    try pending.init(scratch.allocator, atoms, 11);
    defer pending.deinit();
    try pending.addFieldFallible("phase", u8, .int);
    try pending.addFieldFallible("kind", u8, .int);
    try pending.addFieldFallible("arguments", Table.String, .text_field);
    try pending.addFieldFallible("root", Table.String, .text_field);
    try pending.addFieldFallible("generation", u32, .int);
    try pending.addFieldFallible("buffer_seen", u8, .int);
    try pending.addFieldFallible("open_waits", u8, .int);
    try pending.addFieldFallible("message", Table.String, .text_field);
    try pending.addFieldFallible("ring_position", u32, .int);
    try pending.addFieldFallible("draft", Table.String, .text_field);
    try pending.addFieldFallible("head", Table.String, .text_field);
    const defaults = .{
        .phase = @as(u8, @intFromEnum(Phase.none)),
        .kind = @as(u8, @intFromEnum(git.CommitKind.new)),
        .arguments = Table.String{},
        .root = Table.String{},
        .generation = @as(u32, 0),
        .buffer_seen = @as(u8, 0),
        .open_waits = @as(u8, 0),
        .message = Table.String{},
        .ring_position = @as(u32, 0),
        .draft = Table.String{},
        .head = Table.String{},
    };
    _ = try tables.ensureSingleton(&pending, pending_table, defaults, .durable);

    var messages: Table.Schema = undefined;
    try messages.init(scratch.allocator, atoms, 2);
    defer messages.deinit();
    try messages.addFieldFallible("order", u32, .int);
    try messages.addFieldFallible("text", Table.String, .text_field);
    _ = try tables.ensure(&messages, max_messages, messages_table, .durable);
}

/// What the commits read and write, for the panel's system's access: their tables, the message
/// buffer, and the text panels' requests that show it and give it its mode.
pub fn declareAccess(result: *sequencer.Access, tables: *Table.Registry) void {
    result.writeAll(&.{ pending_table, messages_table });
    text_editor.declareBuffer(result, tables, message_buffer);
    result.writeIfPresent(tables, buffer_modes_table);
    result.writeIfPresent(tables, show_requests_table);
}

// ---- taking the messages -------------------------------------------------------------------------

/// One of `Msg`'s, which `claims` took.
pub fn take(work: status.Work, received: sequencer.Message) !void {
    switch (received.tag.to(Msg)) {
        .vcs_git_commit_menu => presentMenu(work),
        .vcs_git_commit_chosen => {
            const chosen = try received.payloadAs(transient.Chosen);
            if (chosen.cancelled != 0) return;
            const item = std.enums.fromInt(MenuItem, chosen.id) orelse return;
            try choose(work, item, chosen.state);
        },
        .vcs_message_finish => try finish(work),
        .vcs_message_cancel => try cancel(work),
        .vcs_message_previous_message => try stepMessages(work, .earlier),
        .vcs_message_next_message => try stepMessages(work, .later),
        _ => {},
    }
}

/// What the commit chosen in the menu does, with the switches `state` has on.
fn choose(work: status.Work, item: MenuItem, state: ui.transient.State) !void {
    if (work.rootUnknown()) return;
    const all = ui.transient.isOn(&menu, &state, @intFromEnum(MenuItem.all));
    // A reword changes the message alone: `--all` with `--only` is refused by git.
    var switches = state;
    const leaves_all_out = item == .reword and all;
    if (leaves_all_out) {
        _ = ui.transient.setToggle(&menu, &switches, @intFromEnum(MenuItem.all), .off);
    }
    var arguments_buffer: [256]u8 = undefined;
    var arguments_writer = std.Io.Writer.fixed(&arguments_buffer);
    try ui.transient.writeArguments(&menu, &switches, process.argument_separator, &arguments_writer);
    const arguments = arguments_writer.buffered();
    switch (item) {
        .commit => {
            const staged = work.state.staged_count.* != 0;
            const allow_empty = ui.transient.isOn(&menu, &state, @intFromEnum(MenuItem.allow_empty));
            if (!staged and !all and !allow_empty) return work.tell("Nothing staged; s stages, or c -a c commits all changes");
            try startMessage(work, .new, arguments);
        },
        .amend, .reword => {
            if (work.hasCommit() == .unborn) return work.tell("There is no commit to amend");
            if (leaves_all_out) work.tell("Reword changes the message only; --all was left out");
            const kind: git.CommitKind = if (item == .amend) .amend else .reword;
            try startMessage(work, kind, arguments);
        },
        .extend => {
            if (work.hasCommit() == .unborn) return work.tell("There is no commit to extend");
            try work.runCommand(.{ .commit = .{ .kind = .extend, .arguments = arguments } }, "");
        },
        .fixup => {
            const target = switch (try work.commitAtCursor()) {
                .commit => |hash| hash,
                .none => return work.tell("Put the cursor on a commit to fix up"),
                .changed => return,
            };
            // The job carries the target's short hash, which its end tells.
            try work.runCommand(.{ .commit = .{ .kind = .fixup, .target = target, .arguments = arguments } }, "");
        },
        .all, .allow_empty, .no_verify, .signoff, .reset_author => {},
    }
}

/// Starts a commit whose message is written in the buffer: empty for a new commit, `HEAD`'s for
/// an amend or a reword, asked for first. One being written already is shown again instead,
/// but one whose buffer never opened is let go.
fn startMessage(work: status.Work, kind: git.CommitKind, arguments: []const u8) !void {
    const pending = try work.pass.writeSingleton(pending_table, PendingRow);
    const phase: Phase = std.enums.fromInt(Phase, pending.phase.*) orelse .none;
    const tables = work.pass.frame.tables;
    switch (phase) {
        .none => {},
        .editing => {
            const open = text_editor.tableOf(tables, message_buffer) != null;
            const never_opened = !open and pending.buffer_seen.* == 0;
            if (!never_opened) {
                text_panel.setBufferMode(tables, message_buffer, modes.vcs_message);
                text_panel.showBuffer(tables, message_buffer, .other_window);
                return work.tell("A commit message is being written: C-c C-c commits it, C-c C-k gives it up");
            }
        },
        .loading, .verifying => return work.tell("A commit message is being written: C-c C-c commits it, C-c C-k gives it up"),
        .running => return work.tell("The commit is still running"),
    }
    const cells = try work.writeCells(pending_table);
    const root = work.cells.textOf(work.state.root.*);
    const head = switch (kind) {
        .amend, .reword => work.cells.textOf(work.state.oid.*),
        .new, .extend, .fixup => "",
    };
    try cells.assignString(pending.head, head);
    pending.kind.* = @intFromEnum(kind);
    try cells.assignString(pending.arguments, arguments);
    try cells.assignString(pending.root, root);
    try cells.assignString(pending.message, "");
    try cells.assignString(pending.draft, "");
    pending.generation.* = work.state.generation.*;
    pending.buffer_seen.* = 0;
    pending.open_waits.* = 0;
    pending.ring_position.* = 0;
    switch (kind) {
        .new => try openMessage(work, pending, ""),
        .amend, .reword => {
            pending.phase.* = @intFromEnum(Phase.loading);
            try work.askHeadMessage();
        },
        .extend, .fixup => unreachable,
    }
}

/// `HEAD`'s message, asked for an amend or a reword, answered: `said` is what git said, null
/// when it failed. An answer no commit waits for is dropped.
pub fn takeHeadMessage(work: status.Work, said: ?[]const u8) !void {
    const pending = try work.pass.writeSingleton(pending_table, PendingRow);
    if (pending.phase.* != @intFromEnum(Phase.loading)) return;
    const bytes = said orelse {
        pending.phase.* = @intFromEnum(Phase.none);
        return work.tell("git log failed; $ shows why");
    };
    const message = git.parseMessage(bytes);
    try openMessage(work, pending, message);
}

/// Shows the message buffer, made if it is not open, holding `text`, in the other window with
/// the focus and its windows' mode `vcs_message`: the commit is being written.
fn openMessage(work: status.Work, pending: PendingRow, text: []const u8) !void {
    const memory = work.pass.frame.memory;
    const tables = work.pass.frame.tables;
    if (text_editor.tableOf(tables, message_buffer) == null) {
        text_editor.request(memory, tables, .{ .create = .{ .buffer = message_buffer, .lines = .multi, .name = message_name } });
    }
    text_editor.request(memory, tables, .{ .set_text = .{ .buffer = message_buffer, .text = text } });
    text_panel.setBufferMode(tables, message_buffer, modes.vcs_message);
    text_panel.showBuffer(tables, message_buffer, .other_window);
    pending.phase.* = @intFromEnum(Phase.editing);
    pending.open_waits.* = 0;
}

/// `C-c C-c`: commits the buffer's text, unless it is empty or a commit runs. An amend or a
/// reword is refused when the status says `HEAD` moved since the message was begun, and
/// otherwise reads the status again first, running only as that refresh ends with `HEAD` still
/// there (`refreshEnded`). The buffer stays until the commit ends well (`commitEnded`).
fn finish(work: status.Work) !void {
    const pending = try work.pass.writeSingleton(pending_table, PendingRow);
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    const phase: Phase = std.enums.fromInt(Phase, pending.phase.*) orelse .none;
    switch (phase) {
        .none, .loading => return work.tell("No commit message is being written"),
        .running => return work.tell("The commit is still running"),
        .verifying => return work.tell("The status is being read before the commit runs"),
        .editing => {},
    }
    const root = work.cells.textOf(work.state.root.*);
    if (!std.mem.eql(u8, root, read.root)) return endCommit(work, .repository_changed);
    const text = try shared.textOf(work.pass.frame.tables, message_buffer);
    const blank = std.mem.trim(u8, text, " \t\r\n").len == 0;
    if (blank) return work.tell("The message is empty");
    const kind = std.enums.fromInt(git.CommitKind, pending.kind.*) orelse .new;
    if (try headMoved(work, kind)) return;
    const cells = try work.writeCells(pending_table);
    try cells.assignString(pending.message, text);
    pending.generation.* = work.state.generation.*;
    switch (kind) {
        .amend, .reword => {
            pending.phase.* = @intFromEnum(Phase.verifying);
            try work.refresh(.by_rule);
        },
        .new, .extend, .fixup => try runCommit(work, kind),
    }
}

/// Whether an amend's or a reword's `HEAD` moved since its message was begun, as the status
/// says now: told, the buffer kept. A new commit's never did.
fn headMoved(work: status.Work, kind: git.CommitKind) !bool {
    switch (kind) {
        .amend, .reword => {},
        .new, .extend, .fixup => return false,
    }
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    const head_now = work.cells.textOf(work.state.oid.*);
    if (std.mem.eql(u8, head_now, read.head)) return false;
    work.tell("HEAD moved since the message was begun: c a / c w asks again; the buffer is kept");
    return true;
}

/// Runs the commit of `kind` with the message kept in the pending row (`finish`).
fn runCommit(work: status.Work, kind: git.CommitKind) !void {
    const pending = try work.pass.writeSingleton(pending_table, PendingRow);
    pending.phase.* = @intFromEnum(Phase.running);
    pending.generation.* = work.state.generation.*;
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    try work.runCommand(.{ .commit = .{ .kind = kind, .arguments = read.arguments } }, read.message);
}

/// The refresh that ended, as `git_rebase.refreshEnded` is told it: an amend or a reword whose
/// `C-c C-c` asked it (`verifying`) runs when the status was read and `HEAD` is where it was as
/// the message was begun; else it is told, and the buffer kept for another `C-c C-c`. While a
/// command of the panel's runs, which may move `HEAD` before the commit would run, it waits for
/// the refresh that command's end asks.
pub fn refreshEnded(work: status.Work, status_read: StatusRead) !void {
    const pending = try work.pass.writeSingleton(pending_table, PendingRow);
    if (pending.phase.* != @intFromEnum(Phase.verifying)) return;
    if (work.state.commands_running.* != 0) return;
    const kind = std.enums.fromInt(git.CommitKind, pending.kind.*) orelse .new;
    // A status not read leaves HEAD as it was held: nothing verified, nothing run.
    const unread = status_read == .unread;
    if (unread) work.tell("The status could not be read ($ shows why); the commit was not made");
    if (unread or try headMoved(work, kind)) {
        pending.phase.* = @intFromEnum(Phase.editing);
        return;
    }
    try runCommit(work, kind);
}

/// A give-up of the panel's jobs (`C-g`) or a change of project while the status is read for
/// `C-c C-c`: the message is being written again, nothing run.
pub fn abandon(work: status.Work) !void {
    const pending = try work.pass.writeSingleton(pending_table, PendingRow);
    if (pending.phase.* == @intFromEnum(Phase.verifying)) pending.phase.* = @intFromEnum(Phase.editing);
}

/// Whether the status a refresh ended with is its own.
const StatusRead = @import("git_rebase.zig").StatusRead;

/// `C-c C-k` and `C-x k`: gives the commit up, its text kept among the messages for `M-p`.
fn cancel(work: status.Work) !void {
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    const phase: Phase = std.enums.fromInt(Phase, read.phase.*) orelse .none;
    switch (phase) {
        .none => return work.tell("No commit message is being written"),
        .running => return work.tell("The commit is still running"),
        .loading, .editing, .verifying => try endCommit(work, .cancelled),
    }
}

/// Why a commit being written ends without being made here, and what is told.
const Ending = enum {
    /// `C-c C-k`, `C-x k`, the buffer killed, or `HEAD`'s message given up.
    cancelled,
    /// Another repository's status is shown now.
    repository_changed,
    /// The commit's job was given up while it ran.
    gave_up_waiting,
    /// The message buffer could not be made.
    unopened,

    fn sentence(ending: Ending) []const u8 {
        return switch (ending) {
            .cancelled => "Commit cancelled",
            .repository_changed => "The repository changed; the commit was given up (M-p has the message)",
            .gave_up_waiting => "Gave up waiting for the commit; it may have been made (M-p has the message)",
            .unopened => "The message buffer could not be opened; close a buffer and try again",
        };
    }
};

/// Ends the commit being written, and tells why: its text, the buffer's or, with the buffer
/// gone, the one git was last given, is kept among the messages, and the buffer closes.
fn endCommit(work: status.Work, ending: Ending) !void {
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    const tables = work.pass.frame.tables;
    const open = text_editor.tableOf(tables, message_buffer) != null;
    const kept = if (open) try shared.textOf(tables, message_buffer) else read.message;
    const scratch = try work.pass.frame.memory.frameScratchAllocator();
    const text = try scratch.allocator.dupe(u8, kept);
    try endPending(work);
    if (ending == .unopened) {
        text_panel.forgetShowRequest(tables, message_buffer);
        text_panel.setBufferMode(tables, message_buffer, modes.buffer);
    }
    keepMessage(work, text) catch |err| Log.err("vcs_git_message_unkept", .{ .@"error" = @errorName(err) });
    work.tell(ending.sentence());
}

/// The commit's job ended: well, its message is kept, told and the buffer closed; badly (told by
/// the panel), the buffer and its text stay for another `C-c C-c`.
pub fn commitEnded(work: status.Work, outcome: Outcome) !void {
    const pending = try work.pass.writeSingleton(pending_table, PendingRow);
    if (pending.phase.* != @intFromEnum(Phase.running)) return;
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    switch (outcome) {
        .failed => pending.phase.* = @intFromEnum(Phase.editing),
        .succeeded => {
            const allocator = try work.pass.frame.memory.frameScratchAllocator();
            const message = try allocator.allocator.dupe(u8, read.message);
            try endPending(work);
            keepMessage(work, message) catch |err| Log.err("vcs_git_message_unkept", .{ .@"error" = @errorName(err) });
            const sentence = try std.fmt.allocPrint(allocator.allocator, "Committed: {s}", .{summaryOf(message)});
            work.tell(sentence);
        },
    }
}

/// A commit with no message of its own, an extend or a fixup, ended well: told, a fixup with
/// `fixup_target`, the short hash its job carried (`git_status.JobData.fixup_target`).
pub fn otherCommitEnded(work: status.Work, kind: git.CommitKind, fixup_target: []const u8) !void {
    switch (kind) {
        .extend => work.tell("Extended HEAD"),
        .fixup => {
            const allocator = try work.pass.frame.memory.frameScratchAllocator();
            const sentence = try std.fmt.allocPrint(allocator.allocator, "Made a fixup of {s}", .{fixup_target});
            work.tell(sentence);
        },
        .new, .amend, .reword => {},
    }
}

/// How a commit's job ended.
pub const Outcome = enum { succeeded, failed };

/// Nothing is being written any more: the buffer closes, and the text panels give the focus back
/// as its window shows again what it showed or closes.
fn endPending(work: status.Work) !void {
    const pending = try work.pass.writeSingleton(pending_table, PendingRow);
    pending.phase.* = @intFromEnum(Phase.none);
    pending.buffer_seen.* = 0;
    pending.open_waits.* = 0;
    pending.ring_position.* = 0;
    const cells = try work.writeCells(pending_table);
    try cells.assignString(pending.message, "");
    try cells.assignString(pending.draft, "");
    const memory = work.pass.frame.memory;
    const tables = work.pass.frame.tables;
    if (text_editor.tableOf(tables, message_buffer) != null) text_editor.request(memory, tables, .{ .close = message_buffer });
}

/// The summary of `message`: its first line that is not blank, its ends trimmed.
fn summaryOf(message: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, message, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) return trimmed;
    }
    return "";
}

// ---- the messages written ------------------------------------------------------------------------

/// Keeps `text` as the latest message, the oldest forgotten past `max_messages`; a blank one,
/// or one the latest already is, is not kept.
fn keepMessage(work: status.Work, text: []const u8) !void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
    const messages = try work.writeCells(messages_table);
    var latest_order: u32 = 0;
    var latest_text: []const u8 = "";
    var oldest: ?Table.RowHandle = null;
    var oldest_order: u32 = std.math.maxInt(u32);
    var rows = messages.readQuery(MessageRow);
    while (rows.next()) |found| {
        const order = found.view.order.*;
        if (order >= latest_order) {
            latest_order = order;
            latest_text = found.view.text;
        }
        if (order < oldest_order) {
            oldest_order = order;
            oldest = found.handle;
        }
    }
    if (messages.count() != 0 and std.mem.eql(u8, latest_text, text)) return;
    if (messages.count() >= messages.rowCapacity()) messages.free(oldest.?);
    _ = try messages.tryInsert(.{ .order = latest_order +% 1, .text = text });
}

/// Which way `M-p` and `M-n` go through the messages kept.
const Step = enum { earlier, later };

/// `M-p` and `M-n`: the buffer's text replaced by an earlier or a later message kept, the text
/// being written coming back after the latest.
fn stepMessages(work: status.Work, step: Step) !void {
    const pending = try work.pass.writeSingleton(pending_table, PendingRow);
    if (pending.phase.* != @intFromEnum(Phase.editing)) return work.tell("No commit message is being written");
    const allocator = try work.pass.frame.memory.frameScratchAllocator();
    const kept = try latestFirst(allocator.allocator, try work.pass.table(messages_table));
    const position = pending.ring_position.*;
    const tables = work.pass.frame.tables;
    const moved: u32 = switch (step) {
        .earlier => blk: {
            if (position >= kept.len) return work.tell("No earlier message");
            if (position == 0) {
                const draft = try shared.textOf(tables, message_buffer);
                const cells = try work.writeCells(pending_table);
                try cells.assignString(pending.draft, draft);
            }
            break :blk position + 1;
        },
        .later => blk: {
            if (position == 0) return work.tell("No later message");
            break :blk position - 1;
        },
    };
    pending.ring_position.* = moved;
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    const text = if (moved == 0) read.draft else kept[moved - 1];
    replaceText(work, text);
}

/// The messages kept, the latest first: slices of the table's text, in `allocator`.
fn latestFirst(allocator: std.mem.Allocator, messages: *Table) ![]const []const u8 {
    const Kept = struct { order: u32, text: []const u8 };
    var kept: std.ArrayList(Kept) = .empty;
    var rows = messages.readQuery(MessageRow);
    while (rows.next()) |found| try kept.append(allocator, .{ .order = found.view.order.*, .text = found.view.text });
    const byLatest = struct {
        fn lessThan(_: void, a: Kept, b: Kept) bool {
            return a.order > b.order;
        }
    }.lessThan;
    std.mem.sort(Kept, kept.items, {}, byLatest);
    const texts = try allocator.alloc([]const u8, kept.items.len);
    for (texts, kept.items) |*text, entry| text.* = entry.text;
    return texts;
}

/// Puts `text` in place of the message buffer's, as one step its undo takes back.
fn replaceText(work: status.Work, text: []const u8) void {
    const tables = work.pass.frame.tables;
    const state = text_editor.rowOf(tables, message_buffer) orelse return;
    const length: u32 = @intCast(state.bytes.*);
    text_editor.request(work.pass.frame.memory, tables, .{ .replace_range = .{ .buffer = message_buffer, .start = 0, .len = length, .utf8 = text, .step = .new } });
}

// ---- following what goes on ----------------------------------------------------------------------

/// A kernel of the panel's system: a commit being written is given up when the panel shows
/// another repository; when a give-up moved the panel's generation on while its own job ran,
/// `HEAD`'s message or the commit; when its buffer, once seen, is gone; and when its buffer has
/// not opened within `max_open_waits` runs. A give-up while the message is written leaves it.
pub fn followCommit(pass: *sequencer.Pass) !void {
    const read = try pass.readSingleton(pending_table, PendingRead);
    const phase: Phase = std.enums.fromInt(Phase, read.phase.*) orelse .none;
    if (phase == .none) return;
    const panel_state = try pass.readSingleton(Atom.from(status.state_table_name), struct { generation: *u32, root: []const u8 });
    const tables = pass.frame.tables;
    const open = text_editor.tableOf(tables, message_buffer) != null;
    const other_repository = !std.mem.eql(u8, panel_state.root, read.root);
    const moved_on = read.generation.* != panel_state.generation.*;
    const editing = phase == .editing;
    const verifying = phase == .verifying;
    const seen = read.buffer_seen.* != 0;
    const ending: ?Ending = if (other_repository and phase == .running)
        .gave_up_waiting
    else if (other_repository)
        .repository_changed
    else if (moved_on and phase == .running)
        .gave_up_waiting
    else if (moved_on and phase == .loading)
        .cancelled
    else if ((editing or verifying) and seen and !open)
        .cancelled
    else if (editing and !seen and !open and read.open_waits.* + 1 >= max_open_waits)
        .unopened
    else
        null;
    const waiting = editing and !seen and !open;
    const newly_seen = editing and !seen and open;
    if (ending == null and !waiting and !newly_seen) return;
    const work = try status.Work.of(pass);
    if (ending) |why| return endCommit(work, why);
    const pending = try pass.writeSingleton(pending_table, PendingRow);
    if (newly_seen) pending.buffer_seen.* = 1;
    if (waiting) pending.open_waits.* += 1;
}
