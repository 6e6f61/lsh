const std = @import("std");

const yazap = @import("yazap");
const Linenoize = @import("linenoize").Linenoise;

const Lexer = @import("lexer.zig").Lexer;
const Environment = @import("environment.zig").Environment;
const parser = @import("parser.zig");
const Parser = parser.Parser;
const Expression = parser.Expression;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    // const allocator = std.heap.c_allocator;
    const stdout = std.io.getStdOut();
    const stderr = std.io.getStdErr();

    var app = yazap.App.init(allocator, "lsh", "UNIX Lisp Shell");
    defer app.deinit();
    try app.rootCommand().takesSingleValue("SCRIPT-FILE");
    try app.rootCommand().addArg(yazap.flag.boolean("dump", 'd', "Dump the parsed AST and execute nothing"));

    var environment = Environment.init(stdout, stderr, allocator);
    defer environment.deinit();
    try environment.prepareBuiltin();

    const args = try app.parseProcess();
    if (args.valueOf("SCRIPT-FILE")) |script| {
        const file = try std.fs.cwd().openFile(script, .{ .mode = .read_only });
        const file_content = try file.readToEndAlloc(allocator, 1_000_000);
        defer allocator.free(file_content);
    
        var parsed = try getAst(file_content, allocator) orelse return;
        defer parsed.free(allocator);

        try environment.eval(parsed);
        if (args.isPresent("dump")) { std.debug.print("{?}", .{ parsed }); }

        return;
    }
    
    try repl(&environment, allocator);
}

fn repl(environment: *Environment, allocator: std.mem.Allocator) !void {
    var linenoize = Linenoize.init(allocator);
    defer linenoize.deinit();
    linenoize.multiline_mode = true;

    while (try linenoize.linenoise("λ ")) |line| {    
        defer allocator.free(line);

        var parsed = try getAst(line, allocator) orelse return;
        defer parsed.free(allocator);

        try environment.evalPrint(parsed);

        // TODO: Don't dupe history
        try linenoize.history.add(line);
    }
}

fn getAst(of: []const u8, allocator: std.mem.Allocator) !?Expression {
    const stdout = std.io.getStdOut().writer();

    var lexer = Lexer.init(of, allocator);
    const lexed = lexer.lex() catch |err| {
        try stdout.print("Couldn't lex input: {any}\n", .{ err });
        return null;
    };
    defer lexer.deinit();

    var p = Parser.init(lexed, allocator);

    return p.parse() catch |err| {
        try stdout.print("Couldn't parse input: {any}\n", .{ err });
        return null;
    };
}

test {
    std.testing.refAllDecls(Parser);
}