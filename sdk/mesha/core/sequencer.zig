//! Sequencers, systems and kernels: how the engine's frame is organized.
//!
//! A kernel is a bare function a system runs each frame; it decides in its body when it does
//! anything and which rows it does it for. A system is like a GPU render pass: every frame it
//! declares, from its own state, the tables its kernels read and write (`System.access`), and
//! runs its kernels in order; a guard (`System.active`) may skip a frame that brings it no
//! messages. A sequencer runs systems, and child sequencers among them, in order.
//!
//! A sequencer's run is journaled (`journal.zig`): it gets a layer over its parent's, and
//! while a system's kernels run, the tables it declared are attached to that layer, so every
//! row they read or write goes through it. A kernel that returns an error faults the run: the
//! layer is discarded, with the requests the run appended, the rest of the run is skipped, and
//! the fault is kept in `sequencer_systems`. Next frame the run is tried again. A run with no
//! fault merges into its parent's layer; the root's is flushed into the tables. A child
//! sequencer that faults is discarded alone: its parent goes on.
//!
//! Rules for kernel code:
//!  - Write only tables the system declared it writes. A table it did not declare is
//!    attached only for reading, and only when the run has written it; a write to it is not
//!    the run's, and no fault takes it back.
//!  - A row fetched mutably from a table declared written is copied into the run's layer,
//!    whether or not it is then written; read through `Rows.read` and `Rows.readRow`, which
//!    never copy.
//!  - Arena data is not journaled: it stays when a run is discarded. A table's payload
//!    cells are journaled as its other cells are.
//!
//! A system's inbox is a table, `inbox.<system>`, of the messages delivered to it: a row per
//! message, `{tag, payload, user_data}`, its bytes in the table's arena. Its kernels see the
//! rows as `Frame.messages`; when they all succeed the run clears the inbox, so a run that
//! faults leaves the messages for the next frame's try. The arena is reset when a delivery
//! finds the inbox empty. What a payload points at is not copied: a message whose handling
//! is retried relies on it only as long as its sender says it lives.
//!
//! Who calls what. An owner (the host's `main`, a plugin, a host system with a sequencer of its
//! own) builds its systems and sequencers where it uses them: a `System` is a value its
//! module returns from a function, and a `Sequencer` a list of steps the owner fills on its
//! stack, each holding its system, child sequencer or call. Nothing keeps either past the call
//! it was built for. When the owner starts it builds its sequencer once to intern the names
//! (`internNames`; a host system's owner `claimNames`, a plugin also `checkNamesFree`), make
//! the faults table (`ensure`) and its systems' inboxes (`ensureInboxes`); each frame it
//! builds it again, with the same function so the two agree, and the root's owner calls
//! `beginFrame` and then `run` with an `Env`; a plugin runs its sequencers as children of the
//! layer the host hands it. After the root's run the host calls
//! `orderSubscriptions`. A kernel gets a `Pass`: the tables its system declared (`Pass.rows`,
//! `Pass.writeRows`, `Pass.readSingleton`, `Pass.append`) and its `Frame`.
//!
//! Systems talk through tables: `Commands(T)` holds requests to a system, `Events(E)` what
//! happened in a host system, `Subscribed(T)` what systems ask a host system to tell them of,
//! and a host system answers into inboxes (`Inboxes`, `ReplyTo`, `UserData`, `Message`).
const std = @import("std");
const log = @import("log.zig");
const Atom = @import("atom.zig").Atom;
const memory_mod = @import("memory.zig");
const Table = @import("table.zig");
const journal = @import("journal.zig");

const Layer = journal.Layer;
const Log = log.scope("sequencer");

/// What a `Pass` returns to a kernel, which passes it on with `try` and so faults the run: the
/// journal's errors, `UndeclaredRead` for a table the system did not declare this frame (or
/// declared read and that does not exist), `UndeclaredWrite` for one it did not declare written,
/// and `MissingTable` for a declared table or a singleton's row that is not there, or a row
/// `Pass.append` could not insert for a reason other than memory.
pub const Error = journal.Error || error{ UndeclaredRead, UndeclaredWrite, MissingTable };

/// A function a system runs each frame, and the name its faults and its profile zone are kept
/// under.
pub const Kernel = struct {
    /// `<system>.<kernel>`: the name a fault is kept under.
    name: []const u8,
    /// The kernel's body, called once each frame its system runs. `pass` is valid for the call
    /// only. An error faults the run of a journaled system and is logged for a host system
    /// (`System.Mode`).
    run: *const fn (pass: *Pass) anyerror!void,

    /// The profile zone's name: the kernel's name without its `<system>.`, which the zone's
    /// scope, its system's, already shows.
    pub fn zoneName(kernel: *const Kernel) []const u8 {
        const separator = std.mem.indexOfScalar(u8, kernel.name, '.') orelse return kernel.name;
        return kernel.name[separator + 1 ..];
    }
};

/// A unit of the frame: kernels run in order over the tables the system declares each frame, with
/// an inbox table of its own (`inbox.<name>`). A plain value: its module returns it from a
/// function, and its owner puts it in a `Sequencer`'s steps. What it points at (its names, its
/// kernels and their functions) is constant data that outlives it; the system is known
/// between frames by its name alone.
pub const System = struct {
    /// Names its inbox table, and its faults; interned with its kernels' names.
    name: []const u8,
    /// Every name the system's code compares or stores as an atom, its own name among them:
    /// interned when its owner starts, with its kernels' names, so kernels name atoms by
    /// `Atom.from` and never intern. See `namesOf`.
    names: []const []const u8 = &.{},
    /// The root of the panels the system shows, which the sequencer itself does not read. An
    /// owner's `finished` hook may ask the panels under it to draw again when the system changed a
    /// table, and systems under one root divide its messages by `claims`.
    root: Atom,
    /// Whether a message with this tag is the system's to take. The sequencer does not call it: an
    /// owner does, to choose among its systems the inbox that a subscription or a request names for
    /// `tag`. `claims_nothing` for a system that takes none this way.
    claims: *const fn (tag: Atom) bool,
    /// Whether the system runs this frame with an empty inbox: false skips its `access` and
    /// its kernels, as for an editor tool whose workspace is not shown. It reads the frame's
    /// tables as the run sees them, with what earlier systems of the run appended, and must
    /// keep the system running while work it started is unfinished. A system with messages
    /// always runs; one without a guard runs every frame.
    active: ?*const fn (frame: *const Frame) bool = null,
    /// Whether the system, though active, has nothing to do this frame: true skips its
    /// `access` and kernels, and keeps what it subscribed to (`ensureSubscriptions`), where
    /// an inactive system loses it. It reads the frame's tables as `active` does. A system
    /// with messages always runs, and so does one that has not run since the subscriptions
    /// were reset; one without the check runs every frame it is active.
    idle: ?*const fn (frame: *const Frame) bool = null,
    /// Recomputed every frame, from the system's own state and its inbox.
    access: *const fn (frame: *const Frame) Access,
    /// Its kernels, run in order each frame the system runs, each with a `Pass` over the same
    /// `Frame` and the same declared tables.
    kernels: []const Kernel,
    /// Whether its kernels write through the run's journal; see `Mode`.
    mode: Mode = .journaled,

    /// How a system's kernels reach tables, and what a kernel's error does.
    pub const Mode = enum {
        /// Its tables go through the run's journal; a kernel's error faults the run.
        journaled,
        /// A host system, whose side effects cannot be undone: its kernels write tables
        /// directly, and an error is logged, never a fault. Its access is declared for
        /// reading, not enforced.
        host,
    };
};

fn noClaims(tag: Atom) bool {
    _ = tag;
    return false;
}

/// For a system that claims no messages.
pub const claims_nothing: *const fn (tag: Atom) bool = noClaims;

/// An ordered list of steps that `run` runs as one journaled run. Its owner builds it where it
/// runs it: the host's `main`, a plugin's roots, a host system's own.
pub const Sequencer = struct {
    /// Names the run's journal layer, and a fault of the run itself; interned with its
    /// systems' names.
    name: []const u8,
    /// Run in order. A system that faults ends the run and discards it; a child sequencer or a call
    /// that faults does not. The owner's storage, usually an array on its stack: it must last
    /// until the call the sequencer is handed to returns, as must a child's own steps.
    steps: []const Step,
};

/// A sequencer of one system, with the room for its step: what a host system's owner builds to
/// run that system alone. Build it into a local (`const solo = Solo.of(...)`) and hand
/// `&solo.sequencer()` on; the sequencer points into the `Solo`, which must outlast its use.
pub const Solo = struct {
    /// The sequencer's name; see `Sequencer.name`.
    name: []const u8,
    /// The one step, the system.
    steps: [1]Step,

    /// A sequencer named `name` that runs `system` alone.
    pub fn of(name: []const u8, system: System) Solo {
        return .{ .name = name, .steps = .{.{ .system = system }} };
    }

    /// The sequencer, its steps in `solo`: good while `solo` is.
    pub fn sequencer(solo: *const Solo) Sequencer {
        return .{ .name = solo.name, .steps = &solo.steps };
    }
};

/// A sequencer with the room for its `count` steps: what an owner's function returns so that
/// its start (names, inboxes) and its frames build the same steps. Keep it in a local and hand
/// `&built.sequencer()` on; the sequencer points into it, so it must outlast that use and must
/// not be copied while a sequencer made from it is in use. A step that is a child sequencer
/// names steps kept elsewhere, which must last as long.
pub fn Built(comptime count: usize) type {
    return struct {
        /// The sequencer's name; see `Sequencer.name`.
        name: []const u8,
        /// The steps, in the order they run.
        steps: [count]Step,

        /// The sequencer, its steps in `built`: good while `built` is.
        pub fn sequencer(built: *const @This()) Sequencer {
            return .{ .name = built.name, .steps = &built.steps };
        }
    };
}

/// One step of a sequencer, holding what it runs by value.
pub const Step = union(enum) {
    /// A system: its kernels run over the run's layer.
    system: System,
    /// A child sequencer, run over a layer of its own above the run's: merged into it, or discarded
    /// alone on a fault.
    sequencer: Sequencer,
    /// The owner's code, handed the run's layer; see `Call`.
    call: Call,
};

/// Code of the owner's run as a step, with the run's layer: host code that is not a system, or a
/// sequencer across the plugin boundary, which runs its own child of `layer`. It reports a fault of
/// its own; its parent goes on either way.
pub const Call = struct {
    /// Names the call's profile zone, in its sequencer's scope; interned by `internNames`.
    name: []const u8,
    /// Runs the step. `env` is the run's and `layer` its journal layer, both valid for the call
    /// only. `run` does not act on the outcome: the steps after it run either way.
    run: *const fn (env: *const Env, layer: *Layer) Outcome,
};

/// What a system's kernels touch this frame, by table name. A table written is read too.
pub const Access = struct {
    /// The table windows write the tables of up to 32 windows beside their own.
    pub const max_tables = 64;

    /// The names declared read: the first `read_count` are defined.
    reads: [max_tables]Atom = undefined,
    /// How many of `reads` are declared.
    read_count: usize = 0,
    /// The names declared written: the first `write_count` are defined.
    writes: [max_tables]Atom = undefined,
    /// How many of `writes` are declared.
    write_count: usize = 0,

    /// Declares `name` read; declaring it twice is harmless. More than `max_tables` names is an
    /// assertion failure. A table that does not exist is left out of the frame's pass:
    /// `Pass.declares` is false for it.
    pub fn read(access: *Access, name: Atom) void {
        if (std.mem.indexOfScalar(Atom, access.reads[0..access.read_count], name) != null) return;
        std.debug.assert(access.read_count < max_tables);
        access.reads[access.read_count] = name;
        access.read_count += 1;
    }

    /// Declares `name` written, which lets the kernels read it too; declaring it twice is harmless.
    /// More than `max_tables` names is an assertion failure. A table declared written that does not
    /// exist skips the system for the frame; see `writeIfPresent`.
    pub fn write(access: *Access, name: Atom) void {
        if (std.mem.indexOfScalar(Atom, access.writes[0..access.write_count], name) != null) return;
        std.debug.assert(access.write_count < max_tables);
        access.writes[access.write_count] = name;
        access.write_count += 1;
    }

    /// Declares each of `names` read.
    pub fn readAll(access: *Access, names: []const Atom) void {
        for (names) |name| access.read(name);
    }

    /// Declares each of `names` written.
    pub fn writeAll(access: *Access, names: []const Atom) void {
        for (names) |name| access.write(name);
    }

    /// Declares `name` written while the table is there: a host system's commands table,
    /// which a test without that host does not make. A table declared and missing skips the
    /// system.
    pub fn writeIfPresent(access: *Access, tables: *Table.Registry, name: Atom) void {
        if (tables.findByName(name) == null) return;
        access.write(name);
    }
};

/// What a system sees each frame: the engine's globals and its inbox.
pub const Frame = struct {
    /// The host's memory. A kernel's temporaries go in its frame scratch
    /// (`Memory.frameScratchAllocator`), valid until the host ends the frame's scratch.
    memory: *memory_mod.Memory,
    /// The atom registry, for a name's text. Kernels do not intern: a system's names are interned
    /// when its owner starts (`System.names`).
    atoms: *Atom.Registry,
    /// Every table. A journaled system's kernels reach the tables it declared through their `Pass`,
    /// which checks the declaration; `active`, `idle` and `access` read through this, and a host
    /// system's kernels may.
    tables: *Table.Registry,
    /// The messages in the system's inbox, in arrival order, their bytes in its inbox arena.
    messages: []const Message,
    /// The owner's context, as its hooks see it: what a host system needs from the host
    /// beyond tables.
    context: *anyopaque,
    /// The system the frame is for, in its sequencer's steps: good for the frame's calls.
    system: *const System,
};

/// What the owner of a sequencer hands its run.
pub const Env = struct {
    /// The host's memory: the run's journal layer and each system's messages are allocated in its
    /// frame scratch.
    memory: *memory_mod.Memory,
    /// Handed on as `Frame.atoms`; a fault's error name is interned in it.
    atoms: *Atom.Registry,
    /// The tables the run reads, writes and journals.
    tables: *Table.Registry,
    /// The owner's context, and what it does around each system.
    hooks: Hooks,
};

/// What the owner does around each system.
pub const Hooks = struct {
    /// The owner's, handed to every hook and to its call steps.
    context: *anyopaque,
    /// Before the system's kernels, each frame it runs: not when it is skipped. `leave` follows,
    /// fault or not.
    enter: *const fn (context: *anyopaque, system: *const System) void,
    /// After the system's kernels, whether they finished or one faulted; called exactly when
    /// `enter` was.
    leave: *const fn (context: *anyopaque, system: *const System) void,
    /// After its kernels ran without a fault. `changed` when the system had messages or its kernels
    /// changed a table it writes, tables of subscriptions aside; for a host system, when it had
    /// messages.
    finished: *const fn (context: *anyopaque, system: *const System, changed: bool) void,
};

/// A table's rows seen through `View`, a struct of pointers to the fields a helper reads or
/// writes: what a kernel hands its helpers in place of the tables they would look up.
pub fn Rows(comptime View: type) type {
    return struct {
        /// The table the rows are of: for rows from a `Pass`, as the run sees it.
        table: *Table,

        const Self = @This();
        /// A row's handle and its fields.
        pub const Entry = struct { handle: Table.RowHandle, view: View };

        /// For an entry point that is not a kernel, such as drawing, which reads tables itself.
        pub fn of(table: *Table) Self {
            return .{ .table = table };
        }

        /// The rows that hold every field of `View`, writable: of a table the run writes, each
        /// row handed out is copied into the run's layer. A caller that only reads uses `read`.
        pub fn query(self: Self) Table.Query(View) {
            return self.table.query(View);
        }

        /// The rows that hold every field of `View`, read-only and never copied.
        pub fn read(self: Self) Table.ReadQuery(View) {
            return self.table.readQuery(View);
        }

        /// The row `handle`, writable: of a table the run writes, the row is copied into the run's
        /// layer. Null when `handle` names no row. A caller that only reads uses `readRow`.
        pub fn get(self: Self, handle: Table.RowHandle) ?View {
            return self.table.getRow(handle, View);
        }

        /// A row, read-only and never copied.
        pub fn readRow(self: Self, handle: Table.RowHandle) ?Table.ReadView(View) {
            return self.table.readRow(handle, View);
        }

        /// How many rows the table holds, whichever fields they hold.
        pub fn count(self: Self) u32 {
            return self.table.count();
        }

        /// The first row that holds every field of `View`.
        pub fn first(self: Self) ?Entry {
            var rows = self.query();
            const found = rows.next() orelse return null;
            return .{ .handle = found.handle, .view = found.view };
        }

        /// Appends a row holding `values`, a struct of field values by name, and returns its
        /// handle; an error when the row cannot be stored.
        pub fn insert(self: Self, values: anytype) !Table.RowHandle {
            return self.table.tryInsert(values);
        }

        /// A new row with no fields present, for a caller that writes them itself.
        pub fn alloc(self: Self) !Table.RowHandle {
            return self.table.alloc();
        }

        /// Removes the row `handle`.
        pub fn free(self: Self, handle: Table.RowHandle) void {
            self.table.free(handle);
        }

        /// Removes every row of the table.
        pub fn clear(self: Self) void {
            self.table.clear();
        }
    };
}

/// The names a struct of atom constants declares, each constant `Atom.from` its own name,
/// for a system's `names`. Checked at compile time, so a constant and its name cannot drift.
pub fn namesOf(comptime Names: type) [@typeInfo(Names).@"struct".decls.len][]const u8 {
    const decls = @typeInfo(Names).@"struct".decls;
    @setEvalBranchQuota(1000 * decls.len + 1000);
    var names: [decls.len][]const u8 = undefined;
    for (decls, &names) |decl, *name| {
        if (@field(Names, decl.name) != Atom.from(decl.name)) @compileError("atom constant " ++ decl.name ++ " is not Atom.from its name");
        name.* = decl.name;
    }
    return names;
}

/// The tag names of `E`, for a system that stores `Atom.from(@tagName(value))`, or whose
/// message tags are a non-exhaustive `enum(u64)` each of whose values is `Atom.from` its own
/// name. That is checked at compile time, so a tag and its name cannot drift.
pub fn enumNames(comptime E: type) [@typeInfo(E).@"enum".fields.len][]const u8 {
    const info = @typeInfo(E).@"enum";
    const atom_valued = !info.is_exhaustive and info.tag_type == u64;
    @setEvalBranchQuota(1000 * info.fields.len + 1000);
    var names: [info.fields.len][]const u8 = undefined;
    for (info.fields, &names) |field, *name| {
        if (atom_valued and field.value != Atom.from(field.name).value()) @compileError("message tag " ++ field.name ++ " is not Atom.from its name");
        name.* = field.name;
    }
    return names;
}

/// Interns the names of the sequencer, its child sequencers and every system under them, so
/// their kernels never intern, and names their profile zones in the log: a run's is the
/// sequencer's name and a call's its own, in the sequencer's scope; a kernel's is
/// `Kernel.zoneName`, in its system's scope.
pub fn internNames(atoms: *Atom.Registry, sequencer: *const Sequencer) !void {
    try atoms.tryInternAll(&.{sequencer.name});
    const sequencer_scope = log.registerScope(sequencer.name);
    log.registerZoneName(sequencer_scope, sequencer.name);
    for (sequencer.steps) |*step| switch (step.*) {
        .system => |*system| {
            var buffer: [inbox_name_max]u8 = undefined;
            try atoms.tryInternAll(&.{ system.name, inboxName(system.*, &buffer) });
            try atoms.tryInternAll(system.names);
            const system_scope = log.registerScope(system.name);
            for (system.kernels) |kernel| {
                try atoms.tryInternAll(&.{kernel.name});
                log.registerZoneName(system_scope, kernel.zoneName());
            }
        },
        .sequencer => |*child| try internNames(atoms, child),
        .call => |call| {
            try atoms.tryInternAll(&.{call.name});
            log.registerZoneName(sequencer_scope, call.name);
        },
    };
}

// ---- system names ------------------------------------------------------------------------

/// A system's name names its inbox and its fault row, so two systems never share one. The
/// host's systems are recorded here, a row each, as their owners start; the plugin's are
/// checked against them when it loads.
pub const names_table_name = "sequencer_system_names";
const names_table = Atom.from(names_table_name);
const names_capacity = 64;
const max_named_systems = 64;

/// A system's name, and its kernels' names hashed: the same system reached through two
/// sequencers has the same kernels, a different one of the same name does not.
const NameRow = struct { system: Atom, kernels: u64 };
const NameView = struct { system: *Atom, kernels: *u64 };

fn kernelsHash(system: *const System) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (system.kernels) |kernel| {
        hasher.update(kernel.name);
        hasher.update(&.{0});
    }
    return hasher.final();
}

/// Interns the sequencer's names as `internNames` does and records its systems' names for
/// the host, refusing a name another system already has.
pub fn claimNames(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry, sequencer: *const Sequencer) !void {
    try internNames(atoms, sequencer);
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 2);
    defer schema.deinit();
    try schema.addFieldFallible("system", Atom, .atom);
    try schema.addFieldFallible("kernels", u64, .hex);
    try atoms.tryInternAll(&.{names_table_name});
    const ensured = try tables.ensure(&schema, names_capacity, names_table, .durable);
    const names = ensured.table;
    var buffer: [max_named_systems]*const System = undefined;
    for (collectSystems(sequencer, &buffer)) |system| {
        const name = Atom.from(system.name);
        const kernels = kernelsHash(system);
        if (try recordedKernels(names, name)) |recorded| {
            if (recorded != kernels) return duplicate(system);
            continue;
        }
        const row: NameRow = .{ .system = name, .kernels = kernels };
        _ = try names.tryInsert(row);
    }
}

/// Refuses a sequencer with a system named as one of the host's, or two of its own systems
/// sharing a name. Reads the host's names without writing, as a plugin loading may not.
pub fn checkNamesFree(tables: *Table.Registry, sequencer: *const Sequencer) !void {
    var buffer: [max_named_systems]*const System = undefined;
    const systems = collectSystems(sequencer, &buffer);
    for (systems, 0..) |system, index| {
        const kernels = kernelsHash(system);
        for (systems[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, system.name) and kernelsHash(earlier) != kernels) return duplicate(system);
        }
        const names = tables.findByName(names_table) orelse continue;
        if (try recordedKernels(names, Atom.from(system.name)) != null) return duplicate(system);
    }
}

fn recordedKernels(names: *Table, name: Atom) !?u64 {
    var rows = names.query(NameView);
    while (rows.next()) |row| {
        if (row.view.system.* == name) return row.view.kernels.*;
    }
    return null;
}

fn duplicate(system: *const System) error{DuplicateSystemName} {
    Log.err("duplicate_system_name", .{ .system = system.name });
    return error.DuplicateSystemName;
}

/// The systems under a sequencer, depth first, for an owner routing messages to them. The
/// pointers are into the sequencer's steps, and its children's: good while those last.
pub fn collectSystems(sequencer: *const Sequencer, into: []*const System) []*const System {
    var count: usize = 0;
    collectInto(sequencer, into, &count);
    return into[0..count];
}

fn collectInto(sequencer: *const Sequencer, into: []*const System, count: *usize) void {
    for (sequencer.steps) |*step| switch (step.*) {
        .system => |*system| {
            into[count.*] = system;
            count.* += 1;
        },
        .sequencer => |*child| collectInto(child, into, count),
        .call => {},
    };
}

/// One kernel's run: its frame and its declared tables. Valid for the kernel's call only. Its
/// methods are the way a journaled kernel reaches tables, and each reports a table the system did
/// not declare.
pub const Pass = struct {
    /// The system's frame, the same for each of its kernels.
    frame: *const Frame,
    /// The kernel being run.
    kernel: *const Kernel,
    /// The tables the system declared this frame, resolved. Kernels ask through the methods below.
    access: *const ResolvedAccess,

    fn readHandle(pass: *const Pass, name: Atom) Error!Table.Handle {
        if (pass.access.find(name)) |found| return found.handle;
        return error.UndeclaredRead;
    }

    fn writeHandle(pass: *const Pass, name: Atom) Error!Table.Handle {
        const found = pass.access.find(name) orelse return error.UndeclaredWrite;
        if (!found.writable) return error.UndeclaredWrite;
        return found.handle;
    }

    /// Whether the system declared `name` this frame, read or written.
    pub fn declares(pass: *const Pass, name: Atom) bool {
        return pass.access.find(name) != null;
    }

    /// Whether the system declared `name` written this frame.
    pub fn writes(pass: *const Pass, name: Atom) bool {
        const found = pass.access.find(name) orelse return false;
        return found.writable;
    }

    /// A table the system declared, read or written, as the run sees it: `error.UndeclaredRead`
    /// otherwise, `error.MissingTable` when it is gone.
    pub fn table(pass: *const Pass, name: Atom) Error!*Table {
        const handle = try pass.readHandle(name);
        return pass.frame.tables.get(handle) orelse error.MissingTable;
    }

    /// The row of a singleton the system declared. Of a table it reads, the row in place;
    /// of one it writes, the run's copy.
    pub fn readSingleton(pass: *const Pass, name: Atom, comptime View: type) Error!View {
        const found = try pass.table(name);
        return found.getRow(.{ .row = 0, .generation = found.rowGeneration(0) }, View) orelse error.MissingTable;
    }

    /// The run's copy of the row of a singleton the system writes.
    pub fn writeSingleton(pass: *Pass, name: Atom, comptime View: type) Error!View {
        const handle = try pass.writeHandle(name);
        const found = pass.frame.tables.get(handle) orelse return error.MissingTable;
        return found.getRow(.{ .row = 0, .generation = found.rowGeneration(0) }, View) orelse error.MissingTable;
    }

    /// A table the system reads, as rows of `View`.
    pub fn rows(pass: *const Pass, name: Atom, comptime View: type) Error!Rows(View) {
        return .{ .table = try pass.table(name) };
    }

    /// A table the system writes, as rows of `View`; what the kernel writes, appends or
    /// removes through them a fault takes back.
    pub fn writeRows(pass: *Pass, name: Atom, comptime View: type) Error!Rows(View) {
        const handle = try pass.writeHandle(name);
        return .{ .table = pass.frame.tables.get(handle) orelse return error.MissingTable };
    }

    /// A table the system writes, for a helper that writes its rows, as one that copies a
    /// row's slices into the table's payloads; a fault takes back what it writes.
    pub fn writeTable(pass: *Pass, name: Atom) Error!*Table {
        const handle = try pass.writeHandle(name);
        return pass.frame.tables.get(handle) orelse error.MissingTable;
    }

    /// Appends a row of `values` to a table the system writes.
    pub fn append(pass: *Pass, name: Atom, values: anytype) Error!Table.RowHandle {
        const handle = try pass.writeHandle(name);
        const found = pass.frame.tables.get(handle) orelse return error.MissingTable;
        return found.tryInsert(values) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.MissingTable,
        };
    }
};

/// A system's access for one frame, its names resolved to tables.
pub const ResolvedAccess = struct {
    /// A declared table: its name, its handle, and whether it was declared written.
    pub const Entry = struct { name: Atom, handle: Table.Handle, writable: bool };

    /// The tables declared written, then those only read: the first `count` are defined.
    entries: [2 * Access.max_tables]Entry = undefined,
    /// How many of `entries` are defined.
    count: usize = 0,

    fn find(resolved: *const ResolvedAccess, name: Atom) ?Entry {
        for (resolved.entries[0..resolved.count]) |entry| {
            if (entry.name == name) return entry;
        }
        return null;
    }

    /// Null when a table declared written does not exist, and the system cannot run. A table
    /// declared read that does not exist is left out: a kernel finds it undeclared.
    fn resolve(tables: *Table.Registry, access: *const Access) ?ResolvedAccess {
        var resolved: ResolvedAccess = .{};
        for (access.writes[0..access.write_count]) |name| {
            const handle = tables.findHandleByName(name) orelse return null;
            resolved.entries[resolved.count] = .{ .name = name, .handle = handle, .writable = true };
            resolved.count += 1;
        }
        for (access.reads[0..access.read_count]) |name| {
            if (resolved.find(name) != null) continue;
            const handle = tables.findHandleByName(name) orelse continue;
            resolved.entries[resolved.count] = .{ .name = name, .handle = handle, .writable = false };
            resolved.count += 1;
        }
        return resolved;
    }
};

// ---- runs -------------------------------------------------------------------------------

/// How a run or a call step ended. `done`: a run's layer was merged into its parent's, or flushed
/// into the tables for the root. `faulted`: it was discarded, and a run's fault is in the faults
/// table (`faults_table_name`).
pub const Outcome = enum { done, faulted };

/// Runs the sequencer's steps over a layer of `parent`'s, or of the tables for the root, and merges
/// or flushes it, or discards it on a fault. An owner calls it, never a kernel: the names must be
/// interned (`internNames`), and before a root's run the owner calls `beginFrame`. The layer lives
/// in the frame's scratch and is gone when this returns. `faulted` when a system of the sequencer
/// faulted, or the run itself could not start or end; the fault is recorded.
pub fn run(sequencer: *const Sequencer, env: *const Env, parent: ?*Layer) Outcome {
    // A run's zone is named for its sequencer, in its scope, as `internNames` names it.
    const sequencer_scope = log.scopeTag(sequencer.name);
    const run_zone = log.beginNamedZone(sequencer_scope, sequencer.name);
    defer run_zone.end();
    const name = Atom.from(sequencer.name);
    const scratch = env.memory.frameScratchArena() catch |err| {
        recordFault(env, name, null, err);
        return .faulted;
    };
    var layer = Layer.init(scratch, env.tables, parent, name);
    defer layer.deinit();
    for (sequencer.steps) |*step| switch (step.*) {
        .system => |*system| {
            if (runSystem(&layer, env, system) == .faulted) {
                layer.discard();
                return .faulted;
            }
        },
        // A child that faults has discarded its own run; this one goes on.
        .sequencer => |*child| _ = run(child, env, &layer),
        .call => |call| {
            const call_zone = log.beginNamedZone(sequencer_scope, call.name);
            defer call_zone.end();
            _ = call.run(env, &layer);
        },
    };
    const ended = if (parent == null) layer.flush() else layer.merge();
    ended catch |err| {
        recordFault(env, name, null, err);
        layer.discard();
        return .faulted;
    };
    return .done;
}

fn runSystem(layer: *Layer, env: *const Env, system: *const System) Outcome {
    // Its place in the frame, whether it runs or not.
    const ordinal = env.tables.systems_visited;
    env.tables.systems_visited +%= 1;
    if (system.mode == .host) {
        runHostSystem(env, system);
        return .done;
    }
    const name = Atom.from(system.name);
    var name_buffer: [inbox_name_max]u8 = undefined;
    const inbox_table = env.tables.findHandleByName(Atom.from(inboxName(system.*, &name_buffer)));
    // The inbox is the system's to clear, through the layer, so a fault leaves it.
    if (inbox_table) |handle| layer.attach(handle, .write) catch |err| {
        layer.detach();
        recordFault(env, name, null, err);
        return .faulted;
    };
    const messages = readInbox(env, inbox_table) catch |err| {
        layer.detach();
        recordFault(env, name, null, err);
        return .faulted;
    };
    // What the run already wrote is seen by `access` too, as a request an earlier system of
    // the run appended for this one.
    layer.attachTouched() catch |err| {
        layer.detach();
        recordFault(env, name, null, err);
        return .faulted;
    };
    const frame = systemFrame(env, system, messages);
    switch (runsThisFrame(system, &frame)) {
        .runs => {},
        .idle => {
            layer.detach();
            return .done;
        },
        // Switched off, it hears nothing: what it subscribed to goes.
        .inactive => {
            dropSubscriptions(layer, env.tables, name) catch |err| {
                layer.detach();
                recordFault(env, name, null, err);
                return .faulted;
            };
            layer.detach();
            return .done;
        },
    }
    const access = system.access(&frame);
    // A table it writes is gone, as while the editor's tables are being replaced.
    const resolved = ResolvedAccess.resolve(env.tables, &access) orelse {
        layer.detach();
        return .done;
    };
    for (resolved.entries[0..resolved.count]) |entry| {
        layer.attach(entry.handle, if (entry.writable) .write else .read) catch |err| {
            layer.detach();
            recordFault(env, name, null, err);
            return .faulted;
        };
    }
    defer layer.detach();
    // Its run subscribes anew: what it subscribed to before goes, through the run, so a
    // fault keeps it.
    dropSubscriptions(layer, env.tables, name) catch |err| {
        recordFault(env, name, null, err);
        return .faulted;
    };
    env.hooks.enter(env.hooks.context, system);
    defer env.hooks.leave(env.hooks.context, system);
    const system_scope = log.scopeTag(system.name);
    for (system.kernels) |*kernel| {
        const kernel_zone = log.beginNamedZone(system_scope, kernel.zoneName());
        defer kernel_zone.end();
        var pass: Pass = .{ .frame = &frame, .kernel = kernel, .access = &resolved };
        kernel.run(&pass) catch |err| {
            recordFault(env, name, kernel, err);
            return .faulted;
        };
        // A table access that could not report its error to the kernel faults it here.
        if (layer.failure) |failure| {
            recordFault(env, name, kernel, failure);
            return .faulted;
        }
    }
    // Every kernel had the inbox; it is spent.
    if (inbox_table) |handle| if (env.tables.get(handle)) |found| found.clear();
    if (layer.failure) |failure| {
        recordFault(env, name, null, failure);
        return .faulted;
    }
    claimSubscriptions(env.tables, name, ordinal);
    // A system that heard something draws again. What it subscribes to is not something it
    // shows.
    var changed = messages.len != 0;
    for (resolved.entries[0..resolved.count]) |entry| {
        if (!entry.writable or isSubscriptions(env.tables, entry.handle)) continue;
        if (layer.differs(entry.handle)) changed = true;
    }
    noteSubscribed(env.tables, name);
    if (changed) env.tables.activity +%= 1;
    clearFaults(env.tables, name);
    env.hooks.finished(env.hooks.context, system, changed);
    return .done;
}

const Runs = enum { runs, idle, inactive };

/// A system runs when it has messages, or is active and not idle. One that has not run since
/// the subscriptions were reset is never idle: it has to subscribe again.
fn runsThisFrame(system: *const System, frame: *const Frame) Runs {
    if (frame.messages.len != 0) return .runs;
    if (system.active) |active| {
        if (!active(frame)) return .inactive;
    }
    const idle = system.idle orelse return .runs;
    if (!ranSinceReset(frame.tables, Atom.from(system.name))) return .runs;
    return if (idle(frame)) .idle else .runs;
}

// ---- subscriptions ------------------------------------------------------------------------

/// The name of the table that lists the tables of subscriptions, a row each (`table`). Tables of
/// subscriptions hold rows systems append in their runs, each naming its subscriber in
/// a `subscriber` column and its place in a `subscription_order` column, which the sequencer
/// fills. A system's rows last until it runs again, which replaces them, or is switched off,
/// which drops them; a system that does not run keeps them. Readers walk them in order: the
/// order systems come in a frame, then the order each appended its rows, as when every
/// system appended its own every frame (`orderSubscriptions`). The host empties every one of
/// them with `resetSubscriptions`, as when a plugin loads, after which every system runs to
/// subscribe again.
pub const subscription_tables_name = "sequencer_subscription_tables";
const subscription_tables = Atom.from(subscription_tables_name);
const SubscriptionTableView = struct { table: *Atom };

/// The name of the table of each system's last run since the subscriptions were last reset
/// (`system`, `epoch`): `epoch` is the reset it subscribed after. The row with no system holds the
/// latest reset's.
pub const subscribers_table_name = "sequencer_subscribers";
const subscribers_table = Atom.from(subscribers_table_name);
const SubscriberView = struct { system: *Atom, epoch: *u64 };

/// The atom column of a table of subscriptions that names the system whose run appended the row.
/// The sequencer fills it when that system's run finishes.
pub const subscriber_field = "subscriber";
/// The `u32` column of a table of subscriptions that places a row among everyone's: its
/// subscriber's place in the frame in the high 16 bits, the row's place among that subscriber's in
/// the low. The sequencer fills it; `orderSubscriptions` sorts by it.
pub const subscription_order_field = "subscription_order";
const SubscriberCell = struct { subscriber: *Atom };

/// Records `name`, made with a `subscriber` atom column and a `subscription_order` column, as a
/// table of subscriptions, and makes the two tables that keep track of them unless they are there.
/// Called when the table's owner starts, outside any run; `Subscribed(T).ensure` calls it.
pub fn ensureSubscriptions(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry, comptime name: []const u8) !void {
    try atoms.tryInternAll(&.{ subscription_tables_name, subscribers_table_name, subscriber_field, subscription_order_field });
    var list: Table.Schema = undefined;
    try list.init(scratch.allocator, atoms, 1);
    defer list.deinit();
    try list.addFieldFallible("table", Atom, .atom);
    const listed = (try tables.ensure(&list, 8, subscription_tables, .durable)).table;

    var subscribers: Table.Schema = undefined;
    try subscribers.init(scratch.allocator, atoms, 2);
    defer subscribers.deinit();
    try subscribers.addFieldFallible("system", Atom, .atom);
    try subscribers.addFieldFallible("epoch", u64, .int);
    const known = (try tables.ensure(&subscribers, 2 * max_named_systems, subscribers_table, .durable)).table;
    if (subscriberRow(known, no_atom) == null) _ = try known.tryInsert(.{ .system = no_atom, .epoch = @as(u64, 1) });

    const table_name = Atom.from(name);
    var rows = listed.readQuery(SubscriptionTableView);
    while (rows.next()) |row| if (row.view.table.* == table_name) return;
    _ = try listed.tryInsert(.{ .table = table_name });
}

fn subscriberRow(known: *Table, system: Atom) ?SubscriberView {
    var rows = known.query(SubscriberView);
    while (rows.next()) |row| if (row.view.system.* == system) return row.view;
    return null;
}

/// Whether `handle` is a table of subscriptions.
fn isSubscriptions(tables: *Table.Registry, handle: Table.Handle) bool {
    const listed = tables.findByName(subscription_tables) orelse return false;
    const table = tables.get(handle) orelse return false;
    var rows = listed.readQuery(SubscriptionTableView);
    while (rows.next()) |row| if (row.view.table.* == table.name) return true;
    return false;
}

/// Removes `system`'s rows from every table of subscriptions, through `layer`.
fn dropSubscriptions(layer: *Layer, tables: *Table.Registry, system: Atom) !void {
    const listed = tables.findByName(subscription_tables) orelse return;
    var names = listed.readQuery(SubscriptionTableView);
    while (names.next()) |entry| {
        const handle = tables.findHandleByName(entry.view.table.*) orelse continue;
        try layer.attach(handle, .write);
        const table = tables.get(handle) orelse continue;
        var found: [64]Table.RowHandle = undefined;
        while (true) {
            var count: usize = 0;
            var rows = table.readQuery(SubscriberCell);
            while (rows.next()) |row| {
                if (row.view.subscriber.* != system) continue;
                found[count] = row.handle;
                count += 1;
                if (count == found.len) break;
            }
            for (found[0..count]) |row| table.free(row);
            // The bytes the rows named are dead: shed once no run holds the table.
            if (count != 0) table.compact_payloads_wanted = true;
            if (count < found.len) break;
        }
    }
}

/// Names `system` the subscriber of the rows its kernels appended to the tables of
/// subscriptions, and places them at the system's `ordinal` in the frame. They are the rows
/// the run appended that name no subscriber: every system before it in the run named its own
/// as it finished, and rows from earlier frames all name theirs.
fn claimSubscriptions(tables: *Table.Registry, system: Atom, ordinal: u32) void {
    const listed = tables.findByName(subscription_tables) orelse return;
    var names = listed.readQuery(SubscriptionTableView);
    while (names.next()) |entry| {
        const table = tables.findByName(entry.view.table.*) orelse continue;
        const run_journal = table.journal orelse continue;
        const field = table.getSchema().fieldIndex(subscriber_field) orelse continue;
        const bit = table.getSchema().fields[field].bit;
        var appended: u32 = 0;
        var index: usize = 0;
        while (run_journal.vtable.inserted(run_journal.context, table, index)) |row| : (index += 1) {
            if (table.rowHas(row.row, bit)) continue;
            // A row the run appended and removed again is gone: nothing to name.
            table.writeFieldSingle(Atom, row, subscriber_field, system) catch continue;
            const place = (@as(u32, @min(ordinal, std.math.maxInt(u16))) << 16) | @min(appended, max_rows_per_subscriber - 1);
            table.writeFieldSingle(u32, row, subscription_order_field, place) catch continue;
            appended += 1;
        }
    }
}

fn currentEpoch(known: *Table) u64 {
    const latest = subscriberRow(known, no_atom) orelse return 0;
    return latest.epoch.*;
}

/// Whether `system` has said what it subscribes to now: it has run since the subscriptions
/// were last reset (`resetSubscriptions`), or it was retired (`retireSubscribers`) and has not
/// run since, and subscribes to nothing. A host system that follows a table of subscriptions
/// asks before it takes a row's absence to mean its subscriber dropped it. True where no
/// table of subscriptions was ever made.
pub fn subscribedSinceReset(tables: *Table.Registry, system: Atom) bool {
    const known = tables.findByName(subscribers_table) orelse return true;
    const row = subscriberRow(known, system) orelse return false;
    return row.epoch.* == currentEpoch(known) or row.epoch.* == retired_epoch;
}

/// The epoch of a system that was retired and has not run since: no reset reaches it.
const retired_epoch = std.math.maxInt(u64);

/// Whether `system` has run since the subscriptions were last reset. True where no table of
/// subscriptions was ever made.
fn ranSinceReset(tables: *Table.Registry, system: Atom) bool {
    const known = tables.findByName(subscribers_table) orelse return true;
    const row = subscriberRow(known, system) orelse return false;
    return row.epoch.* == currentEpoch(known);
}

/// Records that `system` ran, and so subscribed, since the latest reset. Outside the run's
/// journal: a run that faults after this still ran.
fn noteSubscribed(tables: *Table.Registry, system: Atom) void {
    const known = tables.findByName(subscribers_table) orelse return;
    std.debug.assert(known.journal == null);
    recordEpoch(known, system, currentEpoch(known));
}

/// Records that `system` was retired: it subscribes to nothing, through any reset, until it
/// next runs.
fn noteRetired(tables: *Table.Registry, system: Atom) void {
    const known = tables.findByName(subscribers_table) orelse return;
    std.debug.assert(known.journal == null);
    recordEpoch(known, system, retired_epoch);
}

/// Writes `system`'s row of `known`, the table of subscribers, making it if there is none.
fn recordEpoch(known: *Table, system: Atom, epoch: u64) void {
    if (subscriberRow(known, system)) |row| {
        row.epoch.* = epoch;
        return;
    }
    _ = known.tryInsert(.{ .system = system, .epoch = epoch }) catch |err| {
        Log.err("subscriber_unrecorded", .{ .@"error" = @errorName(err) });
    };
}

/// A system's rows past this many share the last place.
const max_rows_per_subscriber = 1 << 16;

/// As a frame's runs begin: systems are counted from the first again. The owner of the root
/// sequencer calls it before each root `run`.
pub fn beginFrame(tables: *Table.Registry) void {
    tables.systems_visited = 0;
}

/// Says the systems of `retired`, and of its child sequencers, subscribe to nothing until
/// they next run, outside any run: their rows go from every table of subscriptions, and each
/// counts as having said what it subscribes to (`subscribedSinceReset`) through any reset, so
/// a host system that follows a table takes their rows' absence as dropped, not as yet to
/// come. A plugin calls it for each of its sequencers as it is let go for good
/// (`plugin_deinit`): without it, what its systems declared, a panel among them, would stand
/// for want of a run of theirs to say otherwise. A system that runs again, as when the plugin
/// is loaded once more, subscribes as any other.
pub fn retireSubscribers(tables: *Table.Registry, retired: *const Sequencer) void {
    for (retired.steps) |*step| switch (step.*) {
        .system => |*system| {
            const name = Atom.from(system.name);
            removeSubscriptions(tables, name);
            noteRetired(tables, name);
        },
        .sequencer => |*child| retireSubscribers(tables, child),
        .call => {},
    };
}

/// Removes `system`'s rows from every table of subscriptions, outside any run.
fn removeSubscriptions(tables: *Table.Registry, system: Atom) void {
    const listed = tables.findByName(subscription_tables) orelse return;
    var names = listed.readQuery(SubscriptionTableView);
    while (names.next()) |entry| {
        const table = tables.findByName(entry.view.table.*) orelse continue;
        var found: [64]Table.RowHandle = undefined;
        while (true) {
            var count: usize = 0;
            var rows = table.readQuery(SubscriberCell);
            while (rows.next()) |row| {
                if (row.view.subscriber.* != system) continue;
                found[count] = row.handle;
                count += 1;
                if (count == found.len) break;
            }
            for (found[0..count]) |row| table.free(row);
            // The bytes the rows named are dead: shed once no run holds the table.
            if (count != 0) table.compact_payloads_wanted = true;
            if (count < found.len) break;
        }
    }
}

/// Puts each table of subscriptions in its readers' order, outside any run: after a frame's
/// runs, whose replaced rows took the places of others.
pub fn orderSubscriptions(tables: *Table.Registry) void {
    const listed = tables.findByName(subscription_tables) orelse return;
    var names = listed.readQuery(SubscriptionTableView);
    while (names.next()) |entry| {
        const table = tables.findByName(entry.view.table.*) orelse continue;
        const field = table.getSchema().fieldIndex(subscription_order_field) orelse continue;
        table.sortByU32(@intCast(field));
    }
}

/// Empties every table of subscriptions, outside any run, and has every system run again to
/// subscribe: for the host, when systems come or go, as a plugin loading or the game stopping.
pub fn resetSubscriptions(tables: *Table.Registry) void {
    const listed = tables.findByName(subscription_tables) orelse return;
    var names = listed.readQuery(SubscriptionTableView);
    while (names.next()) |entry| {
        const table = tables.findByName(entry.view.table.*) orelse continue;
        table.clear();
    }
    const known = tables.findByName(subscribers_table) orelse return;
    const latest = subscriberRow(known, no_atom) orelse return;
    latest.epoch.* +%= 1;
}

// ---- inboxes ----------------------------------------------------------------------------

const inbox_name_max = 96;

/// The system's inbox table's name, `inbox.<system>`, written into `buffer`, which the result
/// points into: named for what it is first, so it stays clear of the prefixes that say which owner
/// a table belongs to. A system's name must leave it within the buffer.
pub fn inboxName(system: System, buffer: *[inbox_name_max]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "inbox.{s}", .{system.name}) catch unreachable;
}

/// The system's inbox table's name, for a command or subscription that names where its
/// replies go.
pub fn inboxOf(system: System) Atom {
    var buffer: [inbox_name_max]u8 = undefined;
    return Atom.from(inboxName(system, &buffer));
}

/// A message in a system's inbox: the tag its kernels take it by, the sender's payload, and
/// the user data the receiver gave where it asked for the message, each empty when the row
/// holds none. The bytes are the inbox arena's until the inbox is next found empty: a kernel
/// copies what it keeps.
pub const Message = struct {
    /// What the message is: the receiver's kernels switch on it.
    tag: Atom,
    /// The sender's bytes, empty for none; `payloadAs` reads them as the type the tag carries.
    payload: []const u8 = &.{},
    /// The bytes the receiver gave where it asked for the message, empty for none; `userDataAs`
    /// reads them as the type it gave.
    user_data: []const u8 = &.{},

    /// The payload as the `T` the receiver knows its tag carries; an error when its length
    /// is not `T`'s.
    pub fn payloadAs(received: Message, comptime T: type) error{MessageShape}!*const T {
        return bytesAs(T, received.payload);
    }

    /// The user data as the `T` the receiver gave; an error when its length is not `T`'s.
    pub fn userDataAs(received: Message, comptime T: type) error{MessageShape}!*const T {
        return bytesAs(T, received.user_data);
    }

    /// Logs a message its receiver could not read, which it then skips: a fault would leave
    /// it in the inbox to fail again every frame.
    pub fn unreadable(received: Message, err: anyerror) void {
        Log.warn("message_unreadable", .{ .tag = received.tag, .@"error" = @errorName(err) });
    }
};

/// `bytes`, from an inbox arena's bytes cell, which is aligned for any value, as a `T`.
fn bytesAs(comptime T: type, bytes: []const u8) error{MessageShape}!*const T {
    comptime std.debug.assert(@sizeOf(T) != 0);
    comptime std.debug.assert(@alignOf(T) <= Table.bytes_alignment.toByteUnits());
    if (bytes.len != @sizeOf(T)) return error.MessageShape;
    return @ptrCast(@alignCast(bytes.ptr));
}

/// Bytes a receiver gives where it asks for messages (a subscription, a hit region, a
/// request's `ReplyTo`), which come back unchanged as each message's `user_data`. Any length,
/// none by default. In a command or subscription table it is an opaque bytes column, where a
/// plain slice of bytes would be text.
pub const UserData = struct {
    /// The bytes: borrowed from whoever made the value, or the table's when it was read back from a
    /// row.
    bytes: []const u8 = &.{},

    /// No user data.
    pub const none: UserData = .{};

    /// The bytes of the value `pointer` points at, borrowed: they must live until what
    /// holds them is stored, which copies them.
    pub fn of(pointer: anytype) UserData {
        return .{ .bytes = std.mem.asBytes(pointer) };
    }
};

/// The rows of an inbox table a reader takes: those whose tag is present. A taken row loses
/// its tag, so the rows keep their arrival order until the inbox is cleared.
const InboxEntry = struct { tag: *Atom };

/// The bytes of the payload cell `name` of an inbox row, empty when the row holds none: read
/// as the run sees the row, through an attached journal.
fn inboxCellBytes(inbox: *const Table, row: u32, mask: Table.Mask, comptime name: []const u8) []const u8 {
    const schema = inbox.getSchema();
    const field = &schema.fields[schema.fieldIndex(name).?];
    if (!mask.has(field.bit)) return &.{};
    const cell = inbox.cellBytes(row, field);
    const payload = std.mem.bytesToValue(Table.Payload, cell[0..@sizeOf(Table.Payload)]);
    return inbox.payloadBytes(payload);
}

/// The message of the inbox row `row`, whose tag is `tag`.
fn inboxMessageAt(inbox: *const Table, row: u32, tag: Atom) Message {
    const mask = inbox.rowMask(row);
    return .{
        .tag = tag,
        .payload = inboxCellBytes(inbox, row, mask, "payload"),
        .user_data = inboxCellBytes(inbox, row, mask, "user_data"),
    };
}

/// The oldest message in `inbox` not taken yet, which this marks taken. For a test or a host
/// reading an inbox outside any run.
pub fn takeOldest(inbox: *Table) ?Message {
    std.debug.assert(inbox.journal == null);
    var rows = inbox.query(InboxEntry);
    const row = rows.next() orelse return null;
    const tag = row.view.tag.*;
    const tag_field = inbox.getSchema().fieldIndex("tag").?;
    inbox.setPresent(row.handle.row, inbox.getSchema().fields[tag_field].bit, false);
    return inboxMessageAt(inbox, row.handle.row, tag);
}

/// Up to `into.len` of the messages in `inbox` not taken yet, in arrival order, leaving them
/// there. For a test or a host reading an inbox outside any run.
pub fn peekMessages(inbox: *Table, into: []Message) []Message {
    var count: usize = 0;
    var rows = inbox.readQuery(InboxEntry);
    while (rows.next()) |row| {
        if (count == into.len) break;
        into[count] = inboxMessageAt(inbox, row.handle.row, row.view.tag.*);
        count += 1;
    }
    return into[0..count];
}

/// Whether `inbox` holds a message not taken yet.
pub fn hasUntakenMessage(inbox: *Table) bool {
    var rows = inbox.readQuery(InboxEntry);
    return rows.next() != null;
}

/// Makes the inbox table of every system under the sequencer, unless it is there, and interns its
/// name. An owner calls it when it starts, outside any run.
pub fn ensureInboxes(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry, sequencer: *const Sequencer) !void {
    for (sequencer.steps) |*step| switch (step.*) {
        .system => |*system| {
            var schema: Table.Schema = undefined;
            try schema.init(scratch.allocator, atoms, 3);
            defer schema.deinit();
            try schema.addFieldFallible("tag", Atom, .atom);
            try schema.addFieldFallible("payload", Table.Bytes, .bytes);
            try schema.addFieldFallible("user_data", Table.Bytes, .bytes);
            var buffer: [inbox_name_max]u8 = undefined;
            const name = inboxName(system.*, &buffer);
            try atoms.tryInternAll(&.{name});
            _ = try tables.ensure(&schema, 64, Atom.from(name), .durable);
        },
        .sequencer => |*child| try ensureInboxes(scratch, atoms, tables, child),
        .call => {},
    };
}

/// Appends a message under `tag` to the inbox table named `inbox`, as a host system does for
/// the inbox a command or subscription named, outside any run: copies of `user_data` and
/// `payload`, each absent when empty, kept in the inbox table while the message waits there,
/// through a faulted run's retry.
pub fn deliverMessage(tables: *Table.Registry, inbox: Atom, tag: Atom, user_data: []const u8, payload: []const u8) !void {
    tables.activity +%= 1;
    const table = tables.findByName(inbox) orelse return error.MissingInbox;
    std.debug.assert(table.journal == null);
    // Every message the arena held has been handled.
    table.resetPayloadsIfEmpty();
    const handle = try table.tryInsert(.{ .tag = tag });
    errdefer table.free(handle);
    if (payload.len != 0) try table.setBytes(handle, "payload", payload);
    if (user_data.len != 0) try table.setBytes(handle, "user_data", user_data);
}

/// As `deliverMessage`, the payload `head` followed by `trailing`, written once into the
/// inbox's arena: for a message carrying bytes after a fixed head. `head` is not empty.
pub fn deliverMessageCarrying(tables: *Table.Registry, inbox: Atom, tag: Atom, user_data: []const u8, head: []const u8, trailing: []const u8) !void {
    tables.activity +%= 1;
    std.debug.assert(head.len != 0);
    const table = tables.findByName(inbox) orelse return error.MissingInbox;
    std.debug.assert(table.journal == null);
    // Every message the arena held has been handled.
    table.resetPayloadsIfEmpty();
    const payload = try table.allocatePayload(head.len + trailing.len, Table.bytes_alignment);
    const bytes = table.payloadBytesMut(payload);
    @memcpy(bytes[0..head.len], head);
    @memcpy(bytes[head.len..], trailing);
    const handle = try table.tryInsert(.{ .tag = tag, .payload = Table.Bytes{ .payload = payload } });
    errdefer table.free(handle);
    if (user_data.len != 0) try table.setBytes(handle, "user_data", user_data);
}

/// The bytes of a message's payload `value`, a value of the type the receiver knows its tag
/// carries; none for void.
fn payloadBytesOf(value: anytype) []const u8 {
    if (@TypeOf(value.*) == void) return &.{};
    return std.mem.asBytes(value);
}

/// What a host system delivers to systems' inboxes with: the host's memory and tables. Delivery
/// needs only the tables. It is for host code outside any journaled run, which a delivery asserts:
/// a journaled kernel asks through a commands table and never delivers.
pub const Inboxes = struct {
    /// The host's memory, for a holder that needs its scratch beside the tables.
    memory: *memory_mod.Memory,
    /// The tables the inboxes are in.
    tables: *Table.Registry,

    /// Delivers a message under `tag` to `inbox`: `user_data` as the receiver gave it, and
    /// `payload`, a value of the type the receiver knows the tag carries, or void for none. A
    /// delivery that fails is logged, not retried.
    pub fn send(inboxes: Inboxes, inbox: Atom, tag: Atom, user_data: []const u8, payload: anytype) void {
        inboxes.trySend(inbox, tag, user_data, payload) catch |err| {
            Log.err("inbox_delivery_failed", .{ .@"error" = @errorName(err) });
        };
    }

    /// As `send`, the error returned for the host to deliver again later.
    pub fn trySend(inboxes: Inboxes, inbox: Atom, tag: Atom, user_data: []const u8, payload: anytype) !void {
        try deliverMessage(inboxes.tables, inbox, tag, user_data, payloadBytesOf(&payload));
    }

    /// Answers a request where `reply_to` names, under its tag with its user data: `payload`
    /// a value of the type the requester knows the tag carries. Nothing when it names no
    /// inbox, as a request that wants no reply. A delivery that fails is logged.
    pub fn answer(inboxes: Inboxes, reply_to: ReplyTo, payload: anytype) void {
        inboxes.tryAnswer(reply_to, payload) catch |err| {
            Log.err("inbox_delivery_failed", .{ .@"error" = @errorName(err) });
        };
    }

    /// Answers a request where `reply_to` names with `bytes` as the payload, as text the
    /// requester asked for; none when empty. The error is returned for the host to answer
    /// again later.
    pub fn tryAnswerBytes(inboxes: Inboxes, reply_to: ReplyTo, bytes: []const u8) !void {
        if (reply_to.inbox == no_inbox) return;
        try deliverMessage(inboxes.tables, reply_to.inbox, reply_to.tag, reply_to.user_data.bytes, bytes);
    }

    /// Answers a request where `reply_to` names with a payload of `head`'s bytes, a value of
    /// the fixed type the requester reads first, followed by `trailing`. The error is returned
    /// for the host to answer again later.
    pub fn tryAnswerCarrying(inboxes: Inboxes, reply_to: ReplyTo, head: anytype, trailing: []const u8) !void {
        if (reply_to.inbox == no_inbox) return;
        const head_bytes = std.mem.asBytes(&head);
        try deliverMessageCarrying(inboxes.tables, reply_to.inbox, reply_to.tag, reply_to.user_data.bytes, head_bytes, trailing);
    }

    /// As `answer`, the error returned for the host to answer again later.
    pub fn tryAnswer(inboxes: Inboxes, reply_to: ReplyTo, payload: anytype) !void {
        if (reply_to.inbox == no_inbox) return;
        try inboxes.trySend(reply_to.inbox, reply_to.tag, reply_to.user_data.bytes, payload);
    }

    /// The table named `name`, or null when there is none. The name is hashed on each call.
    pub fn table(inboxes: Inboxes, name: []const u8) ?*Table {
        return inboxes.tables.findByName(Atom.from(name));
    }
};

/// Where a host system's reply to a request goes: the requester's inbox, and the tag the
/// reply arrives under there. A command's columns show both by name.
pub const ReplyTo = struct {
    /// The requester's inbox table's name (`inboxOf`); `no_inbox` for a request that wants no
    /// reply.
    inbox: Atom = no_inbox,
    /// The tag the reply arrives under.
    tag: Atom = no_inbox,
    /// The requester's own bytes, which come back as the reply's user data: which of its editors or
    /// targets asked. Borrowed until the request holding it is stored, which
    /// copies it; a host that keeps the reply past the request's row keeps a copy of its own
    /// (`dupe`).
    user_data: UserData = .none,

    /// A copy with `user_data` in place of its own. The bytes stay borrowed.
    pub fn with(reply_to: ReplyTo, user_data: UserData) ReplyTo {
        var given = reply_to;
        given.user_data = user_data;
        return given;
    }

    /// A copy whose user data is `allocator`'s, for a host that keeps the reply after the
    /// request's row is gone; `free` it with the same allocator.
    pub fn dupe(reply_to: ReplyTo, allocator: std.mem.Allocator) error{OutOfMemory}!ReplyTo {
        var kept = reply_to;
        kept.user_data = .{ .bytes = try allocator.dupe(u8, reply_to.user_data.bytes) };
        return kept;
    }

    /// Frees the user data of a copy made by `dupe`.
    pub fn free(reply_to: ReplyTo, allocator: std.mem.Allocator) void {
        allocator.free(reply_to.user_data.bytes);
    }

    /// Whether both name the same inbox and tag, with the same user data.
    pub fn eql(reply_to: ReplyTo, other: ReplyTo) bool {
        if (reply_to.inbox != other.inbox or reply_to.tag != other.tag) return false;
        return std.mem.eql(u8, reply_to.user_data.bytes, other.user_data.bytes);
    }

    /// The message an answer with `payload` delivers, as a test hands it to the receiver
    /// without an inbox. It borrows `payload` and the user data.
    pub fn answered(reply_to: ReplyTo, payload: []const u8) Message {
        return .{ .tag = reply_to.tag, .payload = payload, .user_data = reply_to.user_data.bytes };
    }

    /// To the system's own inbox, under `tag`.
    pub fn of(system: System, tag: Atom) ReplyTo {
        return .{ .inbox = inboxOf(system), .tag = tag };
    }
};

fn testInboxAccess(frame: *const Frame) Access {
    _ = frame;
    return .{};
}

/// The system a test's inbox belongs to; it runs nothing.
fn testInboxSystem() System {
    return .{ .name = "test_inbox", .root = Atom.from("test_inbox"), .claims = claims_nothing, .access = testInboxAccess, .kernels = &.{} };
}

/// A test's inbox, which the subscriptions and requests a test gives it name: the messages
/// delivered to it, taken in the order they came (`pop`).
pub const TestInbox = struct {
    /// The tables its inbox is in.
    tables: *Table.Registry,
    /// Its inbox table's name: what a test gives as the inbox of a subscription or a request.
    inbox: Atom,

    /// Makes the test's inbox table, `inbox.test_inbox`, in `tables`, unless it is there. It takes
    /// the table scratch.
    pub fn init(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !TestInbox {
        const receivers: Sequencer = .{ .name = "test_inbox_sequencer", .steps = &.{.{ .system = testInboxSystem() }} };
        try ensureInboxes(try memory.tableScratchAllocator(), atoms, tables, &receivers);
        return .{ .tables = tables, .inbox = inboxOf(testInboxSystem()) };
    }

    /// Replies to the inbox under `tag`.
    pub fn reply(test_inbox: TestInbox, tag: Atom) ReplyTo {
        return .{ .inbox = test_inbox.inbox, .tag = tag };
    }

    /// The oldest message not taken yet, which this marks taken; null when there is none. Its bytes
    /// are the inbox table's: copy what must outlive `reset`.
    pub fn pop(test_inbox: TestInbox) ?Message {
        const table = test_inbox.tables.findByName(test_inbox.inbox) orelse return null;
        return takeOldest(table);
    }

    /// Removes every message, taken or not.
    pub fn reset(test_inbox: TestInbox) void {
        const table = test_inbox.tables.findByName(test_inbox.inbox) orelse return;
        table.clear();
    }
};

/// The name meaning "no inbox": a request that wants no reply. It is the zero atom.
pub const no_inbox: Atom = @enumFromInt(0);

/// The inbox's messages, in arrival order, through the run's layer.
fn readInbox(env: *const Env, inbox_table: ?Table.Handle) ![]const Message {
    const handle = inbox_table orelse return &.{};
    const table = env.tables.get(handle) orelse return &.{};
    if (table.count() == 0) return &.{};
    const scratch = try env.memory.frameScratchAllocator();
    const messages = try scratch.allocator.alloc(Message, table.count());
    var count: usize = 0;
    // Read, not fetched to write: the run's layer need not copy the rows it only hands on.
    var rows = table.readQuery(InboxEntry);
    while (rows.next()) |row| {
        messages[count] = inboxMessageAt(table, row.handle.row, row.view.tag.*);
        count += 1;
    }
    return messages[0..count];
}

/// What a system's kernels see this frame.
fn systemFrame(env: *const Env, system: *const System, messages: []const Message) Frame {
    return .{
        .memory = env.memory,
        .atoms = env.atoms,
        .tables = env.tables,
        .messages = messages,
        .context = env.hooks.context,
        .system = system,
    };
}

// ---- subscriptions and commands ------------------------------------------------------------

/// A host system's table of what its subscribers subscribe to: a row per subscription of type `T`,
/// a union whose variants may carry their own `user_data`. It is a table of subscriptions
/// (`subscription_tables_name`): a system's kernels append its rows in its run, they last until it
/// runs again or is switched off, and the host reads them in order (`iterate`). `push`, `reset` and
/// `holding` write it outside any run, as a test does.
pub fn Subscribed(comptime T: type) type {
    return CopiedRows(T, "subscription");
}

/// A system's table of requests to it, `commands.<system>`: a row per command of type `T`,
/// usually a tagged union, its kind and values in columns of their own. Senders append
/// (`push`); the owner applies them in order (`drain`, or `take` in a journaled run). A
/// request's slices outlive the frame that appended it.
pub fn Commands(comptime T: type) type {
    return CopiedRows(T, "command");
}

/// A host system's table of what happened in it, `events.<system>`: a row per event, numbered
/// in order (`sequence`), its kind and values in columns as a command's are. The host
/// publishes outside runs and keeps the latest `retained`. Any system reads them in its run
/// with a cursor of its own in `event_cursors` (`read`), so a run that faults reads them
/// again next frame, and no one subscribes. Events carry no pointers: what they are about is
/// in the host's state tables, which a reader looks up.
pub fn Events(comptime E: type) type {
    if (holdsPointers(E)) @compileError("an event holds no pointers: " ++ @typeName(E));
    return struct {
        /// The tables the events table is in.
        tables: *Table.Registry,
        /// The events table's name.
        name: Atom,

        const Self = @This();
        const Row = struct { sequence: u64, event: E };
        const columns = Columns(Row);

        /// How many events the table keeps: a reader that falls further behind, as one that
        /// faults for that long, misses the oldest.
        pub const retained = 64;

        /// Makes the table and the readers' cursors, unless they are there.
        pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry, comptime name: []const u8) !void {
            var schema: Table.Schema = undefined;
            try schema.init(scratch.allocator, atoms, columns.count);
            defer schema.deinit();
            try columns.add(&schema, atoms);
            try atoms.tryInternAll(&.{name});
            _ = try tables.ensure(&schema, retained, Atom.from(name), .durable);
            try ensureCursors(scratch, atoms, tables);
        }

        /// The events table `name` in `tables`, for publishing and reading. It makes nothing
        /// (`ensure`), and every method treats a missing table as one with no events.
        pub fn of(tables: *Table.Registry, comptime name: []const u8) Self {
            return .{ .tables = tables, .name = comptime Atom.from(name) };
        }

        /// What a reader of the events table `name` declares: the events read, its cursor
        /// written. Without the table, as before its host starts, it declares nothing and
        /// reads none.
        pub fn declare(access: *Access, tables: *Table.Registry, comptime name: []const u8) void {
            const events = comptime Atom.from(name);
            if (tables.findByName(events) == null) return;
            access.read(events);
            access.write(cursors_name);
        }

        /// Appends `event` after the latest, outside any run, dropping the oldest once more
        /// than `retained` are kept. An event that cannot be kept is logged.
        pub fn publish(self: Self, event: E) void {
            const found = self.tables.findByName(self.name) orelse return;
            std.debug.assert(found.journal == null);
            self.tables.activity +%= 1;
            var latest: u64 = 0;
            var oldest: ?Table.RowHandle = null;
            var oldest_sequence: u64 = std.math.maxInt(u64);
            var rows = found.rows();
            while (rows.next()) |row| {
                const sequence = found.getField(u64, row, "sequence").?.*;
                latest = @max(latest, sequence);
                if (sequence < oldest_sequence) {
                    oldest_sequence = sequence;
                    oldest = row;
                }
            }
            if (found.count() >= retained) found.free(oldest.?);
            const handle = found.alloc() catch |err| {
                Log.err("event_dropped", .{ .table = self.name, .@"error" = @errorName(err) });
                return;
            };
            const row: Row = .{ .sequence = latest + 1, .event = event };
            // An event holds no slices, so nothing is copied and nothing can fail.
            columns.store(found, handle, &row) catch unreachable;
        }

        /// Every event kept, oldest first, up to `into.len` of them: for a host or a test,
        /// outside runs.
        pub fn peek(self: Self, into: []E) []E {
            const found = self.tables.findByName(self.name) orelse return into[0..0];
            var sequences: [retained]u64 = undefined;
            const count = collectAfter(found, 0, into, &sequences);
            return into[0..count];
        }

        /// Whether `reader` has a cursor: whether a read of it has taken an event. False before
        /// its first read that took one, as on a reader's first run, or after it is added to a
        /// running host, when what it follows may have changed before any event it can read.
        pub fn hasRead(self: Self, reader: Atom) bool {
            const cursors = self.tables.findByName(cursors_name) orelse return false;
            return findCursor(cursors, reader, self.name) != null;
        }

        /// The events after `reader`'s cursor, oldest first, up to `into.len` of them,
        /// leaving the cursor: for a system's `access`, which declares what reading them
        /// will need.
        pub fn unread(self: Self, reader: Atom, into: []E) []E {
            const found = self.tables.findByName(self.name) orelse return into[0..0];
            const cursors = self.tables.findByName(cursors_name) orelse return into[0..0];
            const cursor = findCursor(cursors, reader, self.name);
            const seen: u64 = if (cursor) |at| cursorSequence(cursors, at) else 0;
            var sequences: [retained]u64 = undefined;
            const count = collectAfter(found, seen, into, &sequences);
            return into[0..count];
        }

        /// The events after `reader`'s cursor, oldest first, up to `into.len` of them; the
        /// cursor moves past those returned, through the run's journal. The rest come next
        /// time. A reader's first read starts from the oldest kept.
        pub fn read(self: Self, pass: *Pass, reader: Atom, into: []E) ![]E {
            // Not declared: the table was not there (`declare`).
            if (!pass.declares(self.name)) return into[0..0];
            const events = try pass.table(self.name);
            const cursors_handle = try pass.writeHandle(cursors_name);
            const cursors = pass.frame.tables.get(cursors_handle) orelse return error.MissingTable;
            const cursor = findCursor(cursors, reader, self.name);
            const seen: u64 = if (cursor) |found| cursorSequence(cursors, found) else 0;
            var sequences: [retained]u64 = undefined;
            const taken = collectAfter(events, seen, into, &sequences);
            if (taken == 0) return into[0..0];
            const last = sequences[taken - 1];
            if (cursor) |found| {
                cursors.getField(u64, found, "sequence").?.* = last;
            } else {
                _ = try cursors.tryInsert(.{ .reader = reader, .events = self.name, .sequence = last });
            }
            return into[0..taken];
        }

        /// The events after `seen`, oldest first, into `into` and their numbers into
        /// `sequences`; returns how many `into` holds. The table keeps no order, as a dropped
        /// row's place is taken by the last, so each is put in its place among the earlier.
        fn collectAfter(found: *Table, seen: u64, into: []E, sequences: *[retained]u64) usize {
            var count: usize = 0;
            var rows = found.rows();
            while (rows.next()) |row| {
                const value = columns.load(found, row);
                if (value.sequence <= seen) continue;
                var at = count;
                while (at > 0 and sequences[at - 1] > value.sequence) : (at -= 1) {
                    sequences[at] = sequences[at - 1];
                    if (at < into.len) into[at] = into[at - 1];
                }
                sequences[at] = value.sequence;
                if (at < into.len) into[at] = value.event;
                count += 1;
            }
            return @min(count, into.len);
        }
    };
}

/// Where each reader of events is: `{reader, events, sequence}`, the last event it took of
/// each events table it reads.
pub const cursors_table_name = "event_cursors";
const cursors_name = Atom.from(cursors_table_name);
const CursorView = struct { reader: *Atom, events: *Atom, sequence: *u64 };

fn ensureCursors(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 3);
    defer schema.deinit();
    try schema.addFieldFallible("reader", Atom, .atom);
    try schema.addFieldFallible("events", Atom, .atom);
    try schema.addFieldFallible("sequence", u64, .int);
    try atoms.tryInternAll(&.{cursors_table_name});
    _ = try tables.ensure(&schema, 32, cursors_name, .durable);
}

fn findCursor(cursors: *Table, reader: Atom, events: Atom) ?Table.RowHandle {
    var rows = cursors.readQuery(CursorView);
    while (rows.next()) |row| {
        if (row.view.reader.* == reader and row.view.events.* == events) return row.handle;
    }
    return null;
}

fn cursorSequence(cursors: *Table, cursor: Table.RowHandle) u64 {
    const index = cursors.getSchema().fieldIndex("sequence").?;
    return cursors.getFieldByIndexConst(u64, cursor, @intCast(index)).?.*;
}

/// What applying a request came to: done, or to be tried again at the next drain, as a
/// refused request whose requester must still hear of it.
/// An integer tag, so a plugin's command hook can return it across the C ABI.
pub const Applied = enum(u8) { done, retry };

/// A table `name` of rows holding one `T` each, in the order pushed, laid out in columns
/// (`Columns`) so the table reads like any other. Slices a value carries are copied into the
/// table's payload arena, which goes when the table is left empty.
fn CopiedRows(comptime T: type, comptime what: []const u8) type {
    return struct {
        /// The host's memory.
        memory: *memory_mod.Memory,
        /// The tables the table is in.
        tables: *Table.Registry,
        /// The table's name.
        name: Atom,

        const Self = @This();
        const columns = Columns(T);

        /// Makes the table, unless it is there.
        pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry, comptime name: []const u8) !void {
            const subscriptions = comptime std.mem.eql(u8, what, "subscription");
            var schema: Table.Schema = undefined;
            try schema.init(scratch.allocator, atoms, columns.count + 2 * @as(usize, @intFromBool(subscriptions)));
            defer schema.deinit();
            try columns.add(&schema, atoms);
            // Subscriptions name the system whose run appended them and their place, which the
            // sequencer fills.
            if (subscriptions) {
                try schema.addFieldFallible(subscriber_field, Atom, .atom);
                try schema.addFieldFallible(subscription_order_field, u32, .int);
            }
            try atoms.tryInternAll(&.{name});
            _ = try tables.ensure(&schema, 16, Atom.from(name), .durable);
            if (subscriptions) try ensureSubscriptions(scratch, atoms, tables, name);
        }

        /// The table `name` holding exactly `subscriptions`, made if it is not there: for a
        /// test or a caller that has its subscriptions as a list.
        pub fn holding(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry, comptime name: []const u8, subscriptions: []const T) !Self {
            try Self.ensure(try memory.tableScratchAllocator(), atoms, tables, name);
            const self = of(memory, tables, name);
            self.reset();
            for (subscriptions) |subscription| self.push(subscription);
            return self;
        }

        /// The table `name` in `tables`. It makes nothing (`ensure`): without the table `tryPush`
        /// and `storage` report `error.MissingTable`, `take` finds it undeclared, and every
        /// other method finds no rows.
        pub fn of(memory: *memory_mod.Memory, tables: *Table.Registry, comptime name: []const u8) Self {
            return .{ .memory = memory, .tables = tables, .name = comptime Atom.from(name) };
        }

        fn table(self: Self) ?*Table {
            return self.tables.findByName(self.name);
        }

        /// Appends `value`, copying its slices. A value that cannot be stored is dropped and
        /// logged: a subscriber hears nothing this frame, a request is not applied.
        pub fn push(self: Self, value: T) void {
            self.tryPush(value) catch |err| switch (err) {
                // A table not made yet, as before its owner starts, takes nothing.
                error.MissingTable => {},
                else => dropped(err),
            };
        }

        /// As `push`, for a caller that must know the row landed before it records that it
        /// sent it.
        pub fn tryPush(self: Self, value: T) !void {
            var copied = value;
            const found = self.table() orelse return error.MissingTable;
            // Everything the value points at goes into the table's arena, so `store` finds its
            // slices there and names them where they are.
            try copySlices(found.payloadAllocator(), T, &copied);
            // A request is work for its owner; a subscription is the subscriber's standing
            // wish, rewritten whenever it runs.
            if (comptime !std.mem.eql(u8, what, "subscription")) self.tables.activity +%= 1;
            const handle = try found.alloc();
            errdefer found.free(handle);
            try columns.store(found, handle, &copied);
        }

        fn dropped(err: anyerror) void {
            Log.err(what ++ "_dropped", .{ .@"error" = @errorName(err) });
        }

        /// Where copied slices live: the table's payload arena, which is host memory, so they
        /// outlive a plugin reload.
        pub fn storage(self: Self) !std.mem.Allocator {
            const found = self.table() orelse return error.MissingTable;
            return found.payloadAllocator();
        }

        /// Applies each row in order with `apply`, which answers whether the row is done or
        /// must be tried again, and may rewrite the row's value before it is tried again.
        /// Rows to try again stay, in their order, for the next drain; their slices stay with
        /// them, so the arena is reclaimed only once every row is done. A row that cannot be
        /// kept is dropped and logged. `apply` must not push to this table.
        pub fn drain(self: Self, context: anytype, comptime apply: fn (@TypeOf(context), *T) Applied) void {
            const found = self.table() orelse return;
            const pushed = found.count();
            var kept: u32 = 0;
            for (0..pushed) |index| {
                const position: u32 = @intCast(index);
                var value = columns.load(found, handleAt(found, position));
                const applied = apply(context, &value);
                std.debug.assert(found.count() == pushed);
                if (applied == .done) continue;
                // Kept in the next free place, as it is now: `apply` may have rewritten it.
                columns.store(found, handleAt(found, kept), &value) catch |err| {
                    dropped(err);
                    continue;
                };
                kept += 1;
            }
            // From the end, so no removal moves a kept row.
            var remaining = pushed;
            while (remaining > kept) : (remaining -= 1) {
                found.free(handleAt(found, remaining - 1));
            }
            found.resetPayloadsIfEmpty();
        }

        /// For a journaled system, which declared the table written: applies each row in
        /// order with `apply`, then clears the table, all through the run's journal, so a
        /// fault takes the rows back. An error from `apply` faults the run. The rows' copied
        /// slices are not reclaimed here, as a faulted run's rows still need them; they go
        /// with `Table.Registry.reclaimPayloads`, outside runs. `apply` copies what it keeps.
        pub fn take(self: Self, pass: *Pass, context: anytype, comptime apply: fn (@TypeOf(context), *const T) anyerror!void) !void {
            const handle = try pass.writeHandle(self.name);
            const found = pass.frame.tables.get(handle) orelse return error.MissingTable;
            if (found.count() == 0) return;
            var rows = found.rows();
            while (rows.next()) |row| {
                const value = columns.load(found, row);
                try apply(context, &value);
            }
            found.clear();
        }

        /// Copies up to `into.len` of the values pushed, in order, leaving the rows and their
        /// slices in the table; returns the copies. For a reader that only looks, as a test.
        pub fn peek(self: Self, into: []T) []T {
            const found = self.table() orelse return into[0..0];
            const pushed: u32 = found.count();
            const copied: u32 = @min(pushed, @as(u32, @intCast(into.len)));
            for (0..copied) |index| {
                const position: u32 = @intCast(index);
                into[index] = columns.load(found, handleAt(found, position));
            }
            return into[0..copied];
        }

        fn handleAt(found: *Table, position: u32) Table.RowHandle {
            const row = found.rowAtPosition(position);
            return .{ .row = row, .generation = found.rowGeneration(row) };
        }

        /// Forgets the rows and the slices they carried.
        pub fn reset(self: Self) void {
            const found = self.table() orelse return;
            found.clear();
        }

        /// How many rows the table holds; 0 without the table.
        pub fn count(self: Self) u32 {
            const found = self.table() orelse return 0;
            return found.count();
        }

        /// The values, in the order they were pushed.
        pub fn iterate(self: Self) Iterator {
            const found = self.table() orelse return .{ .table = null, .rows = undefined };
            return .{ .table = found, .rows = found.rows() };
        }

        /// What `iterate` returns: the table's rows in order, each loaded as a `T`.
        pub const Iterator = struct {
            /// The table, or null when there is none to walk.
            table: ?*Table,
            /// Where the walk is; undefined without a table.
            rows: Table.RowIterator,
            /// The row the last `next` loaded, for a reader of the row's other columns; null
            /// before the first and after the last.
            row: ?Table.RowHandle = null,

            /// The next value, or null at the end. Its slices point into the table's payload arena,
            /// valid while the row stays.
            pub fn next(iterator: *Iterator) ?T {
                iterator.row = null;
                const found = iterator.table orelse return null;
                const row = iterator.rows.next() orelse return null;
                iterator.row = row;
                return columns.load(found, row);
            }

            /// The system whose run appended the row the last `next` loaded, in a table of
            /// subscriptions (`subscriber_field`); none for a row no run has named yet, and in
            /// any other table.
            pub fn subscriber(iterator: *const Iterator) Atom {
                const found = iterator.table orelse return no_atom;
                const row = iterator.row orelse return no_atom;
                const field = found.getSchema().fieldIndex(subscriber_field) orelse return no_atom;
                if (!found.rowHas(row.row, found.getSchema().fields[field].bit)) return no_atom;
                const named = found.getField(Atom, row, subscriber_field) orelse return no_atom;
                return named.*;
            }
        };
    };
}

// ---- a value's columns ----------------------------------------------------------------------

/// How a value of type `V` is laid out across a row's columns, so a table of commands or
/// subscriptions reads like any other in the inspector:
///  - A tagged union's tag is an atom column `kind` (`<name>.kind` when nested) naming its
///    variant, and each variant's values get columns of their own, `<variant>.<field>`. No
///    two variants share a column, so a row holds its variant's columns and no others.
///  - A struct's fields are columns `<name>.<field>`, at any depth.
///  - An optional's value is its column, absent when null; an optional struct or union
///    adds a toggle column `<name>` saying whether it is there.
///  - An exhaustive enum is an atom column of its tag's name; another is a number.
///  - A value with one column, as a request that is an enum, has it as `kind` when it is an
///    enum and `value` otherwise.
///  - `UserData` is an opaque bytes column of any length.
///  - A slice or a terminated name is a payload column, a string when its elements are bytes:
///    its elements live in the table's payload arena. What the elements themselves point at
///    is not in a column; `copySlices` puts it in the same arena.
///  - What has no columns of its own (packed structs, untagged unions, arrays, pointers) is
///    one hex column of its bytes, padded with a zero to four when it is three, which a hex
///    column cannot show.
fn Columns(comptime V: type) type {
    @setEvalBranchQuota(100_000);
    return struct {
        /// How many columns a `V` takes.
        pub const count: usize = countOf(V);

        comptime {
            if (count > Table.Mask.max_bits) @compileError(std.fmt.comptimePrint("{d} columns for {s}, more than a table holds", .{ count, @typeName(V) }));
        }

        const root = rootOf(V);

        /// Adds `V`'s columns to `schema`, in the order `store` and `load` find them by, and
        /// interns the names its enum, error and union tags are stored as.
        pub fn add(schema: *Table.Schema, atoms: *Atom.Registry) !void {
            try addColumns(schema, atoms, V, root);
        }

        /// Writes `value` into the row `handle`, which holds no other value. A slice that is
        /// not in the table's arena yet is copied there, which may fail.
        pub fn store(table: *Table, handle: Table.RowHandle, value: *const V) StoreError!void {
            table.setMask(handle.row, .empty);
            try storeColumns(table, handle, V, V, root, value);
            table.touch();
        }

        /// The value the row `handle` holds, which `store` wrote. Its slices point into the table's
        /// payload arena.
        pub fn load(table: *Table, handle: Table.RowHandle) V {
            var value: V = undefined;
            loadColumns(table, handle, V, V, root, &value);
            return value;
        }
    };
}

/// What a leaf column holds.
const Leaf = enum {
    /// The value's own bytes, in a column of its type.
    plain,
    /// An exhaustive enum, as the atom of its tag's name.
    enum_name,
    /// An error, as the atom of its name.
    error_name,
    /// A slice of bytes or a sentinel-terminated name, as a string column.
    text,
    /// A slice of anything else, as a bytes column.
    slice,
    /// Bytes shown as hex: what has no columns of its own.
    bytes,
    /// `UserData`, as an opaque bytes column of any length.
    user_data,
};

fn leafOf(comptime V: type) ?Leaf {
    if (V == Atom) return .plain;
    if (V == UserData) return .user_data;
    switch (@typeInfo(V)) {
        .bool, .float => return .plain,
        .int => return if (@sizeOf(V) == 1 or @sizeOf(V) == 2 or @sizeOf(V) == 4 or @sizeOf(V) == 8) .plain else .bytes,
        // A non-exhaustive enum is a number, as an id, whose values have no names.
        .@"enum" => |info| return if (info.is_exhaustive) .enum_name else .plain,
        .pointer => |pointer| {
            if (pointer.size == .slice) return if (pointer.child == u8) .text else .slice;
            if (pointer.size == .many and pointer.child == u8 and pointer.sentinel_ptr != null) return .text;
            return .bytes;
        },
        .optional => |info| {
            if (@typeInfo(info.child) != .pointer) return null;
            // An optional slice is its payload column, absent when null.
            return switch (leafOf(info.child).?) {
                .text, .slice => null,
                else => .bytes,
            };
        },
        .@"struct" => |info| return if (info.layout == .@"packed") .bytes else null,
        .@"union" => |info| return if (info.tag_type == null) .bytes else null,
        .array => return .bytes,
        .error_set => return .error_name,
        else => @compileError("no columns for " ++ @typeName(V)),
    }
}

/// A leaf column's type and how the inspector shows it.
fn LeafColumn(comptime V: type, comptime leaf: Leaf) type {
    return switch (leaf) {
        .enum_name, .error_name => Atom,
        .text => Table.String,
        .slice, .user_data => Table.Bytes,
        .plain => V,
        .bytes => HexColumn(V),
    };
}

/// What a hex column of a `V` holds: its bytes, or four for three, which a hex column cannot show.
fn HexColumn(comptime V: type) type {
    return if (@sizeOf(V) == 3) [4]u8 else V;
}

/// `value` as its hex column holds it, a three-byte one followed by a zero.
fn hexColumn(comptime V: type, value: V) HexColumn(V) {
    if (HexColumn(V) == V) return value;
    var column: [4]u8 = @splat(0);
    @memcpy(column[0..3], std.mem.asBytes(&value));
    return column;
}

/// The value a hex column of a `V` holds.
fn hexValue(comptime V: type, column: HexColumn(V)) V {
    if (HexColumn(V) == V) return column;
    var value: V = undefined;
    @memcpy(std.mem.asBytes(&value), column[0..3]);
    return value;
}

fn leafView(comptime V: type, comptime leaf: Leaf) Table.ViewKind {
    if (leaf == .bytes) return .hex;
    if (leaf == .text) return .text_field;
    if (leaf == .slice or leaf == .user_data) return .bytes;
    if (leaf == .enum_name or leaf == .error_name or V == Atom) return .atom;
    return switch (@typeInfo(V)) {
        .bool => .toggle,
        .float => if (V == f32) .{ .vector = .{ .components = 1 } } else .hex,
        .int, .@"enum" => .int,
        .optional => |info| leafView(info.child, leaf),
        else => .hex,
    };
}

fn columnName(comptime prefix: []const u8, comptime name: []const u8) []const u8 {
    if (prefix.len == 0) return name;
    return prefix ++ "." ++ name;
}

/// The names of fields that mean the same in every variant of the tagged union `U` that has
/// them, as the document a figure command addresses: each is one column `<name>.<field>`, not
/// one per variant. A union opts in with `pub const shared_columns`; unrelated values never
/// share a column, though they may share a name.
fn sharedColumns(comptime U: type) []const []const u8 {
    if (!@hasDecl(U, "shared_columns")) return &.{};
    return &U.shared_columns;
}

fn isShared(comptime U: type, comptime field: []const u8) bool {
    for (sharedColumns(U)) |shared| {
        if (std.mem.eql(u8, shared, field)) return true;
    }
    return false;
}

/// Whether a variant's payload is a struct whose fields may go to shared columns.
fn variantFieldsShare(comptime U: type, comptime Payload: type) bool {
    if (sharedColumns(U).len == 0) return false;
    const info = @typeInfo(Payload);
    return info == .@"struct" and info.@"struct".layout != .@"packed";
}

/// A shared column's type: the same in every variant that has the field.
fn SharedType(comptime U: type, comptime field: []const u8) type {
    var found: ?type = null;
    for (@typeInfo(U).@"union".fields) |variant| {
        if (!variantFieldsShare(U, variant.type)) continue;
        for (@typeInfo(variant.type).@"struct".fields) |inner| {
            if (!std.mem.eql(u8, inner.name, field)) continue;
            if (found) |earlier| {
                if (earlier != inner.type) @compileError("shared column " ++ field ++ " has two types in " ++ @typeName(U));
            }
            found = inner.type;
        }
    }
    return found orelse @compileError("no variant of " ++ @typeName(U) ++ " has shared column " ++ field);
}

fn variantColumn(comptime U: type, comptime prefix: []const u8, comptime variant: []const u8, comptime field: []const u8) []const u8 {
    if (isShared(U, field)) return columnName(prefix, field);
    return columnName(columnName(prefix, variant), field);
}

fn countOf(comptime V: type) usize {
    @setEvalBranchQuota(100_000);
    if (V == void) return 0;
    if (leafOf(V)) |leaf| return if (@sizeOf(LeafColumn(V, leaf)) == 0) 0 else 1;
    var total: usize = 0;
    switch (@typeInfo(V)) {
        .@"struct" => |info| for (info.fields) |field| {
            total += countOf(field.type);
        },
        .@"union" => |info| {
            total += 1;
            for (sharedColumns(V)) |shared| total += countOf(SharedType(V, shared));
            for (info.fields) |field| {
                if (!variantFieldsShare(V, field.type)) {
                    total += countOf(field.type);
                    continue;
                }
                for (@typeInfo(field.type).@"struct".fields) |inner| {
                    if (!isShared(V, inner.name)) total += countOf(inner.type);
                }
            }
        },
        .optional => |info| total += if (leafOf(info.child) != null) countOf(info.child) else 1 + countOf(info.child),
        else => unreachable,
    }
    return total;
}

fn addColumns(schema: *Table.Schema, atoms: *Atom.Registry, comptime V: type, comptime name: []const u8) !void {
    @setEvalBranchQuota(100_000);
    if (V == void) return;
    if (comptime leafOf(V)) |leaf| {
        const Column = LeafColumn(V, leaf);
        if (@sizeOf(Column) == 0) return;
        if (leaf == .enum_name) {
            inline for (@typeInfo(V).@"enum".fields) |field| try atoms.tryInternAll(&.{field.name});
        }
        if (leaf == .error_name) {
            inline for (@typeInfo(V).error_set.?) |found| try atoms.tryInternAll(&.{found.name});
        }
        try schema.addFieldFallible(name, Column, comptime leafView(V, leaf));
        return;
    }
    switch (@typeInfo(V)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            try addColumns(schema, atoms, field.type, comptime columnName(name, field.name));
        },
        .@"union" => |info| {
            try schema.addFieldFallible(comptime columnName(name, "kind"), Atom, .atom);
            inline for (comptime sharedColumns(V)) |shared| {
                try addColumns(schema, atoms, SharedType(V, shared), comptime columnName(name, shared));
            }
            inline for (info.fields) |field| {
                try atoms.tryInternAll(&.{field.name});
                if (comptime !variantFieldsShare(V, field.type)) {
                    try addColumns(schema, atoms, field.type, comptime columnName(name, field.name));
                    continue;
                }
                inline for (@typeInfo(field.type).@"struct".fields) |inner| {
                    if (comptime isShared(V, inner.name)) continue;
                    try addColumns(schema, atoms, inner.type, comptime variantColumn(V, name, field.name, inner.name));
                }
            }
        },
        .optional => |info| {
            // A value with a column of its own is that column, absent when null.
            if (comptime leafOf(info.child) == null) try schema.addFieldFallible(name, bool, .toggle);
            try addColumns(schema, atoms, info.child, name);
        },
        else => unreachable,
    }
}

/// What the columns' names start from: nothing, unless the value is one column.
fn rootOf(comptime V: type) []const u8 {
    if (leafOf(V) == null) return "";
    if (@typeInfo(V) == .@"enum") return "kind";
    return "value";
}

/// The columns of `Top`, in the order `addColumns` makes them, which is the table's: a value's
/// columns are found by place, not looked up by name.
fn columnNames(comptime Top: type) []const []const u8 {
    @setEvalBranchQuota(1_000_000);
    comptime {
        var names: []const []const u8 = &.{};
        appendColumnNames(Top, rootOf(Top), &names);
        return names;
    }
}

fn appendColumnNames(comptime V: type, comptime name: []const u8, comptime names: *[]const []const u8) void {
    if (V == void) return;
    if (leafOf(V)) |leaf| {
        if (@sizeOf(LeafColumn(V, leaf)) == 0) return;
        names.* = names.* ++ [_][]const u8{name};
        return;
    }
    switch (@typeInfo(V)) {
        .@"struct" => |info| for (info.fields) |field| {
            appendColumnNames(field.type, columnName(name, field.name), names);
        },
        .@"union" => |info| {
            names.* = names.* ++ [_][]const u8{columnName(name, "kind")};
            for (sharedColumns(V)) |shared| appendColumnNames(SharedType(V, shared), columnName(name, shared), names);
            for (info.fields) |field| {
                if (!variantFieldsShare(V, field.type)) {
                    appendColumnNames(field.type, columnName(name, field.name), names);
                    continue;
                }
                for (@typeInfo(field.type).@"struct".fields) |inner| {
                    if (isShared(V, inner.name)) continue;
                    appendColumnNames(inner.type, variantColumn(V, name, field.name, inner.name), names);
                }
            }
        },
        .optional => |info| {
            if (leafOf(info.child) == null) names.* = names.* ++ [_][]const u8{name};
            appendColumnNames(info.child, name, names);
        },
        else => unreachable,
    }
}

fn columnIndex(comptime Top: type, comptime name: []const u8) u32 {
    @setEvalBranchQuota(1_000_000);
    comptime {
        const names = columnNames(Top);
        for (names, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, name)) return index;
        }
        @compileError("no column " ++ name ++ " in " ++ @typeName(Top));
    }
}

fn storeColumn(table: *Table, handle: Table.RowHandle, comptime Top: type, comptime Column: type, comptime name: []const u8, value: Column) void {
    const index = comptime columnIndex(Top, name);
    const slot = table.getFieldByIndex(Column, handle, @intCast(index)).?;
    slot.* = value;
    const bit = table.getSchema().fields[index].bit;
    table.setPresent(handle.row, bit, true);
}

/// The column's value, or null when the row does not hold it.
fn loadColumn(table: *Table, handle: Table.RowHandle, comptime Top: type, comptime Column: type, comptime name: []const u8) ?Column {
    const index = comptime columnIndex(Top, name);
    const bit = table.getSchema().fields[index].bit;
    const mask = table.rowMask(handle.row);
    if (!mask.has(bit)) return null;
    const slot = table.getFieldByIndexConst(Column, handle, @intCast(index)).?;
    return slot.*;
}

/// What storing a value's columns fails with: the errors of `Table.payloadFor`, when a slice that
/// is not in the table's payload arena cannot be copied there.
pub const StoreError = error{ OutOfMemory, Overflow };

/// The elements of a slice or terminated name `value` and how many follow them as its
/// sentinel: what its payload holds. The sentinel is kept after the payload's bytes, outside
/// its length, so the value is read back terminated.
fn SliceParts(comptime V: type) type {
    return struct { elements: []const @typeInfo(V).pointer.child, sentinel: usize };
}

fn sliceParts(comptime V: type, value: V) SliceParts(V) {
    const pointer = @typeInfo(V).pointer;
    const elements: []const pointer.child = if (pointer.size == .slice) value else std.mem.span(value);
    return .{ .elements = elements, .sentinel = @intFromBool(pointer.sentinel_ptr != null) };
}

/// The payload of the table's arena holding the slice or terminated name `value`: where it
/// lies when it is in the arena already, as a pushed value's copy is, and a copy otherwise.
fn slicePayload(table: *Table, comptime V: type, value: V) StoreError!Table.Payload {
    const Element = @typeInfo(V).pointer.child;
    const parts = sliceParts(V, value);
    const stored = parts.elements.ptr[0 .. parts.elements.len + parts.sentinel];
    var payload = try table.payloadFor(std.mem.sliceAsBytes(stored), .of(Element));
    payload.len -= @intCast(parts.sentinel * @sizeOf(Element));
    return payload;
}

/// The slice or terminated name a payload column holds, in the table's arena.
fn payloadSlice(table: *const Table, comptime V: type, payload: Table.Payload) V {
    const pointer = @typeInfo(V).pointer;
    const Element = pointer.child;
    const sentinel: u32 = @intFromBool(pointer.sentinel_ptr != null);
    const stored: Table.Payload = .{ .offset = payload.offset, .len = payload.len + sentinel * @sizeOf(Element) };
    const bytes = table.payloadBytes(stored);
    if (bytes.len == 0) return &.{};
    const aligned: []align(@alignOf(Element)) const u8 = @alignCast(bytes);
    const elements = std.mem.bytesAsSlice(Element, aligned);
    const count = elements.len - sentinel;
    if (pointer.sentinel_ptr == null) return elements;
    const terminated = elements[0..count :pointer.sentinel().?];
    return if (pointer.size == .slice) terminated else terminated.ptr;
}

fn storeColumns(table: *Table, handle: Table.RowHandle, comptime Top: type, comptime V: type, comptime name: []const u8, value: *const V) StoreError!void {
    @setEvalBranchQuota(100_000);
    if (V == void) return;
    if (comptime leafOf(V)) |leaf| {
        const Column = LeafColumn(V, leaf);
        if (@sizeOf(Column) == 0) return;
        const column: Column = switch (leaf) {
            .enum_name => Atom.from(@tagName(value.*)),
            .error_name => Atom.from(@errorName(value.*)),
            .text, .slice => .{ .payload = try slicePayload(table, V, value.*) },
            .user_data => .{ .payload = try table.payloadFor(value.bytes, Table.bytes_alignment) },
            .plain => value.*,
            .bytes => hexColumn(V, value.*),
        };
        storeColumn(table, handle, Top, Column, name, column);
        return;
    }
    switch (@typeInfo(V)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            try storeColumns(table, handle, Top, field.type, comptime columnName(name, field.name), &@field(value.*, field.name));
        },
        .@"union" => switch (value.*) {
            inline else => |*payload, tag| {
                const variant = @tagName(tag);
                storeColumn(table, handle, Top, Atom, comptime columnName(name, "kind"), comptime Atom.from(variant));
                const Payload = @TypeOf(payload.*);
                if (comptime !variantFieldsShare(V, Payload)) {
                    try storeColumns(table, handle, Top, Payload, comptime columnName(name, variant), payload);
                    return;
                }
                inline for (@typeInfo(Payload).@"struct".fields) |inner| {
                    try storeColumns(table, handle, Top, inner.type, comptime variantColumn(V, name, variant, inner.name), &@field(payload.*, inner.name));
                }
            },
        },
        .optional => |info| {
            if (comptime leafOf(info.child) == null) storeColumn(table, handle, Top, bool, name, value.* != null);
            if (value.*) |*present| try storeColumns(table, handle, Top, info.child, name, present);
        },
        else => unreachable,
    }
}

fn loadColumns(table: *Table, handle: Table.RowHandle, comptime Top: type, comptime V: type, comptime name: []const u8, into: *V) void {
    @setEvalBranchQuota(100_000);
    if (V == void) return;
    if (comptime leafOf(V)) |leaf| {
        const Column = LeafColumn(V, leaf);
        if (@sizeOf(Column) == 0) {
            into.* = undefined;
            return;
        }
        // `store` writes every column of the variant it names.
        const column = loadColumn(table, handle, Top, Column, name) orelse unreachable;
        into.* = switch (leaf) {
            .enum_name => enumNamed(V, column),
            .error_name => errorNamed(V, column),
            .text, .slice => payloadSlice(table, V, column.payload),
            .user_data => .{ .bytes = table.payloadBytes(column.payload) },
            .plain => column,
            .bytes => hexValue(V, column),
        };
        return;
    }
    switch (@typeInfo(V)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            loadColumns(table, handle, Top, field.type, comptime columnName(name, field.name), &@field(into.*, field.name));
        },
        .@"union" => |info| {
            // Every row was written by `store`, which names one of the variants.
            const kind = loadColumn(table, handle, Top, Atom, comptime columnName(name, "kind")) orelse unreachable;
            inline for (info.fields) |field| {
                if (kind == comptime Atom.from(field.name)) {
                    var payload: field.type = undefined;
                    if (comptime !variantFieldsShare(V, field.type)) {
                        loadColumns(table, handle, Top, field.type, comptime columnName(name, field.name), &payload);
                    } else {
                        inline for (@typeInfo(field.type).@"struct".fields) |inner| {
                            loadColumns(table, handle, Top, inner.type, comptime variantColumn(V, name, field.name, inner.name), &@field(payload, inner.name));
                        }
                    }
                    into.* = @unionInit(V, field.name, payload);
                    return;
                }
            }
            unreachable;
        },
        .optional => |info| {
            const present = if (comptime leafOf(info.child) == null)
                loadColumn(table, handle, Top, bool, name) orelse false
            else
                loadColumn(table, handle, Top, LeafColumn(info.child, leafOf(info.child).?), name) != null;
            if (!present) {
                into.* = null;
                return;
            }
            var child: info.child = undefined;
            loadColumns(table, handle, Top, info.child, name, &child);
            into.* = child;
        },
        else => unreachable,
    }
}

fn errorNamed(comptime E: type, name: Atom) E {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(E).error_set.?) |found| {
        if (name == comptime Atom.from(found.name)) return @field(E, found.name);
    }
    // The column was written from a value of `E`.
    unreachable;
}

fn enumNamed(comptime E: type, name: Atom) E {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (name == comptime Atom.from(field.name)) return @enumFromInt(field.value);
    }
    // The column was written from a value of `E`.
    unreachable;
}

/// Replaces every const slice and terminated name `value` holds with a copy in `allocator`, at any
/// depth of structs, tagged unions, optionals, arrays and the copied slices' own elements, such as
/// a batch's dabs and each dab's factors. Mutable slices, pointers to one value and untagged unions
/// are left as they are. A copy of a terminated slice or name ends in zero. On an error the copies
/// already made stay in `allocator`, so it is an arena's.
pub fn copySlices(allocator: std.mem.Allocator, comptime V: type, value: *V) !void {
    switch (@typeInfo(V)) {
        .pointer => |pointer| if (pointer.size == .slice and pointer.is_const) {
            const copied = if (pointer.sentinel_ptr != null)
                try allocator.dupeSentinel(pointer.child, value.*, @as(pointer.child, 0))
            else
                try allocator.dupe(pointer.child, value.*);
            // Flat elements, such as pixels, are copied whole and never visited.
            if (comptime holdsPointers(pointer.child)) {
                for (copied) |*item| try copySlices(allocator, pointer.child, item);
            }
            value.* = copied;
        } else if (pointer.size == .many and pointer.is_const and pointer.sentinel_ptr != null) {
            // A terminated name, such as a shader entry point: its bytes end at the sentinel.
            const terminated = std.mem.span(value.*);
            const copied = try allocator.dupeSentinel(pointer.child, terminated, @as(pointer.child, 0));
            value.* = copied.ptr;
        },
        .optional => |optional| if (value.*) |*inner| try copySlices(allocator, optional.child, inner),
        .@"struct" => |info| {
            // A packed struct holds no pointers, and its fields have no addresses of their own.
            if (info.layout == .@"packed") return;
            inline for (info.fields) |field| try copySlices(allocator, field.type, &@field(value.*, field.name));
        },
        // An untagged union's live field is unknown, so it cannot be copied.
        .@"union" => |info| if (info.tag_type != null) switch (value.*) {
            inline else => |*inner| try copySlices(allocator, @TypeOf(inner.*), inner),
        },
        .array => |info| if (comptime holdsPointers(info.child)) {
            for (value) |*item| try copySlices(allocator, info.child, item);
        },
        else => {},
    }
}

/// Whether a `V` may hold a pointer, so that copying a slice of them must visit each one.
fn holdsPointers(comptime V: type) bool {
    return comptime holdsPointersWithin(V, 16);
}

/// `depth` bounds a type that holds slices of itself; past it the answer is yes, which only
/// costs a visit.
fn holdsPointersWithin(comptime V: type, comptime depth: u32) bool {
    if (depth == 0) return true;
    switch (@typeInfo(V)) {
        .pointer => return true,
        .optional => |info| return holdsPointersWithin(info.child, depth - 1),
        .array => |info| return holdsPointersWithin(info.child, depth - 1),
        .@"struct" => |info| {
            if (info.layout == .@"packed") return false;
            for (info.fields) |field| {
                if (holdsPointersWithin(field.type, depth - 1)) return true;
            }
            return false;
        },
        .@"union" => |info| {
            for (info.fields) |field| {
                if (holdsPointersWithin(field.type, depth - 1)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Runs a sequencer of host systems as a root run for a host caller, outside any other run:
/// `context` is what their kernels' frames carry (`Frame.context`), and nothing is done around each
/// system.
pub fn runHost(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry, sequencer: *const Sequencer, context: *anyopaque) void {
    const env: Env = .{
        .memory = memory,
        .atoms = atoms,
        .tables = tables,
        .hooks = .{ .context = context, .enter = ignoreSystem, .leave = ignoreSystem, .finished = ignoreFinished },
    };
    _ = run(sequencer, &env, null);
}

fn ignoreSystem(context: *anyopaque, system: *const System) void {
    _ = context;
    _ = system;
}

fn ignoreFinished(context: *anyopaque, system: *const System, changed: bool) void {
    _ = context;
    _ = system;
    _ = changed;
}

/// A host system's kernels, without the journal: each runs whatever the one before it did,
/// and an error is logged. The inbox is cleared once they have all run.
fn runHostSystem(env: *const Env, system: *const System) void {
    var name_buffer: [inbox_name_max]u8 = undefined;
    const inbox_table = env.tables.findHandleByName(Atom.from(inboxName(system.*, &name_buffer)));
    const messages = readInbox(env, inbox_table) catch |err| {
        Log.err("host_inbox_unreadable", .{ .system = system.name, .@"error" = @errorName(err) });
        return;
    };
    const frame = systemFrame(env, system, messages);
    // A host system's state is its own: it subscribes to nothing through the sequencer.
    if (runsThisFrame(system, &frame) != .runs) return;
    const access = system.access(&frame);
    const resolved = ResolvedAccess.resolve(env.tables, &access) orelse return;
    env.hooks.enter(env.hooks.context, system);
    defer env.hooks.leave(env.hooks.context, system);
    const system_scope = log.scopeTag(system.name);
    for (system.kernels) |*kernel| {
        const kernel_zone = log.beginNamedZone(system_scope, kernel.zoneName());
        defer kernel_zone.end();
        var pass: Pass = .{ .frame = &frame, .kernel = kernel, .access = &resolved };
        kernel.run(&pass) catch |err| Log.err("host_kernel_error", .{ .kernel = kernel.name, .@"error" = @errorName(err) });
    }
    if (inbox_table) |handle| if (env.tables.get(handle)) |found| found.clear();
    env.hooks.finished(env.hooks.context, system, messages.len != 0);
}

// ---- faults -----------------------------------------------------------------------------

/// A row per system or sequencer that faulted: its consecutive faults, and the last fault's
/// kernel and error. Written directly, never journaled: a fault outlives the run it ended.
pub const faults_table_name = "sequencer_systems";
const faults_table = Atom.from(faults_table_name);
const faults_capacity = 32;

const FaultRow = struct { system: *Atom, faults: *u32, kernel: *Atom, @"error": *Atom };

const no_atom: Atom = @enumFromInt(0);

/// Makes the faults table, `sequencer_systems`, unless it is there. The owner of a root sequencer
/// calls it at init, before any run: without the table a fault still discards its run, but is
/// neither recorded nor logged.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 4);
    defer schema.deinit();
    try schema.addFieldFallible("system", Atom, .atom);
    try schema.addFieldFallible("faults", u32, .int);
    try schema.addFieldFallible("kernel", Atom, .atom);
    try schema.addFieldFallible("error", Atom, .atom);
    _ = try tables.ensure(&schema, faults_capacity, faults_table, .durable);
}

/// The fault row of `system`, made on its first fault, for writing in place outside any run. Null
/// without the faults table, or when the row cannot be made.
pub fn faultRow(tables: *Table.Registry, system: Atom) ?FaultRow {
    const found = tables.findByName(faults_table) orelse return null;
    std.debug.assert(found.journal == null);
    var rows = found.query(FaultRow);
    while (rows.next()) |row| {
        if (row.view.system.* == system) return row.view;
    }
    const created = found.tryInsert(.{ .system = system, .faults = @as(u32, 0), .kernel = no_atom, .@"error" = no_atom }) catch return null;
    return found.getRow(created, FaultRow);
}

fn recordFault(env: *const Env, system: Atom, kernel: ?*const Kernel, err: anyerror) void {
    const row = faultRow(env.tables, system) orelse return;
    const kernel_name = if (kernel) |found| found.name else "";
    // A fault that repeats every frame is logged when it starts, and counted after.
    if (row.faults.* == 0) Log.err("kernel_fault", .{ .kernel = kernel_name, .@"error" = @errorName(err) });
    row.faults.* +|= 1;
    row.kernel.* = if (kernel) |found| Atom.from(found.name) else no_atom;
    // The one intern a frame may make: a fault's error, named for the table that shows it.
    row.@"error".* = env.atoms.intern(@errorName(err));
}

fn clearFaults(tables: *Table.Registry, system: Atom) void {
    const found = tables.findByName(faults_table) orelse return;
    var rows = found.query(FaultRow);
    while (rows.next()) |row| {
        if (row.view.system.* == system) row.view.faults.* = 0;
    }
}

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

const test_state_name = Atom.from("test_sequencer_state");
const test_events_name = Atom.from("test_sequencer_events");
const test_other_name = Atom.from("test_sequencer_other");

/// `mode`: 0 runs, 1 faults after writing and appending, 2 writes a table
/// it only reads.
const TestState = struct { mode: *u8, count: *u32, second: *u32 };

fn testAccess(frame: *const Frame) Access {
    _ = frame;
    var access: Access = .{};
    access.write(test_state_name);
    access.write(test_events_name);
    access.read(test_other_name);
    return access;
}

fn testClaims(tag: Atom) bool {
    _ = tag;
    return true;
}

fn testFirst(pass: *Pass) !void {
    const state = try pass.writeSingleton(test_state_name, TestState);
    state.count.* += 1;
    _ = try pass.append(test_events_name, .{ .count = state.count.* });
    switch (state.mode.*) {
        1 => return error.TestFault,
        2 => _ = try pass.writeSingleton(test_other_name, TestState),
        else => {},
    }
}

fn testSecond(pass: *Pass) !void {
    const state = try pass.writeSingleton(test_state_name, TestState);
    state.second.* += 1;
}

fn testSystem() System {
    return .{
        .name = "test_sequencer",
        .root = Atom.from("test_sequencer"),
        .claims = testClaims,
        .access = testAccess,
        .kernels = &.{
            .{ .name = "test_sequencer.first", .run = testFirst },
            .{ .name = "test_sequencer.second", .run = testSecond },
        },
    };
}

/// A child sequencer that always faults, under a root that otherwise succeeds.
fn testFault(pass: *Pass) !void {
    _ = try pass.append(test_events_name, .{ .count = @as(u32, 99) });
    return error.ChildFault;
}

fn testFaulting() System {
    return .{
        .name = "test_faulting",
        .root = Atom.from("test_faulting"),
        .claims = testClaims,
        .access = testAccess,
        .kernels = &.{.{ .name = "test_faulting.fault", .run = testFault }},
    };
}

const TestHooks = struct {
    changed: usize = 0,

    fn nothing(context: *anyopaque, system: *const System) void {
        _ = context;
        _ = system;
    }

    fn finished(context: *anyopaque, system: *const System, changed: bool) void {
        _ = system;
        const self: *TestHooks = @ptrCast(@alignCast(context));
        if (changed) self.changed += 1;
    }
};

const Fixture = struct {
    memory: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    hooks: TestHooks = .{},
    state_table: *Table = undefined,
    events: *Table = undefined,

    fn init(f: *Fixture) !void {
        f.memory.init(testing.allocator);
        try f.atoms.init(&f.memory);
        try f.tables.init(&f.memory, 32);
        const scratch = try f.memory.tableScratchAllocator();
        try ensure(scratch, &f.atoms, &f.tables);
        var state_schema: Table.Schema = undefined;
        try state_schema.init(scratch.allocator, &f.atoms, 3);
        defer state_schema.deinit();
        try state_schema.addFieldFallible("mode", u8, .int);
        try state_schema.addFieldFallible("count", u32, .int);
        try state_schema.addFieldFallible("second", u32, .int);
        const defaults = .{ .mode = @as(u8, 1), .count = @as(u32, 0), .second = @as(u32, 0) };
        f.state_table = (try f.tables.ensureSingleton(&state_schema, test_state_name, defaults, .durable)).table;
        _ = try f.tables.ensureSingleton(&state_schema, test_other_name, defaults, .durable);
        var events_schema: Table.Schema = undefined;
        try events_schema.init(scratch.allocator, &f.atoms, 1);
        defer events_schema.deinit();
        try events_schema.addFieldFallible("count", u32, .int);
        f.events = (try f.tables.ensure(&events_schema, 4, test_events_name, .durable)).table;
    }

    fn deinit(f: *Fixture) void {
        f.tables.deinit();
        f.atoms.deinit();
        f.memory.deinit();
    }

    fn env(f: *Fixture) Env {
        return .{
            .memory = &f.memory,
            .atoms = &f.atoms,
            .tables = &f.tables,
            .hooks = .{ .context = &f.hooks, .enter = TestHooks.nothing, .leave = TestHooks.nothing, .finished = TestHooks.finished },
        };
    }

    fn state(f: *Fixture) TestState {
        return f.state_table.getRow(.{ .row = 0, .generation = f.state_table.rowGeneration(0) }, TestState).?;
    }
};

test "a faulting kernel discards its sequencer's run, which runs again next frame" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const sequencer: Sequencer = .{ .name = "test_root", .steps = &.{.{ .system = testSystem() }} };
    const env = f.env();

    // A fault takes back the write and the append, and skips `second`.
    try testing.expectEqual(Outcome.faulted, run(&sequencer, &env, null));
    try testing.expectEqual(@as(u32, 0), f.state().count.*);
    try testing.expectEqual(@as(u32, 0), f.state().second.*);
    try testing.expectEqual(@as(u32, 0), f.events.count());
    const faults = faultRow(&f.tables, Atom.from(testSystem().name)).?;
    try testing.expectEqual(@as(u32, 1), faults.faults.*);
    try testing.expectEqual(f.atoms.intern("test_sequencer.first"), faults.kernel.*);
    try testing.expectEqual(f.atoms.intern("TestFault"), faults.@"error".*);

    // A write to a table only declared as read is a fault too.
    f.state().mode.* = 2;
    try testing.expectEqual(Outcome.faulted, run(&sequencer, &env, null));
    try testing.expectEqual(@as(u32, 0), f.state().count.*);
    try testing.expectEqual(@as(u32, 2), faults.faults.*);
    try testing.expectEqual(f.atoms.intern("UndeclaredWrite"), faults.@"error".*);

    // Next frame without the fault, every kernel runs, the root flushes and the streak ends.
    f.state().mode.* = 0;
    try testing.expectEqual(Outcome.done, run(&sequencer, &env, null));
    try testing.expectEqual(@as(u32, 1), f.state().count.*);
    try testing.expectEqual(@as(u32, 1), f.state().second.*);
    try testing.expectEqual(@as(u32, 1), f.events.count());
    try testing.expectEqual(@as(u32, 0), faults.faults.*);
    try testing.expectEqual(@as(usize, 1), f.hooks.changed);
}

test "a child sequencer that faults is discarded alone" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.state().mode.* = 0;
    const child: Sequencer = .{ .name = "test_child", .steps = &.{.{ .system = testFaulting() }} };
    const root: Sequencer = .{ .name = "test_root", .steps = &.{ .{ .system = testSystem() }, .{ .sequencer = child } } };
    const env = f.env();
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 1), f.state().count.*);
    // The root's append stays; the child's is gone.
    try testing.expectEqual(@as(u32, 1), f.events.count());
    try testing.expectEqual(@as(u32, 1), faultRow(&f.tables, Atom.from(testFaulting().name)).?.faults.*);
}

fn testCallAppends(env: *const Env, layer: *Layer) Outcome {
    const child: Sequencer = .{ .name = "test_called", .steps = &.{.{ .system = testSystem() }} };
    return run(&child, env, layer);
}

test "a call step runs a sequencer of its own as a child of the run" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.state().mode.* = 0;
    const call: Call = .{ .name = "test_call", .run = testCallAppends };
    const root: Sequencer = .{ .name = "test_root", .steps = &.{.{ .call = call }} };
    const env = f.env();
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 1), f.state().count.*);
    try testing.expectEqual(@as(u32, 1), f.events.count());
}

/// Counts the messages in its inbox, then faults while `mode` is 1.
fn testTakeInbox(pass: *Pass) !void {
    const state = try pass.writeSingleton(test_state_name, TestState);
    state.count.* += @intCast(pass.frame.messages.len);
    if (state.mode.* == 1) return error.TestFault;
}

fn testReceiver() System {
    return .{
        .name = "test_receiver",
        .root = Atom.from("test_receiver"),
        .claims = testClaims,
        .access = testAccess,
        .kernels = &.{.{ .name = "test_receiver.take", .run = testTakeInbox }},
    };
}

test "a run that faults leaves its inbox for the next frame's, which clears it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const root: Sequencer = .{ .name = "test_root", .steps = &.{.{ .system = testReceiver() }} };
    try ensureInboxes(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, &root);
    const note = Atom.from("note");
    try deliverMessage(&f.tables, inboxOf(testReceiver()), note, &.{}, &.{});
    try deliverMessage(&f.tables, inboxOf(testReceiver()), note, &.{}, &.{});
    const env = f.env();
    var buffer: [inbox_name_max]u8 = undefined;
    const inbox = f.tables.findByName(Atom.from(inboxName(testReceiver(), &buffer))).?;

    try testing.expectEqual(Outcome.faulted, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 2), inbox.count());
    f.state().mode.* = 0;
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 2), f.state().count.*);
    try testing.expectEqual(@as(u32, 0), inbox.count());
}

/// Active while the other state's `mode` is not 0.
fn testOtherActive(frame: *const Frame) bool {
    const other = frame.tables.findByName(test_other_name) orelse return false;
    const state = other.getRow(.{ .row = 0, .generation = other.rowGeneration(0) }, TestState) orelse return false;
    return state.mode.* != 0;
}

/// Counts its runs in `second`.
fn testGuarded() System {
    return .{
        .name = "test_guarded",
        .root = Atom.from("test_guarded"),
        .claims = testClaims,
        .active = testOtherActive,
        .access = testAccess,
        .kernels = &.{.{ .name = "test_guarded.second", .run = testSecond }},
    };
}

test "a guarded system skips a frame its guard declines unless it has messages" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const root: Sequencer = .{ .name = "test_root", .steps = &.{.{ .system = testGuarded() }} };
    try ensureInboxes(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, &root);
    const env = f.env();
    const other = f.tables.findByName(test_other_name).?;
    const other_state = other.getRow(.{ .row = 0, .generation = other.rowGeneration(0) }, TestState).?;

    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 1), f.state().second.*);

    other_state.mode.* = 0;
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 1), f.state().second.*);

    // A message runs it whatever its guard says, and is taken.
    try deliverMessage(&f.tables, inboxOf(testGuarded()), Atom.from("note"), &.{}, &.{});
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 2), f.state().second.*);
    var buffer: [inbox_name_max]u8 = undefined;
    try testing.expectEqual(@as(u32, 0), f.tables.findByName(Atom.from(inboxName(testGuarded(), &buffer))).?.count());
}

const test_subscriptions_name = "subscriptions.test";
const TestSubscription = struct { value: *u32, subscriber: *Atom };

fn testSubscriberAccess(frame: *const Frame) Access {
    _ = frame;
    var access: Access = .{};
    access.write(test_state_name);
    access.write(Atom.from(test_subscriptions_name));
    access.read(test_other_name);
    return access;
}

/// Counts its runs in `count` and subscribes with the count; faults while `mode` is 2.
fn testSubscribe(pass: *Pass) !void {
    const state = try pass.writeSingleton(test_state_name, TestState);
    state.count.* += 1;
    const subscriptions = try pass.writeTable(Atom.from(test_subscriptions_name));
    _ = try subscriptions.tryInsert(.{ .value = state.count.* });
    if (state.mode.* == 2) return error.TestFault;
}

/// Idle while the other table's `count` is 0.
fn testOtherIdle(frame: *const Frame) bool {
    const other = frame.tables.findByName(test_other_name) orelse return false;
    const state = other.getRow(.{ .row = 0, .generation = other.rowGeneration(0) }, TestState) orelse return false;
    return state.count.* == 0;
}

fn testSubscriber() System {
    return .{
        .name = "test_subscriber",
        .root = Atom.from("test_subscriber"),
        .claims = claims_nothing,
        .active = testOtherActive,
        .idle = testOtherIdle,
        .access = testSubscriberAccess,
        .kernels = &.{.{ .name = "test_subscriber.subscribe", .run = testSubscribe }},
    };
}

fn testSubscriberB() System {
    return .{
        .name = "test_subscriber_b",
        .root = Atom.from("test_subscriber_b"),
        .claims = claims_nothing,
        .access = testSubscriberAccess,
        .kernels = &.{.{ .name = "test_subscriber_b.subscribe", .run = testSubscribe }},
    };
}

test "systems subscribing in one run each keep their own rows" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const subscriptions = made: {
        const scratch = try f.memory.tableScratchAllocator();
        var schema: Table.Schema = undefined;
        try schema.init(scratch.allocator, &f.atoms, 3);
        defer schema.deinit();
        try schema.addFieldFallible("value", u32, .int);
        try schema.addFieldFallible(subscriber_field, Atom, .atom);
        try schema.addFieldFallible(subscription_order_field, u32, .int);
        try f.atoms.tryInternAll(&.{ test_subscriptions_name, "test_subscriber", "test_subscriber_b" });
        const made = (try f.tables.ensure(&schema, 8, Atom.from(test_subscriptions_name), .durable)).table;
        try ensureSubscriptions(scratch, &f.atoms, &f.tables, test_subscriptions_name);
        break :made made;
    };
    // As the game's and the editor's are: child runs one after the other, the second seeing
    // the first's rows in its parent's layer.
    const first_child: Sequencer = .{ .name = "test_first_child", .steps = &.{.{ .system = testSubscriberB() }} };
    const second_child: Sequencer = .{ .name = "test_second_child", .steps = &.{.{ .system = testSubscriber() }} };
    const root: Sequencer = .{ .name = "test_root", .steps = &.{ .{ .sequencer = first_child }, .{ .sequencer = second_child } } };
    try ensureInboxes(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, &first_child);
    try ensureInboxes(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, &second_child);
    const env = f.env();
    f.state().mode.* = 0;
    // Each run, each system replaces only its own row.
    for (0..3) |_| {
        try testing.expectEqual(Outcome.done, run(&root, &env, null));
        try testing.expectEqual(@as(u32, 2), subscriptions.count());
        var first = false;
        var second = false;
        var rows = subscriptions.readQuery(TestSubscription);
        while (rows.next()) |row| {
            if (row.view.subscriber.* == Atom.from("test_subscriber")) first = true;
            if (row.view.subscriber.* == Atom.from("test_subscriber_b")) second = true;
        }
        try testing.expect(first and second);
    }
}

test "a system's subscriptions last until it runs again, and go when it is switched off" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const subscriptions = made: {
        const scratch = try f.memory.tableScratchAllocator();
        var schema: Table.Schema = undefined;
        try schema.init(scratch.allocator, &f.atoms, 3);
        defer schema.deinit();
        try schema.addFieldFallible("value", u32, .int);
        try schema.addFieldFallible(subscriber_field, Atom, .atom);
        try schema.addFieldFallible(subscription_order_field, u32, .int);
        try f.atoms.tryInternAll(&.{ test_subscriptions_name, "test_subscriber" });
        const made = (try f.tables.ensure(&schema, 8, Atom.from(test_subscriptions_name), .durable)).table;
        try ensureSubscriptions(scratch, &f.atoms, &f.tables, test_subscriptions_name);
        break :made made;
    };
    const root: Sequencer = .{ .name = "test_root", .steps = &.{.{ .system = testSubscriber() }} };
    try ensureInboxes(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, &root);
    const env = f.env();
    const other = f.tables.findByName(test_other_name).?;
    const other_state = other.getRow(.{ .row = 0, .generation = other.rowGeneration(0) }, TestState).?;
    f.state().mode.* = 0;

    const Expect = struct {
        fn only(table: *Table, value: u32) !void {
            try testing.expectEqual(@as(u32, 1), table.count());
            var rows = table.readQuery(TestSubscription);
            const row = rows.next().?;
            try testing.expectEqual(value, row.view.value.*);
            try testing.expectEqual(Atom.from("test_subscriber"), row.view.subscriber.*);
        }
    };

    // Idle, but it has never subscribed: it runs, and its row names it.
    other_state.count.* = 0;
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try Expect.only(subscriptions, 1);
    // Rewriting its subscriptions is not a change to anything it shows.
    try testing.expectEqual(@as(usize, 1), f.hooks.changed);

    // Idle, it keeps them.
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try Expect.only(subscriptions, 1);

    // Running replaces them.
    other_state.count.* = 1;
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try Expect.only(subscriptions, 2);

    // A run that faults keeps what it had.
    f.state().mode.* = 2;
    try testing.expectEqual(Outcome.faulted, run(&root, &env, null));
    try Expect.only(subscriptions, 2);
    f.state().mode.* = 0;

    // After a reset it runs to subscribe again, idle or not.
    other_state.count.* = 0;
    resetSubscriptions(&f.tables);
    try testing.expectEqual(@as(u32, 0), subscriptions.count());
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try Expect.only(subscriptions, 3);

    // Switched off, it hears nothing.
    other_state.mode.* = 0;
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 0), subscriptions.count());
}

test "a retired system has subscribed to nothing, through a reset, until it runs again" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const subscriptions = made: {
        const scratch = try f.memory.tableScratchAllocator();
        var schema: Table.Schema = undefined;
        try schema.init(scratch.allocator, &f.atoms, 3);
        defer schema.deinit();
        try schema.addFieldFallible("value", u32, .int);
        try schema.addFieldFallible(subscriber_field, Atom, .atom);
        try schema.addFieldFallible(subscription_order_field, u32, .int);
        try f.atoms.tryInternAll(&.{ test_subscriptions_name, "test_subscriber" });
        const made = (try f.tables.ensure(&schema, 8, Atom.from(test_subscriptions_name), .durable)).table;
        try ensureSubscriptions(scratch, &f.atoms, &f.tables, test_subscriptions_name);
        break :made made;
    };
    const root: Sequencer = .{ .name = "test_root", .steps = &.{.{ .system = testSubscriber() }} };
    try ensureInboxes(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, &root);
    const env = f.env();
    const subscriber = Atom.from("test_subscriber");
    f.state().mode.* = 0;

    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 1), subscriptions.count());
    try testing.expect(subscribedSinceReset(&f.tables, subscriber));
    // Only reset, its rows are yet to come: it has not said what it subscribes to.
    resetSubscriptions(&f.tables);
    try testing.expect(!subscribedSinceReset(&f.tables, subscriber));
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 1), subscriptions.count());

    // Retired, its rows go and it has said so, through the reset that follows.
    retireSubscribers(&f.tables, &root);
    try testing.expectEqual(@as(u32, 0), subscriptions.count());
    try testing.expect(subscribedSinceReset(&f.tables, subscriber));
    resetSubscriptions(&f.tables);
    try testing.expect(subscribedSinceReset(&f.tables, subscriber));

    // Run again, it subscribes as any other.
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 1), subscriptions.count());
    resetSubscriptions(&f.tables);
    try testing.expect(!subscribedSinceReset(&f.tables, subscriber));
}

/// Adds each note's payload to the count and its user data to `second`, then faults while
/// `mode` is 1.
fn testTakeMessages(pass: *Pass) !void {
    const state = try pass.writeSingleton(test_state_name, TestState);
    for (pass.frame.messages) |received| {
        if (received.tag != Atom.from("note")) continue;
        if (received.payload.len != 0) state.count.* += (try received.payloadAs(u32)).*;
        if (received.user_data.len != 0) state.second.* += (try received.userDataAs(u32)).*;
    }
    if (state.mode.* == 1) return error.TestFault;
}

fn testMessageReceiver() System {
    return .{
        .name = "test_message_receiver",
        .root = Atom.from("test_message_receiver"),
        .claims = claims_nothing,
        .access = testAccess,
        .kernels = &.{.{ .name = "test_message_receiver.take", .run = testTakeMessages }},
    };
}

test "a message's payload and user data reach its kernels, each absent when empty, again after a fault" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const root: Sequencer = .{ .name = "test_root", .steps = &.{.{ .system = testMessageReceiver() }} };
    try ensureInboxes(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, &root);
    const inbox_name = inboxOf(testMessageReceiver());
    const note = Atom.from("note");
    const five: u32 = 5;
    const seven: u32 = 7;
    const eleven: u32 = 11;
    try deliverMessage(&f.tables, inbox_name, note, std.mem.asBytes(&seven), std.mem.asBytes(&five));
    try deliverMessage(&f.tables, inbox_name, note, std.mem.asBytes(&eleven), &.{});
    try deliverMessage(&f.tables, inbox_name, note, &.{}, std.mem.asBytes(&seven));
    const inbox = f.tables.findByName(inbox_name).?;
    const user_data_field = inbox.getSchema().fieldIndex("user_data").?;
    var rows = inbox.rows();
    var without_user_data: u32 = 0;
    while (rows.next()) |row| {
        if (!inbox.rowMask(row.row).has(inbox.getSchema().fields[user_data_field].bit)) without_user_data += 1;
    }
    try testing.expectEqual(@as(u32, 1), without_user_data);
    const env = f.env();

    f.state().mode.* = 1;
    try testing.expectEqual(Outcome.faulted, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 3), inbox.count());
    f.state().mode.* = 0;
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 12), f.state().count.*);
    try testing.expectEqual(@as(u32, 18), f.state().second.*);
    try testing.expectEqual(@as(u32, 0), inbox.count());
}

test "user data is an opaque bytes column of any length, copied when pushed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const Ask = struct { count: u32, user_data: UserData = .none };
    try Commands(Ask).ensure(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, "commands.user_data_test");
    const commands = Commands(Ask).of(&f.memory, &f.tables, "commands.user_data_test");
    var given = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 };
    commands.push(.{ .count = 1, .user_data = .{ .bytes = &given } });
    commands.push(.{ .count = 2 });
    @memset(&given, 0);
    const table = f.tables.findByName(Atom.from("commands.user_data_test")).?;
    const field = table.getSchema().fields[table.getSchema().fieldIndex("user_data").?];
    try testing.expectEqual(Table.FieldType.bytes, field.field_type);
    var rows = commands.iterate();
    const first = rows.next().?;
    try testing.expectEqual(@as(usize, 20), first.user_data.bytes.len);
    try testing.expectEqual(@as(u8, 20), first.user_data.bytes[19]);
    try testing.expectEqual(@as(usize, 0), rows.next().?.user_data.bytes.len);
}

test "subscriptions keep copies of their slices, terminated names and user data until the table is reset" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const Watch = union(enum) {
        path: struct {
            name: []const u8,
            entry: [*:0]const u8 = "main",
            flags: packed struct { recursive: bool = false, hidden: bool = false } = .{},
            user_data: UserData = .none,
        },
        count: u32,
    };
    try Subscribed(Watch).ensure(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, "subscribed.test");
    const subscribed = Subscribed(Watch).of(&f.memory, &f.tables, "subscribed.test");
    {
        var text: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&text, "a/b", .{});
        var entry_text: [8]u8 = undefined;
        const entry = try std.fmt.bufPrintZ(&entry_text, "vs", .{});
        var seven: u64 = 7;
        subscribed.push(.{ .path = .{ .name = name, .entry = entry.ptr, .flags = .{ .hidden = true }, .user_data = .of(&seven) } });
        @memset(&text, 'x');
        @memset(&entry_text, 'x');
        seven = 0;
    }
    subscribed.push(.{ .count = 3 });
    try testing.expectEqual(@as(u32, 2), subscribed.count());
    var rows = subscribed.iterate();
    const first = rows.next().?;
    try testing.expectEqualStrings("a/b", first.path.name);
    const entry = std.mem.span(first.path.entry);
    try testing.expectEqualStrings("vs", entry);
    try testing.expect(first.path.flags.hidden);
    try testing.expectEqual(@as(usize, 8), first.path.user_data.bytes.len);
    try testing.expectEqual(@as(u64, 7), std.mem.bytesToValue(u64, first.path.user_data.bytes[0..8]));
    try testing.expectEqual(@as(u32, 3), rows.next().?.count);
    try testing.expect(rows.next() == null);
    subscribed.reset();
    try testing.expectEqual(@as(u32, 0), subscribed.count());
}

test "a three-byte value is kept in a four-byte hex column and read back as itself" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const Tinted = struct { color: ?[3]u8 = null, alpha: u8 = 0 };
    try Commands(Tinted).ensure(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, "commands.three_byte_test");
    const commands = Commands(Tinted).of(&f.memory, &f.tables, "commands.three_byte_test");
    commands.push(.{ .color = .{ 1, 2, 3 }, .alpha = 4 });
    commands.push(.{});
    const table = f.tables.findByName(Atom.from("commands.three_byte_test")).?;
    const field = table.getSchema().fields[table.getSchema().fieldIndex("color").?];
    try testing.expectEqual(@as(usize, 4), @as(usize, field.size));
    var rows = commands.iterate();
    const first = rows.next().?;
    try testing.expectEqual([3]u8{ 1, 2, 3 }, first.color.?);
    try testing.expectEqual(@as(u8, 4), first.alpha);
    try testing.expect(rows.next().?.color == null);
}

const TakeRequest = union(enum) { say: []const u8 };
const take_commands_name = "commands.take_test";
const TakeRequests = Commands(TakeRequest);

const TakeHeard = struct {
    text: [16]u8 = undefined,
    len: usize = 0,
    takes: u32 = 0,

    fn hear(heard: *TakeHeard, request: *const TakeRequest) !void {
        const text = request.say;
        @memcpy(heard.text[0..text.len], text);
        heard.len = text.len;
        heard.takes += 1;
    }
};

var take_heard: TakeHeard = .{};

fn takeAccess(frame: *const Frame) Access {
    _ = frame;
    var access: Access = .{};
    access.write(test_state_name);
    access.write(Atom.from(take_commands_name));
    return access;
}

fn takeKernel(pass: *Pass) !void {
    const requests = TakeRequests.of(pass.frame.memory, pass.frame.tables, take_commands_name);
    try requests.take(pass, &take_heard, TakeHeard.hear);
    const state = try pass.writeSingleton(test_state_name, TestState);
    if (state.mode.* == 1) return error.TestFault;
}

fn testTaker() System {
    return .{
        .name = "test_taker",
        .root = Atom.from("test_taker"),
        .claims = testClaims,
        .access = takeAccess,
        .kernels = &.{.{ .name = "test_taker.take", .run = takeKernel }},
    };
}

test "a journaled system takes its command rows in its run, and a fault leaves them and their slices" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try TakeRequests.ensure(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, take_commands_name);
    const requests = TakeRequests.of(&f.memory, &f.tables, take_commands_name);
    {
        var text: [5]u8 = "hello".*;
        requests.push(.{ .say = &text });
        @memset(&text, 'x');
    }
    const root: Sequencer = .{ .name = "test_root", .steps = &.{.{ .system = testTaker() }} };
    const env = f.env();
    take_heard = .{};

    // The run takes the row and faults: the row comes back, and reclaiming keeps its text,
    // which a later push would overwrite had the arena been reset.
    try testing.expectEqual(Outcome.faulted, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 1), requests.count());
    f.tables.reclaimPayloads();
    requests.push(.{ .say = "world" });
    var rows = requests.iterate();
    try testing.expectEqualStrings("hello", rows.next().?.say);
    try testing.expectEqualStrings("world", rows.next().?.say);

    f.state().mode.* = 0;
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 0), requests.count());
    try testing.expectEqual(@as(u32, 3), take_heard.takes);
    try testing.expectEqualStrings("world", take_heard.text[0..take_heard.len]);
    f.tables.reclaimPayloads();
    // A clean run finds nothing left to apply.
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 3), take_heard.takes);
}

test "command rows copy slices held by slices' elements and by unions" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const Dab = struct { factors: []const f32 };
    const Edit = union(enum) { paint: []const Dab, rename: [:0]const u8, clear };
    const Request = union(enum) { preview: struct { edits: []const Edit }, count: u32 };
    try Commands(Request).ensure(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, "commands.copy_test");
    const requests = Commands(Request).of(&f.memory, &f.tables, "commands.copy_test");
    {
        var factors: [2]f32 = .{ 0.25, 0.5 };
        var dabs: [1]Dab = .{.{ .factors = &factors }};
        var name: [4:0]u8 = "lamp".*;
        var edits: [3]Edit = .{ .{ .paint = &dabs }, .{ .rename = &name }, .clear };
        requests.push(.{ .preview = .{ .edits = &edits } });
        // The requester's storage ends with the dispatch.
        @memset(&factors, 9);
        dabs[0].factors = &.{};
        @memset(&name, 'x');
        edits[0] = .clear;
    }
    const Check = struct {
        seen: u32 = 0,
        fn apply(check: *@This(), request: *Request) Applied {
            check.seen += 1;
            const edits = request.preview.edits;
            testing.expectEqual(@as(usize, 3), edits.len) catch unreachable;
            const factors = edits[0].paint[0].factors;
            testing.expectEqualSlices(f32, &.{ 0.25, 0.5 }, factors) catch unreachable;
            testing.expectEqualStrings("lamp", edits[1].rename) catch unreachable;
            testing.expect(edits[2] == .clear) catch unreachable;
            return .done;
        }
    };
    var check: Check = .{};
    requests.drain(&check, Check.apply);
    try testing.expectEqual(@as(u32, 1), check.seen);
}

test "command rows are columns: a kind, then each variant's values, shared only where declared" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const Side = enum { left, right };
    const Request = union(enum) {
        move: struct { doc: Atom, side: Side, by: ?f32 = null },
        rename: struct { doc: Atom, name: []const u8 },
        clear,

        pub const shared_columns = [_][]const u8{"doc"};
    };
    const Requests = Commands(Request);
    try Requests.ensure(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, "commands.columns_test");
    const requests = Requests.of(&f.memory, &f.tables, "commands.columns_test");
    requests.push(.{ .move = .{ .doc = Atom.from("blue"), .side = .right } });
    requests.push(.{ .rename = .{ .doc = Atom.from("red"), .name = "lamp" } });
    requests.push(.clear);

    const table = f.tables.findByName(Atom.from("commands.columns_test")).?;
    var names: [8][]const u8 = undefined;
    for (table.getSchema().fields, 0..) |field, index| names[index] = field.name;
    const expected = [_][]const u8{ "kind", "doc", "move.side", "move.by", "rename.name" };
    try testing.expectEqual(expected.len, table.getSchema().fields.len);
    for (expected, names[0..expected.len]) |want, got| try testing.expectEqualStrings(want, got);

    // The move row holds its kind, the shared doc and its side, and no other column: its
    // absent `by` and the rename's name are not there.
    const first = table.rowAtPosition(0);
    const handle: Table.RowHandle = .{ .row = first, .generation = table.rowGeneration(first) };
    try testing.expectEqual(Atom.from("move"), table.getField(Atom, handle, "kind").?.*);
    try testing.expectEqual(Atom.from("right"), table.getField(Atom, handle, "move.side").?.*);
    const mask = table.rowMask(first);
    const schema = table.getSchema();
    try testing.expect(mask.has(schema.fields[schema.fieldIndex("doc").?].bit));
    try testing.expect(!mask.has(schema.fields[schema.fieldIndex("move.by").?].bit));
    try testing.expect(!mask.has(schema.fields[schema.fieldIndex("rename.name").?].bit));

    var rows = requests.iterate();
    const move = rows.next().?.move;
    try testing.expectEqual(Atom.from("blue"), move.doc);
    try testing.expectEqual(Side.right, move.side);
    try testing.expect(move.by == null);
    const rename = rows.next().?.rename;
    try testing.expectEqual(Atom.from("red"), rename.doc);
    try testing.expectEqualStrings("lamp", rename.name);
    try testing.expect(rows.next().? == .clear);
    try testing.expect(rows.next() == null);
}

const TestEvent = union(enum) { moved: struct { to: Atom }, stopped };
const TestEvents = Events(TestEvent);
const test_events_table = "events.test";

/// What the reader took, across runs.
var test_events_taken: [8]TestEvent = undefined;
var test_events_taken_count: usize = 0;

fn eventsReaderAccess(frame: *const Frame) Access {
    var access: Access = .{};
    access.write(test_state_name);
    TestEvents.declare(&access, frame.tables, test_events_table);
    return access;
}

fn eventsReaderKernel(pass: *Pass) !void {
    const events = TestEvents.of(pass.frame.tables, test_events_table);
    var taken: [2]TestEvent = undefined;
    const read = try events.read(pass, Atom.from("test_reader"), &taken);
    for (read) |event| {
        test_events_taken[test_events_taken_count] = event;
        test_events_taken_count += 1;
    }
    const state = try pass.writeSingleton(test_state_name, TestState);
    if (state.mode.* == 1) return error.TestFault;
}

fn testEventsReader() System {
    return .{
        .name = "test_reader",
        .root = Atom.from("test_reader"),
        .claims = claims_nothing,
        .access = eventsReaderAccess,
        .kernels = &.{.{ .name = "test_reader.read", .run = eventsReaderKernel }},
    };
}

test "a reader takes events after its cursor, oldest first, and a fault takes them again" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try TestEvents.ensure(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, test_events_table);
    const events = TestEvents.of(&f.tables, test_events_table);
    events.publish(.{ .moved = .{ .to = Atom.from("a") } });
    events.publish(.stopped);
    events.publish(.{ .moved = .{ .to = Atom.from("b") } });
    const root: Sequencer = .{ .name = "test_root", .steps = &.{.{ .system = testEventsReader() }} };
    const env = f.env();
    test_events_taken_count = 0;

    // The run takes the first two and faults: the cursor stays, and the next run takes them
    // again.
    f.state().mode.* = 1;
    try testing.expectEqual(Outcome.faulted, run(&root, &env, null));
    f.state().mode.* = 0;
    test_events_taken_count = 0;
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(usize, 2), test_events_taken_count);
    try testing.expectEqual(Atom.from("a"), test_events_taken[0].moved.to);
    try testing.expect(test_events_taken[1] == .stopped);
    // The third waits for the next run, as does what is published meanwhile.
    events.publish(.stopped);
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(usize, 4), test_events_taken_count);
    try testing.expectEqual(Atom.from("b"), test_events_taken[2].moved.to);
    try testing.expect(test_events_taken[3] == .stopped);
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(usize, 4), test_events_taken_count);
}

test "an events table keeps the latest it retains, in order" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try TestEvents.ensure(try f.memory.tableScratchAllocator(), &f.atoms, &f.tables, test_events_table);
    const events = TestEvents.of(&f.tables, test_events_table);
    const published = TestEvents.retained + 3;
    for (0..published) |index| {
        const marker: u64 = @intCast(index + 1);
        events.publish(.{ .moved = .{ .to = @enumFromInt(marker) } });
    }
    var kept: [TestEvents.retained]TestEvent = undefined;
    const all = events.peek(&kept);
    try testing.expectEqual(@as(usize, TestEvents.retained), all.len);
    for (all, 0..) |event, index| {
        const expected: u64 = @intCast(index + 4);
        try testing.expectEqual(@as(Atom, @enumFromInt(expected)), event.moved.to);
    }
}

fn testHostWrite(pass: *Pass) !void {
    const state = try pass.writeSingleton(test_state_name, TestState);
    state.count.* += 1;
    return error.HostTrouble;
}

fn testHostAfter(pass: *Pass) !void {
    const state = try pass.writeSingleton(test_state_name, TestState);
    state.second.* += 1;
}

fn testHost() System {
    return .{
        .name = "test_host",
        .root = Atom.from("test_host"),
        .claims = claims_nothing,
        .access = testAccess,
        .mode = .host,
        .kernels = &.{
            .{ .name = "test_host.write", .run = testHostWrite },
            .{ .name = "test_host.after", .run = testHostAfter },
        },
    };
}

test "a host system's error is logged, not a fault: its writes stay and its run goes on" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const root: Sequencer = .{ .name = "test_root", .steps = &.{.{ .system = testHost() }} };
    const env = f.env();
    try testing.expectEqual(Outcome.done, run(&root, &env, null));
    try testing.expectEqual(@as(u32, 1), f.state().count.*);
    try testing.expectEqual(@as(u32, 1), f.state().second.*);
    try testing.expect(faultRow(&f.tables, Atom.from(testHost().name)) == null or faultRow(&f.tables, Atom.from(testHost().name)).?.faults.* == 0);
}
