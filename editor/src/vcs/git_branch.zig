//! vcs-git's branches and merges, and the prompts vcs-git's commands read a branch, a remote or
//! a new name in: the branch menu (`b` in mode `vcs_git`), the merge menu (`m`), and the
//! dialog a command that throws work away asks first in. A part of the panel's system
//! (`git_status.zig`): what a prompt or a dialog waits on is this file's table, while the jobs,
//! their ends and what is told are the panel's (`git_status.Work`), which these functions are
//! handed.
//!
//! - The branch menu: `b` switches to a branch read in a prompt of the branches (`switch`; a
//!   remote's branch: to the local branch of its name when that tracks it, refused and told when
//!   that tracks another, else a local branch of that name made tracking it, `switch -c <name>
//!   --track`); `c`
//!   creates a branch and switches to it (`switch -c`), `n` creates one and stays (`branch`),
//!   each named in a prompt and starting at the commit under the cursor, or at `HEAD` off one;
//!   `k` deletes a local branch read in a prompt (`branch -d`), refused while a rebase is in
//!   progress (the branch rebased is not one `for-each-ref` tells), and refusing, each in its
//!   own words, when the listing failed,
//!   a name no local branch has, the branch `HEAD` is on and one checked out in a worktree, so
//!   git refusing (exit 1) is the branch not merged, and a dialog offers `branch -D`; `m` renames a local branch read in a
//!   prompt to a name read in another (`branch -m`). Each is one program, and so is each
//!   prompt's listing.
//! - The merge menu: `m` merges a branch read in a prompt into `HEAD` (`merge`, its input
//!   empty, so git keeps its own message), `a` gives up a merge in progress after a dialog
//!   (`merge --abort`); the switches `-f` `--ff-only`, `-n` `--no-ff`, `-c` `--no-commit` and
//!   `-s` `--squash`. A merge stopped on conflicts shows in the status as built, `c c`
//!   committing it once resolved.
//! - The menus' switches start off at each showing, as the commit menu's do; what a command
//!   chosen with them reads in a prompt runs with the switches as the menu closed.
//! - A prompt of the branches (`askListing` with `Listing.refs`) is filled by one
//!   `for-each-ref` asked as the prompt opens, never by a refresh; a prompt of the remotes
//!   (`Listing.remotes`), for a push, by one `git remote`; a prompt whose answer is a remote's
//!   branch (`b b`, `F e`) by both, run together, the remote's name told from the branch's by
//!   the remotes listed (a remote's name may hold a `/`). The list narrows to what is typed,
//!   and Enter on no entry takes the text typed. The log's `o` reads its revision in one too.
//! - A name a person types is checked before anything runs: a new branch's as git would take
//!   it (`git.isRefName`), any other as one argument git does not read as an option
//!   (`git.passes`); a name refused is told and its prompt opens again holding it. Names are
//!   passed after `--end-of-options` where git takes it.
//! - A dialog keeps what it asks about in the row's fields it alone writes (`askFirst`'s
//!   `Subject`), so its yes runs exactly what it showed, whatever prompt opened meanwhile.
//! - Switching with changes git would lose is git's to refuse, and what it said is in `$`: no
//!   stash is made. The commands that move `HEAD` end in a refresh as every command does,
//!   which forgets the diffs the diff panel showed.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const process = mesha.process;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const git = @import("git.zig");
const status = @import("git_status.zig");
const vcs_ask = @import("ask.zig");
const git_log = @import("git_log.zig");
const git_remote = @import("git_remote.zig");
const git_rebase = @import("git_rebase.zig");
const transient = @import("../transient.zig");
const action_palette = @import("../action_palette.zig");

// ---- the messages and the actions ------------------------------------------------------------

/// What the panel's system takes for branches, merges and the prompts: the menus' actions and
/// answers, and the prompts' and the dialog's events.
pub const Msg = enum(u64) {
    /// `b`: shows the branch menu.
    vcs_git_branch_menu = Atom.from("vcs_git_branch_menu").value(),
    /// The branch menu's answer, a `transient.Chosen`.
    vcs_git_branch_chosen = Atom.from("vcs_git_branch_chosen").value(),
    /// `m`: shows the merge menu.
    vcs_git_merge_menu = Atom.from("vcs_git_merge_menu").value(),
    /// The merge menu's answer, a `transient.Chosen`.
    vcs_git_merge_chosen = Atom.from("vcs_git_merge_chosen").value(),
    /// The events of the prompt of the branches or the remotes, palette events.
    vcs_git_choice = Atom.from("vcs_git_choice").value(),
    /// The events of the prompt of a new name, palette events.
    vcs_git_name = Atom.from("vcs_git_name").value(),
    /// The answer of the dialog a command asks first in, a palette event, its user data a
    /// `ConfirmAsked`.
    vcs_git_confirm = Atom.from("vcs_git_confirm").value(),
    _,
};

/// Whether `tag` is one of `Msg`'s.
pub fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// The actions of mode `vcs_git` that show the branch and merge menus; their keys are `b` and
/// `m`.
pub const branch_action: plugin.action_api.Def = .{ .name = "branch", .tag = @tagName(Msg.vcs_git_branch_menu), .doc = "Show the menu of branch commands" };
pub const merge_action: plugin.action_api.Def = .{ .name = "merge", .tag = @tagName(Msg.vcs_git_merge_menu), .doc = "Show the menu of merge commands" };

// ---- the menus -----------------------------------------------------------------------------------

/// The branch menu's items, by their ids.
pub const BranchItem = enum(u32) {
    switch_to = 1,
    create_switch,
    create,
    delete,
    rename,
};

/// The branch menu.
pub const branch_menu: ui.transient.Menu = .{
    .title = "Branch",
    .groups = &.{
        .{ .title = "Checkout", .items = &.{
            ui.transient.Item.command("b", "Switch to a branch", @intFromEnum(BranchItem.switch_to)),
            ui.transient.Item.command("c", "Create and switch", @intFromEnum(BranchItem.create_switch)),
        } },
        .{ .title = "Do", .items = &.{
            ui.transient.Item.command("n", "Create", @intFromEnum(BranchItem.create)),
            ui.transient.Item.command("m", "Rename", @intFromEnum(BranchItem.rename)),
            ui.transient.Item.command("k", "Delete", @intFromEnum(BranchItem.delete)),
        } },
    },
};

/// The merge menu's items, by their ids.
pub const MergeItem = enum(u32) {
    merge = 1,
    abort,
    ff_only,
    no_ff,
    no_commit,
    squash,
};

/// The merge menu: its switches, then merging and giving a merge up.
pub const merge_menu: ui.transient.Menu = .{
    .title = "Merge",
    .groups = &.{
        .{ .title = "Arguments", .items = &.{
            ui.transient.Item.toggle("-f", "Fast-forward only", "--ff-only", @intFromEnum(MergeItem.ff_only)),
            ui.transient.Item.toggle("-n", "No fast-forward", "--no-ff", @intFromEnum(MergeItem.no_ff)),
            ui.transient.Item.toggle("-c", "Do not commit", "--no-commit", @intFromEnum(MergeItem.no_commit)),
            ui.transient.Item.toggle("-s", "Squash", "--squash", @intFromEnum(MergeItem.squash)),
        } },
        .{ .title = "Merge", .items = &.{
            ui.transient.Item.command("m", "Merge a branch", @intFromEnum(MergeItem.merge)),
        } },
        .{ .title = "In progress", .items = &.{
            ui.transient.Item.command("a", "Abort", @intFromEnum(MergeItem.abort)),
        } },
    },
};

/// Shows the branch menu; its answer comes as `vcs_git_branch_chosen`.
pub fn presentBranchMenu(work: status.Work) void {
    const reply = sequencer.ReplyTo.of(status.system(), .from(Msg.vcs_git_branch_chosen));
    transient.present(work.pass.frame.memory, work.pass.frame.tables, .{ .menu = &branch_menu, .reply = reply });
}

/// Shows the merge menu, its switches off; its answer comes as `vcs_git_merge_chosen`.
pub fn presentMergeMenu(work: status.Work) void {
    const reply = sequencer.ReplyTo.of(status.system(), .from(Msg.vcs_git_merge_chosen));
    transient.present(work.pass.frame.memory, work.pass.frame.tables, .{ .menu = &merge_menu, .reply = reply });
}

// ---- the table ---------------------------------------------------------------------------------

/// `editor_vcs_git_branch`: what the prompt or the dialog open waits on, one row (`PendingRow`).
pub const pending_table_name = "editor_vcs_git_branch";
/// The owners the prompts and the dialog are presented as.
const choice_prompt_name = "vcs_git_choice_prompt";
const name_prompt_name = "vcs_git_name_prompt";
const confirm_prompt_name = "vcs_git_confirm_prompt";

const pending_table = Atom.from(pending_table_name);
const choice_prompt = Atom.from(choice_prompt_name);
const name_prompt = Atom.from(name_prompt_name);
const confirm_prompt = Atom.from(confirm_prompt_name);

/// The names this file adds to the system's `names`.
pub const names = [_][]const u8{ choice_prompt_name, name_prompt_name, confirm_prompt_name };

/// What a prompt reads for: what its answer runs.
pub const Asking = enum(u8) {
    none,
    /// The revision the log's query is written for (`l o`).
    log_revision,
    /// The branch `b b` switches to.
    switch_to,
    /// The branch `m m` merges.
    merge,
    /// The revision `r i` rebases onto, off a commit.
    rebase_base,
    /// The local branch `b k` deletes.
    delete,
    /// The local branch `b m` renames.
    rename_from,
    /// The remote's branch `F e` pulls.
    pull_from,
    /// The remote `P p` (with no upstream) and `P e` push to.
    push_to,
    /// The name of the branch `b c` makes and switches to.
    create_switch,
    /// The name of the branch `b n` makes.
    create_stay,
    /// The name `b m` gives the branch it renames.
    rename_to,

    /// What the prompt's line says.
    fn title(asking: Asking) []const u8 {
        return switch (asking) {
            .none => "",
            .log_revision => "Log of",
            .switch_to => "Switch to",
            .merge => "Merge",
            .rebase_base => "Rebase onto",
            .delete => "Delete branch",
            .rename_from => "Rename branch",
            .pull_from => "Pull from",
            .push_to => "Push to remote",
            .create_switch => "Create and switch to",
            .create_stay => "Create branch",
            .rename_to => "Rename to",
        };
    }

    /// Which branches its prompt lists.
    fn kinds(asking: Asking) Kinds {
        return switch (asking) {
            .delete, .rename_from => .local,
            .pull_from => .remote,
            else => .any,
        };
    }
};

/// Which of the branches a prompt lists.
const Kinds = enum { any, local, remote };

/// What fills a prompt's list: the branches, the remotes, or both (a prompt of remotes'
/// branches, whose remote's name is told from the branch's by the remotes, as a remote's name may
/// hold a `/`): one program each, run together.
pub const Listing = enum {
    refs,
    remotes,
    refs_and_remotes,

    /// How many programs it asks.
    fn programs(listing: Listing) u8 {
        return switch (listing) {
            .refs, .remotes => 1,
            .refs_and_remotes => 2,
        };
    }
};

/// What one listing program answered.
pub const Listed = enum {
    refs,
    remotes,

    /// Its bit of `PendingRow.listings_failed`.
    fn bit(listed: Listed) u8 {
        return @as(u8, 1) << @intFromEnum(listed);
    }
};

/// What a dialog asks before a command runs.
pub const Confirm = enum(u8) {
    none,
    /// `branch -D` of the branch `-d` refused, named in `PendingRow.name`.
    force_delete,
    /// `merge --abort`.
    merge_abort,
    /// `rebase --abort`.
    rebase_abort,
    /// A push with `--force`, its arguments, remote and branch in the row.
    force_push,
};

/// The row of `editor_vcs_git_branch`. Text is in its text cells.
pub const PendingRow = struct {
    /// An `Asking`: what the prompt open reads for; `none` while none is.
    asking: *u8,
    /// What `for-each-ref` said, the branches, while the prompt it fills is open.
    listing: *Table.Bytes,
    /// What `git remote` said, the remotes, while the prompt it fills is open.
    remotes: *Table.Bytes,
    /// Counts the listings asked: an answer of an earlier ask is dropped.
    listing_serial: *u32,
    /// How many of the listings the prompt waits on have not answered: it opens at 0.
    listings_waiting: *u8,
    /// Which of the prompt's listings failed, a bit each (`Listed.bit`): what they would have
    /// checked is then not run.
    listings_failed: *u8,
    /// The arguments of the menu the prompt was opened from, each followed by the separator,
    /// for the command its answer runs.
    arguments: *Table.String,
    /// A branch or a commit named before the second prompt: the start of a branch made, the
    /// branch renamed.
    name: *Table.String,
    /// The branch the last `branch -d` was run for, which its refusal's dialog names.
    deleting: *Table.String,
    /// A `Confirm`: what the dialog open asks; `none` while none is.
    confirm: *u8,
    /// Counts the dialogs asked: an answer of an earlier one is dropped.
    confirm_serial: *u32,
    /// What the dialog open asks about, written as it is asked and by nothing else, so its yes
    /// runs what it showed: a branch, and a push's arguments, remote and branch.
    confirm_name: *Table.String,
    confirm_arguments: *Table.String,
    confirm_remote: *Table.String,
    confirm_branch: *Table.String,
};

/// `PendingRow` read, its text as slices of the table's.
pub const PendingRead = struct {
    asking: *u8,
    listing: []const u8,
    remotes: []const u8,
    listing_serial: *u32,
    listings_waiting: *u8,
    listings_failed: *u8,
    arguments: []const u8,
    name: []const u8,
    deleting: []const u8,
    confirm: *u8,
    confirm_serial: *u32,
    confirm_name: []const u8,
    confirm_arguments: []const u8,
    confirm_remote: []const u8,
    confirm_branch: []const u8,
};

/// Makes the branches' table unless it is there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ pending_table_name, choice_prompt_name, name_prompt_name, confirm_prompt_name });
    var pending: Table.Schema = undefined;
    try pending.init(scratch.allocator, atoms, 15);
    defer pending.deinit();
    try pending.addFieldFallible("asking", u8, .int);
    try pending.addFieldFallible("listing", Table.Bytes, .bytes);
    try pending.addFieldFallible("remotes", Table.Bytes, .bytes);
    try pending.addFieldFallible("listing_serial", u32, .int);
    try pending.addFieldFallible("listings_waiting", u8, .int);
    try pending.addFieldFallible("listings_failed", u8, .int);
    try pending.addFieldFallible("arguments", Table.String, .text_field);
    try pending.addFieldFallible("name", Table.String, .text_field);
    try pending.addFieldFallible("deleting", Table.String, .text_field);
    try pending.addFieldFallible("confirm", u8, .int);
    try pending.addFieldFallible("confirm_serial", u32, .int);
    try pending.addFieldFallible("confirm_name", Table.String, .text_field);
    try pending.addFieldFallible("confirm_arguments", Table.String, .text_field);
    try pending.addFieldFallible("confirm_remote", Table.String, .text_field);
    try pending.addFieldFallible("confirm_branch", Table.String, .text_field);
    const defaults = .{
        .asking = @as(u8, @intFromEnum(Asking.none)),
        .listing = Table.Bytes{},
        .remotes = Table.Bytes{},
        .listing_serial = @as(u32, 0),
        .listings_waiting = @as(u8, 0),
        .listings_failed = @as(u8, 0),
        .arguments = Table.String{},
        .name = Table.String{},
        .deleting = Table.String{},
        .confirm = @as(u8, @intFromEnum(Confirm.none)),
        .confirm_serial = @as(u32, 0),
        .confirm_name = Table.String{},
        .confirm_arguments = Table.String{},
        .confirm_remote = Table.String{},
        .confirm_branch = Table.String{},
    };
    _ = try tables.ensureSingleton(&pending, pending_table, defaults, .durable);
}

/// What the branches read and write, for the panel's system's access: their row.
pub fn declareAccess(result: *sequencer.Access) void {
    result.write(pending_table);
}

// ---- taking the messages -------------------------------------------------------------------------

/// One of `Msg`'s, which `claims` took.
pub fn take(work: status.Work, received: sequencer.Message) !void {
    switch (received.tag.to(Msg)) {
        .vcs_git_branch_menu => presentBranchMenu(work),
        .vcs_git_merge_menu => presentMergeMenu(work),
        .vcs_git_branch_chosen => {
            const chosen = try received.payloadAs(transient.Chosen);
            if (chosen.cancelled != 0) return;
            const item = std.enums.fromInt(BranchItem, chosen.id) orelse return;
            try chooseBranch(work, item);
        },
        .vcs_git_merge_chosen => {
            const chosen = try received.payloadAs(transient.Chosen);
            if (chosen.cancelled != 0) return;
            const item = std.enums.fromInt(MergeItem, chosen.id) orelse return;
            try chooseMerge(work, item, chosen.state);
        },
        .vcs_git_choice => try takeChoice(work, received),
        .vcs_git_name => try takeName(work, received),
        .vcs_git_confirm => try takeConfirm(work, received),
        _ => {},
    }
}

/// What the branch command chosen does: a prompt, of the branches or of a new name.
fn chooseBranch(work: status.Work, item: BranchItem) !void {
    switch (item) {
        .switch_to => try askListing(work, .switch_to, "", .refs_and_remotes),
        .delete => try askListing(work, .delete, "", .refs),
        .rename => try askListing(work, .rename_from, "", .refs),
        .create_switch, .create => {
            if (work.rootUnknown()) return;
            // At the commit under the cursor, else at `HEAD`.
            const start: []const u8 = switch (try work.commitAtCursor()) {
                .commit => |hash| hash,
                .none => "",
                .changed => return,
            };
            const asking: Asking = if (item == .create_switch) .create_switch else .create_stay;
            try setPending(work, .{ .asking = asking, .name = start });
            // A listing asked before (`b b`) is no longer awaited: its answer would open its
            // prompt over this one.
            const row = try work.pass.writeSingleton(pending_table, PendingRow);
            row.listing_serial.* +%= 1;
            row.listings_waiting.* = 0;
            try presentName(work, "");
        },
    }
}

/// What the merge command chosen does, with the switches `state` has on.
fn chooseMerge(work: status.Work, item: MergeItem, state: ui.transient.State) !void {
    switch (item) {
        .merge => {
            const allocator = try work.scratch();
            var arguments: std.Io.Writer.Allocating = .init(allocator);
            try ui.transient.writeArguments(&merge_menu, &state, process.argument_separator, &arguments.writer);
            try askListing(work, .merge, arguments.written(), .refs);
        },
        .abort => {
            if (work.state.operation.* != @intFromEnum(git.Operation.merging)) return work.tell("No merge is in progress");
            try askFirst(work, .merge_abort, .{ .title = "Abort the merge?", .body = "Its changes, and the conflicts resolved so far, are thrown away", .confirm = "Abort" }, .{});
        },
        .ff_only, .no_ff, .no_commit, .squash => {},
    }
}

/// What a prompt or a dialog is opened with, written into the row.
const Pending = struct {
    asking: Asking = .none,
    arguments: []const u8 = "",
    name: []const u8 = "",
};

/// The row set for a prompt about to open: what it reads for, the menu's arguments and the name
/// it carries.
fn setPending(work: status.Work, pending: Pending) !void {
    const allocator = try work.scratch();
    // Copied first: they may be the table's own text, which an assignment moves.
    const arguments = try allocator.dupe(u8, pending.arguments);
    const name = try allocator.dupe(u8, pending.name);
    const row = try work.pass.writeSingleton(pending_table, PendingRow);
    const cells = try work.writeCells(pending_table);
    row.asking.* = @intFromEnum(pending.asking);
    try cells.assignString(row.arguments, arguments);
    try cells.assignString(row.name, name);
}

// ---- the prompt of the branches or the remotes ---------------------------------------------------

/// Asks for what fills a prompt for `asking`: the branches (one `for-each-ref`) or the remotes
/// (one `git remote`), which open the prompt as they answer (`takeListing`); `arguments`, the
/// menu's, are kept for the command its answer runs.
pub fn askListing(work: status.Work, asking: Asking, arguments: []const u8, listing: Listing) !void {
    if (work.rootUnknown()) return;
    try setPending(work, .{ .asking = asking, .arguments = arguments });
    const row = try work.pass.writeSingleton(pending_table, PendingRow);
    row.listing_serial.* +%= 1;
    row.listings_waiting.* = listing.programs();
    row.listings_failed.* = 0;
    row.listing.* = .{};
    row.remotes.* = .{};
    switch (listing) {
        .refs => try work.queueRead(.refs, .refs, row.listing_serial.*),
        .remotes => try work.queueRead(.remotes, .remotes, row.listing_serial.*),
        .refs_and_remotes => {
            try work.queueRead(.refs, .refs, row.listing_serial.*);
            try work.queueRead(.remotes, .remotes, row.listing_serial.*);
        },
    }
}

/// A listing's answer, `said`, what `listed` asked, null for one that failed: kept while the
/// prompt it fills is open, which opens once every listing it waits on answered. A failure is
/// told, and the prompt opens listing what the others gave, taking text typed. An answer of an
/// earlier ask is dropped.
pub fn takeListing(work: status.Work, listed: Listed, epoch: u32, said: ?[]const u8) !void {
    const row = try work.pass.writeSingleton(pending_table, PendingRow);
    if (epoch != row.listing_serial.* or row.listings_waiting.* == 0) return;
    const cells = try work.writeCells(pending_table);
    const bytes = said orelse "";
    const kept: Table.Bytes = .{ .payload = try cells.appendPayload(bytes, .@"1") };
    switch (listed) {
        .refs => row.listing.* = kept,
        .remotes => row.remotes.* = kept,
    }
    if (said == null) row.listings_failed.* |= listed.bit();
    if (said == null) work.tell(switch (listed) {
        .refs => "git for-each-ref failed; $ shows why",
        .remotes => "git remote failed; $ shows why",
    });
    row.listings_waiting.* -= 1;
    if (row.listings_waiting.* != 0) return;
    try presentChoice(work, "", .open);
}

/// Whether the prompt opens or narrows what it lists to what is typed.
const Prompting = enum { open, narrow };

/// The prompt of the branches (local first) or the remotes kept, those whose names hold
/// `query`, the text it opens with; Enter on none takes the text typed. A branch's entry carries
/// its full name (`refs/heads/main`), which tells a local branch from a remote's.
fn presentChoice(work: status.Work, query: []const u8, prompting: Prompting) !void {
    const memory = work.pass.frame.memory;
    const tables = work.pass.frame.tables;
    const allocator = try action_palette.completionAllocator(memory, .vcs);
    // While narrowing the arena is not reset: the prompt may still read the entries it shows.
    if (prompting == .open) action_palette.resetCompletionArena(memory, .vcs);
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    const asking = std.enums.fromInt(Asking, read.asking.*) orelse .none;
    const typed = std.mem.trim(u8, query, " ");
    var entries: std.ArrayList(action_palette.Completion) = .empty;
    if (asking == .push_to) {
        const found = try allocator.alloc([]const u8, max_listed);
        const counted = git.parseRemotes(read.remotes, found);
        for (found[0..counted.kept]) |remote| {
            if (std.ascii.indexOfIgnoreCase(remote, typed) == null) continue;
            const label = try ui.displayText(allocator, remote);
            try entries.append(allocator, .{ .label = try allocator.dupe(u8, label), .key = try allocator.dupe(u8, remote) });
        }
    } else {
        const found = try allocator.alloc(git.Ref, max_listed);
        const counted = git.parseRefs(read.listing, found);
        const kinds = asking.kinds();
        for (found[0..counted.kept]) |ref| {
            const wanted = switch (kinds) {
                .any => true,
                .local => ref.kind == .local,
                .remote => ref.kind == .remote,
            };
            if (!wanted) continue;
            if (std.ascii.indexOfIgnoreCase(ref.short_name, typed) == null) continue;
            const label = try ui.displayText(allocator, ref.short_name);
            const detail = if (ref.current) "HEAD" else "";
            try entries.append(allocator, .{ .label = try allocator.dupe(u8, label), .key = try allocator.dupe(u8, ref.name), .detail = detail });
        }
    }
    const completions = try allocator.create(action_palette.Completions);
    completions.* = .{
        .owner = choice_prompt,
        .presentation = .prompt,
        .title = asking.title(),
        .initial_query = try allocator.dupe(u8, query),
        .accepts_text = true,
        .entries = entries.items,
    };
    try action_palette.ownRequestText(allocator, completions);
    if (prompting == .narrow) {
        action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
        return;
    }
    const reply = sequencer.ReplyTo.of(status.system(), .from(Msg.vcs_git_choice));
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

/// The most branches or remotes a prompt lists.
const max_listed = 1024;

/// What a prompt of the branches answered: an entry, by its full name, or the text typed.
pub const Picked = union(enum) {
    /// A branch listed, its full name (`refs/heads/main`, `refs/remotes/origin/main`), or a
    /// remote listed, its name.
    listed: []const u8,
    /// Text typed that names no entry, as typed.
    typed: []const u8,

    /// The name a person reads and git takes: a branch's short name, or the text typed.
    pub fn shortName(picked: Picked) []const u8 {
        return switch (picked) {
            .typed => |text| text,
            .listed => |name| {
                const prefixes = [_][]const u8{ "refs/heads/", "refs/remotes/" };
                for (prefixes) |prefix| {
                    if (std.mem.startsWith(u8, name, prefix)) return name[prefix.len..];
                }
                return name;
            },
        };
    }

    /// Whether it is a remote's branch listed.
    fn isRemoteBranch(picked: Picked) bool {
        return switch (picked) {
            .typed => false,
            .listed => |name| std.mem.startsWith(u8, name, "refs/remotes/"),
        };
    }
};

/// The prompt's events: the list narrowed as the text changes; on Enter what was chosen runs
/// for what the prompt reads (`runChoice`). A choice refused is told, and the prompt opens again
/// holding it; closed with nothing, nothing runs.
fn takeChoice(work: status.Work, received: sequencer.Message) !void {
    const event = try action_palette.eventOf(received);
    if (event.kind == .query_changed) return presentChoice(work, event.query, .narrow);
    action_palette.request(work.pass.frame.memory, work.pass.frame.tables, .{ .acknowledge = .{ .owner = choice_prompt } });
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    const asking = std.enums.fromInt(Asking, read.asking.*) orelse .none;
    const chosen = event.completion orelse return forgetPrompt(work, asking);
    const allocator = try work.scratch();
    const typed = std.mem.trim(u8, event.query, " ");
    const picked: Picked = if (chosen.key.len != 0)
        .{ .listed = try allocator.dupe(u8, chosen.key) }
    else
        .{ .typed = try allocator.dupe(u8, typed) };
    if (picked.shortName().len == 0) return forgetPrompt(work, asking);
    const arguments = try allocator.dupe(u8, read.arguments);
    const listing: Listings = .{ .refs = try allocator.dupe(u8, read.listing), .remotes = try allocator.dupe(u8, read.remotes), .failed = read.listings_failed.* };
    switch (try runChoice(work, asking, picked, arguments, listing)) {
        .ran => try forgetPrompt(work, asking),
        .refused => try presentChoice(work, picked.shortName(), .open),
        // What it reads waits on a program, whose answer ends the prompt (`takeResolved`).
        .waiting => {},
    }
}

/// Whether what a prompt answered ran, was refused and told, or waits on a program.
pub const Outcome = enum { ran, refused, waiting };

/// What the listings a prompt was filled from said, in the frame's memory.
const Listings = struct {
    /// `for-each-ref`'s answer.
    refs: []const u8,
    /// `git remote`'s answer.
    remotes: []const u8,
    /// Which of them failed (`Listed.bit`).
    failed: u8,

    /// Whether `listed` answered: told when it did not, as what it would have checked is then
    /// not known.
    fn answered(listings: Listings, work: status.Work, listed: Listed) bool {
        if (listings.failed & listed.bit() == 0) return true;
        work.tell(switch (listed) {
            .refs => "git could not list the branches ($ shows why), so that name could not be checked: nothing was run",
            .remotes => "git could not list the remotes ($ shows why), so that name could not be checked: nothing was run",
        });
        return false;
    }

    /// The branch whose full or short name is `name`, as listed; null for none.
    fn ref(listings: Listings, allocator: std.mem.Allocator, name: []const u8) !?git.Ref {
        const found = try allocator.alloc(git.Ref, max_listed);
        const counted = git.parseRefs(listings.refs, found);
        for (found[0..counted.kept]) |each| {
            if (std.mem.eql(u8, each.name, name) or std.mem.eql(u8, each.short_name, name)) return each;
        }
        return null;
    }

    /// The local branch named `name`; null for none.
    fn local(listings: Listings, allocator: std.mem.Allocator, name: []const u8) !?git.Ref {
        const full = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
        return listings.ref(allocator, full);
    }

    /// `remote_branch` (`origin/main`) split into a listed remote's name and the branch after
    /// it, the longest remote that begins it winning, as a remote's name may hold a `/`; null
    /// when no remote listed begins it.
    fn splitRemote(listings: Listings, allocator: std.mem.Allocator, remote_branch: []const u8) !?RemoteBranch {
        const found = try allocator.alloc([]const u8, max_listed);
        const counted = git.parseRemotes(listings.remotes, found);
        var best: ?RemoteBranch = null;
        for (found[0..counted.kept]) |remote| {
            const begins = remote_branch.len > remote.len + 1 and std.mem.startsWith(u8, remote_branch, remote) and remote_branch[remote.len] == '/';
            if (!begins) continue;
            if (best) |kept| if (kept.remote.len >= remote.len) continue;
            best = .{ .remote = remote, .branch = remote_branch[remote.len + 1 ..] };
        }
        return best;
    }
};

/// A remote's branch: the remote's name and the branch's on it.
const RemoteBranch = struct { remote: []const u8, branch: []const u8 };

/// Runs what `asking` reads `picked` for, with the menu's `arguments`, against what the prompt
/// was filled from, `listings`.
fn runChoice(work: status.Work, asking: Asking, picked: Picked, arguments: []const u8, listings: Listings) !Outcome {
    const name = picked.shortName();
    const allocator = try work.scratch();
    switch (asking) {
        .none, .create_switch, .create_stay, .rename_to => return .ran,
        .log_revision => {
            try git_log.runRevision(work, name);
            return .ran;
        },
        .switch_to => {
            if (!picked.isRemoteBranch()) return runChecked(work, .{ .switch_to = name });
            if (!listings.answered(work, .remotes)) return .ran;
            return switchToRemote(work, allocator, name, listings);
        },
        .merge => return runChecked(work, .{ .merge = .{ .arguments = arguments, .revision = name } }),
        .rebase_base => {
            if (try baseOf(allocator, name, listings)) |base| return git_rebase.listCommits(work, base, arguments);
            return resolve(work, name, arguments);
        },
        .delete => {
            if (!listings.answered(work, .refs)) return .ran;
            return deleteBranch(work, allocator, name, listings);
        },
        .rename_from => {
            if (!git.passes(.{ .delete_branch = .{ .name = name } })) return refuseName(work);
            try setPending(work, .{ .asking = .rename_to, .name = name });
            try presentName(work, name);
            return .ran;
        },
        .pull_from => {
            if (!listings.answered(work, .remotes)) return .ran;
            const split = try listings.splitRemote(allocator, name) orelse {
                work.tell("Name a remote's branch, its remote's name first: origin/main");
                return .refused;
            };
            return git_remote.pullFrom(work, arguments, split.remote, split.branch);
        },
        .push_to => return git_remote.pushTo(work, arguments, name),
    }
}

/// A revision typed for `r i` that is no branch listed or full hash (`HEAD~3`, a short hash, a
/// tag): one `rev-parse --verify` finds its commit (`takeResolved`), the prompt waiting; one git
/// cannot be given is refused.
fn resolve(work: status.Work, revision: []const u8, arguments: []const u8) !Outcome {
    if (!git.passes(.{ .resolve = revision })) return refuseName(work);
    try setPending(work, .{ .asking = .rebase_base, .arguments = arguments, .name = revision });
    const row = try work.pass.writeSingleton(pending_table, PendingRow);
    try work.queueRead(.resolve, .{ .resolve = revision }, row.listing_serial.*);
    return .waiting;
}

/// `resolve`'s answer, `said`, null for a revision git could not find: its commit's hash lists
/// the rebase onto it; else told, and the prompt opens again holding the text. An answer of an
/// earlier prompt is dropped.
pub fn takeResolved(work: status.Work, epoch: u32, said: ?[]const u8) !void {
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    const waiting = read.asking.* == @intFromEnum(Asking.rebase_base) and epoch == read.listing_serial.*;
    if (!waiting) return;
    const allocator = try work.scratch();
    const revision = try allocator.dupe(u8, read.name);
    const arguments = try allocator.dupe(u8, read.arguments);
    const bytes = said orelse {
        work.tell(try std.fmt.allocPrint(allocator, "git cannot find the revision {s}", .{try ui.displayText(allocator, revision)}));
        return presentChoice(work, revision, .open);
    };
    const hash = try allocator.dupe(u8, std.mem.trim(u8, bytes, " \r\n"));
    switch (try git_rebase.listCommits(work, .{ .hash = hash, .shown = revision }, arguments)) {
        .refused => try presentChoice(work, revision, .open),
        .ran, .waiting => try forgetPrompt(work, .rebase_base),
    }
}

/// `b b` on a remote's branch, `remote_branch` (`origin/topic`): the local branch of its name
/// when there is one tracking it; when one of that name tracks something else, told and nothing
/// run; with none, one of that name made tracking it (`switch -c <name> --track`), the name the
/// one checked, not the one git would derive.
fn switchToRemote(work: status.Work, allocator: std.mem.Allocator, remote_branch: []const u8, listings: Listings) !Outcome {
    const split = try listings.splitRemote(allocator, remote_branch) orelse {
        work.tell("No remote listed begins that branch's name; git remote lists them");
        return .refused;
    };
    const local = try listings.local(allocator, split.branch) orelse return runChecked(work, .{ .switch_track = .{ .name = split.branch, .remote_branch = remote_branch } });
    if (std.mem.eql(u8, local.upstream, remote_branch)) return runChecked(work, .{ .switch_to = split.branch });
    const sentence = try std.fmt.allocPrint(allocator, "A local branch {s} already exists and does not track {s}", .{ try ui.displayText(allocator, split.branch), try ui.displayText(allocator, remote_branch) });
    work.tell(sentence);
    return .refused;
}

/// The commit a rebase onto `name` is onto: a branch listed, by the commit it is at; a full hash
/// typed, itself; null for anything else, which a later move could change under the list.
fn baseOf(allocator: std.mem.Allocator, name: []const u8, listings: Listings) !?git_rebase.Base {
    if (try listings.ref(allocator, name)) |listed| {
        if (listed.hash.len == 0) return null;
        return .{ .hash = listed.hash, .shown = listed.short_name };
    }
    const full = name.len == 40 or name.len == 64;
    const hex = for (name) |byte| {
        if (!std.ascii.isHex(byte)) break false;
    } else true;
    if (!full or !hex) return null;
    return .{ .hash = name, .shown = name[0..7] };
}

/// `b k` of `name`: refused, each told in its own words, for a name that is no local branch
/// listed, the branch `HEAD` is on, and one checked out in a worktree; else `branch -d`, so a
/// refusal of git's (exit 1) is the branch not merged, which the dialog says.
fn deleteBranch(work: status.Work, allocator: std.mem.Allocator, name: []const u8, listings: Listings) !Outcome {
    // The branch being rebased is checked out though HEAD is detached, and git does not say
    // which it is where `for-each-ref` reads.
    if (work.state.operation.* == @intFromEnum(git.Operation.rebasing)) {
        work.tell("A rebase is in progress: b k waits until it ends (r r, r a)");
        return .ran;
    }
    const shown = try ui.displayText(allocator, name);
    const local = try listings.local(allocator, name) orelse {
        work.tell(try std.fmt.allocPrint(allocator, "There is no local branch {s}", .{shown}));
        return .refused;
    };
    if (local.current) {
        work.tell("That is the branch HEAD is on: switch to another first");
        return .refused;
    }
    if (local.worktree.len != 0) {
        work.tell(try std.fmt.allocPrint(allocator, "{s} is checked out in the worktree {s}", .{ shown, try ui.displayText(allocator, local.worktree) }));
        return .refused;
    }
    const outcome = try runChecked(work, .{ .delete_branch = .{ .name = name } });
    if (outcome == .ran) {
        const row = try work.pass.writeSingleton(pending_table, PendingRow);
        const cells = try work.writeCells(pending_table);
        const kept = try allocator.dupe(u8, name);
        try cells.assignString(row.deleting, kept);
    }
    return outcome;
}

/// Runs `command`, a command of the panel's with no input, when every name in it passes as one
/// argument git does not read as an option (`git.passes`); refused and told otherwise.
pub fn runChecked(work: status.Work, command: git.Command) !Outcome {
    if (!git.passes(command)) return refuseName(work);
    try work.runCommand(command, "");
    return .ran;
}

fn refuseName(work: status.Work) Outcome {
    work.tell("git cannot be given that name: it begins with - or holds a control character");
    return .refused;
}

/// The prompt for `answered` ended: the listing kept for it is let go, and nothing is asked any
/// more, unless its answer opened another prompt, which asks for its own.
fn forgetPrompt(work: status.Work, answered: Asking) !void {
    const row = try work.pass.writeSingleton(pending_table, PendingRow);
    if (row.asking.* == @intFromEnum(answered)) row.asking.* = @intFromEnum(Asking.none);
    row.listing.* = .{};
    row.remotes.* = .{};
}

// ---- the prompt of a new name ---------------------------------------------------------------------

/// The prompt of a branch's new name, opening holding `holding`; its answer comes as
/// `vcs_git_name`.
fn presentName(work: status.Work, holding: []const u8) !void {
    const memory = work.pass.frame.memory;
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    const asking = std.enums.fromInt(Asking, read.asking.*) orelse .none;
    const allocator = try action_palette.completionAllocator(memory, .vcs);
    action_palette.resetCompletionArena(memory, .vcs);
    const title = switch (asking) {
        .rename_to => try std.fmt.allocPrint(allocator, "Rename {s} to", .{try ui.displayText(allocator, read.name)}),
        .create_switch, .create_stay => if (read.name.len == 0)
            try std.fmt.allocPrint(allocator, "{s} (at HEAD)", .{asking.title()})
        else
            try std.fmt.allocPrint(allocator, "{s} (at {s})", .{ asking.title(), read.name[0..@min(read.name.len, 7)] }),
        else => asking.title(),
    };
    const completions = try allocator.create(action_palette.Completions);
    completions.* = .{
        .owner = name_prompt,
        .presentation = .prompt,
        .title = title,
        .initial_query = try allocator.dupe(u8, holding),
        .initial_query_edit = .append,
        .accepts_text = true,
        .entries = &.{},
    };
    try action_palette.ownRequestText(allocator, completions);
    const reply = sequencer.ReplyTo.of(status.system(), .from(Msg.vcs_git_name));
    action_palette.request(memory, work.pass.frame.tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

/// The name prompt's events: on Enter a name git takes for a branch (`git.isRefName`) makes or
/// renames it; another is told, and the prompt opens again holding it.
fn takeName(work: status.Work, received: sequencer.Message) !void {
    const event = try action_palette.eventOf(received);
    if (event.kind == .query_changed) return;
    action_palette.request(work.pass.frame.memory, work.pass.frame.tables, .{ .acknowledge = .{ .owner = name_prompt } });
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    const asking = std.enums.fromInt(Asking, read.asking.*) orelse .none;
    _ = event.completion orelse return forgetPrompt(work, asking);
    const allocator = try work.scratch();
    const typed = try allocator.dupe(u8, std.mem.trim(u8, event.query, " \t\r\n"));
    if (typed.len == 0) return forgetPrompt(work, asking);
    const name = try allocator.dupe(u8, read.name);
    if (!git.isRefName(typed)) {
        work.tell("git takes no branch of that name: no space, ~ ^ : ? * [ \\ or .., and no - first");
        return presentName(work, typed);
    }
    const outcome = switch (asking) {
        .create_switch => try runChecked(work, .{ .create_branch = .{ .name = typed, .start = name, .after = .switch_to } }),
        .create_stay => try runChecked(work, .{ .create_branch = .{ .name = typed, .start = name, .after = .stay } }),
        .rename_to => try runChecked(work, .{ .rename_branch = .{ .name = name, .new_name = typed } }),
        else => Outcome.ran,
    };
    switch (outcome) {
        .ran, .waiting => try forgetPrompt(work, asking),
        .refused => try presentName(work, typed),
    }
}

// ---- deleting a branch git refused -----------------------------------------------------------------

/// `branch -d` ended: refused by git with its exit code 1, which for a local branch listed and
/// checked out nowhere (`deleteBranch` refused the rest) is the branch not merged into its
/// upstream or `HEAD`, a dialog offers `branch -D`. Any other failure was told as it is.
pub fn deleteEnded(work: status.Work, refused: bool) !void {
    if (!refused) return;
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    if (read.deleting.len == 0) return;
    const allocator = try work.scratch();
    const name = try allocator.dupe(u8, read.deleting);
    const shown = try ui.displayText(allocator, name);
    const title = try std.fmt.allocPrint(allocator, "Delete {s} anyway?", .{shown});
    try askFirst(work, .force_delete, .{ .title = title, .body = "git branch -d refused: it is not merged into its upstream or HEAD. -D deletes it, and the commits only it holds", .confirm = "Delete with -D" }, .{ .name = name });
}

// ---- the dialog asked first ---------------------------------------------------------------------

/// A dialog's words.
pub const Question = vcs_ask.Question;

/// What a dialog asks about, kept with it as it is asked, so its yes runs exactly that: a branch
/// to delete, or a push's arguments, remote and branch.
pub const Subject = struct {
    name: []const u8 = "",
    arguments: []const u8 = "",
    remote: []const u8 = "",
    branch: []const u8 = "",
};

/// A dialog's user data: what it asks and which time.
pub const ConfirmAsked = extern struct {
    /// A `Confirm`.
    confirm: u8,
    reserved: [3]u8 = @splat(0),
    /// `PendingRow.confirm_serial` as it was asked.
    serial: u32,
};

/// Asks `question` in a dialog before `confirm` runs on `subject`, kept in the row's fields the
/// dialog alone writes: its yes, and only its latest, runs it (`takeConfirm`).
pub fn askFirst(work: status.Work, confirm: Confirm, question: Question, subject: Subject) !void {
    const allocator = try work.scratch();
    // Copied first: they may be the table's text, which an assignment moves.
    const kept: Subject = .{
        .name = try allocator.dupe(u8, subject.name),
        .arguments = try allocator.dupe(u8, subject.arguments),
        .remote = try allocator.dupe(u8, subject.remote),
        .branch = try allocator.dupe(u8, subject.branch),
    };
    const row = try work.pass.writeSingleton(pending_table, PendingRow);
    const cells = try work.writeCells(pending_table);
    try cells.assignString(row.confirm_name, kept.name);
    try cells.assignString(row.confirm_arguments, kept.arguments);
    try cells.assignString(row.confirm_remote, kept.remote);
    try cells.assignString(row.confirm_branch, kept.branch);
    row.confirm.* = @intFromEnum(confirm);
    row.confirm_serial.* +%= 1;
    const asked: ConfirmAsked = .{ .confirm = @intFromEnum(confirm), .serial = row.confirm_serial.* };
    const reply = sequencer.ReplyTo.of(status.system(), .from(Msg.vcs_git_confirm)).with(.of(&asked));
    try vcs_ask.presentDialog(work.pass.frame.memory, work.pass.frame.tables, confirm_prompt, question, reply);
}

/// The dialog's answer: its yes, to the dialog asked last, runs what it asked about; anything
/// else runs nothing.
fn takeConfirm(work: status.Work, received: sequencer.Message) !void {
    const event = try action_palette.eventOf(received);
    if (event.kind != .completed) return;
    action_palette.request(work.pass.frame.memory, work.pass.frame.tables, .{ .acknowledge = .{ .owner = confirm_prompt } });
    const asked = (try received.userDataAs(ConfirmAsked)).*;
    const row = try work.pass.writeSingleton(pending_table, PendingRow);
    const latest = asked.serial == row.confirm_serial.* and asked.confirm == row.confirm.*;
    if (!latest) return;
    row.confirm.* = @intFromEnum(Confirm.none);
    if (!vcs_ask.confirmed(event.completion)) return;
    const read = try work.pass.readSingleton(pending_table, PendingRead);
    const allocator = try work.scratch();
    const confirm = std.enums.fromInt(Confirm, asked.confirm) orelse return;
    switch (confirm) {
        .none => {},
        .force_delete => {
            const name = try allocator.dupe(u8, read.confirm_name);
            _ = try runChecked(work, .{ .delete_branch = .{ .name = name, .how = .force } });
        },
        .merge_abort => try work.runCommand(.merge_abort, ""),
        .rebase_abort => try work.runCommand(.rebase_abort, ""),
        .force_push => {
            const arguments = try allocator.dupe(u8, read.confirm_arguments);
            const remote = try allocator.dupe(u8, read.confirm_remote);
            const branch = try allocator.dupe(u8, read.confirm_branch);
            _ = try runChecked(work, .{ .push = .{ .arguments = arguments, .remote = remote, .branch = branch } });
        },
    }
}
