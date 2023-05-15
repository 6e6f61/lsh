const std = @import("std");
const ascii = std.ascii;
const expectEqualDeep = std.testing.expectEqualDeep;

const Token = @import("token.zig").Token;

pub const Lexer = struct {
    input: []const u8,
    nodes: std.ArrayList(Token),
    build: std.ArrayList(u8),

    allocator: std.mem.Allocator,
    idx: usize,

    pub fn init(input: []const u8, allocator: std.mem.Allocator) Lexer {
        return Lexer {
            .input = input,
            .nodes = std.ArrayList(Token).init(allocator),
            .build = std.ArrayList(u8).init(allocator),

            .idx = 0,
            .allocator = allocator,
        };
    }

    pub fn lex(self: *Lexer) ![]Token {
        // Skip shebangs
        if (std.mem.startsWith(u8, self.input, "#!")) {
            self.skipUntil('\n');
        }

        while (self.peekChar()) |char| {
            if (ascii.isWhitespace(char)) { 
                _ = self.takeChar();
                continue;
            }

            // Skip comments
            if (char == ';') {
                self.skipUntil('\n');
            }

            try self.nodes.append(
                switch (char) {
                    '0'...'9'
                         => Token { .number = try self.parseNumber() },
                    '('  => self.presume(Token.lbrack),
                    ')'  => self.presume(Token.rbrack),
                    '"'  => Token { .string = try self.parseString() },
                    else => Token { .symbol = try self.parseSymbol() },
                }
            );
        }

        return self.nodes.items;
    }

    pub fn deinit(self: *Lexer) void {
        for (self.nodes.items) |node| {
            switch (node) {
                .symbol => self.allocator.free(node.symbol),
                .string => self.allocator.free(node.string),
                else => continue,
            }
        }

        self.nodes.deinit();
        self.build.deinit();
    }

    // Consumes the encountered character
    fn skipUntil(self: *Lexer, until: u8) void {
        while (self.peekChar()) |c| {
            if (c == until) {
                break;
            }

            _ = self.takeChar();
        }

        _ = self.takeChar();
    }

    fn peekChar(self: *Lexer) ?u8 {
        if (self.idx == self.input.len) {
            return null;
        }

        return self.input[self.idx];
    }

    fn takeChar(self: *Lexer) ?u8 {
        if (self.idx == self.input.len) {
            return null;
        }
    
        defer self.idx += 1;
        return self.input[self.idx];
    }

    // Increment idx and return the given Token.
    // No validation is performed.
    fn presume(self: *Lexer, c: Token) Token {
        self.idx += 1;
        return c;
    }

    // There may be an opportunity for some kind of algorithm here.
    fn emptyBuild(self: *Lexer) void {
        self.build.clearAndFree();
    }

    // Returns an owned slice.
    // Expects idx to be pointing to the opening quote.
    fn parseString(self: *Lexer) ![]const u8 {
        _ = self.takeChar();

        while (self.peekChar()) |char| {
            if (char != '"') {
                try self.build.append(self.takeChar().?);
            } else {
                _ = self.takeChar();
    
                return self.build.toOwnedSlice();
            }
        }
    
        // TODO: Multiline strings. Broken atm.
        
        return self.build.toOwnedSlice();
        // return LexError.Eof;
    }

    // TODO: Unicode symbol names
    fn parseSymbol(self: *Lexer) ![]const u8 {
        while (self.peekChar()) |char| {
            if (isSymbol(char)) {
                try self.build.append(self.takeChar().?);
            } else { break; }
        }

        return self.build.toOwnedSlice();
    }

    fn parseNumber(self: *Lexer) !f64 {
        while (isFloat(self.peekChar() orelse '!')) {
            try self.build.append(self.takeChar().?);
        }
    
        defer self.emptyBuild();
        return std.fmt.parseFloat(f64, self.build.items);
    }
};

fn isSymbol(c: u8) bool {
    return !ascii.isControl(c) and
           !ascii.isWhitespace(c) and
           c != '(' and c != ')';
}

// Returns whether this character is either a digit or a period.
fn isFloat(c: u8) bool {
    return ascii.isDigit(c) or c == '.';
}

//// Testing

fn quickLex(s: []const u8) ![]Token {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var lexer = Lexer.init(s, allocator);
    return lexer.lex();
}

fn num(x: f64) Token {
    return Token { .number = x };
}

fn sym(x: []const u8) Token { 
    return Token { .symbol = x };
}

fn str(x: []const u8) Token {
    return Token { .string = x };
}

test "lex numbers" {
    try expectEqualDeep(
        quickLex("12345.6789"),
        &[_]Token{ num(12345.6789)
    });
}

test "lex strings" {
    try expectEqualDeep(
        quickLex("\"Hello, world!\""),
        &[_]Token{ str("Hello, world!")
    });
}

test "lex expression" {
    try expectEqualDeep(
    quickLex("(* 8 (+ 1 5 9 1))"),
    &[_]Token{ 
        Token.lbrack,
        sym("*"),
        num(8),
        Token.lbrack,
        sym("+"),
        num(1), num(5), num(9), num(1),
        Token.rbrack, Token.rbrack,
    });
}