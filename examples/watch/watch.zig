const std = @import("std");
const zabi = @import("zabi");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var iter = try std.process.ArgIterator.initWithAllocator(gpa.allocator());
    defer iter.deinit();

    _ = iter.skip();

    const uri = try std.Uri.parse(iter.next() orelse return error.UnexpectArgument);
    var socket: zabi.WebSocket = undefined;
    defer socket.deinit();

    try socket.init(.{ .uri = uri, .allocator = gpa.allocator() });
    const id = try socket.watchTransactions();

    while (true) {
        const event = try socket.getCurrentEvent();
        std.debug.print("Pending transaction: {}\n", .{event.pending_transactions_hashes_event.params});
    }

    try socket.unsubscribe(id);
}