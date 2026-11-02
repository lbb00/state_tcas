//! Picture of one run: edges, sequence, byte lock against a document.
//! `lock` reads through the caller's `std.Io`. Tests pass `std.testing.io`.

const std = @import("std");

pub const Observation = struct {
    before: []const u8,
    after: []const u8,
    label: []const u8,
    rejected: bool,
    mutated: bool,
    note: []const u8,
    /// Draw this edge even when the name does not change. Default leaves an
    /// unchanged name out of the diagram. A rejection that changes state is
    /// still `RejectedButMutated`.
    keep_unchanged: bool = false,
    /// Sequence arrow ends (Scribble/MPST roles). Empty uses `render` names.
    /// Prefer `Role.initiator` / `Role.responder` / `Role.harness` via
    /// `Role.participant()` so pictures name who sends and who receives.
    from: []const u8 = "",
    to: []const u8 = "",
};

const Edge = struct {
    source: []u8,
    label: []u8,
    target: []u8,
};

const Step = struct {
    label: []u8,
    note: []u8,
    from: []u8,
    to: []u8,
};

pub const Picture = struct {
    edges: std.ArrayList(Edge) = .empty,
    steps: std.ArrayList(Step) = .empty,
    /// The exhaustive pass only collects edges. The sequence belongs to the single story.
    record_steps: bool = true,
    /// The story pass only collects steps. The edges belong to the exhaustive pass.
    record_edges: bool = true,

    pub fn deinit(self: *Picture, allocator: std.mem.Allocator) void {
        for (self.edges.items) |edge| {
            allocator.free(edge.source);
            allocator.free(edge.label);
            allocator.free(edge.target);
        }
        for (self.steps.items) |step| {
            allocator.free(step.label);
            allocator.free(step.note);
            allocator.free(step.from);
            allocator.free(step.to);
        }
        self.edges.deinit(allocator);
        self.steps.deinit(allocator);
    }

    /// Copies every name it keeps. The caller may reuse or free its buffers after this returns.
    pub fn observe(self: *Picture, allocator: std.mem.Allocator, o: Observation) !void {
        if (o.rejected and o.mutated) return error.RejectedButMutated;
        const changed = !std.mem.eql(u8, o.before, o.after);
        if (self.record_edges and (changed or o.keep_unchanged)) {
            for (self.edges.items) |edge| {
                if (std.mem.eql(u8, edge.source, o.before) and
                    std.mem.eql(u8, edge.label, o.label) and
                    std.mem.eql(u8, edge.target, o.after))
                {
                    break;
                }
            } else {
                const source = try allocator.dupe(u8, o.before);
                errdefer allocator.free(source);
                const label = try allocator.dupe(u8, o.label);
                errdefer allocator.free(label);
                const target = try allocator.dupe(u8, o.after);
                errdefer allocator.free(target);
                try self.edges.append(allocator, .{
                    .source = source,
                    .label = label,
                    .target = target,
                });
            }
        }
        if (!self.record_steps) return;
        const label = try allocator.dupe(u8, o.label);
        errdefer allocator.free(label);
        const note = try allocator.dupe(u8, o.note);
        errdefer allocator.free(note);
        const from = try allocator.dupe(u8, o.from);
        errdefer allocator.free(from);
        const to = try allocator.dupe(u8, o.to);
        errdefer allocator.free(to);
        try self.steps.append(allocator, .{ .label = label, .note = note, .from = from, .to = to });
    }

    /// Every declared state must appear as an edge endpoint. Returns the first name that does not.
    pub fn unseen(self: *const Picture, names: []const []const u8) ?[]const u8 {
        for (names) |name| {
            for (self.edges.items) |edge| {
                if (std.mem.eql(u8, edge.source, name) or std.mem.eql(u8, edge.target, name)) break;
            } else return name;
        }
        return null;
    }

    pub fn render(self: *Picture, allocator: std.mem.Allocator, preamble: []const u8, actor: []const u8, target: []const u8) ![]u8 {
        const edges = try allocator.dupe(Edge, self.edges.items);
        defer allocator.free(edges);
        std.mem.sort(Edge, edges, {}, edgeBefore);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, preamble);
        try out.appendSlice(allocator, "```mermaid\nstateDiagram-v2\n");
        for (edges) |edge| {
            try out.appendSlice(allocator, "    ");
            try out.appendSlice(allocator, edge.source);
            try out.appendSlice(allocator, " --> ");
            try out.appendSlice(allocator, edge.target);
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, edge.label);
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, "```\n\n```mermaid\nsequenceDiagram\n    participant ");
        try out.appendSlice(allocator, actor);
        try out.appendSlice(allocator, "\n    participant ");
        try out.appendSlice(allocator, target);
        try out.append(allocator, '\n');
        for (self.steps.items) |step| {
            const from = if (step.from.len == 0) actor else step.from;
            const to = if (step.to.len == 0) target else step.to;
            try out.appendSlice(allocator, "    ");
            try out.appendSlice(allocator, from);
            try out.appendSlice(allocator, "->>");
            try out.appendSlice(allocator, to);
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, step.label);
            try out.appendSlice(allocator, "\n    Note over ");
            try out.appendSlice(allocator, target);
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, step.note);
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, "```\n");
        return out.toOwnedSlice(allocator);
    }

    /// Moves `from`'s edges onto this picture. `from` no longer frees them.
    pub fn takeEdges(self: *Picture, allocator: std.mem.Allocator, from: *Picture) void {
        self.edges.deinit(allocator);
        self.edges = from.edges;
        from.edges = .empty;
    }
};

fn edgeBefore(_: void, a: Edge, b: Edge) bool {
    const source = std.mem.order(u8, a.source, b.source);
    if (source != .eq) return source == .lt;
    const label = std.mem.order(u8, a.label, b.label);
    if (label != .eq) return label == .lt;
    return std.mem.order(u8, a.target, b.target) == .lt;
}

pub fn lock(io: std.Io, allocator: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    // Test-only: if cwd has `.state_tcas-update-pictures`, rewrite the locked doc.
    if (std.Io.Dir.cwd().access(io, ".state_tcas-update-pictures", .{})) |_| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = expected });
        return;
    } else |_| {}
    const actual = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch {
        return error.PictureDrift;
    };
    defer allocator.free(actual);
    try lockBytes(path, expected, actual);
}

fn lockBytes(path: []const u8, expected: []const u8, actual: []const u8) !void {
    _ = path;
    if (std.mem.eql(u8, expected, actual)) return;
    // No stderr diagnostics here: zig build's test `--listen` protocol treats
    // hunk-like (or any noisy) stderr as a failed step in some runners.
    // Callers already get `error.PictureDrift`; harnesses can diff bytes themselves.
    return error.PictureDrift;
}

test "picture lock rejects a missing final newline" {
    try std.testing.expectError(error.PictureDrift, lockBytes("picture", "a\n", "a"));
}

test "edge pass keeps the change and drops the sequence" {
    const allocator = std.testing.allocator;
    var pic = Picture{ .record_steps = false };
    defer pic.deinit(allocator);
    try pic.observe(allocator, .{
        .before = "idle",
        .after = "open",
        .label = "open",
        .rejected = false,
        .mutated = true,
        .note = "open",
    });
    try std.testing.expectEqual(@as(usize, 0), pic.steps.items.len);
    try std.testing.expectEqual(@as(usize, 1), pic.edges.items.len);
    try std.testing.expect(pic.unseen(&.{ "idle", "open" }) == null);
    try std.testing.expectEqualStrings("closing", pic.unseen(&.{"closing"}).?);
}

test "picture keeps names after the caller reuses their buffers" {
    const allocator = std.testing.allocator;
    var pic = Picture{};
    defer pic.deinit(allocator);
    const before = try allocator.dupe(u8, "idle");
    defer allocator.free(before);
    const after = try allocator.dupe(u8, "open");
    defer allocator.free(after);
    const label = try allocator.dupe(u8, "go");
    defer allocator.free(label);
    const note = try allocator.dupe(u8, "went");
    defer allocator.free(note);
    try pic.observe(allocator, .{
        .before = before,
        .after = after,
        .label = label,
        .rejected = false,
        .mutated = true,
        .note = note,
    });
    @memset(before, 'a');
    @memset(after, 'b');
    @memset(label, 'c');
    @memset(note, 'd');
    const text = try pic.render(allocator, "", "caller", "gate");
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "idle --> open: go\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Note over gate: went\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "aaaa") == null);
}

test "picture lock accepts identical bytes and rejects a changed line" {
    try lockBytes("picture", "a\n", "a\n");
    try std.testing.expectError(error.PictureDrift, lockBytes("picture", "a\n", "b\n"));
}

test "unchanged name is an edge only when keep_unchanged is set" {
    const allocator = std.testing.allocator;
    var pic = Picture{ .record_steps = false };
    defer pic.deinit(allocator);
    try pic.observe(allocator, .{
        .before = "idle",
        .after = "idle",
        .label = "again",
        .rejected = true,
        .mutated = false,
        .note = "",
    });
    try std.testing.expectEqual(@as(usize, 0), pic.edges.items.len);
    try pic.observe(allocator, .{
        .before = "idle",
        .after = "idle",
        .label = "again",
        .rejected = true,
        .mutated = false,
        .keep_unchanged = true,
        .note = "",
    });
    try std.testing.expectEqual(@as(usize, 1), pic.edges.items.len);
    try std.testing.expectError(error.RejectedButMutated, pic.observe(allocator, .{
        .before = "idle",
        .after = "open",
        .label = "bad",
        .rejected = true,
        .mutated = true,
        .keep_unchanged = true,
        .note = "",
    }));
}

test "sequence arrow can name its own ends" {
    const allocator = std.testing.allocator;
    var pic = Picture{};
    defer pic.deinit(allocator);
    try pic.observe(allocator, .{
        .before = "a",
        .after = "b",
        .label = "go",
        .rejected = false,
        .mutated = true,
        .note = "b",
        .from = "左",
        .to = "右",
    });
    const text = try pic.render(allocator, "t\n", "默认甲", "默认乙");
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "左->>右: go") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Note over 默认乙: b") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "participant 默认甲") != null);
}
