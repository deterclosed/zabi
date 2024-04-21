const generator = @import("../generator.zig");
const std = @import("std");
const types = @import("../../types/root.zig");
const ws = @import("ws");

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
const Connection = ws.Conn;
const Message = ws.Message;
const Handshake = ws.Handshake;

const server_log = std.log.scoped(.server);

pub const WsContext = struct {
    allocator: Allocator,
    seed: u64,
};

pub const WsHandler = struct {
    conn: *Connection,
    context: *WsContext,

    /// Start the handlers state.
    pub fn init(h: Handshake, conn: *Connection, context: *WsContext) !WsHandler {
        _ = h;

        return .{
            .conn = conn,
            .context = context,
        };
    }
    /// Handles any messages that the socket server gets.
    pub fn handle(self: *WsHandler, message: Message) !void {
        return self.handleRequest(message);
    }
    /// Handles and mimics a json rpc response from a JSON-RPC server.
    /// Uses the custom data generator to produce the response.
    fn handleRequest(self: *WsHandler, message: Message) !void {
        server_log.debug("Parsing request: {s}", .{message.data});

        const parsed = std.json.parseFromSlice(std.json.Value, self.context.allocator, message.data, .{ .ignore_unknown_fields = true }) catch {
            var buffer: [1024]u8 = undefined;
            var buf_writer = std.io.fixedBufferStream(&buffer);

            try std.json.stringify(EthereumErrorResponse{ .@"error" = .{ .code = .InvalidRequest, .message = "Invalid json message sent" } }, .{}, buf_writer.writer());

            return self.conn.write(buf_writer.getWritten());
        };
        defer parsed.deinit();

        const method = blk: {
            const method = parsed.value.object.get("method") orelse {
                var buffer: [1024]u8 = undefined;
                var buf_writer = std.io.fixedBufferStream(&buffer);

                try std.json.stringify(EthereumErrorResponse{ .@"error" = .{ .code = .MethodNotFound, .message = "Missing 'method' field on json request" } }, .{}, buf_writer.writer());

                return self.conn.write(buf_writer.getWritten());
            };

            if (method != .string) {
                var buffer: [1024]u8 = undefined;
                var buf_writer = std.io.fixedBufferStream(&buffer);

                try std.json.stringify(EthereumErrorResponse{ .@"error" = .{ .code = .InvalidRequest, .message = "Incorrect method type. Expected string" } }, .{}, buf_writer.writer());

                return self.conn.write(buf_writer.getWritten());
            }

            const as_enum = std.meta.stringToEnum(EthereumRpcMethods, method.string) orelse {
                var buffer: [1024]u8 = undefined;
                var buf_writer = std.io.fixedBufferStream(&buffer);

                try std.json.stringify(EthereumErrorResponse{ .@"error" = .{ .code = .MethodNotFound, .message = "Invalid RPC Method" } }, .{}, buf_writer.writer());

                return self.conn.write(buf_writer.getWritten());
            };

            break :blk as_enum;
        };

        return switch (method) {
            .eth_sendRawTransaction,
            .eth_getStorageAt,
            => self.sendResponse([32]u8),
            .eth_accounts,
            => self.sendResponse([]const [20]u8),
            .eth_createAccessList,
            => self.sendResponse(AccessListResult),
            .eth_getProof,
            => self.sendResponse(ProofResult),
            .eth_getBlockByNumber,
            .eth_getBlockByHash,
            .eth_getUncleByBlockHashAndIndex,
            .eth_getUncleByBlockNumberAndIndex,
            => self.sendResponse(Block),
            .eth_getTransactionReceipt,
            => self.sendResponse(TransactionReceipt),
            .eth_getTransactionByHash,
            .eth_getTransactionByBlockHashAndIndex,
            .eth_getTransactionByBlockNumberAndIndex,
            => self.sendResponse([32]u8),
            .eth_feeHistory,
            => self.sendResponse(FeeHistory),
            .eth_call,
            .eth_getCode,
            => self.sendResponse([]u8),
            .eth_unsubscribe,
            .eth_uninstallFilter,
            => self.sendResponse(bool),
            .eth_getLogs,
            .eth_getFilterLogs,
            .eth_getFilterChanges,
            => self.sendResponse(Logs),
            .eth_getBalance,
            => self.sendResponse(u256),
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
            => self.sendResponse(u64),
            .eth_newFilter,
            .eth_newBlockFilter,
            .eth_newPendingTransactionFilter,
            .eth_subscribe,
            => self.sendResponse(u128),
            else => error.UnsupportedRpcMethod,
        };
    }
    /// Sends the response back to the user.
    fn sendResponse(self: *WsHandler, comptime T: type) !void {
        const generated = try generator.generateRandomData(EthereumRpcResponse(T), self.context.allocator, self.context.seed, .{
            .slice_size = 2,
            .use_default_values = true,
        });
        defer generated.deinit();
        var buffer: [1024 * 1024]u8 = undefined;
        var buf_writer = std.io.fixedBufferStream(&buffer);

        try std.json.stringify(generated.generated, .{}, buf_writer.writer());

        return self.conn.write(buf_writer.getWritten());
    }
    // called whenever the connection is closed, can do some cleanup in here
    pub fn close(_: *WsHandler) void {}
};