const generator = @import("../generator.zig");
const std = @import("std");
const types = @import("../../types/root.zig");

const AccessListResult = types.transactions.AccessListResult;
const Allocator = std.mem.Allocator;
const Block = types.block.Block;
const EthereumErrorResponse = types.ethereum.EthereumErrorResponse;
const EthereumRpcResponse = types.ethereum.EthereumRpcResponse;
const EthereumRpcMethods = types.ethereum.EthereumRpcMethods;
const FeeHistory = types.transactions.FeeHistory;
const Logs = types.log.Logs;
const ProofResult = types.proof.ProofResult;
const Transaction = types.transactions.Transaction;
const TransactionReceipt = types.transactions.TransactionReceipt;

const server_log = std.log.scoped(.server);

pub const InitOpts = struct {
    seed: u64 = 69,
    path: []const u8 = "/tmp/zabi.ipc",
};

const IpcServer = @This();

/// Allocator for the server to use.
allocator: Allocator,
/// The socket where the server will listen to connections.
listener: std.net.Server,
/// The path to the ipc socket file.
path: []const u8,
/// The seed to use to generate random data.
seed: u64,

/// Start the server and creates the listener.
pub fn init(self: *IpcServer, allocator: Allocator, opts: InitOpts) !void {
    self.* = .{
        .allocator = allocator,
        .listener = undefined,
        .path = opts.path,
        .seed = opts.seed,
    };

    std.fs.cwd().deleteFile(self.path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.net.Address.initUnix(self.path);
    self.listener = try address.listen(.{
        .reuse_port = true,
        .reuse_address = true,
    });
}
/// Shutsdown the socket.
pub fn deinit(self: *IpcServer) void {
    std.posix.shutdown(self.listener.stream.handle, .both) catch |err| {
        server_log.debug("Failed to cleanly shutdown socket. Error found: {s}", .{@errorName(err)});
    };
}
/// Starts the main loop. Will close the client connection
/// if it reports any errors.
pub fn start(self: *IpcServer) !void {
    accept: while (true) {
        const request = try self.listener.accept();

        while (true) {
            self.handleRequest(request.stream) catch |err| {
                server_log.debug("Handler reported error: {s}. Closing the client connection", .{@errorName(err)});
                request.stream.close();
                continue :accept;
            };
        }
    }
}
/// Handles and mimics a json rpc response from a JSON-RPC server.
/// Uses the custom data generator to produce the response.
fn handleRequest(self: *IpcServer, stream: std.net.Stream) !void {
    var req_buffer: [4096]u8 = undefined;
    const size = try stream.read(req_buffer[0..]);

    if (size == 0)
        return error.NoMessageFound;

    const message = req_buffer[0..size];

    server_log.debug("Parsing request: {s}", .{message});

    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, message, .{ .ignore_unknown_fields = true }) catch {
        var buffer: [1024]u8 = undefined;
        var buf_writer = std.io.fixedBufferStream(&buffer);

        try std.json.stringify(EthereumErrorResponse{ .@"error" = .{ .code = .InvalidRequest, .message = "Invalid json message sent" } }, .{}, buf_writer.writer());

        return stream.writeAll(buf_writer.getWritten());
    };
    defer parsed.deinit();

    const method = blk: {
        const method = parsed.value.object.get("method") orelse {
            var buffer: [1024]u8 = undefined;
            var buf_writer = std.io.fixedBufferStream(&buffer);

            try std.json.stringify(EthereumErrorResponse{ .@"error" = .{ .code = .MethodNotFound, .message = "Missing 'method' field on json request" } }, .{}, buf_writer.writer());

            return stream.writeAll(buf_writer.getWritten());
        };

        if (method != .string) {
            var buffer: [1024]u8 = undefined;
            var buf_writer = std.io.fixedBufferStream(&buffer);

            try std.json.stringify(EthereumErrorResponse{ .@"error" = .{ .code = .InvalidRequest, .message = "Incorrect method type. Expected string" } }, .{}, buf_writer.writer());

            return stream.writeAll(buf_writer.getWritten());
        }

        const as_enum = std.meta.stringToEnum(EthereumRpcMethods, method.string) orelse {
            var buffer: [1024]u8 = undefined;
            var buf_writer = std.io.fixedBufferStream(&buffer);

            try std.json.stringify(EthereumErrorResponse{ .@"error" = .{ .code = .MethodNotFound, .message = "Invalid RPC Method" } }, .{}, buf_writer.writer());

            return stream.writeAll(buf_writer.getWritten());
        };

        break :blk as_enum;
    };

    return switch (method) {
        .eth_sendRawTransaction,
        .eth_getStorageAt,
        => self.sendResponse([32]u8, stream),
        .eth_accounts,
        => self.sendResponse([]const [20]u8, stream),
        .eth_createAccessList,
        => self.sendResponse(AccessListResult, stream),
        .eth_getProof,
        => self.sendResponse(ProofResult, stream),
        .eth_getBlockByNumber,
        .eth_getBlockByHash,
        .eth_getUncleByBlockHashAndIndex,
        .eth_getUncleByBlockNumberAndIndex,
        => self.sendResponse(Block, stream),
        .eth_getTransactionReceipt,
        => self.sendResponse(TransactionReceipt, stream),
        .eth_getTransactionByHash,
        .eth_getTransactionByBlockHashAndIndex,
        .eth_getTransactionByBlockNumberAndIndex,
        => self.sendResponse([32]u8, stream),
        .eth_feeHistory,
        => self.sendResponse(FeeHistory, stream),
        .eth_call,
        .eth_getCode,
        => self.sendResponse([]u8, stream),
        .eth_unsubscribe,
        .eth_uninstallFilter,
        => self.sendResponse(bool, stream),
        .eth_getLogs,
        .eth_getFilterLogs,
        .eth_getFilterChanges,
        => self.sendResponse(Logs, stream),
        .eth_getBalance,
        => self.sendResponse(u256, stream),
        .eth_chainId,
        .eth_gasPrice,
        .eth_estimateGas,
        .eth_blobBaseFee,
        .eth_blockNumber,
        .eth_getUncleCountByBlockHash,
        .eth_getUncleCountByBlockNumber,
        .eth_getTransactionCount,
        .eth_maxPriorityFeePerGas,
        .eth_getBlockTransactionCountByHash,
        .eth_getBlockTransactionCountByNumber,
        => self.sendResponse(u64, stream),
        .eth_newFilter,
        .eth_newBlockFilter,
        .eth_newPendingTransactionFilter,
        .eth_subscribe,
        => self.sendResponse(u128, stream),
        else => {
            var buffer: [1024]u8 = undefined;
            var buf_writer = std.io.fixedBufferStream(&buffer);

            try std.json.stringify(EthereumErrorResponse{ .@"error" = .{ .code = .MethodNotFound, .message = "Method not supported" } }, .{}, buf_writer.writer());

            return stream.writeAll(buf_writer.getWritten());
        },
    };
}
/// Sends the response back to the user.
fn sendResponse(self: *IpcServer, comptime T: type, stream: std.net.Stream) !void {
    const generated = try generator.generateRandomData(EthereumRpcResponse(T), self.allocator, self.seed, .{
        .slice_size = 2,
        .use_default_values = true,
    });
    defer generated.deinit();

    var buffer: [1024 * 1024]u8 = undefined;
    var buf_writer = std.io.fixedBufferStream(&buffer);

    try std.json.stringify(generated.generated, .{}, buf_writer.writer());

    return stream.writeAll(buf_writer.getWritten());
}
