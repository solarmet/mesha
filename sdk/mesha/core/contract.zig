//! Checks of what must hold for the engine's own code to be correct, kept in every build mode.
/// Panics with `contract violation: <label>` when `condition` is false, in every optimize
/// mode, where `std.debug.assert` is checked only in safe builds. For a condition that only
/// a bug in the caller can break, such as an index past a buffer or a handle of another
/// table; never for input a person or a file can get wrong, which is an error to return.
/// `label` names the condition for whoever reads the panic.
pub inline fn invariant(condition: bool, comptime label: []const u8) void {
    if (!condition) @panic("contract violation: " ++ label);
}

test "invariant accepts a satisfied condition" {
    invariant(true, "contract.test");
}
