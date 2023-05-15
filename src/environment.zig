const std = @import("std");

const Expression = @import("parser.zig").Expression;
const Token = @import("token.zig").Token;

const Error = struct {
    val: []const u8,
    fn from(t: []const u8) Error {
        return Error {
            .val = t,
        };
    }

    fn msg(self: Error) []const u8 {
        return self.val;
    }
};
const Return = union(enum) {
    ok: Expression,
    err: Error,

    fn ok(v: Expression) Return {
        return Return { .ok = v, };
    }

    fn newErr(e: []const u8) Return {
        return Return { .err = Error.from(e), };
    }

    fn err(e: Error) Return {
        return Return { .err = e, };
    }

    fn nil() Return {
        return Return { .ok = Expression.nil, };
    }

    fn maybeExists(value: ?Expression) Return {
        if (value) |v| {
            return Return { .ok = v, };
        }

        return Return { .err = Error.from("symbol doesn't exist"), };
    }

    fn handle(self: Return, to: std.fs.File) !?Expression {
        const stderr = to.writer();
    
        if (self == .ok) {
            return self.ok;
        }

        try stderr.print("Failure: {s}\n", .{ self.err.msg() });
        return null;
    }
};
const Func = *const fn (*Environment, Expression) Return;

pub const Environment = struct {
    env: std.StringHashMap(Func),
    vars: std.StringHashMap(Expression),
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,

    pub fn init(stdout: std.fs.File, stderr: std.fs.File, allocator: std.mem.Allocator) Environment {
        return Environment { 
            .env = std.StringHashMap(Func).init(allocator),
            .vars = std.StringHashMap(Expression).init(allocator),
            .allocator = allocator,
            .stdout = stdout,
            .stderr = stderr,
        };
    }

    fn vars(self: *Environment, vars: std.StringHashMap(Expression)) void {
        self.vars = vars;
    }

    pub fn deinit(self: *Environment) void {
        defer self.env.deinit();
        defer self.vars.deinit();
    
        var vars_iter = self.vars.iterator();
        while (vars_iter.next()) |v| {
            self.allocator.free(v.key_ptr.*);
            v.value_ptr.*.free(self.allocator);
        }
    }

    pub fn eval(self: *Environment, expr: Expression) !void {
        _ = try (self.env.get("apply").?)(self, expr).handle(self.stderr) orelse return;
    }

    pub fn evalPrint(self: *Environment, expr: Expression) !void {
        const result = try (self.env.get("apply").?)(self, expr).handle(self.stderr) orelse return;
        _ = try (echo(self, result)).handle(self.stderr);
    }

    pub fn prepareBuiltin(self: *Environment) !void {
        try self.env.put("apply", apply);
        try self.env.put("echo", echo);
        try self.env.put("print", print);
        try self.env.put("define", define);
        try self.env.put("+", plus);
        try self.env.put("internal/dump-env", dumpEnv);
        try self.env.put("internal/dump-vars", dumpVars);
        try self.env.put("internal/how-parsed", howParsed);
    }
};

fn howParsed(env: *Environment, expr: Expression) Return {
    const stderr = env.stderr.writer();
    stderr.print("{?}\n", .{ expr }) catch {};

    return Return.nil();
}

fn dumpEnv(env: *Environment, _: Expression) Return {
    const stderr = env.stderr.writer();
    var env_iter = env.env.iterator();
    stderr.print("{s:<25} {s}\n", .{ "Name", "Body" }) catch {};
    while (env_iter.next()) |entry| {
        stderr.print("{s:<25} {any}\n", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
    }

    return Return.nil();
}

fn dumpVars(env: *Environment, _: Expression) Return {
    const stderr = env.stderr.writer();
    var env_iter = env.vars.iterator();
    stderr.print("{s:<25} {s}\n", .{ "Name", "Value" }) catch {};
    while (env_iter.next()) |entry| {
        stderr.print("{s:<25} {any}\n", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
    }

    return Return.nil();
}

fn define(env: *Environment, expr: Expression) Return {
    switch (expr.list[0]) {
        .atom => return defineVariable(env, expr),
        .list => return defineFunction(env, expr),
        else => return Return.newErr("define name cannot be nil"),
    }
}

fn defineVariable(env: *Environment, expr: Expression) Return {
    const name = env.allocator.dupe(u8, expr.list[0].atom.symbol) catch unreachable;
    const rem = expr.list[1..expr.list.len];
    const value = 
        switch (rem.len) {
            1 => (env.env.get("apply").?)(env, rem[0]),
            else => (env.env.get("apply").?)(
                        env,
                        Expression { .list = expr.list[1..expr.list.len] }
                    ),
        };

    if (value == .err) {
        env.allocator.free(name);
        return value;
    }

    env.vars.put(name, dupeExpr(value.ok, env.allocator)) catch unreachable;
    return value;
}

fn dupeExpr(expr: Expression, allocator: std.mem.Allocator) Expression {
    switch (expr) {
        .nil  => return expr,
        .atom =>
            switch (expr.atom) {
                .string => return Expression { .atom = Token { .string = allocator.dupe(u8, expr.atom.string) catch unreachable } },
                .symbol => return Expression { .atom = Token { .symbol = allocator.dupe(u8, expr.atom.symbol) catch unreachable } },
                .number => return expr,
                else => unreachable,
            },
        .list => {
            var t = std.ArrayList(Expression).init(allocator);
            for (expr.list) |v| {
                t.append(dupeExpr(v, allocator)) catch unreachable;
            }
            
            return Expression { .list = t.toOwnedSlice() catch unreachable };
        },
    }
}

fn defineFunction(env: *Environment, expr: Expression) Return {
    const head = expr.list[0];

    const name = env.allocator.dupe(u8, head.list[0].atom.symbol) catch unreachable;
    const params = head[1..head.len];
    const body = (struct {
        params: Expression,
        body: Expression,
        fn func(env: *Environment, expr: Expression) Return {
            const args = matchParams(env, args, expr) catch Return.newErr("couldn't match params");
            defer args.deinit();

        }
    }){ .params = params, .body = expr.list[1], }.func;
    
    env.env.put(name, body);

    return Return.nil();
}

fn matchParams(env: *Environment, arguments: Expression, values: Expression)
    !std.StringHashMap(Expression)
{
    var ret = std.StringHashMap(Expression).init(env.allocator);

    // TODO: Partial application?
    if (arguments.list.len != arguments.list.len) {
        return Return.newErr("function called with incorrect number of arguments");
    }

    for (arguments.list) |argument, i| {
        const arg = env.allocator.dupe(u8, argument.atom.symbol);
        try ret.push(arg, (env.env.get("apply").?)(env, values.list[i]));
    }

    return ret;
}

fn apply(env: *Environment, expr: Expression) Return {
    if (expr == .list and expr.list.len == 0) {
        return Return.nil();
    }

    // Variable / Literal
    if (expr == .nil or expr == .atom) {
        if (expr == .atom and expr.atom == .symbol) {
            return Return.maybeExists(env.vars.get(expr.atom.symbol));
        }

        return Return.ok(expr);
    }

    // Function
    const func = expr.list[0];
    if (func != .atom or func.atom != .symbol) {
        return Return.newErr("incorrect type for function name");
    }

    if (env.env.get(func.atom.symbol)) |f| {
        return f(env, Expression { .list = expr.list[1..expr.list.len] });
    }

    return Return.newErr("function doesn't exist");
}

// This function ignores possible errors returned from stdout.print.
fn echo(env: *Environment, expr: Expression) Return {
    var stdout = env.stdout.writer();
    const r = print(env, expr);
    if (r == .err) {
        return r;
    }

    stdout.print("\n", .{}) catch unreachable;
    return Return.nil();
}

fn print(env: *Environment, expr: Expression) Return {
    var stdout = env.stdout.writer();

    switch (expr) {
        .nil => stdout.print("nil", .{}) catch unreachable,
        .list => for (expr.list) |v| {
            const r = print(env, v);
            if (r == .err) {
                return Return.err(r.err);
            }
        },
        .atom =>
            switch (expr.atom) {
                .string => stdout.print("{s}", .{ expr.atom.string, }) catch unreachable,
                .number => stdout.print("{d}", .{ expr.atom.number, }) catch unreachable,
                .symbol => {
                    const v = (env.env.get("apply").?)(env, expr);
                    if (v == .err) {
                        return Return.err(v.err);
                    }

                    return print(env, v.ok);
                },
                else => unreachable,
            },
    }

    return Return.nil();
}

fn plus(env: *Environment, expr: Expression) Return {
    var acc: f64 = 0;
    for (expr.list) |v| {
        const next = (env.env.get("apply").?)(env, v);
        if (next == .err) {
            return next;
        }

        acc += next.ok.atom.number;
    }
    return Return.ok(Expression { .atom = Token { .number = acc }});
}