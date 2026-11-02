//! Test-only event buffer: action labels and abstract state names.
//! Pass a `Trace` from tests only; not a production logger.

const std = @import("std");

pub const Event = struct {
    action: []const u8,
    before: []const u8,
    after: []const u8,
    rejected: bool,
    from_role: []const u8 = "",
    to_role: []const u8 = "",
};

const Owned = struct {
    action: []u8,
    before: []u8,
    after: []u8,
    rejected: bool,
    from_role: []u8,
    to_role: []u8,
};

pub const Trace = struct {
    events: std.ArrayList(Owned) = .empty,

    pub fn deinit(self: *Trace, allocator: std.mem.Allocator) void {
        for (self.events.items) |e| {
            allocator.free(e.action);
            allocator.free(e.before);
            allocator.free(e.after);
            allocator.free(e.from_role);
            allocator.free(e.to_role);
        }
        self.events.deinit(allocator);
    }

    pub fn append(self: *Trace, allocator: std.mem.Allocator, e: Event) !void {
        const action = try allocator.dupe(u8, e.action);
        errdefer allocator.free(action);
        const before = try allocator.dupe(u8, e.before);
        errdefer allocator.free(before);
        const after = try allocator.dupe(u8, e.after);
        errdefer allocator.free(after);
        const from_role = try allocator.dupe(u8, e.from_role);
        errdefer allocator.free(from_role);
        const to_role = try allocator.dupe(u8, e.to_role);
        errdefer allocator.free(to_role);
        try self.events.append(allocator, .{
            .action = action,
            .before = before,
            .after = after,
            .rejected = e.rejected,
            .from_role = from_role,
            .to_role = to_role,
        });
    }

    pub fn len(self: *const Trace) usize {
        return self.events.items.len;
    }

    /// Compact JSON array. Values are state/action labels only.
    pub fn toJson(self: *const Trace, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.append(allocator, '[');
        for (self.events.items, 0..) |e, i| {
            if (i != 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, "{\"step\":");
            var step_buf: [32]u8 = undefined;
            const step_s = try std.fmt.bufPrint(&step_buf, "{d}", .{i});
            try out.appendSlice(allocator, step_s);
            try out.appendSlice(allocator, ",\"action\":\"");
            try appendEscaped(&out, allocator, e.action);
            try out.appendSlice(allocator, "\",\"before\":\"");
            try appendEscaped(&out, allocator, e.before);
            try out.appendSlice(allocator, "\",\"after\":\"");
            try appendEscaped(&out, allocator, e.after);
            try out.appendSlice(allocator, "\",\"rejected\":");
            try out.appendSlice(allocator, if (e.rejected) "true" else "false");
            try out.appendSlice(allocator, ",\"from\":\"");
            try appendEscaped(&out, allocator, e.from_role);
            try out.appendSlice(allocator, "\",\"to\":\"");
            try appendEscaped(&out, allocator, e.to_role);
            try out.appendSlice(allocator, "\"}");
        }
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    }

    /// Test-only disk helper for harnesses. Caller passes an explicit `dir` +
    /// relative `sub_path` (e.g. under `std.testing.tmpDir`); there is no
    /// default absolute `/tmp` path. Not production logging:
    /// JSON still holds only action/state/role labels — no credentials or host paths.
    pub fn writeJsonFile(
        self: *const Trace,
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        sub_path: []const u8,
    ) !void {
        const json = try self.toJson(allocator);
        defer allocator.free(json);
        try dir.writeFile(io, .{ .sub_path = sub_path, .data = json });
    }
};

fn appendEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            else => try out.append(allocator, c),
        }
    }
}

test "trace json has no credential-shaped fields" {
    const allocator = std.testing.allocator;
    var tr: Trace = .{};
    defer tr.deinit(allocator);
    try tr.append(allocator, .{
        .action = "线发票",
        .before = "空",
        .after = "活",
        .rejected = false,
        .from_role = "responder",
        .to_role = "initiator",
    });
    const json = try tr.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"action\":\"线发票\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"from\":\"responder\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/") == null);
}

test "trace writeJsonFile round-trips under tmpDir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tr: Trace = .{};
    defer tr.deinit(allocator);
    try tr.append(allocator, .{
        .action = "入库",
        .before = "空",
        .after = "活",
        .rejected = false,
        .from_role = "initiator",
        .to_role = "responder",
    });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tr.writeJsonFile(allocator, io, tmp.dir, "story-trace.json");
    const got = try tmp.dir.readFileAlloc(io, "story-trace.json", allocator, .limited(1 << 16));
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"action\":\"入库\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"from\":\"initiator\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "/home") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "/tmp") == null);
}
