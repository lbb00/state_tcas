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
    rejected: bool = false,
};

const Step = struct {
    label: []u8,
    note: []u8,
    from: []u8,
    to: []u8,
    before: []u8,
    after: []u8,
    rejected: bool = false,
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
            allocator.free(step.before);
            allocator.free(step.after);
        }
        self.edges.deinit(allocator);
        self.steps.deinit(allocator);
    }

    /// Copies every name it keeps. The caller may reuse or free its buffers after this returns.
    pub fn observe(self: *Picture, allocator: std.mem.Allocator, o: Observation) !void {
        if (o.rejected and o.mutated) return error.RejectedButMutated;
        const changed = !std.mem.eql(u8, o.before, o.after);
        if (self.record_edges and (changed or o.keep_unchanged)) {
            for (self.edges.items) |*edge| {
                if (std.mem.eql(u8, edge.source, o.before) and
                    std.mem.eql(u8, edge.label, o.label) and
                    std.mem.eql(u8, edge.target, o.after))
                {
                    if (!o.rejected) {
                        edge.rejected = false;
                    }
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
                    .rejected = o.rejected,
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
        const before = try allocator.dupe(u8, o.before);
        errdefer allocator.free(before);
        const after = try allocator.dupe(u8, o.after);
        errdefer allocator.free(after);
        try self.steps.append(allocator, .{
            .label = label,
            .note = note,
            .from = from,
            .to = to,
            .before = before,
            .after = after,
            .rejected = o.rejected,
        });
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
            if (edge.rejected) continue;
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

    fn matchActionLabel(label: []const u8, action_name: []const u8) bool {
        const parsed = parseActionLabel(label);
        return std.mem.eql(u8, parsed.name, action_name);
    }

    /// Verify that every defined variant of `Act` was recorded in non-rejected steps or edges.
    pub fn verifyCoverage(self: *const Picture, comptime Act: type) error{ActUncovered}!void {
        const names = comptime switch (@typeInfo(Act)) {
            .@"enum" => |e| e.field_names,
            .@"union" => |u| u.field_names,
            else => @compileError("Act must be enum or tagged union"),
        };
        inline for (names) |f_name| {
            var covered = false;
            for (self.edges.items) |edge| {
                if (edge.rejected) continue;
                if (matchActionLabel(edge.label, f_name)) {
                    covered = true;
                    break;
                }
            }
            if (!covered) {
                for (self.steps.items) |step| {
                    if (step.rejected) continue;
                    if (matchActionLabel(step.label, f_name)) {
                        covered = true;
                        break;
                    }
                }
            }
            if (!covered) return error.ActUncovered;
        }
    }

    /// Export recorded transition steps as an Apalache ADR-015 compliant ITF JSON trace.
    pub fn renderItfJson(self: *const Picture, allocator: std.mem.Allocator, options: RenderItfOptions) ![]u8 {
        try validateStateVarName(options.state_var_name);
        if (!self.record_steps) return error.StepsNotRecorded;

        var valid_step_count: usize = 0;
        for (self.steps.items) |step| {
            if (!step.rejected) valid_step_count += 1;
        }
        if (valid_step_count == 0) return error.EmptyTrace;

        // Check continuity across consecutive non-rejected steps
        var prev_after: ?[]const u8 = null;
        for (self.steps.items) |step| {
            if (step.rejected) continue;
            if (prev_after) |pa| {
                if (!std.mem.eql(u8, step.before, pa)) {
                    return error.DiscontinuousTrace;
                }
            }
            prev_after = step.after;
        }

        var has_any_payload = false;
        if (options.include_actions) {
            for (self.steps.items) |step| {
                if (step.rejected) continue;
                const parts = parseActionLabel(step.label);
                if (parts.payload != null) {
                    has_any_payload = true;
                    break;
                }
            }
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "{\n  \"#meta\": {\n    \"format\": \"ITF\",\n");
        try out.appendSlice(allocator, "    \"description\": ");
        try appendJsonEscapedString(&out, allocator, options.description);
        try out.appendSlice(allocator, ",\n    \"source\": ");
        try appendJsonEscapedString(&out, allocator, options.source);
        try out.appendSlice(allocator, "\n  },\n  \"vars\": [");
        try appendJsonEscapedString(&out, allocator, options.state_var_name);
        if (options.include_actions) {
            try out.appendSlice(allocator, ", \"action\", \"mbt::actionTaken\"");
            if (has_any_payload) {
                try out.appendSlice(allocator, ", \"payload\"");
            }
        }
        try out.appendSlice(allocator, "],\n  \"states\": [\n");

        var first_step: ?Step = null;
        for (self.steps.items) |step| {
            if (!step.rejected) {
                first_step = step;
                break;
            }
        }

        try out.appendSlice(allocator, "    {\n      \"#meta\": {\"index\": 0},\n");
        if (options.include_actions) {
            try out.appendSlice(allocator, "      \"action\": \"init\",\n");
            try out.appendSlice(allocator, "      \"mbt::actionTaken\": \"init\",\n");
            if (has_any_payload) {
                try out.appendSlice(allocator, "      \"payload\": null,\n");
            }
        }
        try out.appendSlice(allocator, "      ");
        try appendJsonEscapedString(&out, allocator, options.state_var_name);
        try out.appendSlice(allocator, ": ");
        try appendJsonEscapedString(&out, allocator, first_step.?.before);
        try out.appendSlice(allocator, "\n    }");

        var state_idx: usize = 0;
        for (self.steps.items) |step| {
            if (step.rejected) continue;
            state_idx += 1;
            try out.appendSlice(allocator, ",\n    {\n      \"#meta\": {\"index\": ");
            var idx_buf: [32]u8 = undefined;
            const idx_str = try std.fmt.bufPrint(&idx_buf, "{d}", .{state_idx});
            try out.appendSlice(allocator, idx_str);
            try out.appendSlice(allocator, "},\n");

            if (options.include_actions) {
                const parts = parseActionLabel(step.label);
                try out.appendSlice(allocator, "      \"action\": ");
                try appendJsonEscapedString(&out, allocator, parts.name);
                try out.appendSlice(allocator, ",\n");
                try out.appendSlice(allocator, "      \"mbt::actionTaken\": ");
                try appendJsonEscapedString(&out, allocator, parts.name);
                try out.appendSlice(allocator, ",\n");
                if (has_any_payload) {
                    try out.appendSlice(allocator, "      \"payload\": ");
                    if (parts.payload) |p_str| {
                        try appendJsonPayload(&out, allocator, p_str);
                    } else {
                        try out.appendSlice(allocator, "null");
                    }
                    try out.appendSlice(allocator, ",\n");
                }
            }

            try out.appendSlice(allocator, "      ");
            try appendJsonEscapedString(&out, allocator, options.state_var_name);
            try out.appendSlice(allocator, ": ");
            try appendJsonEscapedString(&out, allocator, step.after);
            try out.appendSlice(allocator, "\n    }");
        }
        try out.appendSlice(allocator, "\n  ]\n}\n");
        return out.toOwnedSlice(allocator);
    }
};

pub const ParsedActionLabel = struct {
    name: []const u8,
    payload: ?[]const u8,
};

pub fn parseActionLabel(label: []const u8) ParsedActionLabel {
    var split_idx: ?usize = null;
    var kind: u8 = 0;
    for (label, 0..) |c, idx| {
        if (c == '(' or c == '{' or c == ':' or c == ' ') {
            split_idx = idx;
            kind = c;
            break;
        }
    }
    if (split_idx) |idx| {
        const name = label[0..idx];
        var payload_slice: []const u8 = undefined;
        if (kind == '(') {
            if (std.mem.lastIndexOfScalar(u8, label, ')')) |p_close| {
                if (p_close > idx) {
                    payload_slice = label[idx + 1 .. p_close];
                } else {
                    payload_slice = label[idx + 1 ..];
                }
            } else {
                payload_slice = label[idx + 1 ..];
            }
        } else if (kind == '{') {
            if (std.mem.lastIndexOfScalar(u8, label, '}')) |b_close| {
                if (b_close > idx) {
                    payload_slice = label[idx + 1 .. b_close];
                } else {
                    payload_slice = label[idx + 1 ..];
                }
            } else {
                payload_slice = label[idx + 1 ..];
            }
        } else {
            payload_slice = label[idx + 1 ..];
        }
        const trimmed = std.mem.trim(u8, payload_slice, " \t\r\n");
        if (trimmed.len == 0) {
            return .{ .name = name, .payload = null };
        }
        return .{ .name = name, .payload = trimmed };
    }
    return .{ .name = label, .payload = null };
}

fn isStrictJsonNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '-') {
        i += 1;
        if (i >= s.len) return false;
    }
    if (s[i] == '0') {
        i += 1;
        if (i < s.len and s[i] >= '0' and s[i] <= '9') return false;
    } else if (s[i] >= '1' and s[i] <= '9') {
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    } else {
        return false;
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i >= s.len or s[i] < '0' or s[i] > '9') return false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        if (i >= s.len or s[i] < '0' or s[i] > '9') return false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    }
    return i == s.len;
}

pub fn validateStateVarName(name: []const u8) !void {
    if (name.len == 0 or
        std.mem.eql(u8, name, "action") or
        std.mem.eql(u8, name, "actionTaken") or
        std.mem.eql(u8, name, "mbt::actionTaken") or
        std.mem.eql(u8, name, "payload") or
        std.mem.eql(u8, name, "mbt::nondetPicks") or
        std.mem.eql(u8, name, "after") or
        std.mem.eql(u8, name, "before") or
        std.mem.eql(u8, name, "rejected") or
        std.mem.eql(u8, name, "from") or
        std.mem.eql(u8, name, "to") or
        std.mem.eql(u8, name, "from_role") or
        std.mem.eql(u8, name, "to_role") or
        std.mem.eql(u8, name, "#meta") or
        std.mem.eql(u8, name, "step") or
        std.mem.eql(u8, name, "note"))
    {
        return error.InvalidStateVariableName;
    }
}

fn appendJsonPayload(out: *std.ArrayList(u8), allocator: std.mem.Allocator, p_str: []const u8) !void {
    if (std.mem.eql(u8, p_str, "true") or std.mem.eql(u8, p_str, "false") or std.mem.eql(u8, p_str, "null")) {
        try out.appendSlice(allocator, p_str);
        return;
    }
    if (isStrictJsonNumber(p_str)) {
        const is_float = (std.mem.indexOfAny(u8, p_str, ".eE") != null);
        if (is_float) {
            try out.appendSlice(allocator, p_str);
            return;
        }
        const max_safe_int: i64 = 9007199254740991;
        const min_safe_int: i64 = -9007199254740991;
        if (std.fmt.parseInt(i64, p_str, 10)) |val| {
            if (val > max_safe_int or val < min_safe_int) {
                try out.appendSlice(allocator, "{\"#bigint\": \"");
                try out.appendSlice(allocator, p_str);
                try out.appendSlice(allocator, "\"}");
                return;
            }
        } else |err| switch (err) {
            error.Overflow => {
                try out.appendSlice(allocator, "{\"#bigint\": \"");
                try out.appendSlice(allocator, p_str);
                try out.appendSlice(allocator, "\"}");
                return;
            },
            else => {},
        }
        try out.appendSlice(allocator, p_str);
        return;
    }
    try appendJsonEscapedString(out, allocator, p_str);
}

pub const RenderItfOptions = struct {
    description: []const u8 = "state_tcas counterexample trace",
    source: []const u8 = "exploration",
    state_var_name: []const u8 = "state",
    include_actions: bool = true,
};

fn appendJsonEscapedString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(str)) return error.InvalidUtf8;
    try out.append(allocator, '"');
    for (str) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            '\x08' => try out.appendSlice(allocator, "\\b"),
            '\x0c' => try out.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    var esc_buf: [7]u8 = undefined;
                    const esc_str = try std.fmt.bufPrint(&esc_buf, "\\u00{x:0>2}", .{c});
                    try out.appendSlice(allocator, esc_str);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

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
    if (std.mem.eql(u8, expected, actual)) return;
    // Cross-platform CRLF normalization (read-only): if on-disk file has Windows
    // '\r\n' line endings but matches expected LF line endings, succeed without
    // mutating the disk file (safe in read-only checkouts).
    if (matchesNormalizingCRLF(expected, actual)) return;
    return error.PictureDrift;
}

pub fn matchesNormalizingCRLF(expected: []const u8, actual: []const u8) bool {
    var exp_i: usize = 0;
    var act_i: usize = 0;
    while (act_i < actual.len) {
        if (actual[act_i] == '\r' and act_i + 1 < actual.len and actual[act_i + 1] == '\n') {
            act_i += 1; // skip \r, actual[act_i] is now '\n'
        }
        if (exp_i >= expected.len) return false;
        if (actual[act_i] != expected[exp_i]) return false;
        act_i += 1;
        exp_i += 1;
    }
    return exp_i == expected.len;
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

test "lock normalizes CRLF on-disk content to LF expected and succeeds without mutating disk" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const crlf_content = "```mermaid\r\nstateDiagram-v2\r\n    idle --> done: go\r\n```\r\n";
    const lf_expected = "```mermaid\nstateDiagram-v2\n    idle --> done: go\n```\n";

    // Direct CRLF normalization unit tests
    try std.testing.expect(matchesNormalizingCRLF(lf_expected, crlf_content));
    try std.testing.expect(matchesNormalizingCRLF("a\nb\n", "a\r\nb\r\n"));
    try std.testing.expect(!matchesNormalizingCRLF("ab", "a\rb")); // isolated \r is NOT stripped
    try std.testing.expect(!matchesNormalizingCRLF("different\n", crlf_content));

    const full_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "diagram.md" });
    defer allocator.free(full_path);

    // File lock test: writes CRLF to temp file
    try tmp.dir.writeFile(io, .{ .sub_path = "diagram.md", .data = crlf_content });

    // lock with LF expected succeeds via read-only normalization
    try lock(io, allocator, full_path, lf_expected);

    // Verify on-disk file was NOT mutated (preserved as-is for read-only safety)
    const disk_bytes = try tmp.dir.readFileAlloc(io, "diagram.md", allocator, .limited(1024));
    defer allocator.free(disk_bytes);
    try std.testing.expectEqualStrings(crlf_content, disk_bytes);

    // Non-matching content still returns PictureDrift
    try tmp.dir.writeFile(io, .{ .sub_path = "diagram.md", .data = "different\r\ncontent\r\n" });
    try std.testing.expectError(error.PictureDrift, lock(io, allocator, full_path, lf_expected));
}

test "Picture.verifyCoverage detects covered and uncovered actions" {
    const allocator = std.testing.allocator;
    const Act = enum { start, stop, pause };

    var pic = Picture{};
    defer pic.deinit(allocator);

    try pic.observe(allocator, .{
        .before = "idle",
        .after = "running",
        .label = "start",
        .rejected = false,
        .mutated = true,
        .note = "",
    });

    // 'stop' and 'pause' are not yet covered
    try std.testing.expectError(error.ActUncovered, pic.verifyCoverage(Act));

    try pic.observe(allocator, .{
        .before = "running",
        .after = "paused",
        .label = "pause",
        .rejected = false,
        .mutated = true,
        .note = "",
    });

    try std.testing.expectError(error.ActUncovered, pic.verifyCoverage(Act));

    try pic.observe(allocator, .{
        .before = "paused",
        .after = "idle",
        .label = "stop",
        .rejected = false,
        .mutated = true,
        .note = "",
    });

    // All actions now covered
    try pic.verifyCoverage(Act);
}

test "Picture.renderItfJson exports valid Apalache ADR-015 compliant ITF trace" {
    const allocator = std.testing.allocator;
    var pic = Picture{};
    defer pic.deinit(allocator);

    try pic.observe(allocator, .{
        .before = "init_st",
        .after = "mid_st",
        .label = "step1",
        .rejected = false,
        .mutated = true,
        .note = "",
    });
    try pic.observe(allocator, .{
        .before = "mid_st",
        .after = "final_st",
        .label = "step2",
        .rejected = false,
        .mutated = true,
        .note = "",
    });

    const itf = try pic.renderItfJson(allocator, .{
        .description = "test trace",
        .source = "test",
        .state_var_name = "state",
        .include_actions = true,
    });
    defer allocator.free(itf);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, itf, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("#meta") != null);
    try std.testing.expect(obj.get("vars") != null);
    const states = obj.get("states").?.array;
    try std.testing.expectEqual(@as(usize, 3), states.items.len);
    try std.testing.expectEqualStrings("init", states.items[0].object.get("action").?.string);
    try std.testing.expectEqualStrings("init_st", states.items[0].object.get("state").?.string);
    try std.testing.expectEqualStrings("step1", states.items[1].object.get("action").?.string);
    try std.testing.expectEqualStrings("mid_st", states.items[1].object.get("state").?.string);
    try std.testing.expectEqualStrings("step2", states.items[2].object.get("action").?.string);
    try std.testing.expectEqualStrings("final_st", states.items[2].object.get("state").?.string);
}

test "Picture.verifyCoverage skips rejected steps and matches tagged unions" {
    const allocator = std.testing.allocator;
    const Act = union(enum) {
        push: u32,
        pop: void,
    };

    var pic = Picture{};
    defer pic.deinit(allocator);

    // Rejected step does not count as coverage
    try pic.observe(allocator, .{
        .before = "empty",
        .after = "empty",
        .label = "push(42)",
        .rejected = true,
        .mutated = false,
        .note = "rejected",
    });
    try std.testing.expectError(error.ActUncovered, pic.verifyCoverage(Act));

    // Successful step matching tagged union variant prefix
    try pic.observe(allocator, .{
        .before = "empty",
        .after = "loaded",
        .label = "push(42)",
        .rejected = false,
        .mutated = true,
        .note = "",
    });
    // pop is still uncovered
    try std.testing.expectError(error.ActUncovered, pic.verifyCoverage(Act));

    try pic.observe(allocator, .{
        .before = "loaded",
        .after = "empty",
        .label = "pop",
        .rejected = false,
        .mutated = true,
        .note = "",
    });
    try pic.verifyCoverage(Act);
}

test "Picture.renderItfJson rejects discontinuous or empty traces and skips rejections" {
    const allocator = std.testing.allocator;
    var pic = Picture{};
    defer pic.deinit(allocator);

    // Empty picture rejects ITF export
    try std.testing.expectError(error.EmptyTrace, pic.renderItfJson(allocator, .{}));

    // Only rejected steps also yields empty trace
    try pic.observe(allocator, .{
        .before = "idle",
        .after = "idle",
        .label = "noop",
        .rejected = true,
        .mutated = false,
        .note = "",
    });
    try std.testing.expectError(error.EmptyTrace, pic.renderItfJson(allocator, .{}));

    // Add continuous valid steps with an interleaved rejected step
    try pic.observe(allocator, .{
        .before = "s0",
        .after = "s1",
        .label = "step1",
        .rejected = false,
        .mutated = true,
        .note = "",
    });
    try pic.observe(allocator, .{
        .before = "s1",
        .after = "s1",
        .label = "bad_step",
        .rejected = true,
        .mutated = false,
        .note = "",
    });
    try pic.observe(allocator, .{
        .before = "s1",
        .after = "s2",
        .label = "step2",
        .rejected = false,
        .mutated = true,
        .note = "",
    });

    const itf = try pic.renderItfJson(allocator, .{});
    defer allocator.free(itf);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, itf, .{});
    defer parsed.deinit();
    const states = parsed.value.object.get("states").?.array;
    // index 0 (s0), index 1 (s1 from step1), index 2 (s2 from step2), bad_step skipped
    try std.testing.expectEqual(@as(usize, 3), states.items.len);

    // Now append a discontinuous step
    try pic.observe(allocator, .{
        .before = "s_other",
        .after = "s3",
        .label = "step3",
        .rejected = false,
        .mutated = true,
        .note = "",
    });
    try std.testing.expectError(error.DiscontinuousTrace, pic.renderItfJson(allocator, .{}));
}

test "Picture.verifyCoverage rejects coverage when action only appeared in rejected edges" {
    const allocator = std.testing.allocator;
    const Act = enum { a, b };

    var pic = Picture{ .record_steps = false };
    defer pic.deinit(allocator);

    // Observe 'a' successfully
    try pic.observe(allocator, .{
        .before = "s0",
        .after = "s1",
        .label = "a",
        .rejected = false,
        .mutated = true,
        .note = "",
    });

    // Observe 'b' only as a rejected unchanged edge (keep_unchanged = true)
    try pic.observe(allocator, .{
        .before = "s1",
        .after = "s1",
        .label = "b",
        .rejected = true,
        .mutated = false,
        .keep_unchanged = true,
        .note = "rejected",
    });

    // 'b' must not be counted as covered!
    try std.testing.expectError(error.ActUncovered, pic.verifyCoverage(Act));

    // Now observe 'b' successfully
    try pic.observe(allocator, .{
        .before = "s1",
        .after = "s2",
        .label = "b",
        .rejected = false,
        .mutated = true,
        .note = "",
    });
    try pic.verifyCoverage(Act);
}

test "Picture edge deduplication updates rejected state when edge is later accepted" {
    const allocator = std.testing.allocator;
    const Act = enum { ping };

    var pic = Picture{ .record_steps = false };
    defer pic.deinit(allocator);

    // First observe ping as rejected unchanged edge
    try pic.observe(allocator, .{
        .before = "idle",
        .after = "idle",
        .label = "ping",
        .rejected = true,
        .mutated = false,
        .keep_unchanged = true,
        .note = "",
    });
    try std.testing.expectError(error.ActUncovered, pic.verifyCoverage(Act));

    // Then observe ping on the identical (idle, ping, idle) edge as accepted
    try pic.observe(allocator, .{
        .before = "idle",
        .after = "idle",
        .label = "ping",
        .rejected = false,
        .mutated = false,
        .keep_unchanged = true,
        .note = "",
    });
    // Deduplicated edge must have rejected = false now
    try pic.verifyCoverage(Act);
}

test "Picture.renderItfJson emits valid JSON numbers and adheres to ADR-015 vars schema" {
    const allocator = std.testing.allocator;
    var pic = Picture{};
    defer pic.deinit(allocator);

    try pic.observe(allocator, .{
        .before = "s0",
        .after = "s1",
        .label = "set(007)",
        .rejected = false,
        .mutated = true,
        .note = "",
    });
    try pic.observe(allocator, .{
        .before = "s1",
        .after = "s2",
        .label = "stop()",
        .rejected = false,
        .mutated = true,
        .note = "",
    });
    try pic.observe(allocator, .{
        .before = "s2",
        .after = "s3",
        .label = "big(9007199254740992)",
        .rejected = false,
        .mutated = true,
        .note = "",
    });

    const itf = try pic.renderItfJson(allocator, .{});
    defer allocator.free(itf);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, itf, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const vars = root.get("vars").?.array;
    try std.testing.expectEqual(@as(usize, 4), vars.items.len);
    try std.testing.expectEqualStrings("state", vars.items[0].string);
    try std.testing.expectEqualStrings("action", vars.items[1].string);
    try std.testing.expectEqualStrings("mbt::actionTaken", vars.items[2].string);
    try std.testing.expectEqualStrings("payload", vars.items[3].string);

    const states = root.get("states").?.array;
    try std.testing.expectEqual(@as(usize, 4), states.items.len);

    // Initial state 0 has payload: null
    try std.testing.expect(states.items[0].object.get("payload").? == .null);

    // State 1: set(007) has leading zero so emitted as string "007"
    try std.testing.expectEqualStrings("007", states.items[1].object.get("payload").?.string);

    // State 2: stop() has null payload
    try std.testing.expect(states.items[2].object.get("payload").? == .null);

    // State 3: bigint has #bigint wrapper
    const bigint_obj = states.items[3].object.get("payload").?.object;
    try std.testing.expectEqualStrings("9007199254740992", bigint_obj.get("#bigint").?.string);
}

test "Picture.renderItfJson handles integer overflowing i64 and validates state_var_name" {
    const allocator = std.testing.allocator;
    var pic = Picture{};
    defer pic.deinit(allocator);

    try pic.observe(allocator, .{
        .before = "s0",
        .after = "s1",
        .label = "huge(99999999999999999999)",
        .rejected = false,
        .mutated = true,
        .note = "",
    });

    // 1. Invalid state variable names rejected
    try std.testing.expectError(error.InvalidStateVariableName, pic.renderItfJson(allocator, .{ .state_var_name = "" }));
    try std.testing.expectError(error.InvalidStateVariableName, pic.renderItfJson(allocator, .{ .state_var_name = "action" }));
    try std.testing.expectError(error.InvalidStateVariableName, pic.renderItfJson(allocator, .{ .state_var_name = "payload" }));

    // 2. Huge integer beyond i64 wrapped in #bigint
    const itf = try pic.renderItfJson(allocator, .{});
    defer allocator.free(itf);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, itf, .{});
    defer parsed.deinit();

    const states = parsed.value.object.get("states").?.array;
    const huge_obj = states.items[1].object.get("payload").?.object;
    try std.testing.expectEqualStrings("99999999999999999999", huge_obj.get("#bigint").?.string);
}
