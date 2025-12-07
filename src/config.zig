const std = @import("std");
const mem = std.mem;
const StringHashMap = std.StringHashMap;

pub const Config = struct {
    dry_run: bool = false,
    dry_run_send_log: []const u8 = "",
    dry_run_metadata_log: []const u8 = "",

    auth_token: []const u8 = "",
    bind_addr: []const u8 = "",

    allowed_rcpts: []const []const u8 = &.{},

    ntfy_server: []const u8 = "",
    ntfy_topic: []const u8 = "",
    ntfy_token: []const u8 = "",

    ding_webhook: []const u8 = "",

    telegram_bot_token: []const u8 = "",
    telegram_chat_id: []const u8 = "",

    channels: Channels = .{},

    pub const Channels = struct {
        ntfy: bool = false,
        ding: bool = false,
        tg: bool = false,
    };

    pub fn addr(self: *const Config) struct { host: []const u8, port: u16 } {
        const bind = self.bind_addr;
        if (std.mem.lastIndexOfScalar(u8, bind, ':')) |idx| {
            const host = if (idx == 0) "0.0.0.0" else bind[0..idx];
            const port_str = bind[idx + 1 ..];
            const port = std.fmt.parseInt(u16, port_str, 10) catch 8000;
            return .{ .host = host, .port = port };
        }
        const port = std.fmt.parseInt(u16, bind, 10) catch 8000;
        return .{ .host = "0.0.0.0", .port = port };
    }

    pub fn deinit(self: *Config, allocator: mem.Allocator) void {
        allocator.free(self.auth_token);
        allocator.free(self.bind_addr);
        allocator.free(self.ntfy_server);
        allocator.free(self.ntfy_topic);
        allocator.free(self.ntfy_token);
        allocator.free(self.ding_webhook);
        allocator.free(self.telegram_bot_token);
        allocator.free(self.telegram_chat_id);
        allocator.free(self.dry_run_send_log);
        allocator.free(self.dry_run_metadata_log);

        for (self.allowed_rcpts) |rcpt| allocator.free(rcpt);
        if (self.allowed_rcpts.len > 0) allocator.free(self.allowed_rcpts);
    }
};

fn parseCommaListLowered(
    allocator: mem.Allocator,
    raw: []const u8,
) ![]const []const u8 {
    const trimmed = mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return &.{};

    var count: usize = 0;
    var it_count = mem.splitScalar(u8, trimmed, ',');
    while (it_count.next()) |_| {
        count += 1;
    }

    var list = try allocator.alloc([]const u8, count);
    var actual: usize = 0;

    var it = mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |part| {
        const p = mem.trim(u8, part, " \t\r\n");
        if (p.len == 0) continue;

        var lowered = try allocator.alloc(u8, p.len);
        for (p, 0..) |ch, i| {
            lowered[i] = std.ascii.toLower(ch);
        }

        list[actual] = lowered;
        actual += 1;
    }

    return list[0..actual];
}

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

    if (dot_env.get(name)) |v| return try allocator.dupe(u8, v);

    return try allocator.dupe(u8, default);
}

pub fn loadConfig(allocator: mem.Allocator) !Config {
    var cfg = Config{};

    var dot_env = try loadDotEnv(allocator);
    defer {
        var it = dot_env.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        dot_env.deinit();
    }

    cfg.auth_token = try getConfig(allocator, &dot_env, "AUTH_TOKEN", "");
    cfg.bind_addr = try getConfig(allocator, &dot_env, "BIND_ADDR", ":8000");

    cfg.ntfy_server = try getConfig(allocator, &dot_env, "NTFY_SERVER", "https://ntfy.sh");
    cfg.ntfy_topic = try getConfig(allocator, &dot_env, "NTFY_TOPIC", "");
    cfg.ntfy_token = try getConfig(allocator, &dot_env, "NTFY_TOKEN", "");

    cfg.ding_webhook = try getConfig(allocator, &dot_env, "DINGTALK_WEBHOOK", "");
    cfg.telegram_bot_token = try getConfig(allocator, &dot_env, "TELEGRAM_BOT_TOKEN", "");
    cfg.telegram_chat_id = try getConfig(allocator, &dot_env, "TELEGRAM_CHAT_ID", "");

    const dry_run_str = try getConfig(allocator, &dot_env, "DRY_RUN", "");
    defer allocator.free(dry_run_str);
    cfg.dry_run = std.mem.eql(u8, dry_run_str, "1") or
        std.mem.eql(u8, dry_run_str, "true");

    cfg.dry_run_send_log =
        try getConfig(allocator, &dot_env, "DRY_RUN_SEND_LOG", "dry-run-send.log");
    cfg.dry_run_metadata_log =
        try getConfig(allocator, &dot_env, "DRY_RUN_META_LOG", "dry-run-metadata.log");

    const allowed_str = try getConfig(allocator, &dot_env, "ALLOWED_RCPTS", "");
    defer allocator.free(allowed_str);
    cfg.allowed_rcpts = try parseCommaListLowered(allocator, allowed_str);

    const enabled_str = try getConfig(allocator, &dot_env, "ENABLED_CHANNELS", "");
    defer allocator.free(enabled_str);

    const ch_list = try parseCommaListLowered(allocator, enabled_str);
    defer {
        for (ch_list) |c| allocator.free(c);
        if (ch_list.len > 0) allocator.free(ch_list);
    }

    for (ch_list) |c| {
        if (std.mem.eql(u8, c, "ntfy")) cfg.channels.ntfy = true;
        if (std.mem.eql(u8, c, "ding")) cfg.channels.ding = true;
        if (std.mem.eql(u8, c, "tg")) cfg.channels.tg = true;
    }

    return cfg;
}
