//! Calendar: schedule / cancel / fireDue / ClockRewind / same-time order.
//! Run: `zig build example-calendar` from the package root.

const std = @import("std");
const state_tcas = @import("state_tcas");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var cal = state_tcas.calendar.Calendar.init(allocator, 0);
    defer cal.deinit();

    // Arm a 1000µs timeout; deliver early and cancel; advance; handler must not see it.
    const timeout_id = try cal.schedule(1000, 42, 7);
    if (!cal.cancel(timeout_id)) return error.ExampleFailed;
    cal.compactCancelled();
    try cal.advanceTo(1000);

    const Sink = struct {
        saw: bool = false,
        fn on(self: *@This(), tag: u32, payload: u64) !void {
            _ = tag;
            _ = payload;
            self.saw = true;
        }
    };
    var sink: Sink = .{};
    const fired_cancelled = try cal.fireDue(&sink, Sink.on);
    if (fired_cancelled != 0 or sink.saw) return error.ExampleFailed;

    // ClockRewind must be refused.
    if (cal.advanceTo(10)) |_| {
        return error.ExampleFailed;
    } else |err| {
        if (err != error.ClockRewind) return err;
    }

    // Two same-time Timed entries: fire order is insertion seq.
    _ = try cal.schedule(2000, 1, 0);
    _ = try cal.schedule(2000, 2, 0);
    try cal.advanceTo(2000);
    const Order = struct {
        got: [2]u32 = undefined,
        n: usize = 0,
        fn on(self: *@This(), tag: u32, _: u64) !void {
            self.got[self.n] = tag;
            self.n += 1;
        }
    };
    var order: Order = .{};
    const n = try cal.fireDue(&order, Order.on);
    if (n != 2 or order.got[0] != 1 or order.got[1] != 2) return error.ExampleFailed;

    std.debug.print("toy_calendar_timeout ok\n", .{});
}
