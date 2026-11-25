const std = @import("std");

test "transformed solid and hole winding is normalized before convex classification" {
    const roop = @import("../roop.zig");
    const Command = roop.path.Command;
    var cache: roop.path.PathCache = .empty;
    defer cache.deinit(std.testing.allocator);
    for ([_]f32{ 1, -1 }) |flip| {
        var cmds = [_]Command{ .{ .move_to = .{ 0, 0 } }, .{ .line_to = .{ 10 * flip, 0 } }, .{ .line_to = .{ 10 * flip, 10 } }, .{ .line_to = .{ 0, 10 } }, .close, .{ .winding = .ccw } };
        try roop.geometry.flattenPaths(std.testing.allocator, &cache, &cmds, 0.25, 0.01);
        try roop.geometry.expandFill(&cache, &cache.paths.items[0], 1, 10);
        try std.testing.expect(cache.paths.items[0].convex);
        try std.testing.expect(cache.paths.items[0].ccw);
        cmds[5] = .{ .winding = .cw };
        try roop.geometry.flattenPaths(std.testing.allocator, &cache, &cmds, 0.25, 0.01);
        try std.testing.expect(!cache.paths.items[0].ccw);
    }
}

test "paint uniforms premultiply color and apply global opacity once" {
    const roop = @import("../roop.zig");
    const paint = roop.solidColor(.{ .r = 0.8, .g = 0.4, .b = 0.2, .a = 0.5 });
    const uniforms = roop.draw_list.makePaintUniforms(&paint, .{ .alpha = @as(f32, 0.5), .scissor_xform = roop.transform.identity(), .scissor_extent = [2]f32{ -1, -1 }, .scissor_radius = @as(f32, 0) }, 1, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), uniforms.innerCol[3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), uniforms.innerCol[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), uniforms.innerCol[1], 1e-6);
}

test "roop CPU contract validators cover image handles, geometry, and frame capacities" {
    const roop = @import("../roop.zig");
    const entries = [_]roop.ImageEntry{
        .{ .texture = .null_handle, .sampler = .null_handle, .tex_type = 0 },
        .{ .texture = .null_handle, .sampler = .null_handle, .tex_type = 0, .active = false },
    };
    try std.testing.expectEqual(@as(usize, 0), try roop.validateImageHandle(1, &entries));
    try std.testing.expectError(error.ImageReleased, roop.validateImageHandle(2, &entries));
    try std.testing.expectError(error.InvalidImageHandle, roop.validateImageHandle(0, &entries));
    try std.testing.expectError(error.InvalidImageHandle, roop.validateImageHandle(3, &entries));

    try roop.path.validateCommandCapacity(roop.path.kMaxPathCommands - 1, 1);
    try std.testing.expectError(error.TooManyCommands, roop.path.validateCommandCapacity(roop.path.kMaxPathCommands, 1));
    try roop.path.validatePathCapacity(roop.path.kMaxPaths - 1, 1);
    try std.testing.expectError(error.TooManyPaths, roop.path.validatePathCapacity(roop.path.kMaxPaths, 1));
    try roop.path.validatePointCapacity(roop.path.kMaxFlattenedPoints - 1, 1);
    try std.testing.expectError(error.TooManyPoints, roop.path.validatePointCapacity(roop.path.kMaxFlattenedPoints, 1));
    try roop.geometry.validateFlattenInputs(&.{}, 0.25, 0.01);
    try std.testing.expectError(error.InvalidTessellationTolerance, roop.geometry.validateFlattenInputs(&.{}, 0, 0.01));
    const invalid_point = [_]roop.path.Command{.{ .move_to = .{ std.math.nan(f32), 0 } }};
    try std.testing.expectError(error.NonFiniteCoordinate, roop.geometry.validateFlattenInputs(&invalid_point, 0.25, 0.01));

    try roop.draw_list.validateAppendCapacity(4, 6, 10);
    try std.testing.expectError(error.CapacityExceeded, roop.draw_list.validateAppendCapacity(10, 1, 10));
    try roop.draw_list.validateFrameLimits(
        roop.draw_list.kMaxDrawCallsPerFrame,
        roop.draw_list.kMaxCpuVerticesPerFrame,
        roop.draw_list.kMaxUniformsPerFrame,
        roop.draw_list.kMaxGpuPointsPerFrame,
        roop.draw_list.kMaxGpuShapesPerFrame,
        roop.draw_list.kMaxGpuVerticesPerFrame,
        roop.draw_list.kMaxGpuIndirectDrawsPerFrame,
        roop.draw_list.kMaxQuadInstancesPerFrame,
    );
    try std.testing.expectError(error.TooManyDrawCalls, roop.draw_list.validateFrameLimits(roop.draw_list.kMaxDrawCallsPerFrame + 1, 0, 0, 0, 0, 0, 0, 0));
    try std.testing.expectError(error.TooManyCpuVertices, roop.draw_list.validateFrameLimits(0, roop.draw_list.kMaxCpuVerticesPerFrame + 1, 0, 0, 0, 0, 0, 0));
    try std.testing.expectError(error.TooManyUniforms, roop.draw_list.validateFrameLimits(0, 0, roop.draw_list.kMaxUniformsPerFrame + 1, 0, 0, 0, 0, 0));
    try std.testing.expectError(error.TooManyGpuPoints, roop.draw_list.validateFrameLimits(0, 0, 0, roop.draw_list.kMaxGpuPointsPerFrame + 1, 0, 0, 0, 0));
    try std.testing.expectError(error.TooManyGpuShapes, roop.draw_list.validateFrameLimits(0, 0, 0, 0, roop.draw_list.kMaxGpuShapesPerFrame + 1, 0, 0, 0));
    try std.testing.expectError(error.TooManyGpuVertices, roop.draw_list.validateFrameLimits(0, 0, 0, 0, 0, roop.draw_list.kMaxGpuVerticesPerFrame + 1, 0, 0));
    try std.testing.expectError(error.TooManyIndirectDraws, roop.draw_list.validateFrameLimits(0, 0, 0, 0, 0, 0, roop.draw_list.kMaxGpuIndirectDrawsPerFrame + 1, 0));
    try std.testing.expectError(error.TooManyQuadInstances, roop.draw_list.validateFrameLimits(0, 0, 0, 0, 0, 0, 0, roop.draw_list.kMaxQuadInstancesPerFrame + 1));
}
