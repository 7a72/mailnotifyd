const std = @import("std");

pub const Queue = struct {
    id: []const u8,
};

pub const Context = struct {
    stage: []const u8,
    queue: ?Queue = null,
};

pub const EnvelopeAddr = struct {
    address: []const u8,
};

pub const Envelope = struct {
    from: EnvelopeAddr,
    to: []const EnvelopeAddr,
};

// headers: [["From","..."],["To","..."],...]
pub const Header = [2][]const u8;

pub const Message = struct {
    headers: []const Header,
    contents: []const u8,
};

pub const MTARequest = struct {
    context: Context,
    envelope: Envelope,
    message: Message,
};

pub const Metadata = struct {
    from: []const u8,
    to: []const u8,
    subject: []const u8,
};
