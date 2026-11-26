//! Perforce's words: every command line vcs-p4 runs and the parsers of what `p4` says back.
//! Nothing here runs a program, keeps state, touches a table or allocates, except a local path
//! a Windows client printed with backslashes, which `parseOpened` and `parseInfo` copy
//! `/`-separated into the scratch their caller hands them. The panel runs the lines through the
//! editor's runner (`runner.zig`): `writeArgv` writes a `Job.argv`, and `writePaths`,
//! `writeChangeNumbers` and `writeChangeForm` what goes on its input (`inputOf` says which).
//!
//! No Perforce client or server was available where this was written: every command, flag,
//! field and format here is from Perforce's published documentation, read command by command,
//! each command's doc naming the page it was written from. What a page did not say was taken
//! from Perforce's own published `p4 help` text and message catalog (the `msgs/` of its C++
//! API on workshop.perforce.com, release 2018.2) and is marked so; what neither says is marked
//! UNVERIFIED, and must be checked against a real server before the panel relies on it.
//! Pages: https://help.perforce.com/helix-core/server-apps/cmdref/current/Content/CmdRef/
//! (`global.options.html`, `filespecs.html`, and `p4_<command>.html` for each command).
//!
//! One process per question, and few of them: a process costs the most on Windows. Every
//! command that acts on files takes them on its input, a line each, through the global `-x -`
//! (`global.options.html`: "read arguments, one per line, from standard input"), which `p4`
//! sends to the server in batches of 128 (`-b`), one server command each, in one process; no
//! command takes a file list as arguments.
//!
//! The output form: tagged (`-ztag`) for every command whose answer is read as fields, plain
//! for the four whose answer is a form, a sentence or a diff (`outputOf`). Tagged output is
//! `... name value` lines, a value's later lines (a description's) not beginning `... `, a
//! blank line after each record: the `p4` client's `ClientUser::OutputStat` writes it so, and
//! `p4_fstat.html`'s examples show such records (its nested `...... otherOpen0` where the
//! client writes `... ... otherOpen0`); `parseTagged` reads it. The global options page spells
//! the option `-z tag`; `p4_describe.html` and others `-ztag`, which is written here. Errors
//! and warnings are never records: the client writes them to its standard error as sentences,
//! whichever form is asked, and exits non-zero after an error (UNVERIFIED: read from the
//! published client's `clientmain.cc`; the command reference does not say what the exit code
//! means, nor whether a warning alone makes it non-zero). `-s` was not
//! chosen: it prefixes every line, a value's later lines too, so a description's lines cannot
//! be told from fields. `-G` (marshalled Python) and `-Mj`
//! (JSON, which replaces bytes that are not UTF-8, so a path could not be given back) were not
//! chosen: the pages document neither's records.
//!
//! A limit of tagged output: a value's later lines are told from fields only by not beginning
//! `... ` or `...... ` (`Fields.next` ends a value at either), so a description line that
//! begins `... ` or `...... ` reads as a field, and one that begins `... change 99` as a
//! record. The typed readers count such a record unread when it lacks the fields a real one
//! always has (`parseChanges`, `parseDescribe`), but every field after the line is lost to it,
//! not only the description's tail: in `changes` the `status`, and in `describe -S -s` the
//! `status` and the list of shelved files.
//!
//! A path in a depot (`//depot/a.c`) is `/`-separated and has `@`, `#`, `*` and `%` encoded as
//! `%40`, `%23`, `%2A` and `%25` (`filespecs.html`); a local path is the operating system's,
//! not encoded. Paths in what the parsers return are `/`-separated whatever the client printed.
//!
//! Text from `p4` (paths, descriptions, names) is returned as slices of the bytes parsed, which
//! live as long as those bytes do, unless a doc says it is a copy into scratch. It need not be
//! UTF-8: on a server that is not in Unicode mode, names are the bytes the client sent, and a
//! parser never fails or cuts on bytes that are not UTF-8.

const std = @import("std");
const mesha = @import("mesha");
const process = mesha.process;
const diff_widget = mesha.ui.diff;

const separator = process.argument_separator;

/// The program the panel runs, found on `PATH`. On Windows the process system's spawn looks
/// for it with each of `PATHEXT`'s extensions, so `p4.exe` is found without one.
pub const program = "p4";

/// What a writer fails with: the writer's own failure, or an argument that cannot be passed as
/// one (`UnpassableArgument`): empty where one is needed, holding a NUL or
/// `process.argument_separator` (or, on the input, a line break), beginning with `-`, or a name
/// Perforce does not allow.
pub const WriteError = std.Io.Writer.Error || error{UnpassableArgument};

// ---- command lines -----------------------------------------------------------------------------

/// A pending changelist of the workspace.
pub const Changelist = union(enum) {
    /// The workspace's default changelist, which has no number: `p4` names it `default`.
    default,
    /// A numbered changelist.
    numbered: u32,
};

/// A changelist's status, as `p4 changes -s` takes it and the change form's `Status:` field
/// names it (`p4_changes.html`, `p4_change.html`).
pub const ChangeStatus = enum {
    /// Created and not submitted.
    pending,
    /// Pending, with shelved files. The change form's page says a changelist's status is
    /// `shelved` once its files are shelved; whether `changes -s pending` then still lists it is
    /// UNVERIFIED, so the panel asks for both.
    shelved,
    /// Submitted to the depot.
    submitted,
};

/// `Command.changes`'s changelists.
pub const PendingChanges = struct {
    /// Which: `pending` or `shelved`. The panel asks both and joins them with `mergeShelved`.
    status: ChangeStatus = .pending,
    /// The workspace whose changelists are listed, as `Info.client` names it. `changes -c`
    /// takes a pattern (`*` matches, a `-` first excludes), so `isClientName` must accept it.
    client: []const u8,
};

/// `Command.history`'s changelists.
pub const History = struct {
    /// The most listed, newest first: `-m`.
    max: u32,
    /// Only this user's: `-u`; empty for everyone's.
    user: []const u8 = "",
    /// Only those that changed files under this file specification (`//depot/main/...`); empty
    /// for all.
    path: []const u8 = "",
};

/// What `Command.submit` submits.
pub const Submit = union(enum) {
    /// A numbered changelist, with the description it has: `submit -c <n>`. The description
    /// is set before, with `change -i` (`Command.save_change`).
    numbered: u32,
    /// The default changelist, from the form on the input: `submit -i` (`p4_submit.html`: "Read
    /// a changelist specification from standard input. Input must be in the same format as
    /// that used by the `p4 submit` form"; `p4 help submit`: "The user's editor is not
    /// invoked"). The form is `Command.change_form` of `.default` (`Change: new`, its `Files:`
    /// the default changelist's), its description replaced by `writeChangeForm` with
    /// `FormFiles.keep`: the submit page's form fields say `Change:` is "`new` if submitting
    /// the default changelist", and of `Files:` that files "can be deleted from this list, but
    /// cannot be changed or added", a file left out staying open "in the next default
    /// changelist". So the files submitted are those the form lists. The description never
    /// goes in an argument: any text, a `-` first or many lines, passes. That `change -o`'s
    /// form is in "the same format" as the submit form, so `submit -i` accepts it, is
    /// UNVERIFIED: the user's guide's reading
    /// (`chapter.scripting.html`: "p4 submit (use p4 change -o to create changelist ...)"),
    /// not said on the submit page. A submit that fails at the server is "assigned the next
    /// number in the changelist sequence, and the default changelist is emptied", and "must be
    /// resubmitted by number" (`p4_submit.html`), so the panel lists its changelists again and
    /// that numbered changelist is submitted with `numbered` (`submit -c <n>`), never with
    /// `submit -i` again. That the numbered changelist keeps the description the form gave is
    /// UNVERIFIED (the page does not say), and a submit refused before a changelist is made (a
    /// form the server rejects) leaves the files in the default changelist: the panel keeps
    /// what was typed in either case.
    default,
};

/// What `Command.shelve` does with a changelist's shelf (`p4_shelve.html`).
pub const ShelveAction = enum {
    /// Shelves the changelist's open files: `shelve -c <n>`.
    shelve,
    /// Shelves them over the shelved files of the same names, keeping the others: `-f`.
    overwrite,
    /// Replaces the whole shelf with the open files: `-r`.
    replace,
    /// Deletes the shelf: `-d`.
    discard,
};

/// `Command.shelve`'s shelf.
pub const Shelve = struct {
    /// The changelist, which must be numbered: shelving the default changelist (no `-c`)
    /// starts the editor on a new changelist's form.
    change: u32,
    /// What is done.
    action: ShelveAction = .shelve,
};

/// `Command.unshelve`'s shelf.
pub const Unshelve = struct {
    /// The changelist whose shelved files are unshelved: `-s`.
    from: u32,
    /// The changelist of the workspace they are opened in: `-c`, left out for the default.
    into: Changelist = .default,
};

/// Whether `Command.sync` syncs or tells what it would.
pub const SyncMode = enum {
    /// `sync`.
    sync,
    /// `sync -n`.
    preview,
};

/// What `Command.open` opens its files for.
pub const OpenAction = enum {
    /// `edit`.
    edit,
    /// `add -f`: `-f` so a name with `@`, `#`, `*` or `%` is added as it is, and its input is
    /// `literal_paths`.
    add,
    /// `delete`.
    delete,
};

/// `Command.open`'s files.
pub const Open = struct {
    /// What they are opened for.
    action: OpenAction,
    /// The changelist they are opened in: `-c`, left out for the default.
    into: Changelist = .default,
};

/// Whether `Command.reconcile` opens what it finds.
pub const ReconcileMode = enum {
    /// Lists the files it would open: `-n`.
    preview,
    /// Opens them in `Reconcile.into`: `-c`.
    open,
};

/// `Command.reconcile`'s reconciliation.
pub const Reconcile = struct {
    /// Whether the files found are opened.
    mode: ReconcileMode,
    /// The changelist they are opened in; unused by `preview`.
    into: Changelist = .default,
    /// The files looked at, a file specification (`//bruno_ws/...`).
    path: []const u8,
};

/// A command vcs-p4 runs. `writeArgv` writes its command line, `outputOf` says in which form it
/// answers, and `inputOf` what goes on its input; each field names the page it was written from
/// and which parser reads what it says. Slices are read only while `writeArgv` runs.
///
/// A command never asks a question: its input is closed, or holds exactly what it reads. Those
/// whose files come on the input read all of it before they start (the client's `InputData`),
/// so a password prompt after a session ended finds the input at its end and fails: UNVERIFIED,
/// read from the client's source, not seen; and on Windows the client may read a password from
/// the console rather than its input, which would wait for a person.
pub const Command = union(enum) {
    /// `info`: the user, the workspace, its root and the server, as `parseInfo` reads them.
    /// Needs no ticket (`p4_info.html`: "Minimal access level required: None"). Field names
    /// UNVERIFIED: the page documents only `unloadSupport`, `tenantID` and `datasetID`. Input:
    /// none.
    info,
    /// `login -s`: whether the session has a ticket, told by the exit code alone (`sessionOf`).
    /// `p4_login.html`: "Display the status of the current ticket, if one exists"; that it exits
    /// non-zero when none does is UNVERIFIED (the page does not say; the client's source exits
    /// non-zero after any error). Input: none.
    login_status,
    /// `changes -s <status> -l -c <client>`: the workspace's pending (or shelved) changelists,
    /// each with its whole description (`-l`), as `parseChanges` reads them. The default
    /// changelist is never listed (`p4_changes.html`). Flags verified; the tagged field names
    /// UNVERIFIED for `changes`, taken from `describe`'s example (`change`, `time`, `user`,
    /// `client`, `status`, `desc`). Input: none.
    changes: PendingChanges,
    /// `changes -s submitted -l -m <max> [-u <user>] [<path>]`: submitted changelists, newest
    /// first, as `parseChanges` reads them (`p4_changes.html`); field names as `changes`'.
    /// Input: none.
    history: History,
    /// `fstat -Ro //<client>/...`: every file opened in the workspace, in every changelist, with
    /// its depot and local paths, changelist, action, type and unresolved state, as
    /// `parseOpened` reads them. `fstat`, not `opened`: `p4_fstat.html` documents each of these
    /// fields (`depotFile`, `clientFile` in local syntax, `change`, `action`, `type`,
    /// `unresolved`), where `opened` documents only its sentence, which has no local path and
    /// no unresolved state. Input: none.
    opened: []const u8,
    /// `changes -l <arguments>`: the changelists a person's query lists (vcs-p4's history),
    /// `arguments` its own, as `query.write` split them, each after
    /// `process.argument_separator`, written after `-l` as they are, as `parseChanges` reads
    /// what it says (`p4_changes.html`: `-s`, `-m`, `-u`, `-c`, `-t`, `-L` and a file
    /// specification narrow it). Tagged, the form `-ztag` gives, which no argument after the
    /// command's name can change (`global.options.html`: global options go before the command);
    /// `changes` only reads. Refused: an argument holding a NUL or a line break, or more than
    /// `max_query_arguments`. Input: none.
    changes_query: []const u8,
    /// `-x - describe -S -s`: the shelved files of the changelists whose numbers are on the
    /// input, without their diffs, as `parseDescribe` reads them (`p4_describe.html`). One
    /// process for any number of changelists. The numbered file fields (`depotFile0`, ...) are
    /// UNVERIFIED: no page shows them. Input: `change_numbers`.
    shelved,
    /// `-x - diff -du`: the unified diff of each opened file on the input against the revision
    /// it was opened at, as `parseDiff` reads it; plain, since under `-ztag` a file's header
    /// becomes a record (the C++ API's list of tagged commands: "p4 diff - (summary line)").
    /// The header (`==== //depot/a.c#3 - /local/a.c ====`) is not on `p4_diff.html`; it is
    /// Perforce's message catalog's `MsgDm::DiffData`. Only files open for edit are compared
    /// (`p4_diff.html`: "the client file must be open for `edit`"): one open for add or delete
    /// prints nothing the page documents, and the panel shows such a file's state, not a diff.
    ///
    /// Which diff runs: `p4_diff.html`: "By default, your workstation runs the diff routine
    /// built into the P4 CLI", and an external program when `P4DIFF` names one. The client's
    /// source (`ClientUser::Diff`) asks `P4DIFF`, then `DIFF`, and, for a file of type
    /// `unicode`, `P4DIFFUNICODE`, and runs its own routine only when none is set, on every
    /// system (`P4DIFF.html`'s Windows default, `p4diff.exe`, is not what the source does).
    /// A person's value, from the environment, `P4CONFIG`, `P4ENVIRO` or `p4 set`, replaces the
    /// unified diff with whatever that program writes: `diffBodyOf` tells such a file apart.
    /// See `internal_diff_environment` for what a job can do about it. Input: `depot_paths`.
    diff,
    /// `describe -du <n>`: a submitted changelist, its description, its files and their diffs,
    /// plain, as `parseDiff` reads the diffs (`p4_describe.html`; the header,
    /// `==== //depot/a.c#4 (text) ====`, is UNVERIFIED: the message catalog's
    /// `MsgDm::DescribeDiff`, which no page shows). The
    /// server diffs: `P4DIFF` has no effect. Input: none.
    describe: u32,
    /// `change -o [<n>]`: a changelist's form, plain, as `parseChangeForm` reads it and
    /// `writeChangeForm` writes it back; `default` asks for a new changelist's form, which lists
    /// the default changelist's files (`p4_change.html`). Input: none.
    change_form: Changelist,
    /// `change -i`: creates or updates a changelist from the form on the input, plain;
    /// `parseChangeSaved` reads which (`p4_change.html`: "Read a changelist specification from
    /// standard input"). A form's `Files:` are what the changelist holds after: a file left out
    /// of an existing changelist's form is moved to the default changelist, and a new
    /// changelist's form takes in the default's files it lists. Input: `form`.
    save_change,
    /// `change -d <n>`: deletes a pending changelist with no open files and no fixes
    /// (`p4_change.html`). Input: none.
    delete_change: u32,
    /// `submit -c <n>`, or `submit -i` with the default changelist's form on the input
    /// (`p4_submit.html`; see `Submit`). Whether `-c` ever starts the editor is UNVERIFIED (not
    /// said; `p4 help submit` says only the default changelist's submit "displays a dialog"),
    /// and its input is closed. Input:
    /// none for `numbered`, `form` for `default`.
    submit: Submit,
    /// `-x - reopen -c <n|default>`: moves the opened files on the input to a changelist
    /// (`p4_reopen.html`). Input: `depot_paths`.
    reopen: Changelist,
    /// `-x - revert`: throws away the changes of the opened files on the input; a file opened
    /// for add is left in the workspace (`p4_revert.html`). Input: `depot_paths`.
    revert,
    /// `-x - revert -a`: of the opened files on the input, reverts those that have not changed
    /// since they were opened (`p4_revert.html`: `revert [-a ...] file ...`, `-a` "Revert only
    /// those files that haven't changed (in terms of content or filetype) since they were
    /// opened": open for edit with unchanged content and type, open for integrate and not yet
    /// resolved, open for add but missing from the workspace). The files are named, so it acts
    /// on exactly the files the panel lists for a changelist, the default one too, with no
    /// `-c`. Input: `depot_paths`.
    revert_unchanged,
    /// `shelve [-f|-r|-d] -c <n>` (`p4_shelve.html`). Input: none.
    shelve: Shelve,
    /// `unshelve -s <n> [-c <n>]` (`p4_unshelve.html`). Input: none.
    unshelve: Unshelve,
    /// `sync` or `sync -n`: the whole workspace to the head revision (`p4_sync.html`). Input:
    /// none.
    sync: SyncMode,
    /// `resolve -am`: merges what can be merged, skipping files with conflicts, which stay
    /// unresolved; never the interactive dialog (`p4_resolve.html`). Input: none.
    resolve,
    /// `-x - edit|add -f|delete [-c <n>]` of the files on the input, `-c` left out for the
    /// default changelist (`p4_edit.html`, `p4_add.html`, `p4_delete.html`). Input:
    /// `local_paths`, or `literal_paths` for `add`.
    open: Open,
    /// `reconcile -n <path>` or `reconcile [-c <n>] <path>` (`-c` left out for the default):
    /// files changed, added or deleted without being opened (`p4_reconcile.html`). Input: none.
    reconcile: Reconcile,
};

/// Variables a `diff` job may be given (`runner.Job.environment`: `NAME=value` pairs separated
/// by `process.argument_separator`) so `p4` runs its own diff: `P4DIFF`, `DIFF` and
/// `P4DIFFUNICODE` set empty. The process system only adds or replaces variables (a pair
/// replaces the engine's of that name, and its value may be empty); it cannot remove one. No
/// page documents that an empty value means unset: the client's source does (`Enviro::Get`
/// returns no value for an empty one, and reads the environment before the Windows registry,
/// where `p4 set` writes, and before `P4ENVIRO`'s file), so this is UNVERIFIED. A value set in
/// a `P4CONFIG` file is read before the environment and still wins: the panel then shows
/// what that program wrote (`diffBodyOf`).
pub const internal_diff_environment = "P4DIFF=\x1fDIFF=\x1fP4DIFFUNICODE=";

/// What every command line carries before the command's name: `writeArgv` writes it.
pub const Context = struct {
    /// The workspace, written as the global `-c`, which overrides `P4CLIENT`; empty to let
    /// `p4` find it (`P4CLIENT`, `P4CONFIG`, `p4 set`). Must pass `isClientName`.
    client: []const u8 = "",
};

/// The form a command answers in.
pub const Output = enum {
    /// `-ztag`: records of fields, which `parseTagged` reads.
    tagged,
    /// Plain: a form or a diff.
    text,
};

/// What goes on a command's input.
pub const Input = enum {
    /// Nothing: the input is closed.
    none,
    /// Depot paths, as `p4` printed them (encoded), a line each: `writePaths`.
    depot_paths,
    /// Local paths, a line each, `@`, `#`, `*` and `%` encoded: `writePaths`.
    local_paths,
    /// Local paths as they are, a line each, for `add -f`: `writePaths`.
    literal_paths,
    /// Changelist numbers, a line each: `writeChangeNumbers`.
    change_numbers,
    /// A changelist's form, for `change -i` or `submit -i`: `writeChangeForm`.
    form,
};

/// The form `command` answers in.
pub fn outputOf(command: Command) Output {
    return switch (command) {
        .diff, .describe, .change_form, .save_change => .text,
        else => .tagged,
    };
}

/// What goes on `command`'s input.
pub fn inputOf(command: Command) Input {
    return switch (command) {
        .shelved => .change_numbers,
        .diff, .reopen, .revert, .revert_unchanged => .depot_paths,
        .open => |open| switch (open.action) {
            .add => .literal_paths,
            .edit, .delete => .local_paths,
        },
        .save_change => .form,
        .submit => |submit| switch (submit) {
            .numbered => .none,
            .default => .form,
        },
        else => .none,
    };
}

/// Writes `command`'s whole command line, `program` first, its arguments separated by
/// `process.argument_separator`, for a `runner.Job`'s `argv`: the global options, in the one
/// place they are written (`-ztag` when tagged, `-c <client>` when the context names one, `-x
/// -` when the files come on the input), then the command and its own options. The global
/// options page: global options "must be specified on the command line before the P4 Server
/// command"; after it the same letter is the command's (`p4 -c anotherclient edit -c 140`).
/// Fails as `writer` does, or with `UnpassableArgument`, having written nothing.
pub fn writeArgv(writer: *std.Io.Writer, context: Context, command: Command) WriteError!void {
    try checkCommand(context, command);
    try writer.writeAll(program);
    if (outputOf(command) == .tagged) try writeFlags(writer, &.{"-ztag"});
    if (context.client.len != 0) {
        try writeFlags(writer, &.{"-c"});
        try writeArgument(writer, context.client);
    }
    const files_on_input = switch (inputOf(command)) {
        .depot_paths, .local_paths, .literal_paths, .change_numbers => true,
        .none, .form => false,
    };
    if (files_on_input) try writeFlags(writer, &.{ "-x", "-" });

    switch (command) {
        .info => try writeFlags(writer, &.{"info"}),
        .login_status => try writeFlags(writer, &.{ "login", "-s" }),
        .changes => |changes| {
            try writeFlags(writer, &.{ "changes", "-s", @tagName(changes.status), "-l", "-c" });
            try writeArgument(writer, changes.client);
        },
        .history => |history| {
            try writeFlags(writer, &.{ "changes", "-s", "submitted", "-l", "-m" });
            try writeNumber(writer, history.max);
            if (history.user.len != 0) {
                try writeFlags(writer, &.{"-u"});
                try writeArgument(writer, history.user);
            }
            if (history.path.len != 0) try writeArgument(writer, history.path);
        },
        .changes_query => |arguments| {
            try writeFlags(writer, &.{ "changes", "-l" });
            try writer.writeAll(arguments);
        },
        .opened => |client| {
            try writeFlags(writer, &.{ "fstat", "-Ro" });
            try writer.writeByte(separator);
            try writer.print("//{s}/...", .{client});
        },
        .shelved => try writeFlags(writer, &.{ "describe", "-S", "-s" }),
        .diff => try writeFlags(writer, &.{ "diff", "-du" }),
        .describe => |number| {
            try writeFlags(writer, &.{ "describe", "-du" });
            try writeNumber(writer, number);
        },
        .change_form => |change| {
            try writeFlags(writer, &.{ "change", "-o" });
            switch (change) {
                .default => {},
                .numbered => |number| try writeNumber(writer, number),
            }
        },
        .save_change => try writeFlags(writer, &.{ "change", "-i" }),
        .delete_change => |number| {
            try writeFlags(writer, &.{ "change", "-d" });
            try writeNumber(writer, number);
        },
        .submit => |submit| switch (submit) {
            .numbered => |number| {
                try writeFlags(writer, &.{ "submit", "-c" });
                try writeNumber(writer, number);
            },
            .default => try writeFlags(writer, &.{ "submit", "-i" }),
        },
        .reopen => |change| {
            try writeFlags(writer, &.{ "reopen", "-c" });
            try writeChangelist(writer, change);
        },
        .revert => try writeFlags(writer, &.{"revert"}),
        .revert_unchanged => try writeFlags(writer, &.{ "revert", "-a" }),
        .shelve => |shelve| {
            try writeFlags(writer, &.{"shelve"});
            switch (shelve.action) {
                .shelve => {},
                .overwrite => try writeFlags(writer, &.{"-f"}),
                .replace => try writeFlags(writer, &.{"-r"}),
                .discard => try writeFlags(writer, &.{"-d"}),
            }
            try writeFlags(writer, &.{"-c"});
            try writeNumber(writer, shelve.change);
        },
        .unshelve => |unshelve| {
            try writeFlags(writer, &.{ "unshelve", "-s" });
            try writeNumber(writer, unshelve.from);
            switch (unshelve.into) {
                .default => {},
                .numbered => |number| {
                    try writeFlags(writer, &.{"-c"});
                    try writeNumber(writer, number);
                },
            }
        },
        .sync => |mode| switch (mode) {
            .sync => try writeFlags(writer, &.{"sync"}),
            .preview => try writeFlags(writer, &.{ "sync", "-n" }),
        },
        .resolve => try writeFlags(writer, &.{ "resolve", "-am" }),
        .open => |open| {
            switch (open.action) {
                .edit => try writeFlags(writer, &.{"edit"}),
                .add => try writeFlags(writer, &.{ "add", "-f" }),
                .delete => try writeFlags(writer, &.{"delete"}),
            }
            try writeIntoChangelist(writer, open.into);
        },
        .reconcile => |reconcile| {
            try writeFlags(writer, &.{"reconcile"});
            switch (reconcile.mode) {
                .preview => try writeFlags(writer, &.{"-n"}),
                .open => try writeIntoChangelist(writer, reconcile.into),
            }
            try writeArgument(writer, reconcile.path);
        },
    }
}

/// Whether `writeArgv` takes `command` in `context`: every name and path given passes as one
/// argument `p4` does not read as an option. What a panel asks before it runs a command with a
/// name a person typed, to tell why it does not.
pub fn passes(context: Context, command: Command) bool {
    checkCommand(context, command) catch return false;
    return true;
}

/// Whether Perforce takes `name` as a workspace's name for these command lines: not empty, no
/// `-` first (a `changes -c` pattern beginning `-` excludes), not all digits (`filespecs.html`:
/// "A purely numeric identifier is NOT allowed"), and none of `@`, `#`, `*`, `%`, `/`, `...`, a
/// space or a control character, which the file specifications page forbids in a client's
/// name or which would make it a pattern or split it.
pub fn isClientName(name: []const u8) bool {
    return isIdentifier(name, "@#*%/");
}

/// Whether Perforce takes `name` as a user's name for these command lines: as `isClientName`,
/// but `/` is allowed (`filespecs.html`: `/` is "OK for `p4 user`").
pub fn isUserName(name: []const u8) bool {
    return isIdentifier(name, "@#*%");
}

/// `isClientName`'s and `isUserName`'s rule, `forbidden` the characters refused besides a
/// space and control characters.
fn isIdentifier(name: []const u8, forbidden: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '-') return false;
    var all_digits = true;
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == ' ') return false;
        if (std.mem.indexOfScalar(u8, forbidden, byte) != null) return false;
        if (!std.ascii.isDigit(byte)) all_digits = false;
    }
    if (all_digits) return false;
    if (std.mem.indexOf(u8, name, "...") != null) return false;
    return true;
}

/// Checks every name and path of `command` and `context`, before anything is written.
fn checkCommand(context: Context, command: Command) error{UnpassableArgument}!void {
    if (context.client.len != 0 and !isClientName(context.client)) return error.UnpassableArgument;
    switch (command) {
        .changes => |changes| {
            if (!isClientName(changes.client)) return error.UnpassableArgument;
        },
        .opened => |client| {
            if (!isClientName(client)) return error.UnpassableArgument;
        },
        .history => |history| {
            if (history.user.len != 0 and !isUserName(history.user)) return error.UnpassableArgument;
            if (history.path.len != 0) try checkOption(history.path);
        },
        .reconcile => |reconcile| try checkOption(reconcile.path),
        .changes_query => |arguments| {
            if (std.mem.indexOfAny(u8, arguments, "\x00\r\n") != null) return error.UnpassableArgument;
            if (arguments.len != 0 and arguments[0] != separator) return error.UnpassableArgument;
            const count = std.mem.count(u8, arguments, &.{separator});
            if (count > max_query_arguments) return error.UnpassableArgument;
        },
        else => {},
    }
}

/// The most arguments a history's query (`Command.changes_query`) passes.
pub const max_query_arguments = 48;

/// Writes arguments this file spells, each after a separator.
fn writeFlags(writer: *std.Io.Writer, flags: []const []const u8) std.Io.Writer.Error!void {
    for (flags) |flag| {
        try writer.writeByte(separator);
        try writer.writeAll(flag);
    }
}

/// Writes a name or path given, checked already (`checkCommand`), after a separator, as one
/// argument.
fn writeArgument(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte(separator);
    try writer.writeAll(text);
}

fn writeNumber(writer: *std.Io.Writer, number: u32) std.Io.Writer.Error!void {
    try writer.writeByte(separator);
    try writer.print("{d}", .{number});
}

/// A changelist as `-c` takes it: its number, or `default`.
fn writeChangelist(writer: *std.Io.Writer, change: Changelist) std.Io.Writer.Error!void {
    switch (change) {
        .default => try writeFlags(writer, &.{"default"}),
        .numbered => |number| try writeNumber(writer, number),
    }
}

/// `-c <n>` for a numbered changelist, nothing for the default: `p4_edit.html`, `p4_add.html`,
/// `p4_delete.html` and `p4_reconcile.html` say that without `-c` the files go to the default
/// changelist, and document no value `default` for their `-c` (only `p4_reopen.html` does).
fn writeIntoChangelist(writer: *std.Io.Writer, change: Changelist) std.Io.Writer.Error!void {
    switch (change) {
        .default => {},
        .numbered => |number| {
            try writeFlags(writer, &.{"-c"});
            try writeNumber(writer, number);
        },
    }
}

/// Text passes as one argument: not empty, no NUL, no separator.
fn checkPositional(text: []const u8) error{UnpassableArgument}!void {
    if (text.len == 0) return error.UnpassableArgument;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.UnpassableArgument;
    if (std.mem.indexOfScalar(u8, text, separator) != null) return error.UnpassableArgument;
}

/// Text passes as one argument `p4` does not read as an option.
fn checkOption(text: []const u8) error{UnpassableArgument}!void {
    try checkPositional(text);
    if (text[0] == '-') return error.UnpassableArgument;
}

// ---- what goes on the input --------------------------------------------------------------------

/// Writes `paths` for a command's input as `form` says (`depot_paths`, `local_paths` or
/// `literal_paths`), each followed by a line break: the global `-x -` reads "arguments, one per
/// line", each line one argument, spaces and all. A depot path is written as `p4` printed it,
/// already encoded, and must begin `//`; a local path has `@`, `#`, `*` and `%` encoded as
/// `%40`, `%23`, `%2A` and `%25` (`filespecs.html`: to refer to such a file "use the ASCII
/// expression of the character's hexadecimal value"), except for `add -f`, which takes the name
/// as it is (`p4_add.html`: a name encoded by hand is added as `status%2540june.txt`). The page
/// lists `:` too, which is not encoded here: a Windows path's drive letter has one. A local path
/// is written in `style`'s syntax: for `windows` each `/` a `\`, as `filespecs.html` gives
/// Windows' local syntax (`c:\staff\bruno\myworkspace\file.c`; no page says `p4` takes `/`
/// there), so a UNC path held as `//server/share/a.c` is written `\\server\share\a.c`. A depot
/// path is always `/`-separated and written as printed. A path in client syntax
/// (`//workspace/a.c`) is no local path and must never be given as one: it would be written
/// with backslashes as a UNC path. Fails as `writer` does, or with `UnpassableArgument`, having
/// written nothing, for a path that is empty, begins with `-`, holds a NUL or a line break, or
/// holds `...`, the wildcard no encoding escapes; or a form that is no list of paths.
pub fn writePaths(writer: *std.Io.Writer, paths: []const []const u8, form: Input, style: PathStyle) WriteError!void {
    switch (form) {
        .depot_paths, .local_paths, .literal_paths => {},
        .none, .change_numbers, .form => return error.UnpassableArgument,
    }
    for (paths) |path| {
        if (path.len == 0 or path[0] == '-') return error.UnpassableArgument;
        if (std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return error.UnpassableArgument;
        if (std.mem.indexOf(u8, path, "...") != null) return error.UnpassableArgument;
        if (form == .depot_paths and !std.mem.startsWith(u8, path, "//")) return error.UnpassableArgument;
    }
    const backslashes = style == .windows and form != .depot_paths;
    for (paths) |path| {
        if (form == .depot_paths) {
            try writer.writeAll(path);
            try writer.writeByte('\n');
            continue;
        }
        for (path) |byte| {
            const encoded: ?[]const u8 = switch (byte) {
                '@' => "%40",
                '#' => "%23",
                '*' => "%2A",
                '%' => "%25",
                else => null,
            };
            if (form == .local_paths and encoded != null) {
                try writer.writeAll(encoded.?);
            } else if (backslashes and byte == '/') {
                try writer.writeByte('\\');
            } else {
                try writer.writeByte(byte);
            }
        }
        try writer.writeByte('\n');
    }
}

/// Writes changelist numbers for `Command.shelved`'s input, a line each.
pub fn writeChangeNumbers(writer: *std.Io.Writer, numbers: []const u32) std.Io.Writer.Error!void {
    for (numbers) |number| try writer.print("{d}\n", .{number});
}

/// What `writeChangeForm` does with the form's `Files:`.
pub const FormFiles = enum {
    /// Keeps them: the changelist keeps, or takes in, the files listed. Always so for an
    /// existing changelist, which would lose a file left out.
    keep,
    /// Leaves the field out: a new changelist is made empty, the default changelist's files
    /// left where they are. Only for a form whose `Change:` is `new`: `writeChangeForm` refuses
    /// it for an existing changelist's, which would move every file to the default changelist.
    drop,
};

/// Writes the form `Command.save_change` takes on its input: `form`, as `Command.change_form`
/// printed it, line for line, with its `Description:` replaced by `description` and, as `files`
/// says, its `Files:` kept or left out. Every other field and comment is written as it was, so
/// nothing the panel does not edit (`Jobs:`, `Type:`, `Stream:`) is lost. The description is
/// written a line under the field, each line indented with a tab, an empty line as a tab
/// alone (`p4_change.html`: "If there is a line under a field, indent that line"), its line
/// breaks `\n` and any `\r` before them dropped. A form with no `Description:` gets one at its
/// end. Fails as `writer` does, or with `UnpassableArgument`, having written nothing, for an
/// empty description or one holding a NUL, or for `FormFiles.drop` on a form whose `Change:` is
/// not `new`.
pub fn writeChangeForm(writer: *std.Io.Writer, form: []const u8, description: []const u8, files: FormFiles) WriteError!void {
    if (std.mem.trimEnd(u8, description, "\r\n").len == 0) return error.UnpassableArgument;
    if (std.mem.indexOfScalar(u8, description, 0) != null) return error.UnpassableArgument;
    if (files == .drop) {
        const parsed = parseChangeForm(form);
        if (!std.mem.eql(u8, parsed.change, "new")) return error.UnpassableArgument;
    }
    var described = false;
    var position: usize = 0;
    while (position < form.len) {
        const line = lineAt(form, position);
        position += line.len;
        const field = formFieldName(line);
        const is_description = std.mem.eql(u8, field, "Description");
        const dropped = files == .drop and std.mem.eql(u8, field, "Files");
        if (!is_description and !dropped) {
            try writer.writeAll(line);
            continue;
        }
        // The field's own lines, indented, are passed over.
        position = indentedEnd(form, position);
        if (dropped) continue;
        try writeDescriptionField(writer, description);
        described = true;
    }
    if (!described) {
        const ends_with_line_break = form.len == 0 or form[form.len - 1] == '\n';
        if (!ends_with_line_break) try writer.writeAll("\n");
        try writeDescriptionField(writer, description);
    }
}

fn writeDescriptionField(writer: *std.Io.Writer, description: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("Description:\n");
    const text = std.mem.trimEnd(u8, description, "\r\n");
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        try writer.print("\t{s}\n", .{line});
    }
}

/// The name of the form field `line` begins (`Description` of `Description:`); empty for a
/// line that begins none: indented, a comment, blank.
fn formFieldName(line: []const u8) []const u8 {
    if (line.len == 0) return "";
    if (line[0] == '#' or line[0] == ' ' or line[0] == '\t' or line[0] == '\n' or line[0] == '\r') return "";
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return "";
    return line[0..colon];
}

/// Where the lines indented under a field end, from `position`, the line after the field's
/// own: past indented lines and blank lines between them, but not past the blank lines after
/// the last.
fn indentedEnd(form: []const u8, position: usize) usize {
    var end = position;
    var cursor = position;
    while (cursor < form.len) {
        const line = lineAt(form, cursor);
        const indented = line[0] == '\t' or line[0] == ' ';
        const blank = std.mem.trim(u8, line, "\r\n").len == 0;
        if (!indented and !blank) break;
        cursor += line.len;
        if (indented) end = cursor;
    }
    return end;
}

// ---- what p4 says ------------------------------------------------------------------------------

/// How many records a parser found, and how many of them fit in the slice it was given: the
/// first `kept`.
pub const Counted = struct {
    /// Records found in the bytes.
    seen: u32 = 0,
    /// Records written to the slice: the first `kept` of those found.
    kept: u32 = 0,
};

/// A field of tagged output: `... name value`, or, for a field nested under the one before
/// (`fstat`'s `otherOpen0`), `... ... name value` as the client's source writes it or `......
/// name value` as `p4_fstat.html` prints it. Its slices are of the bytes read.
pub const Field = struct {
    /// 1, or 2 for a nested field.
    level: u8,
    /// The field's name.
    name: []const u8,
    /// Its value, the rest of its line and the lines after it up to the next field, without
    /// the line breaks (and blank lines) at its end; empty for a flag (`... isMapped`).
    value: []const u8,
    /// Where its line begins in the bytes read.
    start: usize,
};

/// Reads tagged output a field at a time. Lines before the first field are passed over. Each
/// byte is read once, so it ends on any input.
pub const Fields = struct {
    /// The bytes read; the caller's.
    bytes: []const u8,
    /// Where the next line begins.
    position: usize = 0,

    /// Reads `bytes` from their start.
    pub fn init(bytes: []const u8) Fields {
        return .{ .bytes = bytes };
    }

    /// The next field; null at the end of the bytes.
    pub fn next(fields: *Fields) ?Field {
        const bytes = fields.bytes;
        while (fields.position < bytes.len) {
            const start = fields.position;
            const line = lineAt(bytes, start);
            fields.position += line.len;
            const nested_page = std.mem.startsWith(u8, line, "...... ");
            if (!nested_page and !std.mem.startsWith(u8, line, "... ")) continue;
            var level: u8 = 1;
            var text_start = start + "... ".len;
            if (nested_page) {
                level = 2;
                text_start = start + "...... ".len;
            } else if (std.mem.startsWith(u8, bytes[text_start..], "... ")) {
                level = 2;
                text_start += "... ".len;
            }
            const line_end = start + std.mem.trimEnd(u8, line, "\r\n").len;
            const first = bytes[@min(text_start, line_end)..line_end];
            const name_end = std.mem.indexOfScalar(u8, first, ' ') orelse first.len;
            const value_start = if (name_end < first.len) text_start + name_end + 1 else line_end;
            // A value's later lines: up to the next field.
            while (fields.position < bytes.len) {
                const following = lineAt(bytes, fields.position);
                if (std.mem.startsWith(u8, following, "... ")) break;
                if (std.mem.startsWith(u8, following, "...... ")) break;
                fields.position += following.len;
            }
            const field_text = std.mem.trimEnd(u8, bytes[start..fields.position], "\r\n");
            const value_end = @max(value_start, start + field_text.len);
            return .{
                .level = level,
                .name = first[0..name_end],
                .value = bytes[value_start..value_end],
                .start = start,
            };
        }
        return null;
    }
};

/// A record of tagged output: its fields' bytes. Its slices are of the bytes read.
pub const Record = struct {
    /// From its key field's line to the next record's.
    bytes: []const u8,

    /// The value of its first level-1 field called `name`; null when it has none.
    pub fn get(record: Record, name: []const u8) ?[]const u8 {
        var each = Fields.init(record.bytes);
        while (each.next()) |field| {
            if (field.level == 1 and std.mem.eql(u8, field.name, name)) return field.value;
        }
        return null;
    }

    /// Its fields, in order.
    pub fn fields(record: Record) Fields {
        return Fields.init(record.bytes);
    }
};

/// Reads tagged output a record at a time (`parseTagged`).
pub const Records = struct {
    /// The fields read.
    fields: Fields,
    /// The name of the field each record begins with.
    key: []const u8,
    /// The key field of the next record, read already.
    pending: ?Field = null,

    /// The next record; null at the end.
    pub fn next(records: *Records) ?Record {
        const first = records.pending orelse records.nextKey() orelse return null;
        records.pending = records.nextKey();
        const end = if (records.pending) |key| key.start else records.fields.bytes.len;
        return .{ .bytes = records.fields.bytes[first.start..end] };
    }

    fn nextKey(records: *Records) ?Field {
        while (records.fields.next()) |field| {
            if (field.level == 1 and std.mem.eql(u8, field.name, records.key)) return field;
        }
        return null;
    }
};

/// Reads tagged output (`-ztag`) as records, each beginning at a level-1 field called `key`
/// (`change` for `changes` and `describe`, `depotFile` for `fstat`) and running to the next
/// such field. A record is not split at its blank line: a value's later lines may hold blank
/// lines (a description's), and `p4` writes a blank line after the value's own last line break,
/// so a blank line is no reliable end; each command's records begin with the same field.
/// Fields before the first key are passed over. A line that does not begin `... ` (or
/// `...... `) belongs to the value before it: so does an info message `p4` writes among the
/// records (`ClientUser::Message` writes it with `OutputInfo`, unprefixed), which becomes part of
/// the previous field's value. A description line that begins `... key ` begins a record:
/// tagged output cannot tell it from one (the module's doc).
pub fn parseTagged(bytes: []const u8, key: []const u8) Records {
    return .{ .fields = Fields.init(bytes), .key = key };
}

/// What a typed reader found: its records, and those it could not read.
pub const Parsed = struct {
    /// The records read, and how many fit in the slice given.
    records: Counted = .{},
    /// Records with the key but without what the reader needs (a number that is none).
    unread: u32 = 0,
};

/// How local paths are separated where the `p4` client runs, which writes them in the operating
/// system's syntax.
pub const PathStyle = enum {
    /// `/`: a backslash is a character of a name.
    posix,
    /// `\`, which is read as `/`.
    windows,
};

/// `path` `/`-separated: as it is for `posix` or when it has no backslash, else a copy into
/// `scratch` with each `\` a `/`.
fn slashPath(path: []const u8, style: PathStyle, scratch: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    if (style == .posix) return path;
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return path;
    const copy = try scratch.dupe(u8, path);
    std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

/// What `Command.info` said.
pub const Info = struct {
    /// `userName`: the user commands run as.
    user: []const u8 = "",
    /// `clientName`: the workspace; with none, the host's name as `p4_info.html`'s example
    /// shows, or `*unknown*` as programs that read it say (UNVERIFIED): `hasClient` tells.
    client: []const u8 = "",
    /// `clientRoot`: the workspace's root, `/`-separated (a copy in scratch when the client
    /// wrote backslashes).
    client_root: []const u8 = "",
    /// `serverAddress`: the server's address.
    server_address: []const u8 = "",

    /// Whether `p4` found a workspace: a name, not `*unknown*`, and a root. `p4_info.html`'s
    /// example of no workspace prints `Client name:` with the host's name, then `Client
    /// unknown.` and no `Client root`, so the root's absence is what tells.
    pub fn hasClient(info: *const Info) bool {
        if (info.client.len == 0 or info.client_root.len == 0) return false;
        return !std.mem.eql(u8, info.client, "*unknown*");
    }
};

/// Reads what `Command.info` said: its first record's fields; a field it lacks is empty.
/// Fails only when `scratch` does, copying a root with backslashes.
pub fn parseInfo(bytes: []const u8, style: PathStyle, scratch: std.mem.Allocator) error{OutOfMemory}!Info {
    var info: Info = .{};
    var fields = Fields.init(bytes);
    while (fields.next()) |field| {
        if (field.level != 1) continue;
        if (std.mem.eql(u8, field.name, "userName")) {
            info.user = field.value;
        } else if (std.mem.eql(u8, field.name, "clientName")) {
            info.client = field.value;
        } else if (std.mem.eql(u8, field.name, "clientRoot")) {
            info.client_root = try slashPath(field.value, style, scratch);
        } else if (std.mem.eql(u8, field.name, "serverAddress")) {
            info.server_address = field.value;
        }
    }
    return info;
}

/// The most bytes of a description's first line `Change.summary` keeps, cut at a character
/// boundary: past it is no line a person reads whole in a list.
pub const max_summary_bytes = 1024;

/// A changelist `Command.changes`, `Command.history` or `Command.shelved` listed.
pub const Change = struct {
    /// `change`: its number.
    number: u32,
    /// `time`: when it was made, or submitted, in seconds since 1970 UTC; 0 when not said.
    time: i64 = 0,
    /// `user`: its owner.
    user: []const u8 = "",
    /// `client`: the workspace it belongs to.
    client: []const u8 = "",
    /// `status`; null for one not named.
    status: ?ChangeStatus = null,
    /// `desc`: the whole description, as `-l` gives it, without the line breaks at its end.
    description: []const u8 = "",
    /// The description's first line, cut to `max_summary_bytes`.
    summary: []const u8 = "",
};

/// A record keyed `change` as a `Change`; null when its `change` is no number, or it lacks the
/// `time`, `user` or `client` every changelist's record carries: a record begun by a
/// description's line `... change N` (the module's doc). `p4_describe.html`'s example shows
/// those fields for `describe`; that every record of `changes` carries them too is UNVERIFIED.
fn changeOf(record: Record) ?Change {
    const number_text = record.get("change") orelse return null;
    const number = std.fmt.parseInt(u32, number_text, 10) catch return null;
    if (record.get("time") == null) return null;
    if (record.get("user") == null) return null;
    if (record.get("client") == null) return null;
    var change: Change = .{ .number = number };
    if (record.get("time")) |time| change.time = std.fmt.parseInt(i64, time, 10) catch 0;
    if (record.get("user")) |user| change.user = user;
    if (record.get("client")) |client| change.client = client;
    if (record.get("status")) |status| change.status = std.meta.stringToEnum(ChangeStatus, status);
    if (record.get("desc")) |description| {
        change.description = description;
        const line_end = std.mem.indexOfAny(u8, description, "\r\n") orelse description.len;
        const first_line = description[0..line_end];
        change.summary = first_line[0..utf8Prefix(first_line, max_summary_bytes)];
    }
    return change;
}

/// Reads what `Command.changes` or `Command.history` said into `into`, in the order `p4` gave
/// them (newest first), as many as fit.
pub fn parseChanges(bytes: []const u8, into: []Change) Parsed {
    var parsed: Parsed = .{};
    var records = parseTagged(bytes, "change");
    while (records.next()) |record| {
        const change = changeOf(record) orelse {
            parsed.unread += 1;
            continue;
        };
        if (parsed.records.kept < into.len) {
            into[parsed.records.kept] = change;
            parsed.records.kept += 1;
        }
        parsed.records.seen += 1;
    }
    return parsed;
}

/// Adds the changelists `Command.changes` listed with status `shelved` to those it listed with
/// status `pending`, `pending` as `parseChanges` counted them, the first `pending.kept` in
/// `into`, so a changelist listed by both (if `-s pending` includes those with shelved files,
/// which no page says) is one entry: one already there is marked `shelved`, one not there is
/// added after the others while there is room. The caller holds to `pending.kept <=
/// into.len`. When the pending list did not fit (`pending.seen > pending.kept`), a shelved
/// changelist not among those kept may be one of those left out, already counted: it is
/// neither added nor counted again, so `seen` is then at most the true count.
/// Returns how many there are and how many `into` holds.
pub fn mergeShelved(into: []Change, pending: Counted, shelved: []const Change) Counted {
    std.debug.assert(pending.kept <= into.len);
    const pending_overflowed = pending.seen > pending.kept;
    var merged: Counted = .{ .seen = pending.seen, .kept = pending.kept };
    for (shelved) |change| {
        const listed = for (into[0..pending.kept]) |*kept| {
            if (kept.number == change.number) break kept;
        } else null;
        if (listed) |kept| {
            kept.status = .shelved;
            continue;
        }
        if (pending_overflowed) continue;
        merged.seen += 1;
        if (merged.kept >= into.len) continue;
        var added = change;
        added.status = .shelved;
        into[merged.kept] = added;
        merged.kept += 1;
    }
    return merged;
}

/// What a file is opened for, or was shelved as (`p4_fstat.html`'s `action`).
pub const FileAction = enum {
    add,
    edit,
    delete,
    branch,
    move_add,
    move_delete,
    integrate,
    import,
    purge,
    archive,
    /// An action not among these.
    other,

    /// The action `p4` names `text` (`move/add` for `move_add`).
    pub fn of(text: []const u8) FileAction {
        const known = [_]struct { word: []const u8, action: FileAction }{
            .{ .word = "add", .action = .add },
            .{ .word = "edit", .action = .edit },
            .{ .word = "delete", .action = .delete },
            .{ .word = "branch", .action = .branch },
            .{ .word = "move/add", .action = .move_add },
            .{ .word = "move/delete", .action = .move_delete },
            .{ .word = "integrate", .action = .integrate },
            .{ .word = "import", .action = .import },
            .{ .word = "purge", .action = .purge },
            .{ .word = "archive", .action = .archive },
        };
        for (known) |entry| {
            if (std.mem.eql(u8, text, entry.word)) return entry.action;
        }
        return .other;
    }
};

/// Whether an opened file waits for a resolve.
pub const Resolve = enum {
    /// Nothing to resolve.
    resolved,
    /// `unresolved` is more than 0: an integration, unshelve or sync to resolve before submit.
    unresolved,
};

/// A file `Command.opened` listed. Its slices are of the bytes parsed, but `local_path` may be
/// a copy in scratch (`parseOpened`).
pub const Opened = struct {
    /// `depotFile`: its depot path, special characters encoded, as commands take it back.
    depot_path: []const u8,
    /// `clientFile`: its local path, special characters as they are, `/`-separated.
    local_path: []const u8,
    /// `change`: the changelist it is open in (`default`, as `p4 opened` names it, for the
    /// default changelist: UNVERIFIED for `fstat`, whose page shows a number).
    change: Changelist,
    /// `action`: what it is opened for.
    action: FileAction,
    /// `type`: the type it is opened as (`text`, `binary+l`).
    file_type: []const u8 = "",
    /// `unresolved`: whether it waits for a resolve.
    resolve: Resolve = .resolved,
    /// `movedFile`: for a file opened for `move/add`, the depot path it moves from; empty
    /// otherwise.
    moved_path: []const u8 = "",
};

/// Reads what `Command.opened` said into `into`, as many as fit, local paths `/`-separated in
/// `style`: a Windows client's are copied into `scratch` with `/` for `\` (a slice when they hold
/// none). A record without `action` or with a `change` that is neither a number nor `default`
/// is unread. Fails only when `scratch` does.
pub fn parseOpened(bytes: []const u8, style: PathStyle, scratch: std.mem.Allocator, into: []Opened) error{OutOfMemory}!Parsed {
    var parsed: Parsed = .{};
    var records = parseTagged(bytes, "depotFile");
    while (records.next()) |record| {
        const change_text = record.get("change") orelse "";
        const action_text = record.get("action") orelse "";
        const change = changelistOf(change_text) orelse {
            parsed.unread += 1;
            continue;
        };
        if (action_text.len == 0) {
            parsed.unread += 1;
            continue;
        }
        parsed.records.seen += 1;
        if (parsed.records.kept >= into.len) continue;
        const unresolved_text = record.get("unresolved") orelse "0";
        const unresolved_count = std.fmt.parseInt(u32, unresolved_text, 10) catch 0;
        const client_file = record.get("clientFile") orelse "";
        into[parsed.records.kept] = .{
            .depot_path = record.get("depotFile").?,
            .local_path = try slashPath(client_file, style, scratch),
            .change = change,
            .action = FileAction.of(action_text),
            .file_type = record.get("type") orelse "",
            .resolve = if (unresolved_count > 0) .unresolved else .resolved,
            .moved_path = record.get("movedFile") orelse "",
        };
        parsed.records.kept += 1;
    }
    return parsed;
}

/// `default` or a number as a changelist; null for anything else.
fn changelistOf(text: []const u8) ?Changelist {
    if (std.mem.eql(u8, text, "default")) return .default;
    const number = std.fmt.parseInt(u32, text, 10) catch return null;
    return .{ .numbered = number };
}

/// A shelved file `Command.shelved` listed. Its slices are of the bytes parsed.
pub const ShelvedFile = struct {
    /// The changelist it is shelved in.
    change: u32,
    /// `depotFile<n>`: its depot path.
    depot_path: []const u8,
    /// `rev<n>`: the revision it was shelved at, as `p4` writes it.
    revision: []const u8 = "",
    /// `action<n>`: what it was open for.
    action: FileAction = .other,
    /// `type<n>`: its type.
    file_type: []const u8 = "",
};

/// What `parseDescribe` found.
pub const Described = struct {
    /// The changelists, and how many fit.
    changes: Counted = .{},
    /// Their shelved files, and how many fit: only those of kept changelists are kept.
    files: Counted = .{},
    /// Records whose `change` is no number.
    unread: u32 = 0,
};

/// Reads what `Command.shelved` said: each changelist into `changes` and its files, in order,
/// into `files`, as many as fit. A file is a numbered `depotFile<n>` field of its changelist's
/// record, its `action<n>`, `type<n>` and `rev<n>` wherever they are in the record; the numbers
/// count the record's files from 0, as `fstat`'s `otherOpen<n>` do.
pub fn parseDescribe(bytes: []const u8, changes: []Change, files: []ShelvedFile) Described {
    var described: Described = .{};
    var records = parseTagged(bytes, "change");
    while (records.next()) |record| {
        const change = changeOf(record) orelse {
            described.unread += 1;
            continue;
        };
        const change_kept = described.changes.kept < changes.len;
        described.changes.seen += 1;
        if (change_kept) {
            changes[described.changes.kept] = change;
            described.changes.kept += 1;
        }
        // Two passes over the record's fields, so the order `p4` writes them in does not matter:
        // the files by their `depotFile<n>`, then each `rev<n>`, `action<n>` and `type<n>` into
        // the file `n` names, the record's `n`th, its numbers counting from 0.
        const record_first = described.files.kept;
        var fields = record.fields();
        while (fields.next()) |field| {
            if (field.level != 1) continue;
            const split = splitNumbered(field.name) orelse continue;
            if (!std.mem.eql(u8, split.name, "depotFile")) continue;
            described.files.seen += 1;
            if (!change_kept or described.files.kept >= files.len) continue;
            files[described.files.kept] = .{ .change = change.number, .depot_path = field.value };
            described.files.kept += 1;
        }
        const record_kept = described.files.kept - record_first;
        fields = record.fields();
        while (fields.next()) |field| {
            if (field.level != 1) continue;
            const split = splitNumbered(field.name) orelse continue;
            const number = std.fmt.parseInt(u32, split.index, 10) catch continue;
            if (number >= record_kept) continue;
            const file = &files[record_first + number];
            if (std.mem.eql(u8, split.name, "rev")) {
                file.revision = field.value;
            } else if (std.mem.eql(u8, split.name, "action")) {
                file.action = FileAction.of(field.value);
            } else if (std.mem.eql(u8, split.name, "type")) {
                file.file_type = field.value;
            }
        }
    }
    return described;
}

/// A numbered field's name split into its name and its number's digits (`action0`: `action`
/// and `0`); null for a name with no digits at its end, or nothing before them.
fn splitNumbered(name: []const u8) ?struct { name: []const u8, index: []const u8 } {
    var digits_start = name.len;
    while (digits_start > 0 and std.ascii.isDigit(name[digits_start - 1])) digits_start -= 1;
    if (digits_start == name.len or digits_start == 0) return null;
    return .{ .name = name[0..digits_start], .index = name[digits_start..] };
}

/// A file of a diff `Command.diff` or `Command.describe` printed. Its slices are of the bytes
/// parsed.
pub const FileDiff = struct {
    /// Its `==== ... ====` line, its line break included.
    header: []const u8,
    /// Its depot path, as the header gives it (encoded).
    depot_path: []const u8,
    /// Its revision after `#`: the one the workspace file is diffed against, or the one a
    /// submitted changelist made.
    revision: []const u8,
    /// Its local path, as `diff`'s header gives it (the message catalog's `%localPath%`; the
    /// diff page says the header is in P4 Server syntax: which it is, is UNVERIFIED); empty for
    /// `describe`'s.
    local_path: []const u8 = "",
    /// Its type, from `describe`'s header (`text`, or `text/ktext` when it changed) or after
    /// `diff`'s (`binary`); empty when not given.
    file_type: []const u8 = "",
    /// Whether it differs as a binary file does (`(... files differ ...)`): it has no hunks.
    binary: bool = false,
    /// Everything after its header up to the next file's, the blank lines at its end left
    /// out: its hunks, or what else `p4` or a person's diff program wrote for it.
    body: []const u8 = "",
    /// Its first hunk among those `parseDiff` kept: its hunks are
    /// `hunks[first_hunk..][0..hunk_count]`.
    first_hunk: u32 = 0,
    /// How many of its hunks `parseDiff` kept: fewer than it has when the slice filled.
    hunk_count: u32 = 0,
};

/// What a file's part of a diff holds.
pub const DiffBody = enum {
    /// Hunks: a line beginning `@@ `.
    hunks,
    /// `(... files differ ...)`: a binary file that changed. The literal is the published
    /// client's (`clientuser.cc`, `ClientUser::Diff`), not a page's.
    binary,
    /// Nothing: the header alone. For a text file that did not change since it was opened; but
    /// `p4 diff` without `-t` does not compare a file whose type is not text (`p4_diff.html`:
    /// `-t` "Force `p4 diff` to diff binary files"), and what it prints for one then is
    /// UNVERIFIED: an empty part of a file whose `file_type` is not text is "not compared", not
    /// "unchanged". A file opened for add has nothing to compare.
    empty,
    /// Lines that are none of these: not a unified diff, as a program named by `P4DIFF`,
    /// `DIFF` or `P4DIFFUNICODE` may write. The panel shows `FileDiff.body` as text.
    other,
};

/// What `file`'s part holds, from its `body`.
pub fn diffBodyOf(file: FileDiff) DiffBody {
    if (file.binary) return .binary;
    if (std.mem.trim(u8, file.body, " \t\r\n").len == 0) return .empty;
    var position: usize = 0;
    while (position < file.body.len) {
        const line = lineAt(file.body, position);
        if (std.mem.startsWith(u8, line, "@@ ")) return .hunks;
        position += line.len;
    }
    return .other;
}

/// How many files and hunks `parseDiff` found and kept.
pub const Counts = struct {
    /// The files found, and how many fit in `files`.
    files: Counted = .{},
    /// The hunks found, and how many fit in `hunks`: only those of kept files are kept.
    hunks: Counted = .{},
};

/// Splits what `Command.diff` or `Command.describe` said into `files` and `hunks`, without
/// copying, as many as fit: a hunk is kept only when its file is. A file begins at a line
/// `==== <depot path>#<rev> - <local path> ====[ (<type>)]` (`diff`) or `==== <depot
/// path>#<rev> (<type>) ====` (`describe`), the message catalog's headers, and runs to the next
/// such line; its hunks are read from it by `ui.diff.parseHunks`, with the blank lines at its
/// end left out (`describe` writes one before each header; a hunk's lines all begin with a
/// character). `p4`'s own unified diff writes no `---` and `+++` lines; a diff program named by
/// `P4DIFF` may, and `parseHunks` passes over what comes before a file's first `@@`. Anything
/// before the first header (`describe`'s change and its list of files) is passed over.
pub fn parseDiff(bytes: []const u8, files: []FileDiff, hunks: []diff_widget.Hunk) Counts {
    var counts: Counts = .{};
    var position: usize = 0;
    while (position < bytes.len) {
        const line = lineAt(bytes, position);
        if (isDiffHeader(line)) {
            position = parseFileDiff(bytes, position, files, hunks, &counts);
        } else {
            position += line.len;
        }
    }
    return counts;
}

fn isDiffHeader(line: []const u8) bool {
    const text = std.mem.trimEnd(u8, line, "\r\n");
    return std.mem.startsWith(u8, text, "==== //") and std.mem.indexOf(u8, text[5..], " ====") != null;
}

/// Reads the file whose header begins at `start`, and its hunks, and returns where the next
/// line after them begins.
fn parseFileDiff(bytes: []const u8, start: usize, files: []FileDiff, hunks: []diff_widget.Hunk, counts: *Counts) usize {
    const header = lineAt(bytes, start);
    var file = fileDiffOf(header);
    var position = start + header.len;
    const part_start = position;
    var part_end = position;
    while (position < bytes.len) {
        const line = lineAt(bytes, position);
        if (isDiffHeader(line)) break;
        position += line.len;
        const text = std.mem.trimEnd(u8, line, "\r\n");
        if (text.len != 0) part_end = position;
        if (std.mem.eql(u8, text, "(... files differ ...)")) file.binary = true;
    }

    const file_kept = counts.files.kept < files.len;
    const file_index = counts.files.kept;
    counts.files.seen += 1;
    if (file_kept) {
        file.first_hunk = counts.hunks.kept;
        counts.files.kept += 1;
    }
    const part = bytes[part_start..part_end];
    file.body = part;
    const room = if (file_kept) hunks[counts.hunks.kept..] else hunks[0..0];
    const hunk_counts = diff_widget.parseHunks(part, room);
    counts.hunks.seen += hunk_counts.seen;
    counts.hunks.kept += hunk_counts.kept;
    file.hunk_count = hunk_counts.kept;
    if (file_kept) files[file_index] = file;
    return position;
}

/// A file's header read: `==== //depot/a.c#3 - /ws/a.c ====[ (type)]` or `==== //depot/a.c#4
/// (type) ====`. The depot path runs to its first `#` (a `#` in a name is encoded), the revision
/// to the space after it.
fn fileDiffOf(header: []const u8) FileDiff {
    const text = std.mem.trimEnd(u8, header, "\r\n");
    var file: FileDiff = .{ .header = header, .depot_path = "", .revision = "" };
    const rest = text["==== ".len..];
    const hash = std.mem.indexOfScalar(u8, rest, '#') orelse {
        const end = std.mem.indexOf(u8, rest, " ") orelse rest.len;
        file.depot_path = rest[0..end];
        return file;
    };
    file.depot_path = rest[0..hash];
    const after_hash = rest[hash + 1 ..];
    const revision_end = std.mem.indexOfScalar(u8, after_hash, ' ') orelse after_hash.len;
    file.revision = after_hash[0..revision_end];
    const tail = after_hash[revision_end..];
    if (std.mem.startsWith(u8, tail, " - ")) {
        // `diff`: the local path to the last ` ====`, a type in parentheses after it.
        const names = tail[" - ".len..];
        const close = std.mem.lastIndexOf(u8, names, " ====") orelse names.len;
        file.local_path = names[0..close];
        const after_close = @min(close + " ====".len, names.len);
        const after = std.mem.trim(u8, names[after_close..], " ");
        if (after.len >= 2 and after[0] == '(' and after[after.len - 1] == ')') file.file_type = after[1 .. after.len - 1];
    } else if (std.mem.startsWith(u8, tail, " (")) {
        // `describe`: the type in parentheses before ` ====`.
        const close = std.mem.lastIndexOf(u8, tail, ") ====") orelse return file;
        file.file_type = tail[" (".len..close];
    }
    return file;
}

/// A changelist's form, as `Command.change_form` printed it. Its slices are of the bytes
/// parsed.
pub const ChangeForm = struct {
    /// `Change:`: its number, or `new`.
    change: []const u8 = "",
    /// `Client:`: its workspace.
    client: []const u8 = "",
    /// `User:`: its owner.
    user: []const u8 = "",
    /// `Status:`: `new`, `pending`, `shelved` or `submitted`.
    status: []const u8 = "",
    /// `Type:`: `public` or `restricted`.
    type: []const u8 = "",
    /// `Description:`'s lines as the form holds them, indented; `writeDescription` writes them
    /// as text.
    description: []const u8 = "",
    /// How many files `Files:` lists.
    file_count: u32 = 0,
};

/// Reads a changelist's form: its single-line fields (`Name:` and a tab or spaces and the
/// value), its description's lines and how many files it lists. Comments (`#` first) and
/// fields it does not know are passed over.
pub fn parseChangeForm(bytes: []const u8) ChangeForm {
    var form: ChangeForm = .{};
    var position: usize = 0;
    while (position < bytes.len) {
        const line = lineAt(bytes, position);
        position += line.len;
        const name = formFieldName(line);
        if (name.len == 0) continue;
        const line_text = std.mem.trimEnd(u8, line, "\r\n");
        const value = std.mem.trim(u8, line_text[name.len + 1 ..], " \t");
        const field_end = indentedEnd(bytes, position);
        const under = bytes[position..field_end];
        if (std.mem.eql(u8, name, "Change")) {
            form.change = value;
        } else if (std.mem.eql(u8, name, "Client")) {
            form.client = value;
        } else if (std.mem.eql(u8, name, "User")) {
            form.user = value;
        } else if (std.mem.eql(u8, name, "Status")) {
            form.status = value;
        } else if (std.mem.eql(u8, name, "Type")) {
            form.type = value;
        } else if (std.mem.eql(u8, name, "Description")) {
            form.description = under;
        } else if (std.mem.eql(u8, name, "Files")) {
            var files = std.mem.splitScalar(u8, under, '\n');
            while (files.next()) |file_line| {
                if (std.mem.trim(u8, file_line, " \t\r").len != 0) form.file_count += 1;
            }
        }
        position = field_end;
    }
    return form;
}

/// Writes a form's description lines (`ChangeForm.description`) as text: each line without the
/// one tab (or the spaces) it is indented with, the line breaks between them `\n`, none after
/// the last.
pub fn writeDescription(writer: *std.Io.Writer, indented: []const u8) std.Io.Writer.Error!void {
    const trimmed = std.mem.trimEnd(u8, indented, "\r\n");
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const text = if (std.mem.startsWith(u8, line, "\t")) line[1..] else std.mem.trimStart(u8, line, " ");
        if (!first) try writer.writeByte('\n');
        try writer.writeAll(text);
        first = false;
    }
}

/// Reads what `Command.save_change` said, `Change <n> created.` or `Change <n> updated...`: the
/// changelist's number; null for anything else. The sentence is UNVERIFIED: Perforce's message
/// catalog's (`MsgDm::ChangeCreated`, `MsgDm::ChangeUpdated`), not a page's, and a server whose
/// messages are translated may word it otherwise: the panel then refreshes its changelists to
/// find the new one.
pub fn parseChangeSaved(bytes: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "Change ")) continue;
        const rest = line["Change ".len..];
        const number_end = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        const after = rest[number_end..];
        const known = std.mem.startsWith(u8, after, " created") or std.mem.startsWith(u8, after, " updated");
        if (!known) continue;
        return std.fmt.parseInt(u32, rest[0..number_end], 10) catch continue;
    }
    return null;
}

/// Whether commands can run without asking for a password.
pub const Session = enum {
    /// `login -s` succeeded: a valid ticket, or a user with no password.
    signed_in,
    /// The server answered `info`, which needs no ticket, and `login -s` failed: the person runs
    /// `p4 login` in a terminal.
    not_signed_in,
    /// No server answered: nothing is known of the ticket.
    unknown,
};

/// The session, from the exit codes of `Command.info` and `Command.login_status`, run one
/// after the other: never from what either said, which is a sentence a server may translate.
/// The panel asks when a command fails, to tell a session that ended from another failure.
pub fn sessionOf(info_exit_code: i32, login_status_exit_code: i32) Session {
    if (info_exit_code != 0) return .unknown;
    if (login_status_exit_code != 0) return .not_signed_in;
    return .signed_in;
}

/// The line that begins at `position`, its line break included; the rest of `bytes` when it
/// has none.
fn lineAt(bytes: []const u8, position: usize) []const u8 {
    const end = std.mem.indexOfScalarPos(u8, bytes, position, '\n');
    if (end) |newline| return bytes[position .. newline + 1];
    return bytes[position..];
}

/// How many bytes of `text` fit in `limit` without cutting a UTF-8 character: all of it when it
/// fits, else up to the last character boundary at or before `limit`.
fn utf8Prefix(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var cut = limit;
    while (cut > 0 and text[cut] & 0xc0 == 0x80) cut -= 1;
    return cut;
}
