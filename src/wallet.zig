const eip712 = @import("abi/eip712.zig");
const serialize = @import("encoding/serialize.zig");
const std = @import("std");
const testing = std.testing;
const transaction = @import("meta/transaction.zig");
const types = @import("meta/ethereum.zig");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;
const Anvil = @import("tests/Anvil.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Chains = types.PublicChains;
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const PubClient = @import("Client.zig");
const secp256k1 = @import("secp256k1");
const Signer = secp256k1.Signer;
const Signature = secp256k1.Signature;
const WebSocketClient = @import("WebSocket.zig");
const Handler = WebSocketClient.Handler;

pub const WalletClients = enum { http, websocket };

pub fn Wallet(comptime client_type: WalletClients) type {
    return struct {
        /// Allocator used by the wallet implementation
        alloc: Allocator,
        /// Arena used to manage allocated memory
        arena: *ArenaAllocator,
        /// Http client used to make request. Supports almost all rpc methods.
        pub_client: if (client_type == .http) *PubClient else *WebSocketClient,
        /// Signer that will sign transactions or ethereum messages.
        signer: Signer,

        /// Init wallet instance. Must call `deinit` to clean up.
        pub fn init(alloc: Allocator, private_key: []const u8, url: []const u8, chain_id: ?Chains) !*Wallet(client_type) {
            var wallet = try alloc.create(Wallet(client_type));
            errdefer alloc.destroy(wallet);

            wallet.arena = try alloc.create(ArenaAllocator);
            errdefer alloc.destroy(wallet.arena);

            wallet.arena.* = ArenaAllocator.init(alloc);

            const client = client: {
                switch (client_type) {
                    .http => break :client try PubClient.init(alloc, url, chain_id),
                    .websocket => {
                        const ws_client = try alloc.create(WebSocketClient);
                        errdefer alloc.destroy(ws_client);

                        const uri = try std.Uri.parse(url);

                        try ws_client.init(.{
                            .allocator = alloc,
                            .uri = uri,
                        });

                        break :client ws_client;
                    },
                }
            };
            const signer = try Signer.init(private_key);

            wallet.pub_client = client;
            wallet.alloc = wallet.arena.allocator();
            wallet.signer = signer;

            return wallet;
        }

        /// Inits wallet from a random generated priv key. Must call `deinit` after.
        pub fn initFromRandomKey(alloc: Allocator, url: []const u8, chain_id: ?Chains) !*Wallet(client_type) {
            var wallet = try alloc.create(Wallet(client_type));
            errdefer alloc.destroy(wallet);

            wallet.arena = try alloc.create(ArenaAllocator);
            errdefer alloc.destroy(wallet.arena);

            wallet.arena.* = ArenaAllocator.init(alloc);

            const client = client: {
                switch (client_type) {
                    .http => break :client try PubClient.init(alloc, url, chain_id),
                    .websocket => {
                        const ws_client = try alloc.create(WebSocketClient);
                        errdefer alloc.destroy(ws_client);

                        try ws_client.init(.{ .alloc = alloc, .host = url });

                        break :client ws_client;
                    },
                }
            };
            const signer = try Signer.generateRandomSigner();

            wallet.pub_client = client;
            wallet.alloc = wallet.arena.allocator();
            wallet.signer = signer;

            return wallet;
        }

        pub fn deinit(self: *Wallet(client_type)) void {
            self.pub_client.deinit();

            const allocator = self.arena.child_allocator;
            self.signer.deinit();
            self.arena.deinit();
            allocator.destroy(self.arena);
            if (client_type == .websocket) allocator.destroy(self.pub_client);
            allocator.destroy(self);
        }

        /// Signs a ethereum message with the specified prefix.
        pub fn signEthereumMessage(self: *Wallet(client_type), message: []const u8) !Signature {
            return try self.signer.signMessage(self.alloc, message);
        }

        /// Signs a EIP712 message according to the expecification
        /// https://eips.ethereum.org/EIPS/eip-712
        ///
        /// `types` parameter is expected to be a struct where the struct
        /// keys are used to grab the solidity type information so that the
        /// encoding and hashing can happen based on it. See the specification
        /// for more details.
        ///
        /// `primary_type` is the expected main type that you want to hash this message.
        /// Compilation will fail if the provided string doesn't exist on the `types` parameter
        ///
        /// `domain` is the values of the defined EIP712Domain. Currently it doesnt not support custom
        /// domain types.
        ///
        /// `message` is expected to be a struct where the solidity types are transalated to the native
        /// zig types. I.E string -> []const u8 or int256 -> i256 and so on.
        /// In the future work will be done where the compiler will offer more clearer types
        /// base on a meta programming type function.
        ///
        /// Returns the libsecp256k1 signature type.
        pub fn signTypedData(self: *Wallet(client_type), comptime eip_types: anytype, comptime primary_type: []const u8, domain: ?eip712.TypedDataDomain, message: anytype) !Signature {
            return try self.signer.sign(try eip712.hashTypedData(self.alloc, eip_types, primary_type, domain, message));
        }

        /// Get the wallet address.
        /// By calling `deinit` memory will be cleaned.
        pub fn getWalletAddress(self: *Wallet(client_type)) ![]u8 {
            const address = try self.signer.getAddressFromPublicKey();

            const hex_address_lower = std.fmt.bytesToHex(address, .lower);

            var hashed: [Keccak256.digest_length]u8 = undefined;
            Keccak256.hash(hex_address_lower[0..], &hashed, .{});
            const hex = std.fmt.bytesToHex(hashed, .lower);

            const checksum = try self.alloc.alloc(u8, 42);
            for (checksum[2..], 0..) |*c, i| {
                const char = hex_address_lower[i];

                if (try std.fmt.charToDigit(hex[i], 16) > 7) {
                    c.* = std.ascii.toUpper(char);
                } else {
                    c.* = char;
                }
            }

            @memcpy(checksum[0..2], "0x");

            return checksum;
        }

        /// Verifies if a given signature was signed by the current wallet.
        pub fn verifyMessage(self: *Wallet(client_type), sig: Signature, message: []const u8) !bool {
            var hash_buffer: [Keccak256.digest_length]u8 = undefined;
            Keccak256.hash(message, &hash_buffer, .{});
            return try self.signer.verifyMessage(sig, hash_buffer);
        }

        /// Verifies a EIP712 message according to the expecification
        /// https://eips.ethereum.org/EIPS/eip-712
        ///
        /// `types` parameter is expected to be a struct where the struct
        /// keys are used to grab the solidity type information so that the
        /// encoding and hashing can happen based on it. See the specification
        /// for more details.
        ///
        /// `primary_type` is the expected main type that you want to hash this message.
        /// Compilation will fail if the provided string doesn't exist on the `types` parameter
        ///
        /// `domain` is the values of the defined EIP712Domain. Currently it doesnt not support custom
        /// domain types.
        ///
        /// `message` is expected to be a struct where the solidity types are transalated to the native
        /// zig types. I.E string -> []const u8 or int256 -> i256 and so on.
        /// In the future work will be done where the compiler will offer more clearer types
        /// base on a meta programming type function.
        ///
        /// Returns the libsecp256k1 signature type.
        pub fn verifyTypedData(self: *Wallet(client_type), sig: Signature, comptime eip712_types: anytype, comptime primary_type: []const u8, domain: ?eip712.TypedDataDomain, message: anytype) !bool {
            const hash = try eip712.hashTypedData(self.alloc, eip712_types, primary_type, domain, message);

            const address = try secp256k1.recoverEthereumAddress(hash, sig);
            const wallet_address = (try self.getWalletAddress())[2..];

            return std.mem.eql(u8, wallet_address, &address);
        }

        /// Prepares a transaction so that it can be sent through the network.
        pub fn prepareTransaction(self: *Wallet(client_type), unprepared_envelope: transaction.PrepareEnvelope) !transaction.TransactionEnvelope {
            const address = try self.getWalletAddress();

            switch (unprepared_envelope) {
                .eip1559 => |tx| {
                    if (tx.type != 2)
                        return error.InvalidTransactionType;

                    var request: transaction.EthCallEip1559 = .{ .from = address, .to = tx.to, .gas = tx.gas, .maxFeePerGas = tx.maxFeePerGas, .maxPriorityFeePerGas = tx.maxPriorityFeePerGas, .data = tx.data, .value = tx.value orelse 0 };

                    const curr_block = try self.pub_client.getBlockByNumber(.{});
                    const chain_id = tx.chainId orelse self.pub_client.chain_id;
                    const accessList: []const transaction.AccessList = tx.accessList orelse &.{};

                    const nonce: u64 = tx.nonce orelse try self.pub_client.getAddressTransactionCount(.{ .address = address });

                    if (tx.maxFeePerGas == null or tx.maxPriorityFeePerGas == null) {
                        const fees = try self.pub_client.estimateFeesPerGas(.{ .eip1559 = request }, curr_block);
                        request.maxPriorityFeePerGas = tx.maxPriorityFeePerGas orelse fees.eip1559.max_priority_fee;
                        request.maxFeePerGas = tx.maxFeePerGas orelse fees.eip1559.max_fee_gas;

                        if (tx.maxFeePerGas) |fee| {
                            if (fee < fees.eip1559.max_priority_fee) return error.MaxFeePerGasUnderflow;
                        }
                    }

                    if (tx.gas == null) {
                        request.gas = try self.pub_client.estimateGas(.{ .eip1559 = request }, .{});
                    }

                    return .{ .eip1559 = .{ .chainId = chain_id, .nonce = nonce, .gas = request.gas.?, .maxFeePerGas = request.maxFeePerGas.?, .maxPriorityFeePerGas = request.maxPriorityFeePerGas.?, .data = request.data, .to = request.to, .value = request.value.?, .accessList = accessList } };
                },
                .eip2930 => |tx| {
                    if (tx.type != 1)
                        return error.InvalidTransactionType;

                    var request: transaction.EthCallLegacy = .{ .from = address, .to = tx.to, .gas = tx.gas, .gasPrice = tx.gasPrice, .data = tx.data, .value = tx.value orelse 0 };

                    const curr_block = try self.pub_client.getBlockByNumber(.{});
                    const chain_id = tx.chainId orelse self.pub_client.chain_id;
                    const accessList: []const transaction.AccessList = tx.accessList orelse &.{};

                    const nonce: u64 = tx.nonce orelse try self.pub_client.getAddressTransactionCount(.{ .address = address });

                    if (tx.gasPrice == null) {
                        const fees = try self.pub_client.estimateFeesPerGas(.{ .legacy = request }, curr_block);
                        request.gasPrice = fees.legacy.gas_price;
                    }

                    if (tx.gas == null) {
                        request.gas = try self.pub_client.estimateGas(.{ .legacy = request }, .{});
                    }

                    return .{ .eip2930 = .{ .chainId = chain_id, .nonce = nonce, .gas = request.gas.?, .gasPrice = request.gasPrice.?, .data = request.data, .to = request.to, .value = request.value.?, .accessList = accessList } };
                },
                .legacy => |tx| {
                    var request: transaction.EthCallLegacy = .{ .from = address, .to = tx.to, .gas = tx.gas, .gasPrice = tx.gasPrice, .data = tx.data, .value = tx.value orelse 0 };

                    const curr_block = try self.pub_client.getBlockByNumber(.{});
                    const chain_id = tx.chainId orelse self.pub_client.chain_id;

                    const nonce: u64 = tx.nonce orelse try self.pub_client.getAddressTransactionCount(.{ .address = address });

                    if (tx.gasPrice == null) {
                        const fees = try self.pub_client.estimateFeesPerGas(.{ .legacy = request }, curr_block);
                        request.gasPrice = fees.legacy.gas_price;
                    }

                    if (tx.gas == null) {
                        request.gas = try self.pub_client.estimateGas(.{ .legacy = request }, .{});
                    }

                    return .{ .legacy = .{ .chainId = chain_id, .nonce = nonce, .gas = request.gas.?, .gasPrice = request.gasPrice.?, .data = request.data, .to = request.to, .value = request.value.? } };
                },
            }
        }

        /// Asserts that the transactions is ready to be sent.
        pub fn assertTransaction(self: *Wallet(client_type), tx: transaction.TransactionEnvelope) !void {
            switch (tx) {
                .eip1559 => |tx_eip1559| {
                    if (tx_eip1559.chainId != self.pub_client.chain_id) return error.InvalidChainId;
                    if (tx_eip1559.maxPriorityFeePerGas > tx_eip1559.maxFeePerGas) return error.TransactionTipToHigh;
                    if (tx_eip1559.to) |addr| if (!try utils.isAddress(self.alloc, addr)) return error.InvalidAddress;
                },
                .eip2930 => |tx_eip2930| {
                    if (tx_eip2930.chainId != self.pub_client.chain_id) return error.InvalidChainId;
                    if (tx_eip2930.to) |addr| if (!try utils.isAddress(self.alloc, addr)) return error.InvalidAddress;
                },
                .legacy => |tx_legacy| {
                    if (tx_legacy.chainId != 0 and tx_legacy.chainId != self.pub_client.chain_id) return error.InvalidChainId;
                    if (tx_legacy.to) |addr| if (!try utils.isAddress(self.alloc, addr)) return error.InvalidAddress;
                },
            }
        }

        /// Signs, serializes and send the transaction via `eth_sendRawTransaction`.
        pub fn sendSignedTransaction(self: *Wallet(client_type), tx: transaction.TransactionEnvelope) !types.Hex {
            const serialized = try serialize.serializeTransaction(self.alloc, tx, null);

            var hash_buffer: [Keccak256.digest_length]u8 = undefined;
            Keccak256.hash(serialized, &hash_buffer, .{});

            const signed = try self.signer.sign(hash_buffer);
            const serialized_signed = try serialize.serializeTransaction(self.alloc, tx, signed);

            const hex = try std.fmt.allocPrint(self.alloc, "{s}", .{std.fmt.fmtSliceHexLower(serialized_signed)});

            return self.pub_client.sendRawTransaction(hex);
        }

        /// Prepares, asserts, signs and send the transaction via `eth_sendRawTransaction`.
        pub fn sendTransaction(self: *Wallet(client_type), unprepared_envelope: transaction.PrepareEnvelope) !types.Hex {
            const prepared = try self.prepareTransaction(unprepared_envelope);

            try self.assertTransaction(prepared);

            return try self.sendSignedTransaction(prepared);
        }
    };
}

test "Address match" {
    var wallet = try Wallet(.http).init(testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .anvil);
    defer wallet.deinit();

    try testing.expectEqualStrings(try wallet.getWalletAddress(), "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
}

test "verifyMessage" {
    var wallet = try Wallet(.http).init(testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .anvil);
    defer wallet.deinit();

    var hash_buffer: [Keccak256.digest_length]u8 = undefined;
    Keccak256.hash("02f1827a6980847735940084773594008252099470997970c51812dc3a010c7d01b50e0d17dc79c8880de0b6b3a764000080c0", &hash_buffer, .{});
    const sign = try wallet.signer.sign(hash_buffer);

    try testing.expect(wallet.signer.verifyMessage(sign, hash_buffer));
}

test "signMessage" {
    var wallet = try Wallet(.http).init(testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .anvil);
    defer wallet.deinit();

    const sig = try wallet.signEthereumMessage("hello world");
    const hex = try sig.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings("a461f509887bd19e312c0c58467ce8ff8e300d3c1a90b608a760c5b80318eaf15fe57c96f9175d6cd4daad4663763baa7e78836e067d0163e9a2ccf2ff753f5b00", hex);
}

test "signTypedData" {
    var wallet = try Wallet(.http).init(testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .anvil);
    defer wallet.deinit();

    const sig = try wallet.signTypedData(.{ .EIP712Domain = &.{} }, "EIP712Domain", .{}, .{});
    const hex = try sig.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings("da87197eb020923476a6d0149ca90bc1c894251cc30b38e0dd2cdd48567e12386d3ed40a509397410a4fd2d66e1300a39ac42f828f8a5a2cb948b35c22cf29e801", hex);
}

test "verifyTypedData" {
    var wallet = try Wallet(.http).init(testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .anvil);
    defer wallet.deinit();

    const domain: eip712.TypedDataDomain = .{ .name = "Ether Mail", .version = "1", .chainId = 1, .verifyingContract = "0x0000000000000000000000000000000000000000" };
    const e_types = .{ .EIP712Domain = &.{ .{ .type = "string", .name = "name" }, .{ .name = "version", .type = "string" }, .{ .name = "chainId", .type = "uint256" }, .{ .name = "verifyingContract", .type = "address" } }, .Person = &.{ .{ .name = "name", .type = "string" }, .{ .name = "wallet", .type = "address" } }, .Mail = &.{ .{ .name = "from", .type = "Person" }, .{ .name = "to", .type = "Person" }, .{ .name = "contents", .type = "string" } } };

    const sig = try Signature.fromHex("0x32f3d5975ba38d6c2fba9b95d5cbed1febaa68003d3d588d51f2de522ad54117760cfc249470a75232552e43991f53953a3d74edf6944553c6bef2469bb9e5921b");
    const validate = try wallet.verifyTypedData(sig, e_types, "Mail", domain, .{ .from = .{ .name = "Cow", .wallet = "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826" }, .to = .{ .name = "Bob", .wallet = "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB" }, .contents = "Hello, Bob!" });

    try testing.expect(validate);
}

test "sendTransaction" {
    // CI coverage runner dislikes this tests so for now we skip it.
    if (true) return error.SkipZigTest;
    var wallet = try Wallet(.websocket).init(testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545/", .ethereum);
    defer wallet.deinit();

    var tx: transaction.PrepareEnvelope = .{ .eip1559 = undefined };
    tx.eip1559.type = 2;
    tx.eip1559.value = try utils.parseEth(1);
    tx.eip1559.to = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

    const tx_hash = try wallet.sendTransaction(tx);

    try testing.expect(tx_hash.len != 0);
}

test "assertTransaction" {
    var tx: transaction.TransactionEnvelope = undefined;

    var wallet = try Wallet(.http).init(testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .ethereum);
    defer wallet.deinit();

    tx = .{ .eip1559 = .{
        .nonce = 0,
        .gas = 21001,
        .maxPriorityFeePerGas = 2,
        .maxFeePerGas = 2,
        .chainId = 1,
        .accessList = &.{},
        .value = 0,
        .to = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        .data = null,
    } };
    try wallet.assertTransaction(tx);

    tx.eip1559.chainId = 2;
    try testing.expectError(error.InvalidChainId, wallet.assertTransaction(tx));

    tx.eip1559.chainId = 1;
    tx.eip1559.to = "";
    try testing.expectError(error.InvalidAddress, wallet.assertTransaction(tx));

    tx.eip1559.maxPriorityFeePerGas = 69;
    tx.eip1559.to = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
    try testing.expectError(error.TransactionTipToHigh, wallet.assertTransaction(tx));
}

test "assertTransactionLegacy" {
    var tx: transaction.TransactionEnvelope = undefined;

    var wallet = try Wallet(.http).init(testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .ethereum);
    defer wallet.deinit();

    tx = .{ .eip2930 = .{
        .nonce = 0,
        .gas = 21001,
        .gasPrice = 2,
        .chainId = 1,
        .accessList = &.{},
        .value = 0,
        .to = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        .data = null,
    } };
    try wallet.assertTransaction(tx);

    tx.eip2930.chainId = 2;
    try testing.expectError(error.InvalidChainId, wallet.assertTransaction(tx));

    tx.eip2930.chainId = 1;
    tx.eip2930.to = "";
    try testing.expectError(error.InvalidAddress, wallet.assertTransaction(tx));

    tx = .{ .legacy = .{
        .nonce = 0,
        .gas = 21001,
        .gasPrice = 2,
        .chainId = 1,
        .value = 0,
        .to = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        .data = null,
    } };
    try wallet.assertTransaction(tx);

    tx.legacy.chainId = 2;
    try testing.expectError(error.InvalidChainId, wallet.assertTransaction(tx));

    tx.legacy.chainId = 1;
    tx.legacy.to = "";
    try testing.expectError(error.InvalidAddress, wallet.assertTransaction(tx));
}