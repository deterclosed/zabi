const abi = @import("zabi-abi").abitypes;
const abi_param = @import("zabi-abi").abi_parameter;
const human = @import("zabi-human").parsing;
const meta = @import("zabi-meta").abi;
const std = @import("std");
const testing = std.testing;
const types = @import("zabi-types").ethereum;
const utils = @import("zabi-utils").utils;

/// Types
const AbiParameter = abi_param.AbiParameter;
const AbiParametersToPrimative = meta.AbiParametersToPrimative;
const ParamType = @import("zabi-abi").param_type.ParamType;

const encodeAbiParameters = @import("zabi-encoding").abi_encoding.encodeAbiParameters;
// const encodeAbiParametersComptime = @import("zabi-encoding").abi_encoding.encodeAbiParametersComptime;
const encodePacked = @import("zabi-encoding").abi_encoding.encodePacked;

test "Bool" {
    try testEncode("0000000000000000000000000000000000000000000000000000000000000001", &.{.{ .type = .{ .bool = {} }, .name = "foo" }}, .{true});
    try testEncode("0000000000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .bool = {} }, .name = "foo" }}, .{false});
}

test "Uint/Int" {
    try testEncode("0000000000000000000000000000000000000000000000000000000000000005", &.{.{ .type = .{ .uint = 8 }, .name = "foo" }}, .{5});
    try testEncode("0000000000000000000000000000000000000000000000000000000000010f2c", &.{.{ .type = .{ .uint = 256 }, .name = "foo" }}, .{69420});
    try testEncode("fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffb", &.{.{ .type = .{ .int = 256 }, .name = "foo" }}, .{-5});
    try testEncode("fffffffffffffffffffffffffffffffffffffffffffffffffffffffff8a432eb", &.{.{ .type = .{ .int = 64 }, .name = "foo" }}, .{-123456789});
}

test "Address" {
    try testEncode("0000000000000000000000004648451b5f87ff8f0f7d622bd40574bb97e25980", &.{.{ .type = .{ .address = {} }, .name = "foo" }}, .{try utils.addressToBytes("0x4648451b5F87FF8F0F7D622bD40574bb97E25980")});
    try testEncode("000000000000000000000000388c818ca8b9251b393131c08a736a67ccb19297", &.{.{ .type = .{ .address = {} }, .name = "foo" }}, .{try utils.addressToBytes("0x388C818CA8B9251b393131C08a736A67ccB19297")});
}

test "Fixed Bytes" {
    try testEncode("0123456789000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .fixedBytes = 5 }, .name = "foo" }}, .{[5]u8{ 0x01, 0x23, 0x45, 0x67, 0x89 }});
    try testEncode("0123456789000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .fixedBytes = 10 }, .name = "foo" }}, .{[5]u8{ 0x01, 0x23, 0x45, 0x67, 0x89 } ++ [_]u8{0x00} ** 5});
}

test "Bytes/String" {
    try testEncode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003666f6f0000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .string = {} }, .name = "foo" }}, .{"foo"});
    try testEncode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003666f6f0000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .string = {} }, .name = "foo" }}, .{"foo"});
}

test "Arrays" {
    try testEncode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .dynamicArray = &ParamType{ .int = 256 } }, .name = "foo" }}, .{&[_]i256{ 4, 2, 0 }});
    try testEncode("00000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000002", &.{.{ .type = .{ .fixedArray = .{ .child = &.{ .int = 256 }, .size = 2 } }, .name = "foo" }}, .{[2]i256{ 4, 2 }});
    try testEncode("0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003666f6f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000036261720000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .fixedArray = .{ .child = &.{ .string = {} }, .size = 2 } }, .name = "foo" }}, .{[2][]const u8{ "foo", "bar" }});
    try testEncode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003666f6f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000036261720000000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .dynamicArray = &.{ .string = {} } }, .name = "foo" }}, .{&[_][]const u8{ "foo", "bar" }});
    try testEncode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003666f6f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003626172000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000362617a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003626f6f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000466697a7a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000462757a7a00000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .fixedArray = .{ .child = &.{ .fixedArray = .{ .child = &.{ .string = {} }, .size = 2 } }, .size = 3 } }, .name = "foo" }}, .{[3][2][]const u8{ .{ "foo", "bar" }, .{ "baz", "boo" }, .{ "fizz", "buzz" } }});
    try testEncode("0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000003666f6f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000036261720000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000666697a7a7a7a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000362757a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000466697a7a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000462757a7a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000662757a7a7a7a0000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .fixedArray = .{ .child = &.{ .dynamicArray = &.{ .string = {} } }, .size = 2 } }, .name = "foo" }}, .{[2][]const []const u8{ &.{ "foo", "bar", "fizzzz", "buz" }, &.{ "fizz", "buzz", "buzzzz" } }});
}

test "Tuples" {
    try testEncode("0000000000000000000000000000000000000000000000000000000000000001", &.{.{ .type = .{ .tuple = {} }, .name = "foo", .components = &.{.{ .type = .{ .bool = {} }, .name = "bar" }} }}, .{.{ .bar = true }});
    try testEncode("0000000000000000000000000000000000000000000000000000000000000001", &.{.{ .type = .{ .tuple = {} }, .name = "foo", .components = &.{.{ .type = .{ .tuple = {} }, .name = "bar", .components = &.{.{ .type = .{ .bool = {} }, .name = "baz" }} }} }}, .{.{ .bar = .{ .baz = true } }});
    try testEncode("0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000450000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000462757a7a00000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .tuple = {} }, .name = "foo", .components = &.{ .{ .type = .{ .bool = {} }, .name = "bar" }, .{ .type = .{ .uint = 256 }, .name = "baz" }, .{ .type = .{ .string = {} }, .name = "fizz" } } }}, .{.{ .bar = true, .baz = 69, .fizz = "buzz" }});
    try testEncode("000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000450000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000462757a7a00000000000000000000000000000000000000000000000000000000", &.{.{ .type = .{ .dynamicArray = &.{ .tuple = {} } }, .name = "foo", .components = &.{ .{ .type = .{ .bool = {} }, .name = "bar" }, .{ .type = .{ .uint = 256 }, .name = "baz" }, .{ .type = .{ .string = {} }, .name = "fizz" } } }}, .{&.{.{ .bar = true, .baz = 69, .fizz = "buzz" }}});
}

test "Multiple" {
    try testEncode("0000000000000000000000000000000000000000000000000000000000000045000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000004500000000000000000000000000000000000000000000000000000000000001a40000000000000000000000000000000000000000000000000000000000010f2c", &.{ .{ .type = .{ .uint = 256 }, .name = "foo" }, .{ .type = .{ .bool = {} }, .name = "bar" }, .{ .type = .{ .dynamicArray = &.{ .int = 120 } }, .name = "baz" } }, .{ 69, true, &[_]i120{ 69, 420, 69420 } });

    const params: []const AbiParameter = &.{.{ .type = .{ .tuple = {} }, .name = "fizzbuzz", .components = &.{ .{ .type = .{ .dynamicArray = &.{ .string = {} } }, .name = "foo" }, .{ .type = .{ .uint = 256 }, .name = "bar" }, .{ .type = .{ .dynamicArray = &.{ .tuple = {} } }, .name = "baz", .components = &.{ .{ .type = .{ .dynamicArray = &.{ .string = {} } }, .name = "fizz" }, .{ .type = .{ .bool = {} }, .name = "buzz" }, .{ .type = .{ .dynamicArray = &.{ .int = 256 } }, .name = "jazz" } } } } }};

    try testEncode("00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000a45500000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000001c666f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f00000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000018424f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f00000000000000000000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000700000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000009", params, .{.{ .foo = &[_][]const u8{"fooooooooooooooooooooooooooo"}, .bar = 42069, .baz = &.{.{ .fizz = &.{"BOOOOOOOOOOOOOOOOOOOOOOO"}, .buzz = true, .jazz = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 } }} }});

    // const none = try encodeAbiParameters(&.{}, testing.allocator, .{});
    //
    // try testing.expectEqualStrings("", none.data);
}

// test "Errors" {
//     try testing.expectError(error.InvalidParamType, encodeAbiParameters(testing.allocator, &.{.{ .type = .{ .fixedBytes = 5 }, .name = "foo" }}, .{true}));
//     try testing.expectError(error.InvalidParamType, encodeAbiParameters(testing.allocator, &.{.{ .type = .{ .int = 5 }, .name = "foo" }}, .{true}));
//     try testing.expectError(error.InvalidParamType, encodeAbiParameters(testing.allocator, &.{.{ .type = .{ .tuple = {} }, .name = "foo" }}, .{.{ .bar = "foo" }}));
//     try testing.expectError(error.InvalidParamType, encodeAbiParameters(testing.allocator, &.{.{ .type = .{ .uint = 5 }, .name = "foo" }}, .{"foo"}));
//     try testing.expectError(error.InvalidParamType, encodeAbiParameters(testing.allocator, &.{.{ .type = .{ .string = {} }, .name = "foo" }}, .{[_][]const u8{"foo"}}));
//     try testing.expectError(error.InvalidLength, encodeAbiParameters(testing.allocator, &.{.{ .type = .{ .fixedBytes = 55 }, .name = "foo" }}, .{"foo"}));
// }
//
// test "EncodePacked" {
//     try testEncodePacked("45", .{69});
//     try testEncodePacked("01", .{true});
//     try testEncodePacked("00", .{false});
//     try testEncodePacked("01", .{true});
//     try testEncodePacked("01", .{true});
//     {
//         var buffer: [20]u8 = undefined;
//         _ = try std.fmt.hexToBytes(&buffer, "4648451b5f87ff8f0f7d622bd40574bb97e25980");
//         try testEncodePacked("4648451b5f87ff8f0f7d622bd40574bb97e25980", .{buffer});
//     }
//     try testEncodePacked("666f6f626172", .{ "foo", "bar" });
//     try testEncodePacked("666f6f626172", .{&.{ "foo", "bar" }});
//     {
//         const foo: []const []const u8 = &.{ "foo", "bar" };
//         try testEncodePacked("666f6f626172", .{foo});
//     }
//     {
//         const foo: []const bool = &.{ false, false };
//         try testEncodePacked("00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000", .{foo});
//     }
//     {
//         const foo: []const u24 = &.{ 69420, 69420 };
//         try testEncodePacked("0000000000000000000000000000000000000000000000000000000000010f2c0000000000000000000000000000000000000000000000000000000000010f2c", .{foo});
//     }
//     {
//         var buffer: [20]u8 = undefined;
//         _ = try std.fmt.hexToBytes(&buffer, "4648451b5f87ff8f0f7d622bd40574bb97e25980");
//         const foo: []const [20]u8 = &.{buffer};
//         try testEncodePacked("0000000000000000000000004648451b5f87ff8f0f7d622bd40574bb97e25980", .{foo});
//     }
//     {
//         const foo: [2]u24 = [2]u24{ 69420, 69420 };
//         try testEncodePacked("0000000000000000000000000000000000000000000000000000000000010f2c0000000000000000000000000000000000000000000000000000000000010f2c", .{foo});
//     }
//     {
//         const foo: struct { u32, u32 } = .{ 69420, 69420 };
//         try testEncodePacked("0000000000000000000000000000000000000000000000000000000000010f2c0000000000000000000000000000000000000000000000000000000000010f2c", .{foo});
//     }
//     {
//         const foo: @Vector(2, u32) = .{ 69420, 69420 };
//         try testEncodePacked("0000000000000000000000000000000000000000000000000000000000010f2c0000000000000000000000000000000000000000000000000000000000010f2c", .{foo});
//     }
//     try testEncodePacked("00010f2c", .{@as(u32, @intCast(69420))});
//     {
//         const foo: struct { foo: u32, bar: bool } = .{ .foo = 69420, .bar = true };
//         try testEncodePacked("00010f2c01", .{foo});
//     }
//     try testEncodePacked("666f6f", .{.foo});
//     {
//         const foo: ?u8 = 69;
//         try testEncodePacked("45", .{foo});
//     }
//     {
//         const foo: enum { foo } = .foo;
//         try testEncodePacked("666f6f", .{foo});
//     }
//     {
//         const foo: error{foo} = error.foo;
//         try testEncodePacked("666f6f", .{foo});
//     }
// }
//
// test "Constructor" {
//     const sig = try human.parseHumanReadable(testing.allocator, "constructor(bool foo)");
//     defer sig.deinit();
//
//     const encoded = try sig.value[0].abiConstructor.encode(testing.allocator, .{true});
//     defer encoded.deinit();
//
//     const hex = try std.fmt.allocPrint(testing.allocator, "{s}", .{std.fmt.fmtSliceHexLower(encoded.data)});
//     defer testing.allocator.free(hex);
//     try testing.expectEqualStrings("0000000000000000000000000000000000000000000000000000000000000001", hex);
// }
//
// test "Constructor multi params" {
//     const sig = try human.parseHumanReadable(testing.allocator, "constructor(bool foo, string bar)");
//     defer sig.deinit();
//
//     const fizz: []const u8 = "fizzbuzz";
//     const encoded = try sig.value[0].abiConstructor.encode(testing.allocator, .{ true, fizz });
//     defer encoded.deinit();
//
//     const hex = try std.fmt.allocPrint(testing.allocator, "{s}", .{std.fmt.fmtSliceHexLower(encoded.data)});
//     defer testing.allocator.free(hex);
//
//     try testing.expectEqualStrings("00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000866697a7a62757a7a000000000000000000000000000000000000000000000000", hex);
// }
//
// test "Error signature" {
//     const sig = try human.parseHumanReadable(testing.allocator, "error Foo(bool foo, string bar)");
//     defer sig.deinit();
//
//     const fizz: []const u8 = "fizzbuzz";
//     const encoded = try sig.value[0].abiError.encode(testing.allocator, .{ true, fizz });
//     defer testing.allocator.free(encoded);
//
//     const hex = try std.fmt.allocPrint(testing.allocator, "{s}", .{std.fmt.fmtSliceHexLower(encoded)});
//     defer testing.allocator.free(hex);
//
//     try testing.expectEqualStrings("65c9c0c100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000866697a7a62757a7a000000000000000000000000000000000000000000000000", hex);
// }
//
// test "Event signature" {
//     const sig = try human.parseHumanReadable(testing.allocator, "event Transfer(address indexed from, address indexed to, uint256 tokenId)");
//     defer sig.deinit();
//
//     const encoded = try sig.value[0].abiEvent.encode(testing.allocator);
//
//     const hex = try std.fmt.allocPrint(testing.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(&encoded)});
//     defer testing.allocator.free(hex);
//
//     try testing.expectEqualStrings("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef", hex);
// }
//
// test "Event signature non indexed" {
//     const sig = try human.parseHumanReadable(testing.allocator, "event Transfer(address from, address to, uint256 tokenId)");
//     defer sig.deinit();
//
//     const encoded = try sig.value[0].abiEvent.encode(testing.allocator);
//
//     const hex = try std.fmt.allocPrint(testing.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(&encoded)});
//     defer testing.allocator.free(hex);
//
//     try testing.expectEqualStrings("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef", hex);
// }
//
// test "Function" {
//     const sig = try human.parseHumanReadable(testing.allocator, "function Foo(bool foo, string bar)");
//     defer sig.deinit();
//
//     const fizz: []const u8 = "fizzbuzz";
//     const encoded = try sig.value[0].abiFunction.encode(testing.allocator, .{ true, fizz });
//     defer testing.allocator.free(encoded);
//
//     const hex = try std.fmt.allocPrint(testing.allocator, "{s}", .{std.fmt.fmtSliceHexLower(encoded)});
//     defer testing.allocator.free(hex);
//
//     try testing.expectEqualStrings("65c9c0c100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000866697a7a62757a7a000000000000000000000000000000000000000000000000", hex);
// }
//
// test "Function outputs" {
//     const sig = try human.parseHumanReadable(testing.allocator, "function Foo(bool foo, string bar) public view returns(int120 baz)");
//     defer sig.deinit();
//
//     const encoded = try sig.value[0].abiFunction.encodeOutputs(testing.allocator, .{1});
//     defer testing.allocator.free(encoded);
//
//     const hex = try std.fmt.allocPrint(testing.allocator, "{s}", .{std.fmt.fmtSliceHexLower(encoded)});
//     defer testing.allocator.free(hex);
//
//     try testing.expectEqualStrings("65c9c0c10000000000000000000000000000000000000000000000000000000000000001", hex);
// }
//
// test "AbiItem" {
//     const sig = try human.parseHumanReadable(testing.allocator, "function Foo(bool foo, string bar)");
//     defer sig.deinit();
//
//     const fizz: []const u8 = "fizzbuzz";
//     const encoded = try sig.value[0].abiFunction.encode(testing.allocator, .{ true, fizz });
//     defer testing.allocator.free(encoded);
//
//     const hex = try std.fmt.allocPrint(testing.allocator, "{s}", .{std.fmt.fmtSliceHexLower(encoded)});
//     defer testing.allocator.free(hex);
//
//     try testing.expectEqualStrings("65c9c0c100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000866697a7a62757a7a000000000000000000000000000000000000000000000000", hex);
// }

fn testEncode(expected: []const u8, comptime params: []const AbiParameter, values: AbiParametersToPrimative(params)) !void {
    const encoded = try encodeAbiParameters(params, testing.allocator, values);
    defer testing.allocator.free(encoded);

    const hex = try std.fmt.allocPrint(testing.allocator, "{s}", .{std.fmt.fmtSliceHexLower(encoded)});
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings(expected, hex);
}

fn testEncodePacked(expected: []const u8, values: anytype) !void {
    const encoded = try encodePacked(testing.allocator, values);
    defer testing.allocator.free(encoded);

    const hex = try std.fmt.allocPrint(testing.allocator, "{s}", .{std.fmt.fmtSliceHexLower(encoded)});
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings(expected, hex);
}
