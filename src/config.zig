const std = @import("std");
const mem = std.mem;
const StringHashMap = std.StringHashMap;

pub const Config = struct {
    auth_token: []const u8 = "",
    bind_addr: []const u8 = ":8000",
    allowed_rcpts: []const u8 = "",
    ntfy_server: []const u8 = "https://ntfy.sh",
    ntfy_topic: []const u8 = "",
    ntfy_token: []const u8 = "",
    ding_webhook: []const u8 = "",
    telegram_bot_token: []const u8 = "",
    telegram_chat_id: []const u8 = "",
    enabled_channels: []const u8 = "",

    pub fn addr(self: *const Config) struct { host: []const u8, port: u16 } {
        if (mem.lastIndexOfScalar(u8, self.bind_addr, ':')) |idx| {
            const host = if (idx == 0) "0.0.0.0" else self.bind_addr[0..idx];
            const port_str = self.bind_addr[idx + 1 ..];
            const port = std.fmt.parseInt(u16, port_str, 10) catch 8000;
            return .{ .host = host, .port = port };
        }
        const port = std.fmt.parseInt(u16, self.bind_addr, 10) catch 8000;
        return .{ .host = "0.0.0.0", .port = port };
    }
};

fn loadDotEnv(allocator: mem.Allocator) !StringHashMap([]const u8) {
    var map = StringHashMap([]const u8).init(allocator);

    const path = ".env";
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return map,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    var buf = try allocator.alloc(u8, stat.size);
    defer allocator.free(buf);

    const n = try file.readAll(buf);
    var it = mem.splitScalar(u8, buf[0..n], '\n');

    while (it.next()) |line_raw| {
        var line = mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const eq_index = mem.indexOfScalar(u8, line, '=') orelse continue;

        const key = mem.trimRight(u8, line[0..eq_index], " \t\r\n");
        var value = mem.trim(u8, line[eq_index + 1 ..], " \t\r\n");

        if (value.len >= 2) {
            const first = value[0];
            const last = value[value.len - 1];
            if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
                value = value[1 .. value.len - 1];
            }
        }

        const key_copy = try allocator.dupe(u8, key);
        const val_copy = try allocator.dupe(u8, value);

        try map.put(key_copy, val_copy);
    }

    return map;
}

fn getConfig(
    allocator: mem.Allocator,
    dot_env: *const StringHashMap([]const u8),
    name: []const u8,
    default: []const u8,
) ![]const u8 {
    const env_val = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_val) |v| return v;

    if (dot_env.get(name)) |v| {
        return v;
    }

    return default;
}

pub fn loadConfig(allocator: mem.Allocator) !Config {
    var cfg = Config{};

    var dot_env = try loadDotEnv(allocator);

    cfg.auth_token = try getConfig(allocator, &dot_env, "AUTH_TOKEN", "");
    cfg.bind_addr = try getConfig(allocator, &dot_env, "BIND_ADDR", ":8000");
    cfg.allowed_rcpts = try getConfig(allocator, &dot_env, "ALLOWED_RCPTS", "");
    cfg.ntfy_server = try getConfig(allocator, &dot_env, "NTFY_SERVER", "https://ntfy.sh");
    cfg.ntfy_topic = try getConfig(allocator, &dot_env, "NTFY_TOPIC", "");
    cfg.ntfy_token = try getConfig(allocator, &dot_env, "NTFY_TOKEN", "");
    cfg.ding_webhook = try getConfig(allocator, &dot_env, "DINGTALK_WEBHOOK", "");
    cfg.telegram_bot_token = try getConfig(allocator, &dot_env, "TELEGRAM_BOT_TOKEN", "");
    cfg.telegram_chat_id = try getConfig(allocator, &dot_env, "TELEGRAM_CHAT_ID", "");
    cfg.enabled_channels = try getConfig(allocator, &dot_env, "ENABLED_CHANNELS", "");

    return cfg;
}
