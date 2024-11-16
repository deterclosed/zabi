//! Runs the tests as a benchmark withou the client tests since those are network bound.
test {
    _ = @import("abi/root.zig");
    _ = @import("ast/tokenizer.test.zig");
    _ = @import("ast/parser.test.zig");
    _ = @import("crypto/root.zig");
    _ = @import("decoding/root.zig");
    _ = @import("encoding/root.zig");
    _ = @import("evm/root.zig");
    _ = @import("human-readable/root.zig");
    _ = @import("meta/root.zig");
    _ = @import("utils/root.zig");
}