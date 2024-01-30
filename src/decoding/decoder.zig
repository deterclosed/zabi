const abi = @import("../abi/abi.zig");
const std = @import("std");
const meta = @import("../meta/meta.zig");
const testing = std.testing;
const utils = @import("../utils.zig");
const AbiParameter = @import("../abi/abi_parameter.zig").AbiParameter;
const AbiParameterToPrimative = meta.AbiParameterToPrimative;
const AbiParametersToPrimative = meta.AbiParametersToPrimative;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const ParamType = @import("../abi/param_type.zig").ParamType;

pub fn Decoded(comptime T: type) type {
    return struct { consumed: usize, data: T, bytes_read: u16 };
}

pub fn AbiDecoded(comptime params: []const AbiParameter) type {
    return struct {
        arena: *ArenaAllocator,
        values: AbiParametersToPrimative(params),

        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();

            allocator.destroy(self.arena);
        }
    };
}

pub fn AbiSignatureDecoded(comptime params: []const AbiParameter) type {
    return struct {
        arena: *ArenaAllocator,
        name: []const u8,
        values: AbiParametersToPrimative(params),

        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();

            allocator.free(self.name);
            allocator.destroy(self.arena);
        }
    };
}

pub const DecodeOptions = struct {
    /// Max amount of bytes allowed to be read by the decoder.
    /// This avoid a DoS vulnerability discovered here:
    /// https://github.com/paulmillr/micro-eth-signer/discussions/20
    max_bytes: u16 = 1024,
    /// By default this is false.
    allow_junk_data: bool = false,
};

pub const DecodedErrors = error{ JunkData, InvalidAbiSignature, BufferOverrun, InvalidLength, NoSpaceLeft, InvalidDecodeDataSize } || Allocator.Error || std.fmt.ParseIntError;

/// Decode the hex values based on the struct signature
/// Caller owns the memory.
pub fn decodeAbiFunction(alloc: Allocator, comptime function: abi.Function, hex: []const u8, opts: DecodeOptions) DecodedErrors!AbiSignatureDecoded(function.inputs) {
    std.debug.assert(hex.len > 7);

    const hashed_func_name = hex[0..8];
    const prepare = try function.allocPrepare(alloc);
    defer alloc.free(prepare);

    var hashed: [Keccak256.digest_length]u8 = undefined;
    Keccak256.hash(prepare, &hashed, .{});

    const hash_hex = std.fmt.bytesToHex(hashed, .lower);

    if (!std.mem.eql(u8, hashed_func_name, hash_hex[0..8]))
        return error.InvalidAbiSignature;

    const data = hex[8..];
    const func_name = try std.mem.concat(alloc, u8, &.{ "0x", hashed_func_name });
    errdefer alloc.free(func_name);

    if (data.len == 0 and function.inputs.len > 0)
        return error.InvalidDecodeDataSize;

    const decoded = try decodeAbiParameters(alloc, function.inputs, data, opts);

    return .{ .arena = decoded.arena, .name = func_name, .values = decoded.values };
}

/// Decode the hex values based on the struct signature
/// Caller owns the memory.
pub fn decodeAbiFunctionOutputs(alloc: Allocator, comptime function: abi.Function, hex: []const u8, opts: DecodeOptions) DecodedErrors!AbiSignatureDecoded(function.outputs) {
    std.debug.assert(hex.len > 7);

    const hashed_func_name = hex[0..8];
    const prepare = try function.allocPrepare(alloc);
    defer alloc.free(prepare);

    var hashed: [Keccak256.digest_length]u8 = undefined;
    Keccak256.hash(prepare, &hashed, .{});

    const hash_hex = std.fmt.bytesToHex(hashed, .lower);

    if (!std.mem.eql(u8, hashed_func_name, hash_hex[0..8])) return error.InvalidAbiSignature;

    const data = hex[8..];
    const func_name = try std.mem.concat(alloc, u8, &.{ "0x", hashed_func_name });
    errdefer alloc.free(func_name);

    if (data.len == 0 and function.outputs.len > 0)
        return error.InvalidDecodeDataSize;

    const decoded = try decodeAbiParameters(alloc, function.outputs, data, opts);

    return .{ .arena = decoded.arena, .name = func_name, .values = decoded.values };
}

/// Decode the hex values based on the struct signature
/// Caller owns the memory.
pub fn decodeAbiError(alloc: Allocator, comptime err: abi.Error, hex: []const u8, opts: DecodeOptions) DecodedErrors!AbiSignatureDecoded(err.inputs) {
    std.debug.assert(hex.len > 7);

    const hashed_func_name = hex[0..8];
    const prepare = try err.allocPrepare(alloc);
    defer alloc.free(prepare);

    var hashed: [Keccak256.digest_length]u8 = undefined;
    Keccak256.hash(prepare, &hashed, .{});

    const hash_hex = std.fmt.bytesToHex(hashed, .lower);

    if (!std.mem.eql(u8, hashed_func_name, hash_hex[0..8])) return error.InvalidAbiSignature;

    const data = hex[8..];
    const func_name = try std.mem.concat(alloc, u8, &.{ "0x", hashed_func_name });
    errdefer alloc.free(func_name);

    if (data.len == 0 and err.inputs.len > 0)
        return error.InvalidDecodeDataSize;

    const decoded = try decodeAbiParameters(alloc, err.inputs, data, opts);

    return .{ .arena = decoded.arena, .name = func_name, .values = decoded.values };
}

/// Decode the hex values based on the struct signature
/// Caller owns the memory.
pub fn decodeAbiConstructor(alloc: Allocator, comptime constructor: abi.Constructor, hex: []const u8, opts: DecodeOptions) DecodedErrors!AbiSignatureDecoded(constructor.inputs) {
    const decoded = try decodeAbiParameters(alloc, constructor.inputs, hex, opts);

    return .{ .arena = decoded.arena, .name = "", .values = decoded.values };
}

/// Main function that will be used to decode the hex values based on the abi paramters.
/// This will allocate and a ArenaAllocator will be used to manage the memory.
///
/// Caller owns the memory.
pub fn decodeAbiParameters(alloc: Allocator, comptime params: []const AbiParameter, hex: []const u8, opts: DecodeOptions) !AbiDecoded(params) {
    var decoded: AbiDecoded(params) = .{ .arena = try alloc.create(ArenaAllocator), .values = undefined };
    errdefer alloc.destroy(decoded.arena);

    decoded.arena.* = ArenaAllocator.init(alloc);
    errdefer decoded.arena.deinit();

    const allocator = decoded.arena.allocator();
    decoded.values = try decodeAbiParametersLeaky(allocator, params, hex, opts);

    return decoded;
}

/// Subset function used for decoding. Its highly recommend to use an ArenaAllocator
/// or a FixedBufferAllocator to manage memory since allocations will not be freed when done,
/// and with those all of the memory can be freed at once.
///
/// Caller owns the memory.
pub fn decodeAbiParametersLeaky(alloc: Allocator, comptime params: []const AbiParameter, hex: []const u8, opts: DecodeOptions) !AbiParametersToPrimative(params) {
    if (params.len == 0) return;
    std.debug.assert(hex.len > 63 and hex.len % 2 == 0);

    const buffer = try alloc.alloc(u8, @divExact(hex.len, 2));
    const bytes = try std.fmt.hexToBytes(buffer, hex);

    return decodeParameters(alloc, params, bytes, opts);
}

fn decodeParameters(alloc: Allocator, comptime params: []const AbiParameter, hex: []u8, opts: DecodeOptions) !AbiParametersToPrimative(params) {
    var pos: usize = 0;
    var read: u16 = 0;

    var result: AbiParametersToPrimative(params) = undefined;
    inline for (params, 0..) |param, i| {
        const decoded = try decodeParameter(alloc, param, hex, pos, opts);
        pos += decoded.consumed;
        result[i] = decoded.data;
        read += decoded.bytes_read;

        if (pos > opts.max_bytes)
            return error.BufferOverrun;
    }

    if (!opts.allow_junk_data and hex.len > read)
        return error.JunkData;

    return result;
}

fn decodeParameter(alloc: Allocator, comptime param: AbiParameter, hex: []u8, position: usize, opts: DecodeOptions) !Decoded(AbiParameterToPrimative(param)) {
    const decoded = switch (param.type) {
        .string => try decodeString(alloc, hex, position),
        .bytes => try decodeBytes(alloc, hex, position),
        .address => try decodeAddress(alloc, hex, position),
        .fixedBytes => |val| try decodeFixedBytes(alloc, val, hex, position),
        .int => |val| try decodeNumber(alloc, if (val % 8 != 0 or val > 256) @compileError("Invalid bits passed in to int type") else @Type(.{ .Int = .{ .signedness = .signed, .bits = val } }), hex, position),
        .uint => |val| try decodeNumber(alloc, if (val % 8 != 0 or val > 256) @compileError("Invalid bits passed in to int type") else @Type(.{ .Int = .{ .signedness = .unsigned, .bits = val } }), hex, position),
        .bool => try decodeBool(alloc, hex, position),
        .dynamicArray => |val| try decodeArray(alloc, .{ .type = val.*, .name = param.name, .internalType = param.internalType, .components = param.components }, hex, position, opts),
        .fixedArray => |val| try decodeFixedArray(alloc, .{ .type = val.child.*, .name = param.name, .internalType = param.internalType, .components = param.components }, val.size, hex, position, opts),
        .tuple => try decodeTuple(alloc, param, hex, position, opts),
        inline else => @compileError("Not implemented " ++ @tagName(param.type)),
    };

    if (decoded.bytes_read > opts.max_bytes)
        return error.BufferOverrun;

    return decoded;
}

fn decodeAddress(alloc: Allocator, hex: []u8, position: usize) !Decoded([]const u8) {
    const slice = hex[position + 12 .. position + 32];

    const checksumed = try utils.toChecksum(alloc, try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.fmtSliceHexLower(slice)}));
    return .{ .consumed = 32, .data = checksumed, .bytes_read = 32 };
}

fn decodeNumber(alloc: Allocator, comptime T: type, hex: []u8, position: usize) !Decoded(T) {
    const info = @typeInfo(T);
    if (info != .Int)
        @compileError("Invalid type passed");

    const hexed = std.fmt.fmtSliceHexLower(hex[position .. position + 32]);
    const slice = try std.fmt.allocPrint(alloc, "{s}", .{hexed});

    if (info.Int.signedness == .signed) {
        const parsed = std.fmt.parseInt(T, slice, 16) catch |err| {
            switch (err) {
                error.Overflow => {
                    const parsedUnsigned = try std.fmt.parseInt(u256, slice, 16);
                    const negative = std.math.cast(T, (std.math.maxInt(u256) - parsedUnsigned) + 1) orelse return err;
                    return .{ .consumed = 32, .data = -negative, .bytes_read = 32 };
                },
                inline else => return err,
            }
        };
        return .{ .consumed = 32, .data = parsed, .bytes_read = 32 };
    }
    return .{ .consumed = 32, .data = try std.fmt.parseInt(T, slice, 16), .bytes_read = 32 };
}

fn decodeBool(alloc: Allocator, hex: []u8, position: usize) !Decoded(bool) {
    const b = try decodeNumber(alloc, u1, hex, position);

    return .{ .consumed = 32, .data = b.data != 0, .bytes_read = 32 };
}

fn decodeString(alloc: Allocator, hex: []u8, position: usize) !Decoded([]const u8) {
    const offset = try decodeNumber(alloc, usize, hex, position);
    const length = try decodeNumber(alloc, usize, hex, offset.data);

    const slice = hex[offset.data + 32 .. offset.data + 32 + length.data];
    const remainder = length.data % 32;
    const len_padded = length.data + 32 - remainder;

    return .{ .consumed = 32, .data = try std.fmt.allocPrint(alloc, "{s}", .{slice}), .bytes_read = @intCast(len_padded + 64) };
}

fn decodeBytes(alloc: Allocator, hex: []u8, position: usize) !Decoded([]const u8) {
    const offset = try decodeNumber(alloc, usize, hex, position);
    const length = try decodeNumber(alloc, usize, hex, offset.data);

    const slice = hex[offset.data + 32 .. offset.data + 32 + length.data];
    const remainder = length.data % 32;
    const len_padded = length.data + 32 - remainder;

    return .{ .consumed = 32, .data = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.fmtSliceHexLower(slice)}), .bytes_read = @intCast(len_padded + 64) };
}

fn decodeFixedBytes(alloc: Allocator, size: usize, hex: []u8, position: usize) !Decoded([]const u8) {
    return .{ .consumed = 32, .data = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.fmtSliceHexLower(hex[position .. position + size])}), .bytes_read = 32 };
}

fn decodeArray(alloc: Allocator, comptime param: AbiParameter, hex: []u8, position: usize, opts: DecodeOptions) !Decoded([]const AbiParameterToPrimative(param)) {
    const offset = try decodeNumber(alloc, usize, hex, position);
    const length = try decodeNumber(alloc, usize, hex, offset.data);

    var pos: usize = 0;
    var read: u16 = 0;

    var list = std.ArrayList(AbiParameterToPrimative(param)).init(alloc);

    for (0..length.data) |_| {
        const decoded = try decodeParameter(alloc, param, hex[offset.data + 32 ..], pos, opts);
        pos += decoded.consumed;
        read += decoded.bytes_read;

        if (pos > opts.max_bytes)
            return error.BufferOverrun;

        try list.append(decoded.data);
    }

    return .{ .consumed = 32, .data = try list.toOwnedSlice(), .bytes_read = read + 64 };
}

fn decodeFixedArray(alloc: Allocator, comptime param: AbiParameter, comptime size: usize, hex: []u8, position: usize, opts: DecodeOptions) !Decoded([size]AbiParameterToPrimative(param)) {
    if (isDynamicType(param)) {
        const offset = try decodeNumber(alloc, usize, hex, position);
        var pos: usize = 0;
        var read: u16 = 0;

        var result: [size]AbiParameterToPrimative(param) = undefined;
        const child = blk: {
            switch (param.type) {
                .dynamicArray => |val| break :blk val.*,
                inline else => {},
            }
        };

        for (0..size) |i| {
            const decoded = try decodeParameter(alloc, param, hex[offset.data..], if (@TypeOf(child) != void) pos else i * 32, opts);
            pos += decoded.consumed;
            result[i] = decoded.data;
            read += decoded.bytes_read;

            if (pos > opts.max_bytes)
                return error.BufferOverrun;
        }

        return .{ .consumed = 32, .data = result, .bytes_read = read + 32 };
    }

    var pos: usize = 0;
    var read: u16 = 0;

    var result: [size]AbiParameterToPrimative(param) = undefined;
    for (0..size) |i| {
        const decoded = try decodeParameter(alloc, param, hex, pos + position, opts);
        pos += decoded.consumed;
        result[i] = decoded.data;
        read += decoded.bytes_read;

        if (pos > opts.max_bytes)
            return error.BufferOverrun;
    }

    return .{ .consumed = 32, .data = result, .bytes_read = read };
}

fn decodeTuple(alloc: Allocator, comptime param: AbiParameter, hex: []u8, position: usize, opts: DecodeOptions) !Decoded(AbiParameterToPrimative(param)) {
    var result: AbiParameterToPrimative(param) = undefined;

    if (param.components) |components| {
        if (isDynamicType(param)) {
            var pos: usize = 0;
            var read: u16 = 0;
            const offset = try decodeNumber(alloc, usize, hex, position);

            inline for (components) |component| {
                const decoded = try decodeParameter(alloc, component, hex[offset.data..], pos, opts);
                pos += decoded.consumed;
                read += decoded.bytes_read;

                if (pos > opts.max_bytes)
                    return error.BufferOverrun;

                @field(result, component.name) = decoded.data;
            }

            return .{ .consumed = 32, .data = result, .bytes_read = read + 32 };
        }

        var pos: usize = 0;
        var read: u16 = 0;
        inline for (components) |component| {
            const decoded = try decodeParameter(alloc, component, hex, position + pos, opts);
            pos += decoded.consumed;
            read += decoded.bytes_read;

            if (pos > opts.max_bytes)
                return error.BufferOverrun;

            @field(result, component.name) = decoded.data;
        }

        return .{ .consumed = 32, .data = result, .bytes_read = read };
    } else @compileError("Expected components to not be null");
}

inline fn isDynamicType(comptime param: AbiParameter) bool {
    return switch (param.type) {
        .string,
        .bytes,
        .dynamicArray,
        => true,
        .tuple => {
            inline for (param.components.?) |component| {
                const dyn = isDynamicType(component);

                if (dyn) return dyn;
            }

            return false;
        },
        .fixedArray => |val| isDynamicType(.{ .type = val.child.*, .name = param.name, .internalType = param.internalType, .components = param.components }),
        inline else => false,
    };
}

test "Bool" {
    try testDecode("0000000000000000000000000000000000000000000000000000000000000001", &.{.{ .type = .{ .bool = {} }, .name = "foo" }}, .{true});
    try testDecode("0000000000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .bool = {} }, .name = "foo" }}, .{false});

    const decoded = try decodeAbiConstructor(testing.allocator, .{ .type = .constructor, .stateMutability = .nonpayable, .inputs = &.{.{ .type = .{ .bool = {} }, .name = "foo" }} }, "0000000000000000000000000000000000000000000000000000000000000000", .{});
    defer decoded.deinit();

    try testInnerValues(.{false}, decoded.values);
}

test "Uint/Int" {
    try testDecode("0000000000000000000000000000000000000000000000000000000000000005", &.{.{ .type = .{ .uint = 8 }, .name = "foo" }}, .{5});
    try testDecode("0000000000000000000000000000000000000000000000000000000000010f2c", &.{.{ .type = .{ .uint = 256 }, .name = "foo" }}, .{69420});
    try testDecode("fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffb", &.{.{ .type = .{ .int = 256 }, .name = "foo" }}, .{-5});
    try testDecode("fffffffffffffffffffffffffffffffffffffffffffffffffffffffff8a432eb", &.{.{ .type = .{ .int = 64 }, .name = "foo" }}, .{-123456789});

    const decoded = try decodeAbiError(testing.allocator, .{ .type = .@"error", .name = "Bar", .inputs = &.{.{ .type = .{ .int = 256 }, .name = "foo" }} }, "22217e1f0000000000000000000000000000000000000000000000000000000000010f2c", .{});
    defer decoded.deinit();

    try testInnerValues(.{69420}, decoded.values);
    try testing.expectEqualStrings("0x22217e1f", decoded.name);
}

test "Address" {
    try testDecode("0000000000000000000000004648451b5f87ff8f0f7d622bd40574bb97e25980", &.{.{ .type = .{ .address = {} }, .name = "foo" }}, .{"0x4648451b5F87FF8F0F7D622bD40574bb97E25980"});
    try testDecode("000000000000000000000000388c818ca8b9251b393131c08a736a67ccb19297", &.{.{ .type = .{ .address = {} }, .name = "foo" }}, .{"0x388C818CA8B9251b393131C08a736A67ccB19297"});

    const decoded = try decodeAbiFunctionOutputs(testing.allocator, .{ .type = .function, .name = "Bar", .inputs = &.{}, .stateMutability = .nonpayable, .outputs = &.{.{ .type = .{ .address = {} }, .name = "foo" }} }, "b0a378b0000000000000000000000000388c818ca8b9251b393131c08a736a67ccb19297", .{});
    defer decoded.deinit();

    try testInnerValues(.{"0x388C818CA8B9251b393131C08a736A67ccB19297"}, decoded.values);
    try testing.expectEqualStrings("0xb0a378b0", decoded.name);
}

test "Fixed Bytes" {
    try testDecode("0123456789000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .fixedBytes = 5 }, .name = "foo" }}, .{"0123456789"});
    try testDecode("0123456789012345678900000000000000000000000000000000000000000000", &.{.{ .type = .{ .fixedBytes = 10 }, .name = "foo" }}, .{"01234567890123456789"});

    const decoded = try decodeAbiError(testing.allocator, .{ .type = .@"error", .name = "Bar", .inputs = &.{} }, "b0a378b0", .{});
    defer decoded.deinit();

    try testing.expectEqualStrings("0xb0a378b0", decoded.name);
}

test "Bytes/String" {
    try testDecode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003666f6f0000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .string = {} }, .name = "foo" }}, .{"foo"});
    try testDecode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003666f6f0000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .bytes = {} }, .name = "foo" }}, .{"666f6f"});

    const decoded = try decodeAbiFunction(testing.allocator, .{ .type = .function, .name = "Bar", .inputs = &.{.{ .type = .{ .string = {} }, .name = "foo" }}, .stateMutability = .nonpayable, .outputs = &.{} }, "4ec7c7ae00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003666f6f0000000000000000000000000000000000000000000000000000000000", .{});
    defer decoded.deinit();

    try testInnerValues(.{"foo"}, decoded.values);
    try testing.expectEqualStrings("0x4ec7c7ae", decoded.name);
}

test "Errors" {
    try testing.expectError(error.InvalidAbiSignature, decodeAbiFunction(testing.allocator, .{ .type = .function, .name = "Bar", .inputs = &.{.{ .type = .{ .string = {} }, .name = "foo" }}, .stateMutability = .nonpayable, .outputs = &.{} }, "4ec7c7af00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003666f6f0000000000000000000000000000000000000000000000000000000000", .{}));
    try testing.expectError(error.InvalidDecodeDataSize, decodeAbiFunction(testing.allocator, .{ .type = .function, .name = "Bar", .inputs = &.{.{ .type = .{ .string = {} }, .name = "foo" }}, .stateMutability = .nonpayable, .outputs = &.{} }, "4ec7c7ae", .{}));
    try testing.expectError(error.BufferOverrun, decodeAbiParameters(testing.allocator, &.{.{ .type = .{ .dynamicArray = &.{ .dynamicArray = &.{ .dynamicArray = &.{ .dynamicArray = &.{ .dynamicArray = &.{ .dynamicArray = &.{ .dynamicArray = &.{ .dynamicArray = &.{ .dynamicArray = &.{ .dynamicArray = &.{ .uint = 256 } } } } } } } } } } }, .name = "" }}, "0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020", .{}));
    try testing.expectError(error.JunkData, decodeAbiParameters(testing.allocator, &.{ .{ .type = .{ .uint = 256 }, .name = "foo" }, .{ .type = .{ .dynamicArray = &.{ .address = {} } }, .name = "bar" }, .{ .type = .{ .address = {} }, .name = "baz" }, .{ .type = .{ .uint = 256 }, .name = "fizz" } }, "0000000000000000000000000000000000000000000000164054d8356b4f5c2800000000000000000000000000000000000000000000000000000000000000800000000000000000000000006994ece772cc4abb5c9993c065a34c94544a40870000000000000000000000000000000000000000000000000000000062b348620000000000000000000000000000000000000000000000000000000000000002000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000106d3c66d22d2dd0446df23d7f5960752994d6007a6572696f6e", .{}));
}

test "Arrays" {
    try testDecode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .dynamicArray = &ParamType{ .int = 256 } }, .name = "foo" }}, .{&[_]i256{ 4, 2, 0 }});
    try testDecode("00000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000002", &.{.{ .type = .{ .fixedArray = .{ .child = &.{ .int = 256 }, .size = 2 } }, .name = "foo" }}, .{[2]i256{ 4, 2 }});
    try testDecode("0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003666f6f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000036261720000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .fixedArray = .{ .child = &.{ .string = {} }, .size = 2 } }, .name = "foo" }}, .{[2][]const u8{ "foo", "bar" }});
    try testDecode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003666f6f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000036261720000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .dynamicArray = &.{ .string = {} } }, .name = "foo" }}, .{&[_][]const u8{ "foo", "bar" }});
    try testDecode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003666f6f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003626172000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000362617a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003626f6f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000466697a7a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000462757a7a00000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .fixedArray = .{ .child = &.{ .fixedArray = .{ .child = &.{ .string = {} }, .size = 2 } }, .size = 3 } }, .name = "foo" }}, .{[3][2][]const u8{ .{ "foo", "bar" }, .{ "baz", "boo" }, .{ "fizz", "buzz" } }});
    try testDecode("0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000003666f6f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000036261720000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000666697a7a7a7a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000362757a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000466697a7a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000462757a7a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000662757a7a7a7a0000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .fixedArray = .{ .child = &.{ .dynamicArray = &.{ .string = {} } }, .size = 2 } }, .name = "foo" }}, .{[2][]const []const u8{ &.{ "foo", "bar", "fizzzz", "buz" }, &.{ "fizz", "buzz", "buzzzz" } }});
}
//
test "Tuples" {
    try testDecode("0000000000000000000000000000000000000000000000000000000000000001", &.{.{ .type = .{ .tuple = {} }, .name = "foo", .components = &.{.{ .type = .{ .bool = {} }, .name = "bar" }} }}, .{.{ .bar = true }});
    try testDecode("0000000000000000000000000000000000000000000000000000000000000001", &.{.{ .type = .{ .tuple = {} }, .name = "foo", .components = &.{.{ .type = .{ .tuple = {} }, .name = "bar", .components = &.{.{ .type = .{ .bool = {} }, .name = "baz" }} }} }}, .{.{ .bar = .{ .baz = true } }});
    try testDecode("0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000450000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000462757a7a00000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .tuple = {} }, .name = "foo", .components = &.{ .{ .type = .{ .bool = {} }, .name = "bar" }, .{ .type = .{ .uint = 256 }, .name = "baz" }, .{ .type = .{ .string = {} }, .name = "fizz" } } }}, .{.{ .bar = true, .baz = 69, .fizz = "buzz" }});
    try testDecode("000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000450000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000462757a7a00000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .dynamicArray = &.{ .tuple = {} } }, .name = "foo", .components = &.{ .{ .type = .{ .bool = {} }, .name = "bar" }, .{ .type = .{ .uint = 256 }, .name = "baz" }, .{ .type = .{ .string = {} }, .name = "fizz" } } }}, .{&.{.{ .bar = true, .baz = 69, .fizz = "buzz" }}});
}

test "Multiple" {
    try testDecode("0000000000000000000000000000000000000000000000000000000000000045000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000004500000000000000000000000000000000000000000000000000000000000001a40000000000000000000000000000000000000000000000000000000000010f2c", &.{ .{ .type = .{ .uint = 256 }, .name = "foo" }, .{ .type = .{ .bool = {} }, .name = "bar" }, .{ .type = .{ .dynamicArray = &.{ .int = 120 } }, .name = "baz" } }, .{ 69, true, &[_]i120{ 69, 420, 69420 } });

    const params: []const AbiParameter = &.{.{ .type = .{ .tuple = {} }, .name = "fizzbuzz", .components = &.{ .{ .type = .{ .dynamicArray = &.{ .string = {} } }, .name = "foo" }, .{ .type = .{ .uint = 256 }, .name = "bar" }, .{ .type = .{ .dynamicArray = &.{ .tuple = {} } }, .name = "baz", .components = &.{ .{ .type = .{ .dynamicArray = &.{ .string = {} } }, .name = "fizz" }, .{ .type = .{ .bool = {} }, .name = "buzz" }, .{ .type = .{ .dynamicArray = &.{ .int = 256 } }, .name = "jazz" } } } } }};
    //
    try testDecode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000a45500000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000001c666f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f00000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000018424f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f00000000000000000000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000700000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000009", params, .{.{ .foo = &[_][]const u8{"fooooooooooooooooooooooooooo"}, .bar = 42069, .baz = &.{.{ .fizz = &.{"BOOOOOOOOOOOOOOOOOOOOOOO"}, .buzz = true, .jazz = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 } }} }});
}

test "foo" {}

fn testDecode(hex: []const u8, comptime params: []const AbiParameter, comptime expected: anytype) !void {
    const decoded = try decodeAbiParameters(testing.allocator, params, hex, .{});
    defer decoded.deinit();

    try testing.expectEqual(decoded.values.len, expected.len);

    inline for (expected, 0..) |e, i| {
        try testInnerValues(e, decoded.values[i]);
    }
}

fn testInnerValues(expected: anytype, actual: anytype) !void {
    if (@TypeOf(actual) == []const u8) {
        return try testing.expectEqualStrings(expected, actual);
    }

    const info = @typeInfo(@TypeOf(expected));
    if (info == .Pointer) {
        if (@typeInfo(info.Pointer.child) == .Struct) return try testInnerValues(expected[0], actual[0]);

        for (expected, actual) |e, a| {
            try testInnerValues(e, a);
        }
        return;
    }
    if (info == .Array) {
        for (expected, actual) |e, a| {
            try testInnerValues(e, a);
        }
        return;
    }

    if (info == .Struct) {
        inline for (info.Struct.fields) |field| {
            try testInnerValues(@field(expected, field.name), @field(actual, field.name));
        }
        return;
    }
    return try testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}