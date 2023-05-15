const std = @import("std");

const Token = @import("token.zig").Token;

pub const Expression = union(enum) {
    atom: Token,
    list: []Expression,
    nil: void,

    // Free memory of the expression - for lists, recursively.
    pub fn free(self: *Expression, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .nil => return,
            .atom =>
                switch (self.atom) {
                    .string => allocator.free(self.atom.string),
                    .symbol => allocator.free(self.atom.symbol),
                    .number,
                    .lbrack,
                    .rbrack => return,
                },
            .list => {
                for (self.list) |*v| {
                    v.free(allocator);
                }
                allocator.free(self.list);
            },
        }
    }
};

const ParserError = error {
    ExpectedToken,
    HangingBracket,
    UnmatchedRightBracket,
    EOF,
};

pub const Parser = struct {
    input: []const Token,
    allocator: std.mem.Allocator,
    head: usize,

    pub fn init(input: []const Token, allocator: std.mem.Allocator) Parser {
        return Parser {
            .input = input,
            .allocator = allocator,
            .head = 0,
        };
    }

    pub fn parse(self: *Parser) !Expression {
        var top_level = std.ArrayList(Expression).init(self.allocator);
        while (self.peekToken()) |_| {
            try top_level.append(try self.parseExpr());
        }
        
        if (top_level.items.len == 1) {
            defer top_level.deinit();
            return top_level.items[0];
        } else {
            return Expression { .list = try top_level.toOwnedSlice(), };
        }
    }

    pub fn parseExpr(self: *Parser) !Expression {
        while (self.nextToken()) |token| {
            switch (token) {
                .symbol => return Expression { .atom = Token { .symbol = try self.allocator.dupe(u8, token.symbol) } },
                .string => return Expression { .atom = Token { .string = try self.allocator.dupe(u8, token.string) } },
                .number => return Expression { .atom = Token { .number = token.number } },

                .rbrack => return ParserError.UnmatchedRightBracket,
                .lbrack => {
                    var list = std.ArrayList(Expression).init(self.allocator);
                    while (self.peekToken()) |list_token| {
                        if (list_token == .rbrack) {
                            _ = self.nextToken();
                            return Expression { .list = try list.toOwnedSlice(), };
                        }
                        
                        try list.append(try self.parseExpr());
                    }
                },
            }
        }

        return ParserError.HangingBracket;
    }

    fn nextToken(self: *Parser) ?Token {
        if (self.head == self.input.len) {
            return null;
        }
        
        defer self.head += 1;
        return self.input[self.head];
    }

    fn peekToken(self: *Parser) ?Token {
        if (self.head == self.input.len) {
            return null;
        }
        
        return self.input[self.head];
    }

};
