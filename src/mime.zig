const std = @import("std");
const mem = std.mem;

fn unfoldHeader(raw: []const u8, allocator: mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\r' and i + 2 < raw.len and raw[i + 1] == '\n' and (raw[i + 2] == ' ' or raw[i + 2] == '\t')) {
            try out.append(allocator, ' ');
            i += 3;
        } else if (raw[i] == '\n' and i + 1 < raw.len and (raw[i + 1] == ' ' or raw[i + 1] == '\t')) {
            try out.append(allocator, ' ');
            i += 2;
        } else {
            try out.append(allocator, raw[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn hexVal(c: u8) u8 {
    return std.fmt.charToDigit(c, 16) catch 0;
}

fn decodeQ(encoded: []const u8, allocator: mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < encoded.len) {
        const c = encoded[i];

        if (c == '_') {
            try out.append(allocator, ' ');
            i += 1;
        } else if (c == '=' and i + 2 < encoded.len and std.ascii.isHex(encoded[i + 1]) and std.ascii.isHex(encoded[i + 2])) {
            const hi = try std.fmt.charToDigit(encoded[i + 1], 16);
            const lo = try std.fmt.charToDigit(encoded[i + 2], 16);
            const b: u8 = (hi << 4) | lo;

            try out.append(allocator, b);
            i += 3;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn decodeB(encoded: []const u8, allocator: mem.Allocator) ![]u8 {
    if (encoded.len == 0) {
        return allocator.alloc(u8, 0);
    }

    const decoder = std.base64.standard.Decoder;

    const decoded_len = try decoder.calcSizeForSlice(encoded);

    const buf = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(buf);

    try decoder.decode(buf, encoded);

    return buf;
}

fn decodeWord(
    input: []const u8,
    start: usize,
    allocator: mem.Allocator,
) !?struct { end: usize, data: []u8 } {
    if (start + 2 > input.len) return null;
    if (input[start] != '=' or input[start + 1] != '?') return null;

    const charset_end = mem.indexOfScalarPos(u8, input, start + 2, '?') orelse return null;
    if (charset_end + 2 >= input.len) return null;

    const enc_char = input[charset_end + 1];
    if (input[charset_end + 2] != '?') return null;

    const encoded_end = mem.indexOfScalarPos(u8, input, charset_end + 3, '?') orelse return null;
    if (encoded_end + 1 >= input.len or input[encoded_end + 1] != '=') return null;

    const encoded = input[charset_end + 3 .. encoded_end];
    const encoding = std.ascii.toUpper(enc_char);

    var decoded: []u8 = undefined;
    switch (encoding) {
        'Q' => decoded = decodeQ(encoded, allocator) catch return null,
        'B' => decoded = decodeB(encoded, allocator) catch return null,
        else => return null,
    }

    return .{
        .end = encoded_end + 2,
        .data = decoded,
    };
}

pub fn decodeMimeHeader(raw: []const u8, allocator: mem.Allocator) ![]const u8 {
    var input = raw;
    var unfolded_buf: ?[]u8 = null;
    if (unfoldHeader(raw, allocator)) |buf| {
        input = buf;
        unfolded_buf = buf;
    } else |_| {
        // ignore unfold error, fallback to raw
    }
    defer if (unfolded_buf) |buf| allocator.free(buf);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '=' and input[i + 1] == '?') {
            if (try decodeWord(input, i, allocator)) |ew| {
                defer allocator.free(ew.data);
                try out.appendSlice(allocator, ew.data);
                i = ew.end;
                continue;
            }
        }

        try out.append(allocator, input[i]);
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "unfold header - CRLF with space" {
    const allocator = testing.allocator;
    const input = "Subject: This is a\r\n long header";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Subject: This is a long header", result);
}

test "unfold header - CRLF with tab" {
    const allocator = testing.allocator;
    const input = "Subject: This is a\r\n\tlong header";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Subject: This is a long header", result);
}

test "unfold header - LF with space" {
    const allocator = testing.allocator;
    const input = "Subject: This is a\n long header";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Subject: This is a long header", result);
}

test "Q encoding - ASCII" {
    const allocator = testing.allocator;
    const input = "=?UTF-8?Q?Hello_World?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Hello World", result);
}

test "Q encoding - Chinese (CJK)" {
    const allocator = testing.allocator;
    // "你好世界" encoded in Q-encoding
    const input = "=?UTF-8?Q?=E4=BD=A0=E5=A5=BD=E4=B8=96=E7=95=8C?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("你好世界", result);
}

test "Q encoding - Japanese (CJK)" {
    const allocator = testing.allocator;
    // "こんにちは" encoded in Q-encoding
    const input = "=?UTF-8?Q?=E3=81=93=E3=82=93=E3=81=AB=E3=81=A1=E3=81=AF?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("こんにちは", result);
}

test "Q encoding - Korean (CJK)" {
    const allocator = testing.allocator;
    // "안녕하세요" encoded in Q-encoding
    const input = "=?UTF-8?Q?=EC=95=88=EB=85=95=ED=95=98=EC=84=B8=EC=9A=94?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("안녕하세요", result);
}

test "Q encoding - Cyrillic (Russian)" {
    const allocator = testing.allocator;
    // "Привет мир" encoded in Q-encoding
    const input = "=?UTF-8?Q?=D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82_=D0=BC=D0=B8=D1=80?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Привет мир", result);
}

test "Q encoding - Emoji" {
    const allocator = testing.allocator;
    // "Hello 👋 World 🌍" encoded in Q-encoding
    const input = "=?UTF-8?Q?Hello_=F0=9F=91=8B_World_=F0=9F=8C=8D?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Hello 👋 World 🌍", result);
}

test "Q encoding - Mixed emoji" {
    const allocator = testing.allocator;
    // "😀😃😄😁" encoded in Q-encoding
    const input = "=?UTF-8?Q?=F0=9F=98=80=F0=9F=98=83=F0=9F=98=84=F0=9F=98=81?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("😀😃😄😁", result);
}

test "B encoding - ASCII" {
    const allocator = testing.allocator;
    // "Hello World" in base64
    const input = "=?UTF-8?B?SGVsbG8gV29ybGQ=?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Hello World", result);
}

test "B encoding - Chinese (CJK)" {
    const allocator = testing.allocator;
    // "你好世界" in base64
    const input = "=?UTF-8?B?5L2g5aW95LiW55WM?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("你好世界", result);
}

test "B encoding - Japanese (CJK)" {
    const allocator = testing.allocator;
    // "こんにちは" in base64
    const input = "=?UTF-8?B?44GT44KT44Gr44Gh44Gv?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("こんにちは", result);
}

test "B encoding - Korean (CJK)" {
    const allocator = testing.allocator;
    // "안녕하세요" in base64
    const input = "=?UTF-8?B?7JWI64WV7ZWY7IS47JqU?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("안녕하세요", result);
}

test "B encoding - Cyrillic (Russian)" {
    const allocator = testing.allocator;
    // "Привет мир" in base64
    const input = "=?UTF-8?B?0J/RgNC40LLQtdGCINC80LjRgA==?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Привет мир", result);
}

test "B encoding - Emoji" {
    const allocator = testing.allocator;
    // "Hello 👋 World 🌍" in base64
    const input = "=?UTF-8?B?SGVsbG8g8J+RiyBXb3JsZCDwn4yN?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Hello 👋 World 🌍", result);
}

test "B encoding - Multiple emoji" {
    const allocator = testing.allocator;
    // "🎉🎊🎈🎁" in base64
    const input = "=?UTF-8?B?8J+OifCfjorwn46I8J+OgQ==?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("🎉🎊🎈🎁", result);
}

test "Mixed encoding - Multiple encoded words" {
    const allocator = testing.allocator;
    // Mix of plain text and encoded words
    const input = "Subject: =?UTF-8?Q?=E4=BD=A0=E5=A5=BD?= and =?UTF-8?B?8J+RiQ==?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Subject: 你好 and 👉", result);
}

test "Mixed encoding - Unfolded and encoded" {
    const allocator = testing.allocator;
    const input = "Subject: =?UTF-8?Q?=E4=BD=A0=E5=A5=BD?=\r\n =?UTF-8?Q?=E4=B8=96=E7=95=8C?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Subject: 你好 世界", result);
}

test "Complex - All features combined" {
    const allocator = testing.allocator;
    // Unfolded header with Chinese Q-encoding, Russian B-encoding, and emoji
    const input = "From: =?UTF-8?Q?=E5=BC=A0=E4=B8=89?=\r\n <user@example.com> =?UTF-8?B?0J/RgNC40LLQtdGC?= =?UTF-8?Q?=F0=9F=91=8B?=";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("From: 张三 <user@example.com> Привет 👋", result);
}

test "Edge case - Empty string" {
    const allocator = testing.allocator;
    const input = "";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("", result);
}

test "Edge case - Plain text only" {
    const allocator = testing.allocator;
    const input = "Plain text header";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Plain text header", result);
}

test "Edge case - Invalid encoded word (ignored)" {
    const allocator = testing.allocator;
    const input = "=?UTF-8?X?invalid?= text";
    const result = try decodeMimeHeader(input, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("=?UTF-8?X?invalid?= text", result);
}
