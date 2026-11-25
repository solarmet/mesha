//! vcs-git's remotes: the push menu (`P` in mode `vcs_git`), the pull menu (`F`) and the fetch
//! menu (`f`). A part of the panel's system (`git_status.zig`); the prompts they read a remote
//! or a remote's branch in, and the dialog a forced push asks first in, are `git_branch.zig`'s.
//!
//! - Push: `p` pushes the branch `HEAD` is on to its upstream (`push`); with no upstream it reads
//!   a remote in a prompt of the remotes (one `git remote`) and pushes the branch there, setting
//!   it as the upstream (`push -u <remote> <branch>`); `e` pushes it to a remote read in that
//!   prompt (`push <remote> <branch>`). The switches: `-f` `--force-with-lease`, `-F` `--force`,
//!   `-n` `--dry-run`, `-t` `--tags`, `-u` `--set-upstream`. A push with `--force` asks first in
//!   a dialog, as it may throw away what only the remote holds; `--force-with-lease` does not,
//!   as git refuses it then.
//! - Pull: `p` pulls the branch's upstream into it (`pull`), told and not run with no upstream;
//!   `e` pulls a remote's branch read in a prompt of the remotes' branches (`pull <remote>
//!   <branch>`), filled by `for-each-ref` and `git remote` run together, the remote's name told
//!   from the branch's by the remotes listed. The switches: `-r` `--rebase`, `-f` `--ff-only`.
//! - Fetch: `f` fetches the upstream's remote, or `origin` (`fetch`), `a` every remote (`fetch
//!   --all`); the switch `-p` `--prune`.
//! - Each command is one program, run alone, its input empty. It may take long: the panel's
//!   spinner turns while it runs, and `C-g` gives it up. git asks no password: one a remote wants
//!   fails the command, told as any failure (`git push failed; $ shows why`), never a wait (see
//!   `git.Command.push`). Its end refreshes the status, asking for the operation in progress
//!   after a pull, which may stop on conflicts.
//! - The menus' switches start off at each showing, as the commit menu's do.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const plugin = mesha.plugin;
const process = mesha.process;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const git = @import("git.zig");
const status = @import("git_status.zig");
const git_branch = @import("git_branch.zig");
const transient = @import("../transient.zig");

// ---- the messages and the actions ------------------------------------------------------------

/// What the panel's system takes for the remotes: the menus' actions and answers.
pub const Msg = enum(u64) {
    /// `P`: shows the push menu.
    vcs_git_push_menu = Atom.from("vcs_git_push_menu").value(),
    /// The push menu's answer, a `transient.Chosen`.
    vcs_git_push_chosen = Atom.from("vcs_git_push_chosen").value(),
    /// `F`: shows the pull menu.
    vcs_git_pull_menu = Atom.from("vcs_git_pull_menu").value(),
    /// The pull menu's answer, a `transient.Chosen`.
    vcs_git_pull_chosen = Atom.from("vcs_git_pull_chosen").value(),
    /// `f`: shows the fetch menu.
    vcs_git_fetch_menu = Atom.from("vcs_git_fetch_menu").value(),
    /// The fetch menu's answer, a `transient.Chosen`.
    vcs_git_fetch_chosen = Atom.from("vcs_git_fetch_chosen").value(),
    _,
};

/// Whether `tag` is one of `Msg`'s.
pub fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// The actions of mode `vcs_git` that show the menus; their keys are `P`, `F` and `f`.
pub const push_action: plugin.action_api.Def = .{ .name = "push", .tag = @tagName(Msg.vcs_git_push_menu), .doc = "Show the menu of push commands" };
pub const pull_action: plugin.action_api.Def = .{ .name = "pull", .tag = @tagName(Msg.vcs_git_pull_menu), .doc = "Show the menu of pull commands" };
pub const fetch_action: plugin.action_api.Def = .{ .name = "fetch", .tag = @tagName(Msg.vcs_git_fetch_menu), .doc = "Show the menu of fetch commands" };

// ---- the menus -----------------------------------------------------------------------------------

/// The items of the push, pull and fetch menus, by their ids, unique across the three.
pub const Item = enum(u32) {
    push = 1,
    push_elsewhere,
    force_with_lease,
    force,
    dry_run,
    tags,
    set_upstream,
    pull,
    pull_elsewhere,
    rebase,
    ff_only,
    fetch,
    fetch_all,
    prune,
};

/// The push menu.
pub const push_menu: ui.transient.Menu = .{
    .title = "Push",
    .groups = &.{
        .{ .title = "Arguments", .items = &.{
            ui.transient.Item.toggle("-f", "Force with lease", "--force-with-lease", @intFromEnum(Item.force_with_lease)),
            ui.transient.Item.toggle("-F", "Force", "--force", @intFromEnum(Item.force)),
            ui.transient.Item.toggle("-n", "Dry run", "--dry-run", @intFromEnum(Item.dry_run)),
            ui.transient.Item.toggle("-t", "Include tags", "--tags", @intFromEnum(Item.tags)),
            ui.transient.Item.toggle("-u", "Set upstream", "--set-upstream", @intFromEnum(Item.set_upstream)),
        } },
        .{ .title = "Push to", .items = &.{
            ui.transient.Item.command("p", "upstream, or a remote", @intFromEnum(Item.push)),
            ui.transient.Item.command("e", "elsewhere", @intFromEnum(Item.push_elsewhere)),
        } },
    },
};

/// The pull menu.
pub const pull_menu: ui.transient.Menu = .{
    .title = "Pull",
    .groups = &.{
        .{ .title = "Arguments", .items = &.{
            ui.transient.Item.toggle("-r", "Rebase local commits", "--rebase", @intFromEnum(Item.rebase)),
            ui.transient.Item.toggle("-f", "Fast-forward only", "--ff-only", @intFromEnum(Item.ff_only)),
        } },
        .{ .title = "Pull from", .items = &.{
            ui.transient.Item.command("p", "upstream", @intFromEnum(Item.pull)),
            ui.transient.Item.command("e", "elsewhere", @intFromEnum(Item.pull_elsewhere)),
        } },
    },
};

/// The fetch menu.
pub const fetch_menu: ui.transient.Menu = .{
    .title = "Fetch",
    .groups = &.{
        .{ .title = "Arguments", .items = &.{
            ui.transient.Item.toggle("-p", "Prune deleted branches", "--prune", @intFromEnum(Item.prune)),
        } },
        .{ .title = "Fetch from", .items = &.{
            ui.transient.Item.command("f", "upstream, or origin", @intFromEnum(Item.fetch)),
            ui.transient.Item.command("a", "all remotes", @intFromEnum(Item.fetch_all)),
        } },
    },
};

/// Shows `menu`, its switches off; its answer comes as `reply_tag`.
fn present(work: status.Work, menu: *const ui.transient.Menu, reply_tag: Msg) void {
    const reply = sequencer.ReplyTo.of(status.system(), .from(reply_tag));
    transient.present(work.pass.frame.memory, work.pass.frame.tables, .{ .menu = menu, .reply = reply });
}

/// Shows the push menu.
pub fn presentPushMenu(work: status.Work) void {
    present(work, &push_menu, .vcs_git_push_chosen);
}

/// Shows the pull menu.
pub fn presentPullMenu(work: status.Work) void {
    present(work, &pull_menu, .vcs_git_pull_chosen);
}

/// Shows the fetch menu.
pub fn presentFetchMenu(work: status.Work) void {
    present(work, &fetch_menu, .vcs_git_fetch_chosen);
}

// ---- taking the messages -------------------------------------------------------------------------

/// One of `Msg`'s, which `claims` took.
pub fn take(work: status.Work, received: sequencer.Message) !void {
    const menu: *const ui.transient.Menu = switch (received.tag.to(Msg)) {
        .vcs_git_push_menu => return presentPushMenu(work),
        .vcs_git_pull_menu => return presentPullMenu(work),
        .vcs_git_fetch_menu => return presentFetchMenu(work),
        .vcs_git_push_chosen => &push_menu,
        .vcs_git_pull_chosen => &pull_menu,
        .vcs_git_fetch_chosen => &fetch_menu,
        _ => return,
    };
    const chosen = try received.payloadAs(transient.Chosen);
    if (chosen.cancelled != 0) return;
    const item = std.enums.fromInt(Item, chosen.id) orelse return;
    try choose(work, menu, item, chosen.state);
}

/// What the command chosen in `menu` does, with the switches `state` has on.
fn choose(work: status.Work, menu: *const ui.transient.Menu, item: Item, state: ui.transient.State) !void {
    if (work.rootUnknown()) return;
    const allocator = try work.scratch();
    switch (item) {
        .push => {
            const branch = currentBranch(work) orelse return work.tell("HEAD is detached: there is no branch to push");
            const upstream = work.cells.textOf(work.state.upstream.*);
            if (upstream.len != 0) {
                const arguments = try argumentsOf(allocator, menu, state);
                _ = try push(work, .{ .arguments = arguments }, branch);
                return;
            }
            // With no upstream, the remote read is made the branch's upstream.
            var with_upstream = state;
            _ = ui.transient.setToggle(menu, &with_upstream, @intFromEnum(Item.set_upstream), .on);
            const arguments = try argumentsOf(allocator, menu, with_upstream);
            try git_branch.askListing(work, .push_to, arguments, .remotes);
        },
        .push_elsewhere => {
            if (currentBranch(work) == null) return work.tell("HEAD is detached: there is no branch to push");
            const arguments = try argumentsOf(allocator, menu, state);
            try git_branch.askListing(work, .push_to, arguments, .remotes);
        },
        .pull => {
            const upstream = work.cells.textOf(work.state.upstream.*);
            if (upstream.len == 0) return work.tell("The branch has no upstream: F e pulls a remote's branch");
            const arguments = try argumentsOf(allocator, menu, state);
            try work.runCommand(.{ .pull = arguments }, "");
        },
        .pull_elsewhere => {
            if (currentBranch(work) == null) return work.tell("HEAD is detached: there is no branch to pull into");
            const arguments = try argumentsOf(allocator, menu, state);
            try git_branch.askListing(work, .pull_from, arguments, .refs_and_remotes);
        },
        .fetch => {
            const arguments = try argumentsOf(allocator, menu, state);
            try work.runCommand(.{ .fetch = arguments }, "");
        },
        .fetch_all => {
            const arguments = try argumentsOf(allocator, menu, state);
            try work.runCommand(.{ .fetch_all = arguments }, "");
        },
        .force_with_lease, .force, .dry_run, .tags, .set_upstream, .rebase, .ff_only, .prune => {},
    }
}

/// The branch `HEAD` is on, the table's text; null while it is detached.
fn currentBranch(work: status.Work) ?[]const u8 {
    if (work.state.head.* == @intFromEnum(git.Head.detached)) return null;
    const branch = work.cells.textOf(work.state.branch.*);
    if (branch.len == 0) return null;
    return branch;
}

/// The arguments of what `state` has on in `menu`, each followed by the separator, in
/// `allocator`.
fn argumentsOf(allocator: std.mem.Allocator, menu: *const ui.transient.Menu, state: ui.transient.State) ![]const u8 {
    var arguments: std.Io.Writer.Allocating = .init(allocator);
    try ui.transient.writeArguments(menu, &state, process.argument_separator, &arguments.writer);
    return arguments.written();
}

/// The remote read in the push prompt: the branch `HEAD` is on pushed there, with `arguments`.
pub fn pushTo(work: status.Work, arguments: []const u8, remote: []const u8) !git_branch.Outcome {
    const branch = currentBranch(work) orelse {
        work.tell("HEAD is detached: there is no branch to push");
        return .ran;
    };
    const allocator = try work.scratch();
    const kept_branch = try allocator.dupe(u8, branch);
    return push(work, .{ .arguments = arguments, .remote = remote, .branch = kept_branch }, kept_branch);
}

/// Runs `wanted`, the push of `branch`; with `--force` among its arguments, after a dialog.
fn push(work: status.Work, wanted: git.Push, branch: []const u8) !git_branch.Outcome {
    if (!git.passes(.{ .push = wanted })) {
        work.tell("git cannot be given that name: it begins with - or holds a control character");
        return .refused;
    }
    if (!forces(wanted.arguments)) {
        try work.runCommand(.{ .push = wanted }, "");
        return .ran;
    }
    const allocator = try work.scratch();
    const shown = try ui.displayText(allocator, branch);
    const title = try std.fmt.allocPrint(allocator, "Push {s} with --force?", .{shown});
    const subject: git_branch.Subject = .{ .arguments = wanted.arguments, .remote = wanted.remote, .branch = wanted.branch };
    try git_branch.askFirst(work, .force_push, .{ .title = title, .body = "The remote's branch is replaced by yours: what only it holds is lost. --force-with-lease (-f) refuses when it holds what you have not fetched", .confirm = "Force push" }, subject);
    return .ran;
}

/// Whether `arguments`, each followed by the separator, hold `--force` itself.
fn forces(arguments: []const u8) bool {
    var each = std.mem.tokenizeScalar(u8, arguments, process.argument_separator);
    while (each.next()) |argument| {
        if (std.mem.eql(u8, argument, "--force")) return true;
    }
    return false;
}

/// The remote's branch read in the pull prompt, pulled with `arguments`.
pub fn pullFrom(work: status.Work, arguments: []const u8, remote: []const u8, branch: []const u8) !git_branch.Outcome {
    return git_branch.runChecked(work, .{ .pull_from = .{ .arguments = arguments, .remote = remote, .branch = branch } });
}
