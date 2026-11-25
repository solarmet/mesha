//! git's words: every command line the editor's git panel runs and the parsers of what git
//! says back. Nothing here runs a program, keeps state, touches a table or allocates, except a
//! diff's quoted paths, which `parseDiff` unquotes into the scratch its caller hands it. The
//! panel runs the lines through the editor's runner (`runner.zig`): `writeArgv` writes a
//! `Job.argv`, `writeEnvironment` its `environment`, and `writePaths` and `rebaseList` what goes
//! on its input.
//!
//! One process per question: a process costs the most on Windows, so each command answers as
//! much as git lets one command answer. One `status` gives the branch, its upstream, how far
//! ahead and behind it is, the stash count and every changed file with its staged and unstaged
//! state; one `diff` gives every unstaged hunk and one `diff` of the index every staged one;
//! staging, unstaging or discarding any number of files is one command with the paths on its
//! input; a hunk is one `apply`. No command takes a file list as arguments but `clean`, which
//! git gives no other way, in batches of what fits in one command line (`max_clean_bytes`).
//!
//! Every command begins `git -c core.quotepath=false -c color.ui=false`, so paths come back as
//! their bytes and nothing is coloured. Those that only read also pass `--no-optional-locks`,
//! so a refresh never takes the index's lock from a commit a person runs in a terminal, and
//! those that take paths pass `--literal-pathspecs`, so a file named `*.txt` is that file. The
//! parsers read only output whose shape git promises (`--porcelain=v2`, `-z`, an explicit
//! `--format`, a unified diff), never a sentence, which git translates.
//!
//! Text a person reads that comes from git (paths, subjects, names) is returned as slices of
//! the bytes parsed, which live as long as those bytes do. It need not be UTF-8: a parser never
//! fails or cuts on bytes that are not, and `mesha.ui.displayText` makes it displayable.
//!
//! Requires git `minimum_version`.

const std = @import("std");
const mesha = @import("mesha");
const process = mesha.process;
const diff_widget = mesha.ui.diff;

const separator = process.argument_separator;
const vcs_query = @import("query.zig");

/// The program the panel runs, found on `PATH`. On Windows the process system's spawn looks
/// for it with each of `PATHEXT`'s extensions, so `git.exe` is found without one.
pub const program = "git";

/// The oldest git these command lines run on: `rm`'s `--pathspec-from-file` needs 2.26
/// (`add`'s and `restore`'s 2.25); `--end-of-options` 2.24; `switch` and `restore` 2.23;
/// `rebase -i`'s `break` 2.20. Below 2.35 `status` gives no `# stash` line, so
/// `Status.stash_count` reads 0 however many there are.
pub const minimum_version = "2.26";

/// The most arguments a command line of the panel's other than `clean`'s is written with, the
/// program's name included: what a log's query is bounded by (`max_query_arguments`).
pub const max_arguments = 64;

/// How many commits `Command.recent` lists.
pub const recent_count = 10;

/// The arguments before the paths in `writeClean`'s command line.
const clean_prefix = [_][]const u8{ program, "--literal-pathspecs", "-c", "core.quotepath=false", "-c", "color.ui=false", "clean", "-f", "--" };

/// The most bytes one `clean` command line takes, its separators counted: below Windows' limit
/// of 32,767 characters for a command line, with room for the quotes the spawn adds.
pub const max_clean_bytes = 30_000;

/// The bytes of `clean_prefix` in a command line, each argument followed by a separator.
const clean_prefix_bytes = blk: {
    var bytes: usize = 0;
    for (clean_prefix) |argument| bytes += argument.len + 1;
    break :blk bytes;
};

/// The most paths one `clean` command line removes: as many one-byte paths as `max_clean_bytes`
/// holds after `clean_prefix`, each with its separator (14,961), so the line's bytes are what
/// ends a batch: about 1,000 paths of 30 bytes a process. Within what the process system passes
/// to one program (`process.max_arguments`).
pub const max_clean_paths = (max_clean_bytes - clean_prefix_bytes) / 2;

comptime {
    std.debug.assert(clean_prefix.len + max_clean_paths <= process.max_arguments);
}

/// What a writer fails with: the writer's own failure, or an argument that cannot be passed as
/// one (`UnpassableArgument`): empty where one is needed, holding a NUL or
/// `process.argument_separator`, or a name or revision that begins with `-`.
pub const WriteError = std.Io.Writer.Error || error{UnpassableArgument};

// ---- command lines -----------------------------------------------------------------------------

/// Which changes a diff shows.
pub const Side = enum {
    /// The working tree against the index: what is not staged.
    unstaged,
    /// The index against `HEAD`, or against nothing before the first commit: what is staged.
    staged,
};

/// What a hunk applied with `apply` does.
pub const Apply = enum {
    /// Applies it to the index: a hunk of the unstaged diff is staged.
    stage,
    /// Applies it reversed to the index: a hunk of the staged diff is unstaged.
    unstage,
    /// Applies it reversed to the working tree: a hunk of the unstaged diff is thrown away.
    discard,
};

/// Which commit `Command.commit` makes.
pub const CommitKind = enum {
    /// A new commit of what is staged, its message on the input.
    new,
    /// Replaces `HEAD` with what is staged added to it, the message on the input.
    amend,
    /// Replaces `HEAD`'s message alone, the message on the input: `--only` with no path keeps
    /// what is staged out of it, and staged.
    reword,
    /// Replaces `HEAD` with what is staged added to it, keeping its message. Its input must be
    /// empty: an `--edit` among the transient's arguments starts git's editor, which writes any
    /// input over the message.
    extend,
    /// A new commit, `fixup! ` and `target`'s subject, for `rebase --autosquash` to fold into
    /// `target`. Its input must be empty, as `extend`'s.
    fixup,
};

/// `Command.commit`'s commit.
pub const Commit = struct {
    /// Which commit is made.
    kind: CommitKind = .new,
    /// The commit a `fixup` fixes, as git names it (a hash); unused by the other kinds.
    target: []const u8 = "",
    /// The commit transient's arguments, as `ui.transient.writeArguments` wrote them with
    /// `process.argument_separator`: each followed by the separator.
    arguments: []const u8 = "",
};

/// Where `Command.create_branch` leaves the person.
pub const AfterCreate = enum {
    /// On the new branch: `switch -c`.
    switch_to,
    /// Where they were: `branch`.
    stay,
};

/// `Command.create_branch`'s branch.
pub const NewBranch = struct {
    /// Its name, which `isRefName` accepts.
    name: []const u8,
    /// The commit it starts at; empty for `HEAD`.
    start: []const u8 = "",
    /// Whether the person is switched to it.
    after: AfterCreate = .switch_to,
};

/// How `Command.delete_branch` deletes.
pub const Deletion = enum {
    /// Only a branch merged into its upstream or `HEAD`: `branch -d`, which fails otherwise.
    merged,
    /// Whatever it holds: `branch -D`.
    force,
};

/// `Command.delete_branch`'s branch.
pub const DeleteBranch = struct {
    /// The local branch's name, as `Ref.short_name` gives it.
    name: []const u8,
    /// Whether an unmerged branch is deleted too.
    how: Deletion = .merged,
};

/// `Command.rename_branch`'s branch.
pub const RenameBranch = struct {
    /// The local branch's name now, as `Ref.short_name` gives it.
    name: []const u8,
    /// The name it is given, which `isRefName` accepts.
    new_name: []const u8,
};

/// `Command.merge`'s merge.
pub const Merge = struct {
    /// The merge transient's arguments (`--no-ff`, `--squash`, ...): each followed by the
    /// separator.
    arguments: []const u8 = "",
    /// What is merged into `HEAD`.
    revision: []const u8,
};

/// `Command.rebase`'s rebase.
pub const Rebase = struct {
    /// The rebase transient's arguments (`--autosquash`, `--root`, ...): each followed by the
    /// separator.
    arguments: []const u8 = "",
    /// The commit the list is replayed onto, the parent of its first commit; empty with
    /// `--root` among the arguments.
    base: []const u8 = "",
};

/// `Command.pull_from`'s pull.
pub const PullFrom = struct {
    /// The pull transient's arguments (`--rebase`, `--ff-only`): each followed by the separator.
    arguments: []const u8 = "",
    /// The remote pulled from.
    remote: []const u8,
    /// Its branch pulled.
    branch: []const u8,
};

/// `Command.switch_track`'s branches.
pub const SwitchTrack = struct {
    /// The local branch made.
    name: []const u8,
    /// The remote's branch it tracks, `<remote>/<branch>`.
    remote_branch: []const u8,
};

/// `Command.rebase_commits`'s two commits.
pub const RebaseCommits = struct {
    /// The commit the list is replayed onto, a full hash.
    base: []const u8,
    /// The commit `HEAD` is at as the list is made, a full hash.
    head: []const u8,
};

/// `Command.push`'s push.
pub const Push = struct {
    /// The push transient's arguments (`--set-upstream`, `--force-with-lease`, ...): each
    /// followed by the separator.
    arguments: []const u8 = "",
    /// The remote pushed to; empty for the branch's upstream's, or `origin`.
    remote: []const u8 = "",
    /// The branch pushed; empty for what `push.default` pushes. Needs `remote`. One whose name
    /// begins with `+` is written as `refs/heads/<branch>`, which git does not read as a forced
    /// refspec, and which `--set-upstream` still tracks.
    branch: []const u8 = "",
};

/// A command the git panel runs. `writeArgv` writes its command line; each field says what goes
/// on its input and which parser reads what it says. Slices are read only while `writeArgv`
/// runs.
///
/// Every job runs with `writeEnvironment`'s variables, whose editor is the host writing the
/// job's input over the file git hands it. So a command whose input is said to be empty must be
/// given none: git may start its editor (a squash, a continued rebase, an `--edit` from a
/// transient), and an input would replace the message git prepared.
pub const Command = union(enum) {
    /// `-c status.renames=true status --porcelain=v2 --branch --show-stash -z
    /// --untracked-files=all`, which finds renames and never copies, whatever the person's
    /// `status.renames` says: the branch, its
    /// upstream, ahead and behind, the stash count and every changed or untracked file.
    /// `parseStatus` reads it. Input: empty.
    status,
    /// The last `recent_count` commits of `HEAD`, as `parseLog` reads them. Fails before the
    /// first commit. Input: empty.
    recent,
    /// The commits a log view lists, as `parseLog` reads them: `git log` and the person's query,
    /// the text after `git log ` as they wrote it (`-n 256 HEAD`), split into arguments by
    /// `query.write`. vcs-git's own options (`log_options`: `--no-show-signature`, `-z`, the format
    /// `parseLog` reads, `--date=short` and `--max-count` one past `max_log_commits`) come first,
    /// before the person's arguments and so before any `--` among them: an option of the
    /// person's that says how many commits (`-n`) or changes what git prints (`--oneline`,
    /// `--format`, `--stat`, `-p`, `--graph`) wins, git taking the last of each, and output not
    /// in vcs-git's shape is what `parseLog` reports it could not read. The table the log fills
    /// holds `max_log_commits`, but the runner keeps all git writes until it is parsed: a query
    /// with a huge `-n`, or `-p` over many commits, holds that much in the process's output;
    /// the queries vcs-git writes itself always carry `-n`. Input: empty.
    log: []const u8,
    /// Every hunk of one side, as `parseDiff` reads them, with no rename detection: a renamed
    /// file is an added file and a deleted one, so applying one of its hunks never stages or
    /// undoes the rename (as `git reset -p` does). Input: empty.
    diff: Side,
    /// Stages its paths: their changes, their deletion, or the file when untracked. Input: the
    /// paths, `writePaths`. Each must be in the index or the working tree: one that is in
    /// neither (a deletion already staged) fails the whole batch.
    stage,
    /// Unstages its paths, back to `HEAD`. Fails before the first commit: `unstage_unborn` then.
    /// Input: the paths, `writePaths`, each in the index or `HEAD`, or the whole batch fails. A
    /// renamed entry is unstaged whole with both its paths: its new one alone leaves the
    /// deletion of its original staged.
    unstage,
    /// Unstages its paths before the first commit: takes them out of the index, leaving the
    /// files as they are. `-f` lets it take out a file edited since it was staged, which `rm
    /// --cached` alone refuses; with `--cached` it touches only the index. Input: the paths,
    /// `writePaths`, each in the index.
    unstage_unborn,
    /// Throws away the unstaged changes of its paths: each file becomes what the index holds.
    /// Input: the paths, `writePaths`, each tracked and not unmerged: one that is not (an
    /// untracked file, a conflict) fails the whole batch and nothing is thrown away.
    discard,
    /// Applies a patch. Input: `ui.diff.patch`'s bytes, a file's `FileDiff.header` before them.
    apply: Apply,
    /// Commits. Input: the message for `new`, `amend` and `reword`; empty for `extend` and
    /// `fixup`. `-F -` takes the message as it is but for git's `whitespace` cleanup: blank
    /// lines at its ends and spaces at its lines' ends go, and a line beginning `#` stays.
    commit: Commit,
    /// `HEAD`'s whole message; `parseMessage` reads it. Fails before the first commit. Input:
    /// empty.
    head_message,
    /// Every local and remote-tracking branch, as `parseRefs` reads them. Input: empty.
    refs,
    /// Switches to the branch of this name; a name only a remote has becomes a local branch
    /// tracking it. Input: empty.
    switch_to: []const u8,
    /// Makes the local branch `name` of a remote's branch, `remote_branch` (`<remote>/<branch>`),
    /// tracking it, and switches to it: `switch -c <name> --track <remote_branch>`, the name the
    /// panel's own, not the one git would derive. Fails when a local branch of that name is
    /// there. Input: empty.
    switch_track: SwitchTrack,
    /// Creates a branch. Input: empty.
    create_branch: NewBranch,
    /// Deletes a local branch. Input: empty.
    delete_branch: DeleteBranch,
    /// Renames a local branch, its upstream and its reflog with it. Input: empty.
    rename_branch: RenameBranch,
    /// Merges a revision into `HEAD`. Input: empty: an `--edit` among the transient's arguments
    /// starts git's editor on the merge's message.
    merge: Merge,
    /// Gives up a merge stopped on conflicts, back to before it. Input: empty.
    merge_abort,
    /// Starts an interactive rebase, with `rebase.missingCommitsCheck=error`: git refuses a list
    /// that leaves out a commit it would have listed (`HEAD` moved since the list was made),
    /// exit 1, the rebase then begun and stopped before its first line, for `--abort`. Input:
    /// the list, `rebaseList`'s bytes, which the sequence editor writes over git's. git reads no more of the input after that, and a `squash` later
    /// starts its editor with nothing left to read, which keeps the joined message.
    rebase: Rebase,
    /// Goes on with a rebase stopped by a conflict once it is resolved and staged, an `edit`, or
    /// a `break`, with `rebase.missingCommitsCheck=error`: a list git refused as missing commits
    /// is refused again (exit 1), never run short. Input: empty: git starts its editor for a squash or a commit whose conflict was
    /// resolved, and keeps its message only when the editor reads nothing.
    rebase_continue,
    /// Leaves out the commit a rebase stopped on and goes on, with
    /// `rebase.missingCommitsCheck=error` as `rebase_continue`. Input: empty, as
    /// `rebase_continue`'s.
    rebase_skip,
    /// Gives up a rebase, back to before it. Input: empty.
    rebase_abort,
    /// The commits an interactive rebase of `head` onto `base` lists, as git lists them in its
    /// own todo list (`rebase -i` with no `--rebase-merges`): those of `head` not in `base`,
    /// merges left out, and those whose change `base` already has (`--cherry-pick
    /// --right-only` of `<base>...<head>`) too, oldest first (`--reverse`, `--topo-order`), in
    /// `log`'s format, which `parseLog` reads; at most one past `max_rebase_commits`, so a rebase
    /// of more than the list holds is told apart. Both are full hashes, so the list is of those
    /// two commits whatever moves after. Input: empty.
    rebase_commits: RebaseCommits,
    /// What is left of the todo list of the interactive rebase in progress, as git shows it to
    /// its sequence editor, its comments with it, which `parseTodo` reads: `rebase --edit-todo`
    /// run with the host as a sequence editor that prints the file git hands it
    /// (`SequenceEditor.print_file`) and leaves it as it was. Fails, exit 128, with no rebase in
    /// progress, and exit 1 at a list lacking commits (`rebase.missingCommitsCheck=error`), which
    /// git refuses even to show: the list is then one git did not run. Input: empty.
    rebase_todo,
    /// Replaces what is left of the todo list of the interactive rebase in progress, and stops
    /// there: `rebase --edit-todo`, `r r` going on, with `rebase.missingCommitsCheck=error`. Input: the list, `rebaseList`'s bytes, which
    /// the sequence editor writes over git's; an empty input would leave the list as it was.
    rebase_edit_todo,
    /// Whether an interactive rebase is in progress, told by the exit code alone
    /// (`rebaseCheckAnswer`): `rebase --edit-todo`, whose editor writes nothing over the list
    /// when the input is empty. One process, asked only when `operation` reads `none` with `HEAD`
    /// detached (see `InProgress`). Input: empty, or the list would be replaced.
    rebase_check,
    /// Pushes. Input: empty. A remote command (`push`, `pull`, `pull_from`, `fetch`) can take
    /// long and can want a password: git asks none in a terminal (`GIT_TERMINAL_PROMPT=0`,
    /// `writeEnvironment`) and its input is empty and closed, so an https remote that wants one
    /// fails, and what git said tells why; a credential helper or askpass program the person
    /// set up still answers. ssh's own questions (a passphrase, a host's key) are its own: no
    /// `GIT_SSH_COMMAND` is set, as one set here would override the person's own (in the
    /// environment, `core.sshCommand` or `GIT_SSH`), which a plugin cannot see. With no
    /// terminal (an engine not started from one, or on Windows, where a program runs with no
    /// console) ssh has nowhere to ask and fails; started from a terminal it may ask there, and
    /// `C-g` gives the command up.
    push: Push,
    /// Pulls into the current branch from its upstream; the pull transient's arguments, each
    /// followed by the separator. Input: empty: a merge it makes may start git's editor.
    pull: []const u8,
    /// Pulls from a remote's branch: `pull <arguments> <remote> <branch>`. Input: empty, as
    /// `pull`'s.
    pull_from: PullFrom,
    /// Fetches; the fetch transient's arguments (`--prune`, ...), each followed by the
    /// separator. Input: empty.
    fetch: []const u8,
    /// Fetches every remote: `fetch <arguments> --all`, the arguments as `fetch`'s. Input: empty.
    fetch_all: []const u8,
    /// The repository's remotes, a name a line, as `parseRemotes` reads them. Input: empty.
    remotes,
    /// One commit, its message and its changes, as `parseShow` reads them; the revision. A
    /// merge's changes are those against its first parent. Renames are shown as renames.
    /// Input: empty.
    show: []const u8,
    /// What operation is in progress, as `parseInProgress` reads it: one process, asked when
    /// `InProgress` says. Input: empty.
    operation,
    /// The full hash of the commit a revision a person typed names (`HEAD~3`, a short hash, a
    /// tag): `rev-parse --verify --end-of-options <revision>^{commit}`, one line; fails, exit
    /// 128, for one git cannot find. Input: empty.
    resolve: []const u8,
    /// `rev-parse --show-toplevel`: the root of the repository the job's directory is in, which
    /// `status` does not tell and whose paths are relative to it, as `parseRoot` reads it.
    /// Fails outside a repository, as `status` does (exit 128). Asked once for a working
    /// directory. Input: empty.
    root,
};

/// Which of git's global options a command line begins with.
const Access = enum {
    /// Reads only: `--no-optional-locks`.
    reads,
    /// May write.
    writes,
    /// May write, and takes pathspecs, which are paths: `--literal-pathspecs`.
    writes_paths,
};

/// The format `recent` and `log` list commits in: the hash, the short hash, the author's name,
/// the date, the refs that point at it, and the subject, separated by 0x1f.
const log_format = "--format=%H%x1f%h%x1f%an%x1f%ad%x1f%D%x1f%s";
/// The most commits a log keeps, the rows of the table that holds them: `Command.log` asks git
/// for one more unless the person's query says how many (`-n`), so a log that lists more than
/// the table holds says so.
pub const max_log_commits = 4096;
/// What `Command.log` writes after `log`, before the person's query: what makes git's answer
/// the records `parseLog` reads, and at most one commit past `max_log_commits` unless the query
/// says how many.
const log_options = [_][]const u8{ "log", "--no-show-signature", "-z", log_format, "--date=short", std.fmt.comptimePrint("--max-count={d}", .{max_log_commits + 1}) };
/// The most arguments a log's query may split into: what `max_arguments` leaves after the
/// longest prefix (`--no-optional-locks` and the two `-c`s) and `log_options`.
pub const max_query_arguments = max_arguments - 1 - 5 - log_options.len;
/// The most commits an interactive rebase's list holds: `Command.rebase_commits` asks for one
/// more, and a rebase that would list more is refused, never run on a list cut short, since a
/// commit left out of the list is lost.
pub const max_rebase_commits = 1024;
/// The setting an interactive rebase runs with, so git refuses a list missing a commit.
const missing_commits_check = [_][]const u8{ "-c", "rebase.missingCommitsCheck=error" };
/// What `Command.rebase_commits` writes after `log`, before `<base>...<head>`: the commits
/// `rebase -i <revision>` lists in its own todo list, oldest first, in `log`'s format.
const rebase_commits_options = [_][]const u8{ "log", "--no-show-signature", "-z", log_format, "--date=short", "--no-merges", "--cherry-pick", "--right-only", "--topo-order", "--reverse", std.fmt.comptimePrint("--max-count={d}", .{max_rebase_commits + 1}), "--end-of-options" };
/// The format `show` writes before the commit's changes: the hash, the author's name, the date
/// and the whole message, separated by 0x1f, the message ended by 0x1e.
const show_format = "--format=%H%x1f%an%x1f%ad%x1f%B%x1e";
/// `for-each-ref`'s format for `refs`: the full name, the short name, the upstream, `*` for
/// the branch `HEAD` is on, the commit it is at and the worktree it is checked out in, separated
/// by 0x1f. `for-each-ref` writes a byte as `%` and two hex
/// digits, where `log` writes `%x` and two.
const refs_format = "--format=%(refname)%1f%(refname:short)%1f%(upstream:short)%1f%(HEAD)%1f%(objectname)%1f%(worktreepath)";
/// The refs whose presence tells which operation is in progress, as `parseInProgress` reads
/// them. `rebase-merge/onto` and `rebase-apply/onto` are files in the git directory, which git
/// reads as refs where refs are files (the default backend), and are there for the whole of a
/// rebase, a `break` included, where `REBASE_HEAD` is there only while one is stopped on a
/// commit; `rebase-merge/amend`, a file of the same kind, only while one is stopped on a commit
/// marked `edit`, which tells that stop from a conflict's. `log --source` prints a commit once,
/// under the first name given that reaches it: `rebase-merge/amend` comes before `REBASE_HEAD`,
/// which at an `edit` in place is the same commit.
const operation_refs = [_][]const u8{ "MERGE_HEAD", "rebase-merge/amend", "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_EXPECTED_REV", "rebase-merge/onto", "rebase-apply/onto" };

/// Writes `command`'s whole command line, `program` first, its arguments separated by
/// `process.argument_separator`, for a `runner.Job`'s `argv`. Fails as `writer` does, or with
/// `UnpassableArgument`, having written nothing, for a name, revision, hash or path that is
/// empty where one is needed, begins with `-`, or holds a NUL or the separator, or a push's
/// branch without its remote.
pub fn writeArgv(writer: *std.Io.Writer, command: Command) WriteError!void {
    try checkCommand(command);
    switch (command) {
        .status => {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &.{ "-c", "status.renames=true", "status", "--porcelain=v2", "--branch", "--show-stash", "-z", "--untracked-files=all" });
        },
        .recent => {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &.{ "log", "--no-show-signature", "-n", std.fmt.comptimePrint("{d}", .{recent_count}), "-z", log_format, "--date=short" });
        },
        .log => |query| {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &log_options);
            // Checked already (`checkCommand`): only the writer can fail here.
            _ = vcs_query.write(writer, query) catch |err| switch (err) {
                error.WriteFailed => return error.WriteFailed,
                error.UnterminatedQuote, error.UnpassableArgument => return error.UnpassableArgument,
            };
        },
        .diff => |side| {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &.{ "diff", "--no-ext-diff", "--no-color", "-U3", "--no-renames", "--src-prefix=a/", "--dst-prefix=b/" });
            if (side == .staged) try writeFlags(writer, &.{"--cached"});
        },
        .stage => {
            try writePrefix(writer, .writes_paths);
            try writeFlags(writer, &.{ "add", "--pathspec-from-file=-", "--pathspec-file-nul" });
        },
        .unstage => {
            try writePrefix(writer, .writes_paths);
            try writeFlags(writer, &.{ "restore", "--staged", "--pathspec-from-file=-", "--pathspec-file-nul" });
        },
        .unstage_unborn => {
            try writePrefix(writer, .writes_paths);
            try writeFlags(writer, &.{ "rm", "--cached", "-f", "-q", "--pathspec-from-file=-", "--pathspec-file-nul" });
        },
        .discard => {
            try writePrefix(writer, .writes_paths);
            try writeFlags(writer, &.{ "restore", "--worktree", "--pathspec-from-file=-", "--pathspec-file-nul" });
        },
        .apply => |how| {
            try writePrefix(writer, .writes);
            const flags: []const []const u8 = switch (how) {
                .stage => &.{ "apply", "--cached", "--whitespace=nowarn", "-" },
                .unstage => &.{ "apply", "--cached", "--reverse", "--whitespace=nowarn", "-" },
                .discard => &.{ "apply", "--reverse", "--whitespace=nowarn", "-" },
            };
            try writeFlags(writer, flags);
        },
        .commit => |commit| {
            try writePrefix(writer, .writes);
            switch (commit.kind) {
                .new => try writeFlags(writer, &.{ "commit", "-F", "-" }),
                .amend => try writeFlags(writer, &.{ "commit", "-F", "-", "--amend" }),
                .reword => try writeFlags(writer, &.{ "commit", "-F", "-", "--amend", "--only" }),
                .extend => try writeFlags(writer, &.{ "commit", "--amend", "--no-edit" }),
                .fixup => {
                    try writeFlags(writer, &.{"commit"});
                    try writer.writeByte(separator);
                    try writer.print("--fixup={s}", .{commit.target});
                },
            }
            try writeTransient(writer, commit.arguments);
        },
        .head_message => {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &.{ "log", "--no-show-signature", "-1", "--format=%B" });
        },
        .refs => {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &.{ "for-each-ref", refs_format, "refs/heads", "refs/remotes" });
        },
        .switch_to => |name| {
            try writePrefix(writer, .writes);
            try writeFlags(writer, &.{ "switch", "--end-of-options" });
            try writeArgument(writer, name);
        },
        .switch_track => |track| {
            try writePrefix(writer, .writes);
            try writeFlags(writer, &.{ "switch", "-c" });
            try writeArgument(writer, track.name);
            try writeFlags(writer, &.{ "--track", "--end-of-options" });
            try writeArgument(writer, track.remote_branch);
        },
        .create_branch => |branch| {
            try writePrefix(writer, .writes);
            switch (branch.after) {
                .switch_to => {
                    try writeFlags(writer, &.{ "switch", "-c" });
                    try writeArgument(writer, branch.name);
                    if (branch.start.len != 0) {
                        try writeFlags(writer, &.{"--end-of-options"});
                        try writeArgument(writer, branch.start);
                    }
                },
                .stay => {
                    try writeFlags(writer, &.{ "branch", "--end-of-options" });
                    try writeArgument(writer, branch.name);
                    if (branch.start.len != 0) try writeArgument(writer, branch.start);
                },
            }
        },
        .delete_branch => |branch| {
            try writePrefix(writer, .writes);
            const flag = switch (branch.how) {
                .merged => "-d",
                .force => "-D",
            };
            try writeFlags(writer, &.{ "branch", flag, "--end-of-options" });
            try writeArgument(writer, branch.name);
        },
        .rename_branch => |branch| {
            try writePrefix(writer, .writes);
            try writeFlags(writer, &.{ "branch", "-m", "--end-of-options" });
            try writeArgument(writer, branch.name);
            try writeArgument(writer, branch.new_name);
        },
        .merge => |merge| {
            try writePrefix(writer, .writes);
            try writeFlags(writer, &.{"merge"});
            try writeTransient(writer, merge.arguments);
            try writeFlags(writer, &.{"--end-of-options"});
            try writeArgument(writer, merge.revision);
        },
        .merge_abort => {
            try writePrefix(writer, .writes);
            try writeFlags(writer, &.{ "merge", "--abort" });
        },
        .rebase => |rebase| {
            try writeRebase(writer, &.{"-i"});
            try writeTransient(writer, rebase.arguments);
            if (rebase.base.len != 0) {
                try writeFlags(writer, &.{"--end-of-options"});
                try writeArgument(writer, rebase.base);
            }
        },
        .rebase_continue => try writeRebase(writer, &.{"--continue"}),
        .rebase_skip => try writeRebase(writer, &.{"--skip"}),
        .resolve => |revision| {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &.{ "rev-parse", "--verify", "--end-of-options" });
            try writer.writeByte(separator);
            try writer.print("{s}^{{commit}}", .{revision});
        },
        .rebase_abort => try writeRebase(writer, &.{"--abort"}),
        .rebase_check, .rebase_todo, .rebase_edit_todo => try writeRebase(writer, &.{"--edit-todo"}),
        .rebase_commits => |commits| {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &rebase_commits_options);
            try writer.writeByte(separator);
            try writer.print("{s}...{s}", .{ commits.base, commits.head });
        },
        .push => |push| {
            try writePrefix(writer, .writes);
            try writeFlags(writer, &.{"push"});
            try writeTransient(writer, push.arguments);
            if (push.remote.len != 0) {
                try writeFlags(writer, &.{"--end-of-options"});
                try writeArgument(writer, push.remote);
                // A refspec beginning with `+` is a forced push: such a branch is named whole.
                const forced_looking = std.mem.startsWith(u8, push.branch, "+");
                if (forced_looking) {
                    try writer.writeByte(separator);
                    try writer.print("refs/heads/{s}", .{push.branch});
                } else if (push.branch.len != 0) {
                    try writeArgument(writer, push.branch);
                }
            }
        },
        .pull => |arguments| {
            try writePrefix(writer, .writes);
            try writeFlags(writer, &.{"pull"});
            try writeTransient(writer, arguments);
        },
        .pull_from => |pull| {
            try writePrefix(writer, .writes);
            try writeFlags(writer, &.{"pull"});
            try writeTransient(writer, pull.arguments);
            try writeFlags(writer, &.{"--end-of-options"});
            try writeArgument(writer, pull.remote);
            try writeArgument(writer, pull.branch);
        },
        .fetch => |arguments| {
            try writePrefix(writer, .writes);
            try writeFlags(writer, &.{"fetch"});
            try writeTransient(writer, arguments);
        },
        .fetch_all => |arguments| {
            try writePrefix(writer, .writes);
            try writeFlags(writer, &.{"fetch"});
            try writeTransient(writer, arguments);
            try writeFlags(writer, &.{"--all"});
        },
        .remotes => {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &.{"remote"});
        },
        .show => |revision| {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &.{ "show", "--no-show-signature", "--no-ext-diff", "--no-color", "--stat", "--patch", "-m", "--first-parent", "--src-prefix=a/", "--dst-prefix=b/", "--date=short", show_format, "--end-of-options" });
            try writeArgument(writer, revision);
        },
        .operation => {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &.{ "log", "--no-show-signature", "--no-walk=unsorted", "--ignore-missing", "--source", "--format=%S%x1f%H", "--end-of-options" });
            try writeFlags(writer, &operation_refs);
        },
        .root => {
            try writePrefix(writer, .reads);
            try writeFlags(writer, &.{ "rev-parse", "--show-toplevel" });
        },
    }
}

/// Whether `writeArgv` takes `command`: every name, revision, hash and path a person or git gave
/// in it passes as one argument git does not read as an option. What a panel asks before it runs
/// a command with a name a person typed, to tell why it does not.
pub fn passes(command: Command) bool {
    checkCommand(command) catch return false;
    return true;
}

/// Checks every argument of `command` a person or git gave, before anything is written.
fn checkCommand(command: Command) error{UnpassableArgument}!void {
    switch (command) {
        .log => |query| {
            const count = vcs_query.count(query) catch return error.UnpassableArgument;
            if (count > max_query_arguments) return error.UnpassableArgument;
        },
        .commit => |commit| {
            if (commit.kind == .fixup) try checkName(commit.target);
        },
        .switch_to => |name| try checkName(name),
        .switch_track => |track| {
            try checkName(track.name);
            try checkName(track.remote_branch);
        },
        .resolve => |revision| try checkName(revision),
        .create_branch => |branch| {
            try checkName(branch.name);
            if (branch.start.len != 0) try checkName(branch.start);
        },
        .delete_branch => |branch| try checkName(branch.name),
        .rename_branch => |branch| {
            try checkName(branch.name);
            try checkName(branch.new_name);
        },
        .rebase_commits => |commits| {
            try checkName(commits.base);
            try checkName(commits.head);
        },
        .pull_from => |pull| {
            try checkName(pull.remote);
            try checkName(pull.branch);
        },
        .merge => |merge| try checkName(merge.revision),
        .rebase => |rebase| {
            if (rebase.base.len != 0) try checkName(rebase.base);
        },
        .push => |push| {
            if (push.branch.len != 0 and push.remote.len == 0) return error.UnpassableArgument;
            if (push.remote.len != 0) try checkName(push.remote);
            if (push.branch.len != 0) try checkName(push.branch);
        },
        .show => |revision| try checkName(revision),
        else => {},
    }
}

/// Writes the command line that removes the untracked `paths` from the working tree, as many
/// of them from the first as fit in one, at most `max_clean_paths` and `max_clean_bytes`, and
/// returns how many it took: the caller runs it and writes the next from the rest, one process
/// for each batch. git's `clean` takes no paths on its input. `clean -f` removes files and
/// leaves the untracked directories they empty. Input: empty. Fails as `writeArgv` does,
/// having written nothing for `UnpassableArgument`: a path it cannot pass among those it would
/// take, or a first path too long for a line of its own.
pub fn writeClean(writer: *std.Io.Writer, paths: []const []const u8) WriteError!usize {
    var line_bytes: usize = clean_prefix_bytes;
    var taken: usize = 0;
    while (taken < paths.len and taken < max_clean_paths) : (taken += 1) {
        const path = paths[taken];
        if (line_bytes + path.len + 1 > max_clean_bytes) break;
        try checkPositional(path);
        line_bytes += path.len + 1;
    }
    if (taken == 0 and paths.len != 0) return error.UnpassableArgument;
    try writer.writeAll(clean_prefix[0]);
    try writeFlags(writer, clean_prefix[1..]);
    for (paths[0..taken]) |path| try writeArgument(writer, path);
    return taken;
}

/// Writes `paths` for a command's input, each followed by a NUL, as `stage`, `unstage`,
/// `unstage_unborn` and `discard` read them. Fails as `writer` does, or with
/// `UnpassableArgument`, having written nothing, for an empty path or one holding a NUL.
pub fn writePaths(writer: *std.Io.Writer, paths: []const []const u8) WriteError!void {
    for (paths) |path| {
        if (path.len == 0) return error.UnpassableArgument;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.UnpassableArgument;
    }
    for (paths) |path| {
        try writer.writeAll(path);
        try writer.writeByte(0);
    }
}

/// What the sequence editor of a job's environment does with the todo list git hands it
/// (`writeEnvironment`).
pub const SequenceEditor = enum {
    /// Writes the job's input over it, leaving it as git wrote it when the input is empty:
    /// `--stdin-to-file`. Every command's but one.
    write_input,
    /// Prints it, leaving it as it was: `--file-to-stdout`, for `Command.rebase_todo` alone.
    print_file,
};

/// The sequence editor `command` runs with.
pub fn sequenceEditorOf(command: Command) SequenceEditor {
    return switch (command) {
        .rebase_todo => .print_file,
        else => .write_input,
    };
}

/// Writes the variables every git command runs with, for a `runner.Job`'s `environment`:
/// `GIT_TERMINAL_PROMPT=0`, so git fails rather than asks for a password nobody can type, and
/// `GIT_EDITOR` and `GIT_SEQUENCE_EDITOR`, the host at `executable` as git's editors: the
/// message editor `executable --stdin-to-file`, which writes the job's input over the file git
/// hands it and leaves the file as git wrote it when the input is empty, so a command given no
/// input keeps git's own message; the sequence editor that too, or, as `sequence` says,
/// `executable --file-to-stdout`, which prints the file and leaves it. `executable` is the
/// host's path, `os_places.executable`: absolute and `/`-separated. git hands an editor's value
/// to a shell (its own `sh` on Windows), so the path is written in double quotes, and `"`, `\`,
/// `$` and a backquote in it are escaped with a backslash. Nothing here keeps ssh from asking:
/// see `Command.push`. Fails as `writer` does, or with `UnpassableArgument` for an empty path
/// or one holding a NUL or the separator.
pub fn writeEnvironment(writer: *std.Io.Writer, executable: []const u8, sequence: SequenceEditor) WriteError!void {
    try checkPositional(executable);
    try writer.writeAll("GIT_TERMINAL_PROMPT=0");
    const sequence_flag = switch (sequence) {
        .write_input => "--stdin-to-file",
        .print_file => "--file-to-stdout",
    };
    const editors = [_]struct { variable: []const u8, flag: []const u8 }{
        .{ .variable = "GIT_EDITOR", .flag = "--stdin-to-file" },
        .{ .variable = "GIT_SEQUENCE_EDITOR", .flag = sequence_flag },
    };
    for (editors) |editor| {
        try writer.writeByte(separator);
        try writer.print("{s}=\"", .{editor.variable});
        for (executable) |byte| {
            const escaped = byte == '"' or byte == '\\' or byte == '$' or byte == '`';
            if (escaped) try writer.writeByte('\\');
            try writer.writeByte(byte);
        }
        try writer.print("\" {s}", .{editor.flag});
    }
}

/// Whether git takes `name` as a branch's name: not empty, no `-` or `/` first, no space, `~`,
/// `^`, `:`, `?`, `*`, `[`, `\` or control character, no `..`, `//` or `@{`, no `.` or `/`
/// last, nor `@` alone, and no `/`-separated part that begins with `.` or ends with `.lock`. A
/// panel asks before it runs a command with a name a person typed, and refuses with a sentence;
/// git checks again.
pub fn isRefName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '-' or name[0] == '/') return false;
    if (std.mem.eql(u8, name, "@")) return false;
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
        if (std.mem.indexOfScalar(u8, " ~^:?*[\\", byte) != null) return false;
    }
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOf(u8, name, "@{") != null) return false;
    if (std.mem.indexOf(u8, name, "//") != null) return false;
    if (std.mem.endsWith(u8, name, "/")) return false;
    if (std.mem.endsWith(u8, name, ".")) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, ".")) return false;
        if (std.mem.endsWith(u8, part, ".lock")) return false;
    }
    return true;
}

/// Writes the beginning of every `rebase` command line, the one place it is written: git's
/// prefix, `-c rebase.missingCommitsCheck=error`, `rebase` and `flags`. With the check git refuses
/// (exit 1) to start, go on with, skip in, or even show, a todo list that lacks a commit it
/// listed, and keeps its record of the commits left out; without it, any `rebase --edit-todo`
/// whose editor changes nothing (the `r e` read, `rebase_check`) would forget that record and a
/// later `--continue` would run the short list. `--abort` carries it too, where it changes
/// nothing.
fn writeRebase(writer: *std.Io.Writer, flags: []const []const u8) std.Io.Writer.Error!void {
    try writePrefix(writer, .writes);
    try writeFlags(writer, &missing_commits_check);
    try writeFlags(writer, &.{"rebase"});
    try writeFlags(writer, flags);
}

fn writePrefix(writer: *std.Io.Writer, access: Access) std.Io.Writer.Error!void {
    try writer.writeAll(program);
    switch (access) {
        .reads => try writeFlags(writer, &.{"--no-optional-locks"}),
        .writes => {},
        .writes_paths => try writeFlags(writer, &.{"--literal-pathspecs"}),
    }
    try writeFlags(writer, &.{ "-c", "core.quotepath=false", "-c", "color.ui=false" });
}

/// Writes arguments this file spells, each after a separator.
fn writeFlags(writer: *std.Io.Writer, flags: []const []const u8) std.Io.Writer.Error!void {
    for (flags) |flag| {
        try writer.writeByte(separator);
        try writer.writeAll(flag);
    }
}

/// Writes a transient's arguments, each followed by the separator as
/// `ui.transient.writeArguments` wrote them, each after a separator instead.
fn writeTransient(writer: *std.Io.Writer, arguments: []const u8) std.Io.Writer.Error!void {
    if (arguments.len == 0) return;
    const ends_with_separator = arguments[arguments.len - 1] == separator;
    const kept = if (ends_with_separator) arguments[0 .. arguments.len - 1] else arguments;
    if (kept.len == 0) return;
    try writer.writeByte(separator);
    try writer.writeAll(kept);
}

/// Whether `arguments`, a transient's as `ui.transient.writeArguments` wrote them (each followed
/// by the separator), hold `argument` itself.
pub fn hasArgument(arguments: []const u8, argument: []const u8) bool {
    var each = std.mem.tokenizeScalar(u8, arguments, separator);
    while (each.next()) |one| {
        if (std.mem.eql(u8, one, argument)) return true;
    }
    return false;
}

/// Writes a name, revision or path a person or git gave, checked already (`checkCommand`),
/// after a separator, as one argument.
fn writeArgument(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte(separator);
    try writer.writeAll(text);
}

/// Whether `text` can be passed in an argument: it holds no NUL and no separator.
pub fn isPassable(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, 0) == null and std.mem.indexOfScalar(u8, text, separator) == null;
}

/// Whether `arguments`, a query's as `query.write` wrote them (each after a separator), ask
/// `git log` to write its output to a file: `--output` or `--output=…`, or a prefix of it git
/// would take for it (`--outp`), before a `--` (after one, every argument is a path). A log
/// viewer reads; it writes nothing. `--ext-diff` and `--textconv` are passed: they run only what
/// the person's own git configuration names.
pub fn writesFile(arguments: []const u8) bool {
    var each = std.mem.tokenizeScalar(u8, arguments, separator);
    while (each.next()) |argument| {
        if (std.mem.eql(u8, argument, "--")) return false;
        const name_end = std.mem.indexOfScalar(u8, argument, '=') orelse argument.len;
        const name = argument[0..name_end];
        if (name.len >= "--ou".len and std.mem.startsWith(u8, "--output", name)) return true;
    }
    return false;
}

/// A path or other text passes as one argument: not empty, no NUL, no separator.
fn checkPositional(text: []const u8) error{UnpassableArgument}!void {
    if (text.len == 0) return error.UnpassableArgument;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.UnpassableArgument;
    if (std.mem.indexOfScalar(u8, text, separator) != null) return error.UnpassableArgument;
}

/// A branch, remote, revision or hash passes as one argument git does not read as an option.
fn checkName(name: []const u8) error{UnpassableArgument}!void {
    try checkPositional(name);
    if (name[0] == '-') return error.UnpassableArgument;
}

// ---- what goes on the input --------------------------------------------------------------------

/// What `rebaseList` does with a commit.
pub const RebaseAction = enum {
    /// Keeps it.
    pick,
    /// Keeps it, and the rebase stops after it (a `break`) for the person to amend its message
    /// and continue: git's own message editor is never a window here.
    reword,
    /// Keeps it, and the rebase stops on it for the person to change it.
    edit,
    /// Folds it into the commit before, the two messages joined.
    squash,
    /// Folds it into the commit before, keeping that one's message.
    fixup,
    /// Leaves it out.
    drop,
    /// A line of git's own todo list that is none of these (`break`, `exec`, `label`, `reset`,
    /// `merge`, `update-ref`, `fixup -C`): written back as it is, its whole text the entry's
    /// `subject`.
    kept,

    /// The word a list writes for it, and a person reads; empty for `kept`, whose line says it.
    pub fn word(action: RebaseAction) []const u8 {
        return switch (action) {
            .kept => "",
            else => @tagName(action),
        };
    }

    /// The action a todo line's first word names, in full or as git's one letter; null for
    /// another word.
    pub fn ofWord(text: []const u8) ?RebaseAction {
        const known = [_]struct { long: []const u8, short: []const u8, action: RebaseAction }{
            .{ .long = "pick", .short = "p", .action = .pick },
            .{ .long = "reword", .short = "r", .action = .reword },
            .{ .long = "edit", .short = "e", .action = .edit },
            .{ .long = "squash", .short = "s", .action = .squash },
            .{ .long = "fixup", .short = "f", .action = .fixup },
            .{ .long = "drop", .short = "d", .action = .drop },
        };
        for (known) |entry| {
            if (std.mem.eql(u8, text, entry.long) or std.mem.eql(u8, text, entry.short)) return entry.action;
        }
        return null;
    }
};

/// One line of a rebase's list, oldest first.
pub const RebaseEntry = struct {
    /// What is done with it.
    action: RebaseAction,
    /// The commit's hash, full or short; empty for `kept`.
    hash: []const u8,
    /// Its subject, which git ignores and a person reads in the log; for `kept`, the whole line.
    subject: []const u8,
};

/// Writes the list `Command.rebase` and `Command.rebase_edit_todo` take on their input:
/// `<action> <hash> <subject>` a line, oldest first; a `reword` as `pick` and a line `break`;
/// a `kept` line as it is. A subject is cut at its first line break. Fails as `writer` does,
/// or with `UnpassableArgument`, having written nothing, for a commit's hash that is empty or
/// holds a space or line break, or a kept line that is empty or holds a line break.
pub fn rebaseList(writer: *std.Io.Writer, entries: []const RebaseEntry) WriteError!void {
    for (entries) |entry| {
        if (entry.action == .kept) {
            if (entry.subject.len == 0) return error.UnpassableArgument;
            if (std.mem.indexOfAny(u8, entry.subject, "\r\n") != null) return error.UnpassableArgument;
            continue;
        }
        if (entry.hash.len == 0) return error.UnpassableArgument;
        if (std.mem.indexOfAny(u8, entry.hash, " \t\r\n") != null) return error.UnpassableArgument;
    }
    for (entries) |entry| {
        if (entry.action == .kept) {
            try writer.print("{s}\n", .{entry.subject});
            continue;
        }
        const action = switch (entry.action) {
            .pick, .reword => "pick",
            .edit, .squash, .fixup, .drop => entry.action.word(),
            .kept => unreachable,
        };
        const subject_end = std.mem.indexOfAny(u8, entry.subject, "\r\n") orelse entry.subject.len;
        const subject = entry.subject[0..subject_end];
        try writer.print("{s} {s} {s}\n", .{ action, entry.hash, subject });
        if (entry.action == .reword) try writer.writeAll("break\n");
    }
}

// ---- what git says -----------------------------------------------------------------------------

/// How many records a parser found, and how many of them fit in the slice it was given: the
/// first `kept`.
pub const Counted = struct {
    /// Records found in the bytes.
    seen: u32 = 0,
    /// Records written to the slice: the first `kept` of those found.
    kept: u32 = 0,
};

/// What a file of a `status` is.
pub const EntryKind = enum {
    /// Tracked, and changed in the index or the working tree.
    changed,
    /// Renamed in the index (`staged` is `R`): `original_path` is where it was. `Command.status`
    /// asks git for renames and not copies, so a `2` record is always a rename; a `C` read from
    /// another status's output is kept as it is.
    ///
    /// The staged diff (`Command.diff`, which detects no renames) shows it under both paths: the
    /// new as an added file, the original as a deleted one, whose hunks are staged and unstaged
    /// as any other. Unstaging it whole takes both paths (`Command.unstage`).
    renamed,
    /// In a merge's conflict: `staged` and `unstaged` together say how (`UU` both changed it,
    /// `AA` both added it, `DU` deleted by us, ...).
    unmerged,
    /// Not tracked.
    untracked,
    /// Ignored; listed only when asked for, which `Command.status` does not.
    ignored,
};

/// Whether a status entry is a submodule, which the panel shows and does not act on.
pub const Submodule = enum { not_submodule, submodule };

/// A file of a `status`.
pub const Entry = struct {
    /// What the file is: changed, renamed, unmerged, untracked or ignored.
    kind: EntryKind,
    /// The index's letter against `HEAD`: `.` unchanged, `M`, `T`, `A`, `D`, `R`, `C`; for an
    /// unmerged entry the first of its pair; `?` or `!` for an untracked or ignored one.
    staged: u8,
    /// The working tree's letter against the index, as `staged`.
    unstaged: u8,
    /// The path from the repository's root, `/`-separated, as git keeps it: not quoted, not
    /// necessarily UTF-8. A slice of the bytes parsed.
    path: []const u8,
    /// For `renamed`, the path it had; empty otherwise. A slice of the bytes parsed.
    original_path: []const u8 = "",
    /// Whether it is a submodule.
    submodule: Submodule = .not_submodule,
};

/// Whether `HEAD` is on a branch.
pub const Head = enum { branch, detached };

/// What the branch's upstream is.
pub const Upstream = enum {
    /// The branch has none.
    none,
    /// It has one, which exists: `ahead` and `behind` count against it.
    tracking,
    /// It names one that no longer exists (deleted on the remote and pruned): `ahead` and
    /// `behind` are 0 and mean nothing.
    gone,
};

/// What `status` said of the repository: its header and the counts of its entries, which
/// `parseStatus` writes. Its slices are of the bytes parsed.
pub const Status = struct {
    /// Whether `HEAD` is on a branch or detached (in a rebase, a bisection, or checked out at a
    /// commit).
    head: Head = .branch,
    /// The branch `HEAD` is on, also before its first commit; empty when detached.
    branch: []const u8 = "",
    /// The commit `HEAD` is at; empty before the first commit (`hasCommit`).
    oid: []const u8 = "",
    /// The branch's upstream (`origin/main`); empty when it has none.
    upstream: []const u8 = "",
    /// Whether the upstream exists: git names a gone one but gives no counts for it.
    upstream_state: Upstream = .none,
    /// Commits the branch has that its upstream does not.
    ahead: u32 = 0,
    /// Commits the upstream has that the branch does not.
    behind: u32 = 0,
    /// How many stashes there are.
    stash_count: u32 = 0,
    /// The entries found, and how many fit in the slice given.
    entries: Counted = .{},
    /// Entries with a change in the index: a `staged` letter other than `.`, unmerged ones
    /// apart.
    staged_count: u32 = 0,
    /// Entries with a change in the working tree, unmerged ones apart.
    unstaged_count: u32 = 0,
    /// Entries not tracked.
    untracked_count: u32 = 0,
    /// Entries in conflict: a merge, rebase, cherry-pick or revert stopped on them.
    unmerged_count: u32 = 0,

    /// Whether `HEAD` has a commit: false in a repository with none yet, where `unstage` fails
    /// and `unstage_unborn` is run instead.
    pub fn hasCommit(status: *const Status) bool {
        return status.oid.len != 0;
    }
};

/// Reads what `Command.status` said: its `# ` headers into the result, and its entries, in the
/// order git gave them, into `entries`, as many as fit. A record it does not know is passed
/// over.
pub fn parseStatus(bytes: []const u8, entries: []Entry) Status {
    var status: Status = .{};
    var records = std.mem.splitScalar(u8, bytes, 0);
    while (records.next()) |record| {
        if (std.mem.startsWith(u8, record, "# ")) {
            readStatusHeader(&status, record[2..]);
            continue;
        }
        var entry = parseEntry(record) orelse continue;
        // A rename's or copy's original path is the field after its record.
        if (entry.kind == .renamed) entry.original_path = records.next() orelse "";
        switch (entry.kind) {
            .changed, .renamed => {
                if (entry.staged != '.') status.staged_count += 1;
                if (entry.unstaged != '.') status.unstaged_count += 1;
            },
            .unmerged => status.unmerged_count += 1,
            .untracked => status.untracked_count += 1,
            .ignored => {},
        }
        if (status.entries.kept < entries.len) {
            entries[status.entries.kept] = entry;
            status.entries.kept += 1;
        }
        status.entries.seen += 1;
    }
    return status;
}

fn readStatusHeader(status: *Status, header: []const u8) void {
    const space = std.mem.indexOfScalar(u8, header, ' ') orelse return;
    const key = header[0..space];
    const value = header[space + 1 ..];
    if (std.mem.eql(u8, key, "branch.oid")) {
        const initial = std.mem.eql(u8, value, "(initial)");
        status.oid = if (initial) "" else value;
    } else if (std.mem.eql(u8, key, "branch.head")) {
        const detached = std.mem.eql(u8, value, "(detached)");
        status.head = if (detached) .detached else .branch;
        status.branch = if (detached) "" else value;
    } else if (std.mem.eql(u8, key, "branch.upstream")) {
        status.upstream = value;
        // `# branch.ab` follows only when the upstream exists.
        status.upstream_state = .gone;
    } else if (std.mem.eql(u8, key, "branch.ab")) {
        // `+<ahead> -<behind>`.
        var counts = std.mem.splitScalar(u8, value, ' ');
        const ahead = counts.next() orelse return;
        const behind = counts.next() orelse return;
        status.upstream_state = .tracking;
        status.ahead = parseCount(std.mem.trimStart(u8, ahead, "+"));
        status.behind = parseCount(std.mem.trimStart(u8, behind, "-"));
    } else if (std.mem.eql(u8, key, "stash")) {
        status.stash_count = parseCount(value);
    }
}

/// A status record: `1 XY sub mH mI mW hH hI path`, `2 XY sub mH mI mW hH hI Xscore path`,
/// `u XY sub m1 m2 m3 mW h1 h2 h3 path`, `? path` or `! path`. The path is the rest of the
/// record after its fields, spaces and all.
fn parseEntry(record: []const u8) ?Entry {
    if (record.len < 3 or record[1] != ' ') return null;
    switch (record[0]) {
        '?', '!' => {
            const letter = record[0];
            const kind: EntryKind = if (letter == '?') .untracked else .ignored;
            return .{ .kind = kind, .staged = letter, .unstaged = letter, .path = record[2..] };
        },
        '1', '2', 'u' => {},
        else => return null,
    }
    const kind: EntryKind = switch (record[0]) {
        '1' => .changed,
        '2' => .renamed,
        else => .unmerged,
    };
    const field_count: usize = switch (kind) {
        .changed => 8,
        .renamed => 9,
        else => 10,
    };
    const path = afterFields(record, field_count) orelse return null;
    if (record.len < 9) return null;
    const submodule: Submodule = if (record[5] == 'S') .submodule else .not_submodule;
    return .{ .kind = kind, .staged = record[2], .unstaged = record[3], .path = path, .submodule = submodule };
}

/// What follows the first `count` space-separated fields of `record`; null when it has fewer.
fn afterFields(record: []const u8, count: usize) ?[]const u8 {
    var position: usize = 0;
    var passed: usize = 0;
    while (passed < count) : (passed += 1) {
        const space = std.mem.indexOfScalarPos(u8, record, position, ' ') orelse return null;
        position = space + 1;
    }
    return record[position..];
}

/// A decimal count; 0 when `text` is not one.
fn parseCount(text: []const u8) u32 {
    return std.fmt.parseInt(u32, text, 10) catch 0;
}

/// A commit of a log.
pub const LogEntry = struct {
    /// The full hash.
    hash: []const u8,
    /// The hash as short as git keeps it unambiguous.
    short_hash: []const u8,
    /// The author's name.
    author: []const u8,
    /// `YYYY-MM-DD`.
    date: []const u8,
    /// The refs that point at it as git decorates them (`HEAD -> main, origin/main, tag: v1`);
    /// empty for none.
    refs: []const u8,
    /// The message's first paragraph, its lines joined by spaces.
    subject: []const u8,
};

/// What `parseLog` read: the commits, and the records it could not read as commits.
pub const Parsed = struct {
    /// The records read as commits, and how many of them fit in the slice given.
    commits: Counted = .{},
    /// The records that are no commit of `log_format`'s: an output of another shape (a query's
    /// `--oneline`, `--stat`, `-p` or `--graph`), or a record cut short.
    unread: u32 = 0,
    /// The first of them, a slice of the bytes, cut at a character boundary to at most
    /// `unread_sample_bytes`, as a person is shown it (`ui.displayText` makes it readable);
    /// empty when every record was read.
    first_unread: []const u8 = "",
};

/// How much of the first record `parseLog` could not read it keeps, in bytes.
pub const unread_sample_bytes = 60;
/// The most bytes of an author's name, a commit's refs, its date or its subject `parseLog` keeps,
/// cut at a character boundary: past it is no line a person reads whole, and the table holding
/// the log keeps each cell's bytes.
pub const max_log_field_bytes = 1024;

/// Reads what `Command.recent` or `Command.log` said, records ended by NULs, into `into`, newest
/// first, as many as fit; reports what it could not read, never failing on it. A record is a
/// commit when it has the six fields of `log_format` (the subject is the rest, so a 0x1f in it is
/// kept), its hash is 40 or 64 hex digits, its short hash 4 or more of them that begin the hash,
/// and no field holds a line break (`%s` never does: one that does holds what an option of the
/// query added, a patch or a stat). Anything else, a record cut short at the end of the bytes
/// among it, is counted unread. An empty record, or one of spaces and line breaks alone, is
/// nothing. The
/// author, the date, the refs and the subject are cut to `max_log_field_bytes`; the hashes are
/// whole, as they were checked. Every field is a slice of `bytes`. Reads each byte once.
pub fn parseLog(bytes: []const u8, into: []LogEntry) Parsed {
    var parsed: Parsed = .{};
    var records = std.mem.splitScalar(u8, bytes, 0);
    while (records.next()) |record| {
        const trimmed = std.mem.trim(u8, record, " \t\r\n");
        if (trimmed.len == 0) continue;
        const entry = logEntryOf(record) orelse {
            if (parsed.unread == 0) parsed.first_unread = trimmed[0..utf8Prefix(trimmed, unread_sample_bytes)];
            parsed.unread += 1;
            continue;
        };
        if (parsed.commits.kept < into.len) {
            into[parsed.commits.kept] = entry;
            parsed.commits.kept += 1;
        }
        parsed.commits.seen += 1;
    }
    return parsed;
}

/// `record` read as a commit of `log_format`; null when it is not one (`parseLog`).
fn logEntryOf(record: []const u8) ?LogEntry {
    if (std.mem.indexOfAny(u8, record, "\r\n") != null) return null;
    var fields = std.mem.splitScalar(u8, record, 0x1f);
    const hash = fields.next() orelse return null;
    const short_hash = fields.next() orelse return null;
    const author = fields.next() orelse return null;
    const date = fields.next() orelse return null;
    const refs = fields.next() orelse return null;
    if (fields.index == null) return null;
    const subject = fields.rest();
    if (hash.len != 40 and hash.len != 64) return null;
    if (!isHex(hash)) return null;
    if (short_hash.len < 4 or !std.mem.startsWith(u8, hash, short_hash)) return null;
    return .{
        .hash = hash,
        .short_hash = short_hash,
        .author = author[0..utf8Prefix(author, max_log_field_bytes)],
        .date = date[0..utf8Prefix(date, max_log_field_bytes)],
        .refs = refs[0..utf8Prefix(refs, max_log_field_bytes)],
        .subject = subject[0..utf8Prefix(subject, max_log_field_bytes)],
    };
}

fn isHex(text: []const u8) bool {
    for (text) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

/// How many bytes of `text` fit in `limit` without cutting a UTF-8 character: all of it when it
/// fits, else up to the last character boundary at or before `limit`.
fn utf8Prefix(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var cut = limit;
    while (cut > 0 and text[cut] & 0xc0 == 0x80) cut -= 1;
    return cut;
}

/// Whether a ref is a local branch or a remote's.
pub const RefKind = enum { local, remote };

/// A branch `Command.refs` listed.
pub const Ref = struct {
    /// The full name: `refs/heads/main`, `refs/remotes/origin/main`.
    name: []const u8,
    /// The name a person reads and passes back to git: `main`, `origin/main`.
    short_name: []const u8,
    /// A local branch's upstream (`origin/main`); empty when it has none, and for a remote's.
    upstream: []const u8,
    /// Whether it is a local branch or a remote's.
    kind: RefKind,
    /// Whether `HEAD` is on it.
    current: bool,
    /// The commit it is at, a full hash; empty from an answer without it.
    hash: []const u8 = "",
    /// The worktree a local branch is checked out in, this one's too, absolute; empty for none.
    worktree: []const u8 = "",
};

/// Reads what `Command.refs` said into `into`, local branches first and each kind by name, as
/// many as fit. A remote's `HEAD` (`refs/remotes/origin/HEAD`), which names another of its
/// branches, is passed over.
pub fn parseRefs(bytes: []const u8, into: []Ref) Counted {
    var counted: Counted = .{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, 0x1f);
        const name = fields.next() orelse continue;
        const short_name = fields.next() orelse continue;
        const upstream = fields.next() orelse continue;
        const head_mark = fields.next() orelse continue;
        const hash = fields.next() orelse "";
        const worktree = fields.next() orelse "";
        const kind: RefKind = if (std.mem.startsWith(u8, name, "refs/remotes/")) .remote else .local;
        const remote_head = kind == .remote and std.mem.endsWith(u8, name, "/HEAD");
        if (remote_head) continue;
        const ref: Ref = .{ .name = name, .short_name = short_name, .upstream = upstream, .kind = kind, .current = std.mem.eql(u8, head_mark, "*"), .hash = hash, .worktree = worktree };
        if (counted.kept < into.len) {
            into[counted.kept] = ref;
            counted.kept += 1;
        }
        counted.seen += 1;
    }
    return counted;
}

/// Reads what `Command.remotes` said, a remote's name a line, into `into`, as many as fit, in
/// the order git gave them (by name). Slices of `bytes`.
pub fn parseRemotes(bytes: []const u8, into: [][]const u8) Counted {
    var counted: Counted = .{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const name = std.mem.trimEnd(u8, line, "\r");
        if (name.len == 0) continue;
        if (counted.kept < into.len) {
            into[counted.kept] = name;
            counted.kept += 1;
        }
        counted.seen += 1;
    }
    return counted;
}

/// Reads what `Command.rebase_todo` said, the rest of a rebase's todo list as git hands it to
/// its sequence editor, into `into`, as many lines as fit, in order: a line of one of
/// `RebaseAction`'s commands, in full or as one letter, with its hash and its subject; any other
/// line that is no comment and not blank as `kept`, whole, so writing the entries back
/// (`rebaseList`) gives git its own lines again. A `fixup -C` or `-c` is kept too. A comment
/// begins with git's comment string (`core.commentChar`, `#` unless set), read from the help git
/// ends the list with, whose last line is that string alone. Slices of `bytes`.
pub fn parseTodo(bytes: []const u8, into: []RebaseEntry) Counted {
    var counted: Counted = .{};
    const comment = commentStringOf(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, comment)) continue;
        const entry = todoEntryOf(line);
        if (counted.kept < into.len) {
            into[counted.kept] = entry;
            counted.kept += 1;
        }
        counted.seen += 1;
    }
    return counted;
}

/// git's comment string in a todo list it printed: its last line that is not blank, the help's
/// last, which is that string alone; `#` for a list with no help, or a last line too long or
/// beginning as a command does.
fn commentStringOf(bytes: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, bytes, " \t\r\n");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |newline| newline + 1 else 0;
    const last = std.mem.trim(u8, trimmed[start..], " \t\r");
    const plausible = last.len != 0 and last.len <= 8 and !std.ascii.isAlphanumeric(last[0]);
    return if (plausible) last else "#";
}

/// A line of a todo list, not blank and no comment, as a `RebaseEntry`.
fn todoEntryOf(line: []const u8) RebaseEntry {
    const kept: RebaseEntry = .{ .action = .kept, .hash = "", .subject = line };
    const word_end = std.mem.indexOfAny(u8, line, " \t") orelse return kept;
    const action = RebaseAction.ofWord(line[0..word_end]) orelse return kept;
    const rest = std.mem.trimStart(u8, line[word_end..], " \t");
    const hash_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    const hash = rest[0..hash_end];
    // `fixup -C <commit>` names the message to keep: a form the list does not edit.
    if (hash.len == 0 or hash[0] == '-') return kept;
    const subject = std.mem.trimStart(u8, rest[hash_end..], " \t");
    return .{ .action = action, .hash = hash, .subject = subject };
}

/// Reads what `Command.head_message` said: the message, without the line breaks git adds after
/// it. A slice of `bytes`.
pub fn parseMessage(bytes: []const u8) []const u8 {
    return std.mem.trimEnd(u8, bytes, "\n");
}

/// Reads what `Command.root` said: the repository's root, absolute and `/`-separated on every
/// platform (`C:/work/repo` on Windows), without the line break git ends it with. A slice of
/// `bytes`; empty when git said nothing.
pub fn parseRoot(bytes: []const u8) []const u8 {
    return std.mem.trimEnd(u8, bytes, "\r\n");
}

/// An operation git is in the middle of, which waits for the person to go on or give up.
pub const Operation = enum { none, merging, rebasing, cherry_picking, reverting, bisecting };

/// What `Command.operation` said. git's porcelain status does not tell it, and a plugin reads
/// no file, so it takes its own process. A panel asks it in the same refresh as the status:
///
/// - when the panel opens;
/// - while its last answer was not `none`, until one is: a merge, cherry-pick or revert whose
///   conflicts are resolved and staged shows no unmerged entry and leaves `HEAD` on its branch,
///   yet is still in progress;
/// - when the status shows unmerged entries (`Status.unmerged_count`) or `HEAD` detached (any
///   stopped rebase or bisection);
/// - after each of its own merge, rebase, pull, cherry-pick or commit commands ends.
///
/// A refresh of a repository on a branch with no operation, after the first, costs no process
/// for it. One checked out at a detached commit with no operation costs two on every refresh,
/// `operation` and `Command.rebase_check` (below), unless the panel asks `rebase_check` once
/// for each detached commit: when `Status.oid` is the one it last had `none` for, it does not
/// ask again. An operation another program starts while the panel shows a clean branch with no
/// conflict (`merge --no-commit` in a terminal) is seen at the next of these.
///
/// In a repository whose refs are kept in a reftable, a rebase's `rebase-merge/onto` does not
/// resolve as a ref, so `operation` reads `none` at any stop of a rebase there, with `HEAD`
/// detached. Whenever `operation` reads `none` with `HEAD` detached the panel asks
/// `Command.rebase_check` too, one more process, and takes `rebaseCheckAnswer` of its exit
/// code: in a reftable repository it says rebasing, with no kind of stop, and the panel shows
/// the generic line of a rebase in progress.
pub const InProgress = struct {
    /// When several are, the first of rebasing, cherry-picking, reverting, merging and
    /// bisecting: a rebase may stop on a commit it cherry-picks.
    operation: Operation = .none,
    /// The commit it stopped on or brings in: `REBASE_HEAD` for a rebase stopped on a commit
    /// (the commit it is onto at a `break`), `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, or
    /// the commit a bisection has checked out; empty for `none`. A slice of the bytes parsed.
    commit: []const u8 = "",
    /// Where a rebase is stopped; `none` for any other operation.
    stop: RebaseStop = .none,
    /// At an `edit` stop, `HEAD` as the rebase stopped there (`rebase-merge/amend`): a commit
    /// made since leaves `HEAD` elsewhere, and `--continue` then amends nothing. Empty otherwise.
    /// A slice of the bytes parsed.
    amend: []const u8 = "",
};

/// Where a rebase in progress is stopped, as its refs tell.
pub const RebaseStop = enum {
    /// Not told: no rebase, or one `Command.rebase_check` found, which says no more.
    none,
    /// On a commit marked `edit` (`rebase-merge/amend`, which git writes for an `edit` alone,
    /// holding `HEAD` as it stopped: `REBASE_HEAD` is the commit as it was, another hash once
    /// it was replayed onto a new parent).
    on_commit,
    /// On a commit whose change conflicted (`REBASE_HEAD` and no `rebase-merge/amend`), the
    /// conflict perhaps resolved since: `HEAD` is the commit before it, and `--continue`
    /// commits it.
    on_conflict,
    /// Between commits, on none (no `REBASE_HEAD`): at a `break`, which is how a `reword` of
    /// `rebaseList`'s stops, after its commit.
    between_commits,
};

/// Reads what `Command.operation` said: a line `<ref>\x1f<hash>` for each of its refs that
/// exists, none when no operation is in progress. A rebase is in progress when an `onto` line is
/// there (`rebase-merge/onto` or `rebase-apply/onto`, there for the whole of a rebase): a
/// `REBASE_HEAD` alone is one git left behind after a rebase whose last step stopped on a commit
/// was continued to its end, and is no rebase. Where those files do not resolve as refs (a
/// repository whose refs are kept in a reftable), any stop of a rebase reads as `none`, and
/// `Command.rebase_check` is what tells a rebase (see `InProgress`).
/// `git am` stopped on a patch it could not apply, or on a conflict, is not told: it writes none
/// of these refs (its `rebase-apply/` has no `onto`), so it reads as `none`, and
/// `Command.rebase_check` exits 128 there too. A conflict it stopped on shows as unmerged
/// entries on a branch.
pub fn parseInProgress(bytes: []const u8) InProgress {
    var found: std.EnumArray(Operation, []const u8) = .initFill("");
    var rebase_onto: []const u8 = "";
    var amend: []const u8 = "";
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const split = std.mem.indexOfScalar(u8, line, 0x1f) orelse continue;
        const name = line[0..split];
        const hash = line[split + 1 ..];
        if (std.mem.eql(u8, name, "MERGE_HEAD")) {
            found.set(.merging, hash);
        } else if (std.mem.eql(u8, name, "REBASE_HEAD")) {
            found.set(.rebasing, hash);
        } else if (std.mem.eql(u8, name, "CHERRY_PICK_HEAD")) {
            found.set(.cherry_picking, hash);
        } else if (std.mem.eql(u8, name, "REVERT_HEAD")) {
            found.set(.reverting, hash);
        } else if (std.mem.eql(u8, name, "BISECT_EXPECTED_REV")) {
            found.set(.bisecting, hash);
        } else if (std.mem.endsWith(u8, name, "/onto")) {
            rebase_onto = hash;
        } else if (std.mem.eql(u8, name, "rebase-merge/amend")) {
            amend = hash;
        }
    }
    // A rebase is in progress only while its `onto` is there: git leaves `REBASE_HEAD` behind
    // once a rebase whose last step stopped on a commit is continued to its end.
    if (rebase_onto.len == 0) {
        found.set(.rebasing, "");
        amend = "";
    }
    // At an `edit` in place REBASE_HEAD is the commit amend names, printed once, under amend.
    if (amend.len != 0 and found.get(.rebasing).len == 0) found.set(.rebasing, amend);
    const on_commit = found.get(.rebasing).len != 0;
    if (!on_commit) found.set(.rebasing, rebase_onto);
    const order = [_]Operation{ .rebasing, .cherry_picking, .reverting, .merging, .bisecting };
    for (order) |operation| {
        const commit = found.get(operation);
        if (commit.len == 0) continue;
        const stop: RebaseStop = if (operation != .rebasing)
            .none
        else if (amend.len != 0)
            .on_commit
        else if (on_commit)
            .on_conflict
        else
            .between_commits;
        const amended = if (operation == .rebasing) amend else "";
        return .{ .operation = operation, .commit = commit, .stop = stop, .amend = amended };
    }
    return .{};
}

/// What `Command.rebase_check` answered.
pub const RebaseCheck = enum {
    /// An interactive rebase is in progress, stopped anywhere, a `break` included: exit 0.
    rebasing,
    /// None is: exit 128, git's "no rebase in progress", which it says before anything else.
    /// git answers the same during a rebase with `--apply`, which `Command.operation` tells by its
    /// `rebase-apply/onto`, and during `git am`.
    not_rebasing,
    /// Any other positive code: git found a rebase in progress, then failed: it refused the
    /// todo list as lacking a commit (`rebase.missingCommitsCheck`, exit 1), or the editor
    /// could not run. A rebase is in progress either way; the panel says so, and reports the
    /// failure.
    failed,
    /// A negative code: git did not end by itself (a signal ended it, or how it ended was not
    /// seen), so it told nothing. The panel keeps what the status held and reports the failure.
    unknown,
};

/// Reads `Command.rebase_check`'s exit code, as the runner reports it: negative when the
/// program was ended by a signal or its end was not seen.
pub fn rebaseCheckAnswer(exit_code: i32) RebaseCheck {
    if (exit_code < 0) return .unknown;
    return switch (exit_code) {
        0 => .rebasing,
        128 => .not_rebasing,
        else => .failed,
    };
}

/// What a file of a diff is.
pub const Change = enum { modified, added, deleted, renamed, copied };

/// A file of a unified diff. Its slices are of the bytes parsed, or of the scratch `parseDiff`
/// was given for a path git quoted. A binary or mode-only file takes its paths from its
/// `diff --git` line; when that line's names differ and are not quoted, which git does not
/// write for those, they are empty.
pub const FileDiff = struct {
    /// From its `diff --git` line up to its first hunk, or to the next file when it has none (a
    /// binary file, a change of mode, a rename alone): what `ui.diff.patch` writes before a hunk.
    header: []const u8,
    /// The path it had, unquoted, without git's `a/`; empty for an added file.
    old_path: []const u8,
    /// The path it has, unquoted, without git's `b/`; empty for a deleted file.
    new_path: []const u8,
    /// Whether it was changed, added, deleted, renamed or copied.
    change: Change = .modified,
    /// Whether git found it binary: it has no hunks.
    binary: bool = false,
    /// Whether its mode changed (`old mode`, `new mode`).
    mode_changed: bool = false,
    /// Its first hunk among those `parseDiff` kept: its hunks are
    /// `hunks[first_hunk..][0..hunk_count]`.
    first_hunk: u32 = 0,
    /// How many of its hunks `parseDiff` kept: fewer than it has when the slice filled.
    hunk_count: u32 = 0,
};

/// How many files and hunks `parseDiff` found and kept.
pub const Counts = struct {
    /// The files found, and how many fit in `files`.
    files: Counted = .{},
    /// The hunks found, and how many fit in `hunks`: only those of kept files are kept.
    hunks: Counted = .{},
};

/// Splits what `Command.diff` or `Command.show` said into `files` and `hunks`, without
/// copying, as many as fit: a hunk is kept only when its file is. A file's hunks are read from
/// the part of it after its headers by `ui.diff.parseHunks`. Anything that is not part of
/// a `diff --git` file is passed over (`show`'s message and summary, a combined diff). The one
/// allocation is from `scratch`, for each path git quoted (one with a `"`, `\` or control
/// character), unquoted; it lives as long as `scratch` keeps it.
pub fn parseDiff(bytes: []const u8, scratch: std.mem.Allocator, files: []FileDiff, hunks: []diff_widget.Hunk) error{OutOfMemory}!Counts {
    var counts: Counts = .{};
    var position: usize = 0;
    while (position < bytes.len) {
        const line = lineAt(bytes, position);
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            position = try parseFileDiff(bytes, position, scratch, files, hunks, &counts);
        } else {
            position += line.len;
        }
    }
    return counts;
}

/// Reads the file whose `diff --git` line begins at `start`, and its hunks, and returns where
/// the next line after them begins.
fn parseFileDiff(bytes: []const u8, start: usize, scratch: std.mem.Allocator, files: []FileDiff, hunks: []diff_widget.Hunk, counts: *Counts) error{OutOfMemory}!usize {
    const git_line = lineAt(bytes, start);
    var file: FileDiff = .{ .header = "", .old_path = "", .new_path = "" };
    var paths_found = false;
    var position = start + git_line.len;
    while (position < bytes.len) {
        const line = lineAt(bytes, position);
        if (std.mem.startsWith(u8, line, "@@ ") or std.mem.startsWith(u8, line, "diff ")) break;
        position += line.len;
        const text = std.mem.trimEnd(u8, line, "\n");
        if (std.mem.startsWith(u8, text, "new file mode ")) {
            file.change = .added;
        } else if (std.mem.startsWith(u8, text, "deleted file mode ")) {
            file.change = .deleted;
        } else if (std.mem.startsWith(u8, text, "old mode ") or std.mem.startsWith(u8, text, "new mode ")) {
            file.mode_changed = true;
        } else if (std.mem.startsWith(u8, text, "rename from ") or std.mem.startsWith(u8, text, "copy from ")) {
            file.change = if (text[0] == 'r') .renamed else .copied;
            const after = std.mem.indexOfScalar(u8, text, ' ').? + " from ".len;
            file.old_path = try unquote(scratch, text[after..]);
            paths_found = true;
        } else if (std.mem.startsWith(u8, text, "rename to ") or std.mem.startsWith(u8, text, "copy to ")) {
            const after = std.mem.indexOfScalar(u8, text, ' ').? + " to ".len;
            file.new_path = try unquote(scratch, text[after..]);
            paths_found = true;
        } else if (std.mem.startsWith(u8, text, "--- ")) {
            file.old_path = try diffPath(scratch, text["--- ".len..], "a/");
            paths_found = true;
        } else if (std.mem.startsWith(u8, text, "+++ ")) {
            file.new_path = try diffPath(scratch, text["+++ ".len..], "b/");
            paths_found = true;
        } else if (std.mem.startsWith(u8, text, "Binary files ") or std.mem.eql(u8, text, "GIT binary patch")) {
            file.binary = true;
        }
    }
    file.header = bytes[start..position];
    if (!paths_found) {
        // A binary file or a change of mode alone: its one path is on its `diff --git` line.
        const names = std.mem.trimEnd(u8, git_line, "\n")["diff --git ".len..];
        const path = try gitLinePath(scratch, names);
        file.old_path = path;
        file.new_path = path;
    }

    const file_kept = counts.files.kept < files.len;
    const file_index = counts.files.kept;
    counts.files.seen += 1;
    if (file_kept) {
        file.first_hunk = counts.hunks.kept;
        counts.files.kept += 1;
    }

    // The file's hunks run to the next file's `diff` line, or the end.
    const hunks_start = position;
    while (position < bytes.len) {
        const line = lineAt(bytes, position);
        if (std.mem.startsWith(u8, line, "diff ")) break;
        position += line.len;
    }
    const part = bytes[hunks_start..position];
    const room = if (file_kept) hunks[counts.hunks.kept..] else hunks[0..0];
    const hunk_counts = diff_widget.parseHunks(part, room);
    counts.hunks.seen += hunk_counts.seen;
    counts.hunks.kept += hunk_counts.kept;
    file.hunk_count = hunk_counts.kept;
    if (file_kept) files[file_index] = file;
    return position;
}

/// The line that begins at `position`, its line break included; the rest of `bytes` when it
/// has none.
fn lineAt(bytes: []const u8, position: usize) []const u8 {
    const end = std.mem.indexOfScalarPos(u8, bytes, position, '\n');
    if (end) |newline| return bytes[position .. newline + 1];
    return bytes[position..];
}

/// The path of a `---` or `+++` line, unquoted and without `prefix`; empty for `/dev/null`.
/// git ends the name with a tab when it holds a space.
fn diffPath(scratch: std.mem.Allocator, field: []const u8, prefix: []const u8) error{OutOfMemory}![]const u8 {
    const name = std.mem.trimEnd(u8, field, "\t");
    if (std.mem.eql(u8, name, "/dev/null")) return "";
    const unquoted = try unquote(scratch, name);
    if (std.mem.startsWith(u8, unquoted, prefix)) return unquoted[prefix.len..];
    return unquoted;
}

/// The path of a `diff --git a/P b/P` line's names when both are the same, as they are for a
/// binary file or a change of mode; empty when they cannot be told apart. A quoted first name is
/// unquoted into `scratch`; an unquoted pair, whose names may hold spaces, is split where its
/// two halves agree.
fn gitLinePath(scratch: std.mem.Allocator, names: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.startsWith(u8, names, "\"")) {
        const first = try unquote(scratch, names);
        if (std.mem.startsWith(u8, first, "a/")) return first[2..];
        return "";
    }
    return sameNamePath(names) orelse "";
}

/// The `P` of unquoted names `a/P b/P`; null when they are not that.
fn sameNamePath(names: []const u8) ?[]const u8 {
    if (names.len < 5 or (names.len - 5) % 2 != 0) return null;
    const length = (names.len - 5) / 2;
    if (!std.mem.startsWith(u8, names, "a/")) return null;
    const old_path = names[2 .. 2 + length];
    const middle = names[2 + length .. 5 + length];
    const new_path = names[5 + length ..];
    if (!std.mem.eql(u8, middle, " b/")) return null;
    if (!std.mem.eql(u8, old_path, new_path)) return null;
    return old_path;
}

/// `text` as it is when it does not begin with `"`; otherwise the C string git quoted it as,
/// unquoted into `scratch`: `\"`, `\\`, `\a`, `\b`, `\f`, `\n`, `\r`, `\t`, `\v` and
/// three octal digits for any byte. What follows the closing quote is dropped.
fn unquote(scratch: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    if (text.len == 0 or text[0] != '"') return text;
    const out = try scratch.alloc(u8, text.len);
    var length: usize = 0;
    var index: usize = 1;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '"') break;
        if (byte != '\\' or index + 1 >= text.len) {
            out[length] = byte;
            length += 1;
            continue;
        }
        index += 1;
        const escaped = text[index];
        const octal = index + 2 < text.len and isOctal(escaped) and isOctal(text[index + 1]) and isOctal(text[index + 2]);
        if (octal) {
            const value = (@as(u32, escaped - '0') << 6) | (@as(u32, text[index + 1] - '0') << 3) | (text[index + 2] - '0');
            out[length] = @truncate(value);
            index += 2;
        } else {
            out[length] = switch (escaped) {
                'a' => 0x07,
                'b' => 0x08,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'v' => 0x0b,
                else => escaped,
            };
        }
        length += 1;
    }
    return out[0..length];
}

fn isOctal(byte: u8) bool {
    return byte >= '0' and byte <= '7';
}

/// What `Command.show` said, split. Its slices are of the bytes parsed.
pub const Shown = struct {
    /// The full hash.
    hash: []const u8,
    /// The author's name.
    author: []const u8,
    /// `YYYY-MM-DD`.
    date: []const u8,
    /// The whole message, without the line breaks after it.
    message: []const u8,
    /// git's summary of the changes, a line a file and a total; empty for a commit that
    /// changes nothing.
    stat: []const u8,
    /// The changes, for `parseDiff`; empty for a commit that changes nothing.
    diff: []const u8,
};

/// Reads what `Command.show` said; null when it is not a commit's (no `0x1e` after four
/// fields).
pub fn parseShow(bytes: []const u8) ?Shown {
    const message_end = std.mem.indexOfScalar(u8, bytes, 0x1e) orelse return null;
    var fields = std.mem.splitScalar(u8, bytes[0..message_end], 0x1f);
    const hash = fields.next() orelse return null;
    const author = fields.next() orelse return null;
    const date = fields.next() orelse return null;
    if (fields.index == null) return null;
    const message = std.mem.trimEnd(u8, fields.rest(), "\n");

    // After the message: a line break, `---` when there is a summary, the summary, a blank
    // line and the diff.
    var rest = bytes[message_end + 1 ..];
    rest = std.mem.trimStart(u8, rest, "\n");
    if (std.mem.startsWith(u8, rest, "---\n")) rest = rest["---\n".len..];
    const diff_start = if (std.mem.startsWith(u8, rest, "diff --git "))
        0
    else if (std.mem.indexOf(u8, rest, "\ndiff --git ")) |newline|
        newline + 1
    else
        rest.len;
    const stat = std.mem.trimEnd(u8, rest[0..diff_start], "\n");
    return .{ .hash = hash, .author = author, .date = date, .message = message, .stat = stat, .diff = rest[diff_start..] };
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;

fn expectArgv(command: Command, expected: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeArgv(&writer, command);
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "vcs git: command lines are git's arguments, separated" {
    const read = "git\x1f--no-optional-locks\x1f-c\x1fcore.quotepath=false\x1f-c\x1fcolor.ui=false\x1f";
    const write = "git\x1f-c\x1fcore.quotepath=false\x1f-c\x1fcolor.ui=false\x1f";
    const paths = "git\x1f--literal-pathspecs\x1f-c\x1fcore.quotepath=false\x1f-c\x1fcolor.ui=false\x1f";
    try expectArgv(.status, read ++ "-c\x1fstatus.renames=true\x1fstatus\x1f--porcelain=v2\x1f--branch\x1f--show-stash\x1f-z\x1f--untracked-files=all");
    try expectArgv(.recent, read ++ "log\x1f--no-show-signature\x1f-n\x1f10\x1f-z\x1f--format=%H%x1f%h%x1f%an%x1f%ad%x1f%D%x1f%s\x1f--date=short");
    // vcs-git's options, then the person's query split, its `--` and path last.
    try expectArgv(.{ .log = "-n 200 --author=Ana --grep=fix main -- 'src/a b.zig'" }, read ++ "log\x1f--no-show-signature\x1f-z\x1f--format=%H%x1f%h%x1f%an%x1f%ad%x1f%D%x1f%s\x1f--date=short\x1f--max-count=4097\x1f-n\x1f200\x1f--author=Ana\x1f--grep=fix\x1fmain\x1f--\x1fsrc/a b.zig");
    try expectArgv(.{ .diff = .staged }, read ++ "diff\x1f--no-ext-diff\x1f--no-color\x1f-U3\x1f--no-renames\x1f--src-prefix=a/\x1f--dst-prefix=b/\x1f--cached");
    try expectArgv(.stage, paths ++ "add\x1f--pathspec-from-file=-\x1f--pathspec-file-nul");
    try expectArgv(.unstage_unborn, paths ++ "rm\x1f--cached\x1f-f\x1f-q\x1f--pathspec-from-file=-\x1f--pathspec-file-nul");
    try expectArgv(.{ .apply = .unstage }, write ++ "apply\x1f--cached\x1f--reverse\x1f--whitespace=nowarn\x1f-");
    try expectArgv(.{ .commit = .{ .kind = .amend, .arguments = "--signoff\x1f" } }, write ++ "commit\x1f-F\x1f-\x1f--amend\x1f--signoff");
    try expectArgv(.{ .commit = .{ .kind = .fixup, .target = "5b640f3" } }, write ++ "commit\x1f--fixup=5b640f3");
    try expectArgv(.{ .commit = .{ .kind = .reword } }, write ++ "commit\x1f-F\x1f-\x1f--amend\x1f--only");
    try expectArgv(.refs, read ++ "for-each-ref\x1f--format=%(refname)%1f%(refname:short)%1f%(upstream:short)%1f%(HEAD)%1f%(objectname)%1f%(worktreepath)\x1frefs/heads\x1frefs/remotes");
    try expectArgv(.{ .create_branch = .{ .name = "topic", .start = "origin/main" } }, write ++ "switch\x1f-c\x1ftopic\x1f--end-of-options\x1forigin/main");
    try expectArgv(.{ .delete_branch = .{ .name = "topic", .how = .force } }, write ++ "branch\x1f-D\x1f--end-of-options\x1ftopic");
    try expectArgv(.{ .switch_track = .{ .name = "x/topic", .remote_branch = "team/x/topic" } }, write ++ "switch\x1f-c\x1fx/topic\x1f--track\x1f--end-of-options\x1fteam/x/topic");
    try expectArgv(.{ .resolve = "HEAD~3" }, read ++ "rev-parse\x1f--verify\x1f--end-of-options\x1fHEAD~3^{commit}");
    try expectArgv(.rebase_continue, write ++ "-c\x1frebase.missingCommitsCheck=error\x1frebase\x1f--continue");
    try expectArgv(.{ .rebase = .{ .base = "HEAD~5" } }, write ++ "-c\x1frebase.missingCommitsCheck=error\x1frebase\x1f-i\x1f--end-of-options\x1fHEAD~5");
    try expectArgv(.{ .push = .{ .arguments = "-u\x1f", .remote = "origin", .branch = "side" } }, write ++ "push\x1f-u\x1f--end-of-options\x1forigin\x1fside");
    // A branch whose name begins with `+` is named whole, so git does not force its push.
    try expectArgv(.{ .push = .{ .arguments = "-u\x1f", .remote = "origin", .branch = "+side" } }, write ++ "push\x1f-u\x1f--end-of-options\x1forigin\x1frefs/heads/+side");
    try expectArgv(.{ .show = "5b640f3" }, read ++ "show\x1f--no-show-signature\x1f--no-ext-diff\x1f--no-color\x1f--stat\x1f--patch\x1f-m\x1f--first-parent\x1f--src-prefix=a/\x1f--dst-prefix=b/\x1f--date=short\x1f--format=%H%x1f%an%x1f%ad%x1f%B%x1e\x1f--end-of-options\x1f5b640f3");
    try expectArgv(.operation, read ++ "log\x1f--no-show-signature\x1f--no-walk=unsorted\x1f--ignore-missing\x1f--source\x1f--format=%S%x1f%H\x1f--end-of-options\x1fMERGE_HEAD\x1frebase-merge/amend\x1fREBASE_HEAD\x1fCHERRY_PICK_HEAD\x1fREVERT_HEAD\x1fBISECT_EXPECTED_REV\x1frebase-merge/onto\x1frebase-apply/onto");

    try expectArgv(.rebase_check, write ++ "-c\x1frebase.missingCommitsCheck=error\x1frebase\x1f--edit-todo");
    try expectArgv(.rebase_todo, write ++ "-c\x1frebase.missingCommitsCheck=error\x1frebase\x1f--edit-todo");
    try expectArgv(.rebase_edit_todo, write ++ "-c\x1frebase.missingCommitsCheck=error\x1frebase\x1f--edit-todo");
    try expectArgv(.{ .rebase_commits = .{ .base = "5b640f3", .head = "9f5a180" } }, read ++ "log\x1f--no-show-signature\x1f-z\x1f--format=%H%x1f%h%x1f%an%x1f%ad%x1f%D%x1f%s\x1f--date=short\x1f--no-merges\x1f--cherry-pick\x1f--right-only\x1f--topo-order\x1f--reverse\x1f--max-count=1025\x1f--end-of-options\x1f5b640f3...9f5a180");
    try expectArgv(.{ .rename_branch = .{ .name = "topic", .new_name = "topic-2" } }, write ++ "branch\x1f-m\x1f--end-of-options\x1ftopic\x1ftopic-2");
    try expectArgv(.{ .pull_from = .{ .arguments = "--rebase\x1f", .remote = "origin", .branch = "side" } }, write ++ "pull\x1f--rebase\x1f--end-of-options\x1forigin\x1fside");
    try expectArgv(.remotes, read ++ "remote");
    try expectArgv(.{ .fetch_all = "--prune\x1f" }, write ++ "fetch\x1f--prune\x1f--all");
    try testing.expect(hasArgument("--autostash\x1f--autosquash\x1f", "--autosquash"));
    try testing.expect(!hasArgument("--autosquash-not\x1f", "--autosquash"));
    try expectArgv(.root, read ++ "rev-parse\x1f--show-toplevel");

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(error.UnpassableArgument, writeArgv(&writer, .{ .switch_to = "-rf" }));
    try testing.expectError(error.UnpassableArgument, writeArgv(&writer, .{ .push = .{ .arguments = "-u\x1f", .branch = "side" } }));
    try testing.expectError(error.UnpassableArgument, writeArgv(&writer, .{ .push = .{ .remote = "origin", .branch = "a\x1fb" } }));
    try testing.expectError(error.UnpassableArgument, writeArgv(&writer, .{ .rename_branch = .{ .name = "topic", .new_name = "-D" } }));
    try testing.expectError(error.UnpassableArgument, writeArgv(&writer, .{ .rebase_commits = .{ .base = "--all", .head = "9f5a180" } }));
    try testing.expectError(error.UnpassableArgument, writeArgv(&writer, .{ .pull_from = .{ .remote = "-o", .branch = "main" } }));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "vcs git: a log's query past what one command line takes is refused as a whole" {
    // A query past what one command line takes is refused as a whole.
    var many: [2 * (max_query_arguments + 1)]u8 = undefined;
    for (0..max_query_arguments + 1) |index| {
        many[2 * index] = 'a';
        many[2 * index + 1] = ' ';
    }
    var argv_buffer: [512]u8 = undefined;
    var argv = std.Io.Writer.fixed(&argv_buffer);
    try testing.expectError(error.UnpassableArgument, writeArgv(&argv, .{ .log = &many }));
    try writeArgv(&argv, .{ .log = many[2..] });
}

test "vcs git: a log's query that would write a file is told apart" {
    try testing.expect(writesFile("\x1f--output=log.txt"));
    try testing.expect(writesFile("\x1f-n\x1f5\x1f--output\x1flog.txt"));
    try testing.expect(writesFile("\x1f--outp=x"));
    try testing.expect(!writesFile("\x1f--o"));
    try testing.expect(!writesFile("\x1f--oneline\x1f--output-indicator-new=+"));
    try testing.expect(!writesFile("\x1fHEAD\x1f--\x1f--output"));
    try testing.expect(isPassable("main"));
    try testing.expect(!isPassable("a\x1fb"));
}

test "vcs git: what a log's output holds that is no commit is counted, the first of it kept" {
    const hash = "5b640f35160c9e1c2e312b1e53923bdb3785353f";
    const good = hash ++ "\x1f5b640f3\x1fAna\x1f2026-11-20\x1fHEAD -> main\x1fStart\x00";
    var entries: [4]LogEntry = undefined;
    // `--oneline`'s shape: nothing read, the first record kept to show.
    const oneline = parseLog("5b640f3 Start the panel\x0072f25b6 Fix the spinner\x00", &entries);
    try testing.expectEqual(Counted{}, oneline.commits);
    try testing.expectEqual(@as(u32, 2), oneline.unread);
    try testing.expectEqualStrings("5b640f3 Start the panel", oneline.first_unread);
    // A good commit, then a stat that came after it (`--stat`): the commit read, the rest not.
    const stat = parseLog(good ++ "\n a.txt | 2 +-\n" ++ good, &entries);
    try testing.expectEqual(Counted{ .seen = 1, .kept = 1 }, stat.commits);
    try testing.expectEqual(@as(u32, 1), stat.unread);
    try testing.expectEqualStrings("a.txt | 2 +-\n" ++ hash ++ "\x1f5b640f", stat.first_unread);
    // A patch after the subject (`-p`), a short hash that is no prefix, too few fields, a hash
    // of no hex, and a record cut short at the end.
    const bad = [_][]const u8{
        hash ++ "\x1f5b640f3\x1fAna\x1f2026-11-20\x1f\x1fStart\n\ndiff --git a/a b/a\x00",
        hash ++ "\x1f72f25b6\x1fAna\x1f2026-11-20\x1f\x1fStart\x00",
        hash ++ "\x1f5b640f3\x1fAna\x00",
        "z" ** 40 ++ "\x1fzzzz\x1fAna\x1f2026-11-20\x1f\x1fStart\x00",
        good ++ hash[0..20],
    };
    for (bad, 0..) |output, index| {
        const read = parseLog(output, &entries);
        try testing.expectEqual(@as(u32, 1), read.unread);
        const commits: u32 = if (index == bad.len - 1) 1 else 0;
        try testing.expectEqual(commits, read.commits.seen);
    }
    // A 64-digit hash, a subject longer than a cell keeps, cut at a character, and empty
    // records and line breaks around the output, which are nothing.
    const long_subject = "\xc3\xa9" ** 600;
    const sha256 = "a" ** 64 ++ "\x1faaaaaaa\x1fBo\x1f2026-11-21\x1f\x1f" ++ long_subject ++ "\x00\x00\n";
    const long = parseLog(sha256, &entries);
    try testing.expectEqual(@as(u32, 0), long.unread);
    try testing.expectEqual(Counted{ .seen = 1, .kept = 1 }, long.commits);
    try testing.expectEqual(@as(usize, max_log_field_bytes), entries[0].subject.len);
    try testing.expectEqualStrings("a" ** 64, entries[0].hash);
    // More commits than room: all seen, as many kept as fit.
    const four = parseLog(good ++ good ++ good ++ good ++ good, &entries);
    try testing.expectEqual(Counted{ .seen = 5, .kept = 4 }, four.commits);
    try testing.expectEqualStrings("", four.first_unread);
}

test "vcs git: the editor's variables quote the host's path for git's shell" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeEnvironment(&writer, "C:/Program Files/a\"b$c`d\\mesha.exe", .write_input);
    const quoted_path = "\"C:/Program Files/a\\\"b\\$c\\`d\\\\mesha.exe\"";
    const quoted = quoted_path ++ " --stdin-to-file";
    try testing.expectEqualStrings("GIT_TERMINAL_PROMPT=0\x1fGIT_EDITOR=" ++ quoted ++ "\x1fGIT_SEQUENCE_EDITOR=" ++ quoted, writer.buffered());
    // The rest of a rebase's list is read with a sequence editor that prints it.
    writer = std.Io.Writer.fixed(&buffer);
    try writeEnvironment(&writer, "C:/Program Files/a\"b$c`d\\mesha.exe", sequenceEditorOf(.rebase_todo));
    try testing.expectEqualStrings("GIT_TERMINAL_PROMPT=0\x1fGIT_EDITOR=" ++ quoted ++ "\x1fGIT_SEQUENCE_EDITOR=" ++ quoted_path ++ " --file-to-stdout", writer.buffered());
    try testing.expectEqual(SequenceEditor.write_input, sequenceEditorOf(.rebase_continue));
}

test "vcs git: clean takes as many paths as fit in one command line" {
    // One-byte paths: as many as the line's bytes hold, in one process.
    const paths = try testing.allocator.alloc([]const u8, max_clean_paths + 3);
    defer testing.allocator.free(paths);
    for (paths) |*path| path.* = "*";
    var buffer: [max_clean_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const taken = try writeClean(&writer, paths);
    try testing.expectEqual(@as(usize, max_clean_paths), taken);
    try testing.expectEqual(@as(usize, 14_961), max_clean_paths);
    const argument_count = std.mem.count(u8, writer.buffered(), "\x1f") + 1;
    try testing.expectEqual(clean_prefix.len + max_clean_paths, argument_count);
    try testing.expect(writer.buffered().len <= max_clean_bytes);
    try testing.expect(std.mem.startsWith(u8, writer.buffered(), "git\x1f--literal-pathspecs\x1f-c\x1fcore.quotepath=false\x1f-c\x1fcolor.ui=false\x1fclean\x1f-f\x1f--\x1f*\x1f"));
    // A Untracked heading's 4,096 paths of 30 bytes: five processes, not 75.
    const path_30: [30]u8 = @splat('y');
    const listed = try testing.allocator.alloc([]const u8, 4096);
    defer testing.allocator.free(listed);
    for (listed) |*path| path.* = &path_30;
    var batches: usize = 0;
    var rest: []const []const u8 = listed;
    while (rest.len != 0) : (batches += 1) {
        writer = std.Io.Writer.fixed(&buffer);
        rest = rest[try writeClean(&writer, rest)..];
    }
    try testing.expectEqual(@as(usize, 5), batches);

    // Long paths fill the line's bytes before its arguments.
    const long_path: [1000]u8 = @splat('x');
    var long_paths: [40][]const u8 = undefined;
    for (&long_paths) |*path| path.* = &long_path;
    var long_buffer: [max_clean_bytes]u8 = undefined;
    var long_writer = std.Io.Writer.fixed(&long_buffer);
    const long_taken = try writeClean(&long_writer, &long_paths);
    try testing.expectEqual(@as(usize, 29), long_taken);
    try testing.expect(long_writer.buffered().len <= max_clean_bytes);

    // A path it cannot pass, past what fits, is left for the next line.
    var unpassable: [1000]u8 = @splat('x');
    unpassable[500] = separator;
    long_paths[29] = &unpassable;
    long_writer = std.Io.Writer.fixed(&long_buffer);
    try testing.expectEqual(@as(usize, 29), try writeClean(&long_writer, &long_paths));
}

test "vcs git: branch names git would refuse are refused" {
    try testing.expect(isRefName("feature/emacs-workflow"));
    try testing.expect(isRefName("caf\xc3\xa9"));
    const refused = [_][]const u8{ "", "-f", "a b", "a~1", "a^", "a:b", "a?", "a*", "a[", "a\\b", "a\x01", "a..b", "a@{1}", "a/", "a.lock", "a.", "@", "/a", "a//b", "a/.b", ".a", "a.lock/b" };
    for (refused) |name| try testing.expect(!isRefName(name));
}

test "vcs git: status reads its headers, a rename, a conflict and an untracked name" {
    // A merge stopped on a conflict in a.txt, with old.txt renamed and staged, a new file named
    // with a space and an "é", a clone 2 ahead of and 1 behind origin/main, and one stash.
    const merging = "# branch.oid 9f5a1806762fa46dec66685c2bd3bf1d8a98aa82\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +2 -1\x00# stash 1\x002 R. N... 100644 100644 100644 4cb29ea38f70d7c61b2a3a25b02e3bdf44905402 4cb29ea38f70d7c61b2a3a25b02e3bdf44905402 R100 new.txt\x00old.txt\x00u UU N... 100644 100644 100644 100644 78981922613b2afb6025042ff6bd878ac1994e85 b19a1e93bec1317dc6097229e12afaffbfa74dc2 950b81b7eee953d050aa05a641f8e056c85dd1bd a.txt\x00? my fil\xc3\xa9.txt\x00";
    var entries: [2]Entry = undefined;
    const status = parseStatus(merging, &entries);
    try testing.expectEqual(Head.branch, status.head);
    try testing.expectEqualStrings("main", status.branch);
    try testing.expectEqualStrings("9f5a1806762fa46dec66685c2bd3bf1d8a98aa82", status.oid);
    try testing.expectEqualStrings("origin/main", status.upstream);
    try testing.expectEqual(Upstream.tracking, status.upstream_state);
    try testing.expectEqual(@as(u32, 2), status.ahead);
    try testing.expectEqual(@as(u32, 1), status.behind);
    try testing.expectEqual(@as(u32, 1), status.stash_count);
    try testing.expectEqual(Counted{ .seen = 3, .kept = 2 }, status.entries);
    try testing.expectEqual(@as(u32, 1), status.staged_count);
    try testing.expectEqual(@as(u32, 0), status.unstaged_count);
    try testing.expectEqual(@as(u32, 1), status.unmerged_count);
    try testing.expectEqual(@as(u32, 1), status.untracked_count);
    try testing.expectEqual(EntryKind.renamed, entries[0].kind);
    try testing.expectEqual(@as(u8, 'R'), entries[0].staged);
    try testing.expectEqual(@as(u8, '.'), entries[0].unstaged);
    try testing.expectEqualStrings("new.txt", entries[0].path);
    try testing.expectEqualStrings("old.txt", entries[0].original_path);
    try testing.expectEqual(EntryKind.unmerged, entries[1].kind);
    try testing.expectEqualStrings("a.txt", entries[1].path);

    var all: [3]Entry = undefined;
    _ = parseStatus(merging, &all);
    try testing.expectEqual(EntryKind.untracked, all[2].kind);
    try testing.expectEqualStrings("my fil\xc3\xa9.txt", all[2].path);

    const changed = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +1 -0\x001 MM N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b ab4d2b1079bf560e64cdb7242e2cdcceca23cf4c a.txt\x00";
    const changed_status = parseStatus(changed, &all);
    try testing.expectEqual(@as(u32, 1), changed_status.staged_count);
    try testing.expectEqual(@as(u32, 1), changed_status.unstaged_count);
    try testing.expectEqual(EntryKind.changed, all[0].kind);
    try testing.expectEqual(@as(u8, 'M'), all[0].staged);
    try testing.expectEqual(@as(u8, 'M'), all[0].unstaged);
    try testing.expectEqualStrings("a.txt", all[0].path);

    // topic's upstream, origin/topic, was deleted on the remote and pruned.
    const gone = parseStatus("# branch.oid 21b9efbef4740b81c56f0f458043ffe7954e557b\x00# branch.head topic\x00# branch.upstream origin/topic\x00", &all);
    try testing.expectEqual(Upstream.gone, gone.upstream_state);
    try testing.expectEqualStrings("origin/topic", gone.upstream);

    const unborn = parseStatus("# branch.oid (initial)\x00# branch.head main\x00? a.txt\x00", &all);
    try testing.expectEqual(Upstream.none, unborn.upstream_state);
    try testing.expect(!unborn.hasCommit());
    try testing.expectEqualStrings("main", unborn.branch);

    const detached = parseStatus("# branch.oid 2bd62b6fbc3f7fbfb4783aa883754a2402a0971c\x00# branch.head (detached)\x00", &all);
    try testing.expectEqual(Head.detached, detached.head);
    try testing.expectEqualStrings("", detached.branch);
    try testing.expect(detached.hasCommit());
}

test "vcs git: a log of two commits, one subject with a tab and an accent" {
    const output = "5b640f35160c9e1c2e312b1e53923bdb3785353f\x1f5b640f3\x1fZo\xc3\xab \xc3\x96degaard\x1f2026-11-20\x1fHEAD -> main\x1fTab\there and caf\xc3\xa9\x0072f25b65411d1f8a0a15a3f577334b3e0e3a4cc0\x1f72f25b6\x1fZo\xc3\xab \xc3\x96degaard\x1f2026-11-20\x1f\x1fStart\x00";
    var entries: [4]LogEntry = undefined;
    const parsed = parseLog(output, &entries);
    try testing.expectEqual(Counted{ .seen = 2, .kept = 2 }, parsed.commits);
    try testing.expectEqual(@as(u32, 0), parsed.unread);
    try testing.expectEqualStrings("5b640f35160c9e1c2e312b1e53923bdb3785353f", entries[0].hash);
    try testing.expectEqualStrings("5b640f3", entries[0].short_hash);
    try testing.expectEqualStrings("Zo\xc3\xab \xc3\x96degaard", entries[0].author);
    try testing.expectEqualStrings("2026-11-20", entries[0].date);
    try testing.expectEqualStrings("HEAD -> main", entries[0].refs);
    try testing.expectEqualStrings("Tab\there and caf\xc3\xa9", entries[0].subject);
    try testing.expectEqualStrings("", entries[1].refs);
    try testing.expectEqualStrings("Start", entries[1].subject);
}

test "vcs git: refs mark the current branch and its upstream" {
    const output = "refs/heads/feature\x1ffeature\x1f\x1f \nrefs/heads/main\x1fmain\x1forigin/main\x1f*\nrefs/remotes/origin/HEAD\x1forigin\x1f\x1f \nrefs/remotes/origin/main\x1forigin/main\x1f\x1f \n";
    var refs: [4]Ref = undefined;
    const counted = parseRefs(output, &refs);
    try testing.expectEqual(Counted{ .seen = 3, .kept = 3 }, counted);
    try testing.expectEqualStrings("feature", refs[0].short_name);
    try testing.expect(!refs[0].current);
    try testing.expectEqualStrings("refs/heads/main", refs[1].name);
    try testing.expectEqualStrings("origin/main", refs[1].upstream);
    try testing.expect(refs[1].current);
    try testing.expectEqual(RefKind.local, refs[1].kind);
    try testing.expectEqual(RefKind.remote, refs[2].kind);
    try testing.expectEqualStrings("origin/main", refs[2].short_name);
}

test "vcs git: the operation in progress is read from the refs that exist" {
    const editing = parseInProgress("REBASE_HEAD\x1feedb12ac6f4f91937ebda469973fdecf7d97b84b\nrebase-merge/onto\x1f057605be00ef6f0889b1bd91798a2d742079830d\n");
    try testing.expectEqual(Operation.rebasing, editing.operation);
    try testing.expectEqualStrings("eedb12ac6f4f91937ebda469973fdecf7d97b84b", editing.commit);
    const at_break = parseInProgress("rebase-merge/onto\x1f2bd62b6fbc3f7fbfb4783aa883754a2402a0971c\n");
    try testing.expectEqual(Operation.rebasing, at_break.operation);
    const merging = parseInProgress("MERGE_HEAD\x1fcb39646fee52c7bb1444c78a11cda8603bacefcc\n");
    try testing.expectEqual(Operation.merging, merging.operation);
    try testing.expectEqual(Operation.none, parseInProgress("").operation);
    try testing.expectEqual(RebaseStop.on_conflict, editing.stop);
    // An `edit` stop: git wrote `rebase-merge/amend`, HEAD's hash, not REBASE_HEAD's.
    const at_edit = parseInProgress("REBASE_HEAD\x1f0021ce590095b3e5c630e8a3b745bd6de6ef68df\nrebase-merge/onto\x1f72982b5ff4efc42bc709c8e805f253bb7b1bd17e\nrebase-merge/amend\x1fb73e0fa910ebbe33bf23c8458756366fb9faadea\n");
    try testing.expectEqual(RebaseStop.on_commit, at_edit.stop);
    try testing.expectEqualStrings("b73e0fa910ebbe33bf23c8458756366fb9faadea", at_edit.amend);
    // An `edit` in place: REBASE_HEAD is the commit amend names, which `--source` prints once.
    const in_place = parseInProgress("rebase-merge/amend\x1f21495e2ccd6554034547f7cf65f06caf0c6c7e2d\nrebase-merge/onto\x1ff38a28f04d2deb8e454774de2debecf30402f65a\n");
    try testing.expectEqual(Operation.rebasing, in_place.operation);
    try testing.expectEqual(RebaseStop.on_commit, in_place.stop);
    try testing.expectEqualStrings("21495e2ccd6554034547f7cf65f06caf0c6c7e2d", in_place.commit);
    try testing.expectEqual(RebaseStop.between_commits, at_break.stop);
    try testing.expectEqual(RebaseStop.none, merging.stop);
    try testing.expectEqual(RebaseCheck.rebasing, rebaseCheckAnswer(0));
    try testing.expectEqual(RebaseCheck.not_rebasing, rebaseCheckAnswer(128));
    try testing.expectEqual(RebaseCheck.failed, rebaseCheckAnswer(1));
    try testing.expectEqual(RebaseCheck.unknown, rebaseCheckAnswer(-1));
    try testing.expectEqual(RebaseCheck.unknown, rebaseCheckAnswer(-9));
}

test "vcs git: a diff's hunks are kept byte for byte and give back the patch that applies them" {
    // Two hunks of a file with CRLF lines, the second with a byte that is not UTF-8 (Latin-1
    // "é"), and a hunk of a file with no line break at its end.
    const unstaged = "diff --git a/crlf.txt b/crlf.txt\nindex 0cd7b95..2c327e9 100644\n--- a/crlf.txt\n+++ b/crlf.txt\n@@ -7,7 +7,7 @@ line 6\n line 7\r\n line 8\r\n line 9\r\n-line 10\r\n+line ten\r\n line 11\r\n line 12\r\n line 13\r\n@@ -16,5 +16,5 @@ line 15\n line 16\r\n line 17\r\n line 18\r\n-line 19\r\n+line nineteen \xe9\r\n line 20\r\ndiff --git a/tail.txt b/tail.txt\nindex b9e9ab4..2a5e3fa 100644\n--- a/tail.txt\n+++ b/tail.txt\n@@ -1,3 +1,3 @@\n alpha\n beta\n-gamma\n\\ No newline at end of file\n+gamma!\n\\ No newline at end of file\n";
    var files: [4]FileDiff = undefined;
    var hunks: [4]diff_widget.Hunk = undefined;
    const counts = try parseDiff(unstaged, testing.allocator, &files, &hunks);
    try testing.expectEqual(Counts{ .files = .{ .seen = 2, .kept = 2 }, .hunks = .{ .seen = 3, .kept = 3 } }, counts);
    try testing.expectEqualStrings("crlf.txt", files[0].old_path);
    try testing.expectEqualStrings("crlf.txt", files[0].new_path);
    try testing.expectEqual(@as(u32, 0), files[0].first_hunk);
    try testing.expectEqual(@as(u32, 2), files[0].hunk_count);
    try testing.expectEqual(@as(u32, 2), files[1].first_hunk);
    try testing.expectEqual(@as(u32, 1), files[1].hunk_count);
    try testing.expectEqual(diff_widget.Hunk{ .header = hunks[1].header, .body = hunks[1].body, .old_start = 16, .old_count = 5, .new_start = 16, .new_count = 5 }, hunks[1]);
    try testing.expectEqualStrings(" line 16\r\n line 17\r\n line 18\r\n-line 19\r\n+line nineteen \xe9\r\n line 20\r\n", hunks[1].body);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try diff_widget.patch(&writer, files[0].header, hunks[1]);
    try testing.expectEqualStrings("diff --git a/crlf.txt b/crlf.txt\nindex 0cd7b95..2c327e9 100644\n--- a/crlf.txt\n+++ b/crlf.txt\n@@ -16,5 +16,5 @@ line 15\n line 16\r\n line 17\r\n line 18\r\n-line 19\r\n+line nineteen \xe9\r\n line 20\r\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try diff_widget.patch(&writer, files[1].header, hunks[2]);
    try testing.expectEqualStrings("diff --git a/tail.txt b/tail.txt\nindex b9e9ab4..2a5e3fa 100644\n--- a/tail.txt\n+++ b/tail.txt\n@@ -1,3 +1,3 @@\n alpha\n beta\n-gamma\n\\ No newline at end of file\n+gamma!\n\\ No newline at end of file\n", writer.buffered());

    var one_hunk: [1]diff_widget.Hunk = undefined;
    const cut = try parseDiff(unstaged, testing.allocator, files[0..1], &one_hunk);
    try testing.expectEqual(Counts{ .files = .{ .seen = 2, .kept = 1 }, .hunks = .{ .seen = 3, .kept = 1 } }, cut);
    try testing.expectEqual(@as(u32, 1), files[0].hunk_count);
}

test "vcs git: a diff names renamed, binary, deleted, re-moded and quoted new files" {
    const staged = "diff --git a/before.txt b/after.txt\nsimilarity index 100%\nrename from before.txt\nrename to after.txt\ndiff --git a/blob.bin b/blob.bin\nindex 0f49c4a..4c2de3c 100644\nBinary files a/blob.bin and b/blob.bin differ\ndiff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\nindex 4202011..0000000\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-to be deleted\ndiff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\ndiff --git \"a/say \\\"hi\\\" \xc3\xbcn\xc3\xaf.txt\" \"b/say \\\"hi\\\" \xc3\xbcn\xc3\xaf.txt\"\nnew file mode 100644\nindex 0000000..92d5444\n--- /dev/null\n+++ \"b/say \\\"hi\\\" \xc3\xbcn\xc3\xaf.txt\"\t\n@@ -0,0 +1 @@\n+fresh\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var files: [8]FileDiff = undefined;
    var hunks: [8]diff_widget.Hunk = undefined;
    const counts = try parseDiff(staged, arena_state.allocator(), &files, &hunks);
    try testing.expectEqual(Counts{ .files = .{ .seen = 5, .kept = 5 }, .hunks = .{ .seen = 2, .kept = 2 } }, counts);

    try testing.expectEqual(Change.renamed, files[0].change);
    try testing.expectEqualStrings("before.txt", files[0].old_path);
    try testing.expectEqualStrings("after.txt", files[0].new_path);
    try testing.expectEqualStrings("diff --git a/before.txt b/after.txt\nsimilarity index 100%\nrename from before.txt\nrename to after.txt\n", files[0].header);
    try testing.expectEqual(@as(u32, 0), files[0].hunk_count);

    try testing.expect(files[1].binary);
    try testing.expectEqualStrings("blob.bin", files[1].new_path);

    try testing.expectEqual(Change.deleted, files[2].change);
    try testing.expectEqualStrings("gone.txt", files[2].old_path);
    try testing.expectEqualStrings("", files[2].new_path);
    try testing.expectEqual(@as(u32, 0), files[2].first_hunk);
    try testing.expectEqual(@as(u32, 1), files[2].hunk_count);
    try testing.expectEqual(diff_widget.Hunk{ .header = hunks[0].header, .body = hunks[0].body, .old_start = 1, .old_count = 1, .new_start = 0, .new_count = 0 }, hunks[0]);
    try testing.expectEqualStrings("@@ -1 +0,0 @@\n", hunks[0].header);
    try testing.expectEqualStrings("-to be deleted\n", hunks[0].body);

    try testing.expect(files[3].mode_changed);
    try testing.expectEqualStrings("run.sh", files[3].old_path);
    try testing.expectEqualStrings("run.sh", files[3].new_path);

    try testing.expectEqual(Change.added, files[4].change);
    try testing.expectEqualStrings("", files[4].old_path);
    try testing.expectEqualStrings("say \"hi\" \xc3\xbcn\xc3\xaf.txt", files[4].new_path);

    // A binary file and a change of mode, both named with quotes: their paths are only on
    // their quoted `diff --git` lines.
    const quoted = "diff --git \"a/bin \\\"q\\\".bin\" \"b/bin \\\"q\\\".bin\"\nindex 88768ef..3e3315e 100644\nBinary files \"a/bin \\\"q\\\".bin\" and \"b/bin \\\"q\\\".bin\" differ\ndiff --git \"a/run \\\"me\\\".sh\" \"b/run \\\"me\\\".sh\"\nold mode 100644\nnew mode 100755\n";
    const quoted_counts = try parseDiff(quoted, arena_state.allocator(), &files, &hunks);
    try testing.expectEqual(@as(u32, 2), quoted_counts.files.kept);
    try testing.expect(files[0].binary);
    try testing.expectEqualStrings("bin \"q\".bin", files[0].old_path);
    try testing.expectEqualStrings("bin \"q\".bin", files[0].new_path);
    try testing.expect(files[1].mode_changed);
    try testing.expectEqualStrings("run \"me\".sh", files[1].new_path);
}

test "vcs git: show splits a commit's fields, message, summary and changes" {
    const output = "5b640f35160c9e1c2e312b1e53923bdb3785353f\x1fZo\xc3\xab \xc3\x96degaard\x1f2026-11-20\x1fTab\there and caf\xc3\xa9\n\x1e\n---\n readme.txt | 1 +\n 1 file changed, 1 insertion(+)\n\ndiff --git a/readme.txt b/readme.txt\nindex df967b9..2b07b76 100644\n--- a/readme.txt\n+++ b/readme.txt\n@@ -1 +1,2 @@\n base\n+second\n";
    const shown = parseShow(output) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("5b640f35160c9e1c2e312b1e53923bdb3785353f", shown.hash);
    try testing.expectEqualStrings("Zo\xc3\xab \xc3\x96degaard", shown.author);
    try testing.expectEqualStrings("2026-11-20", shown.date);
    try testing.expectEqualStrings("Tab\there and caf\xc3\xa9", shown.message);
    try testing.expectEqualStrings(" readme.txt | 1 +\n 1 file changed, 1 insertion(+)", shown.stat);
    try testing.expect(std.mem.startsWith(u8, shown.diff, "diff --git a/readme.txt b/readme.txt\n"));
    try testing.expect(std.mem.endsWith(u8, shown.diff, "+second\n"));

    const empty = parseShow("5af43c18d18ffc68c3ceda16b242ba65c964e8cc\x1fC\x1f2026-11-23\x1fempty one\n\x1e\n") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("empty one", empty.message);
    try testing.expectEqualStrings("", empty.stat);
    try testing.expectEqualStrings("", empty.diff);
}

test "vcs git: the root is the one line rev-parse writes" {
    try testing.expectEqualStrings("/home/ana/work/repo", parseRoot("/home/ana/work/repo\n"));
    try testing.expectEqualStrings("C:/Users/Ana/work/repo", parseRoot("C:/Users/Ana/work/repo\r\n"));
    try testing.expectEqualStrings("", parseRoot(""));
}

test "vcs git: a reword picks its commit and breaks after it" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const entries = [_]RebaseEntry{
        .{ .action = .pick, .hash = "6b6ad69", .subject = "c2" },
        .{ .action = .reword, .hash = "2bd62b6", .subject = "c3" },
        .{ .action = .squash, .hash = "4f68c22", .subject = "c4" },
        .{ .action = .fixup, .hash = "186cfc7", .subject = "c5" },
        .{ .action = .drop, .hash = "b71dfca", .subject = "c6" },
    };
    try rebaseList(&writer, &entries);
    try testing.expectEqualStrings("pick 6b6ad69 c2\npick 2bd62b6 c3\nbreak\nsquash 4f68c22 c4\nfixup 186cfc7 c5\ndrop b71dfca c6\n", writer.buffered());
}

test "vcs git: a reword and git's own lines are written back as the list holds them" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const entries = [_]RebaseEntry{
        .{ .action = .reword, .hash = "2bd62b6", .subject = "c3" },
        .{ .action = .kept, .hash = "", .subject = "exec make test" },
        .{ .action = .drop, .hash = "b71dfca", .subject = "c6" },
    };
    try rebaseList(&writer, &entries);
    try testing.expectEqualStrings("pick 2bd62b6 c3\nbreak\nexec make test\ndrop b71dfca c6\n", writer.buffered());
    var refused = std.Io.Writer.fixed(&buffer);
    const broken = [_]RebaseEntry{.{ .action = .kept, .hash = "", .subject = "exec a\nb" }};
    try testing.expectError(error.UnpassableArgument, rebaseList(&refused, &broken));
    try testing.expectEqual(@as(usize, 0), refused.buffered().len);
}

test "vcs git: the rest of a rebase's list is read from what its sequence editor printed" {
    // As git 2.56 hands the list to its sequence editor in `rebase --edit-todo`, its help after it.
    const printed = "pick 16adce6 c3\nr 4c2897a c2 reworded\nbreak\nexec make test\nfixup -C 8573240 c4\nd 8de3971 c1\n" ++
        "#\n# Commands:\n# p, pick <commit> = use commit\n#\n# You are editing the todo file of an ongoing interactive rebase.\n\n";
    var entries: [8]RebaseEntry = undefined;
    const counted = parseTodo(printed, &entries);
    try testing.expectEqual(Counted{ .seen = 6, .kept = 6 }, counted);
    try testing.expectEqual(RebaseAction.pick, entries[0].action);
    try testing.expectEqualStrings("16adce6", entries[0].hash);
    try testing.expectEqualStrings("c3", entries[0].subject);
    try testing.expectEqual(RebaseAction.reword, entries[1].action);
    try testing.expectEqualStrings("c2 reworded", entries[1].subject);
    try testing.expectEqual(RebaseAction.kept, entries[2].action);
    try testing.expectEqualStrings("break", entries[2].subject);
    try testing.expectEqualStrings("exec make test", entries[3].subject);
    try testing.expectEqual(RebaseAction.kept, entries[4].action);
    try testing.expectEqualStrings("fixup -C 8573240 c4", entries[4].subject);
    try testing.expectEqual(RebaseAction.drop, entries[5].action);
    // Written back, git's own lines are as they were.
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try rebaseList(&writer, entries[0..counted.kept]);
    try testing.expectEqualStrings("pick 16adce6 c3\npick 4c2897a c2 reworded\nbreak\nbreak\nexec make test\nfixup -C 8573240 c4\ndrop 8de3971 c1\n", writer.buffered());
}

test "vcs git: remotes are a name a line" {
    var names: [1][]const u8 = undefined;
    const counted = parseRemotes("origin\r\nupstream\n", &names);
    try testing.expectEqual(Counted{ .seen = 2, .kept = 1 }, counted);
    try testing.expectEqualStrings("origin", names[0]);
}

test "vcs git: a todo list read with git's comment string set to another" {
    const printed = "pick 16adce6 c3\nbreak\n;\n; Commands:\n; p, pick <commit> = use commit\n;\n";
    var entries: [8]RebaseEntry = undefined;
    try testing.expectEqual(Counted{ .seen = 2, .kept = 2 }, parseTodo(printed, &entries));
    try testing.expectEqualStrings("16adce6", entries[0].hash);
    try testing.expectEqualStrings("break", entries[1].subject);
}

test "vcs git: refs carry their commit and the worktree they are checked out in" {
    const listed = "refs/heads/main\x1fmain\x1f\x1f*\x1fdc0de9dd5ba4f82268b1ae06cf592e3389e41d36\x1f/work/repo\nrefs/heads/wtb\x1fwtb\x1f\x1f \x1fdc0de9dd5ba4f82268b1ae06cf592e3389e41d36\x1f/work/wt\n";
    var refs: [2]Ref = undefined;
    _ = parseRefs(listed, &refs);
    try testing.expectEqualStrings("dc0de9dd5ba4f82268b1ae06cf592e3389e41d36", refs[1].hash);
    try testing.expectEqualStrings("/work/wt", refs[1].worktree);
}

test "vcs git: every rebase command line runs with the check of commits left out" {
    const rebase_commands = [_]Command{ .{ .rebase = .{ .base = "5b640f3" } }, .rebase_continue, .rebase_skip, .rebase_abort, .rebase_check, .rebase_todo, .rebase_edit_todo };
    for (rebase_commands) |command| {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writeArgv(&writer, command);
        try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1f-c\x1frebase.missingCommitsCheck=error\x1frebase\x1f") != null);
    }
    // Every command that names `rebase` is among them.
    const names = std.meta.fieldNames(Command);
    var rebase_named: usize = 0;
    for (names) |name| {
        const is_rebase = std.mem.startsWith(u8, name, "rebase") and !std.mem.eql(u8, name, "rebase_commits");
        if (is_rebase) rebase_named += 1;
    }
    try testing.expectEqual(rebase_commands.len, rebase_named);
}

test "vcs git: a REBASE_HEAD git left behind with no onto is no rebase" {
    const left = parseInProgress("REBASE_HEAD\x1f67991e6e1ee513964fa9aa8b83f5393e03e003e7\n");
    try testing.expectEqual(Operation.none, left.operation);
    try testing.expectEqual(RebaseStop.none, left.stop);
    const with_merge = parseInProgress("MERGE_HEAD\x1fcb39646fee52c7bb1444c78a11cda8603bacefcc\nREBASE_HEAD\x1f67991e6e1ee513964fa9aa8b83f5393e03e003e7\n");
    try testing.expectEqual(Operation.merging, with_merge.operation);
}
