const std = @import("std");
const mem = std.mem;

pub fn unfoldHeader(raw: []const u8, allocator: mem.Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\r' and i + 2 < raw.len and raw[i + 1] == '\n' and (raw[i + 2] == ' ' or raw[i + 2] == '\t')) {
            try out.append(' ');
            i += 3;
        } else if (raw[i] == '\n' and i + 1 < raw.len and (raw[i + 1] == ' ' or raw[i + 1] == '\t')) {
            try out.append(' ');
            i += 2;
        } else {
            try out.append(raw[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice();
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f');
}

fn hexVal(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => 0,
    };
}

fn decodeQHeader(encoded: []const u8, allocator: mem.Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < encoded.len) {
        const c = encoded[i];
        if (c == '_') {
            try out.append(' ');
            i += 1;
        } else if (c == '=' and i + 2 < encoded.len and isHex(encoded[i + 1]) and isHex(encoded[i + 2])) {
            const b: u8 = (hexVal(encoded[i + 1]) << 4) | hexVal(encoded[i + 2]);
            try out.append(b);
            i += 3;
        } else {
            try out.append(c);
            i += 1;
        }
    }

    return try out.toOwnedSlice();
}

fn decodeBHeader(encoded: []const u8, allocator: mem.Allocator) ![]u8 {
    if (encoded.len == 0) {
        return allocator.alloc(u8, 0);
    }

    var pad: usize = 0;
    if (encoded[encoded.len - 1] == '=') pad += 1;
    if (encoded.len >= 2 and encoded[encoded.len - 2] == '=') pad += 1;

    const decoded_len = encoded.len * 3 / 4 - pad;
    const buf = try allocator.alloc(u8, decoded_len);

    try std.base64.standard.Decoder.decode(buf, encoded);

    return buf;
}

// RFC 2047
pub fn decodeMimeHeader(raw: []const u8, allocator: mem.Allocator) ![]const u8 {
    const input = unfoldHeader(raw, allocator) catch raw;

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (i + 2 <= input.len and input[i] == '=' and input[i + 1] == '?') {
            const start = i;

            const q1_opt = mem.indexOfScalarPos(u8, input, i + 2, '?');
            if (q1_opt == null) {
                try out.append(input[i]);
                i += 1;
                continue;
            }
            const q1 = q1_opt.?;

            if (q1 + 2 >= input.len) {
                try out.append(input[i]);
                i += 1;
                continue;
            }

            const enc_char = input[q1 + 1];
            if (input[q1 + 2] != '?') {
                try out.append(input[i]);
                i += 1;
                continue;
            }

            const q2_opt = mem.indexOfScalarPos(u8, input, q1 + 3, '?');
            if (q2_opt == null) {
                try out.append(input[i]);
                i += 1;
                continue;
            }
            const q2 = q2_opt.?;

            if (q2 + 1 >= input.len or input[q2 + 1] != '=') {
                try out.append(input[i]);
                i += 1;
                continue;
            }

            const encoding = std.ascii.toUpper(enc_char);
            const encoded_data = input[q1 + 3 .. q2];

            const decoded: []u8 = switch (encoding) {
                'B' => decodeBHeader(encoded_data, allocator),
                'Q' => decodeQHeader(encoded_data, allocator),
                else => {
                    try out.appendSlice(input[start .. q2 + 2]);
                    i = q2 + 2;
                    continue;
                },
            } catch {
                try out.appendSlice(input[start .. q2 + 2]);
                i = q2 + 2;
                continue;
            };

            try out.appendSlice(decoded);
            i = q2 + 2; // skip "?="
        } else {
            try out.append(input[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice();
}
