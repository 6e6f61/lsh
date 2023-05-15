pub const Token = union(enum) {
    symbol: []const u8,
    string: []const u8,
    number: f64,

    lbrack: void,
    rbrack: void,
};