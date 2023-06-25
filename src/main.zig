const std = @import("std");

const net = std.net;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// Find a way to create generic job
const Job = struct {
    handler: *const fn (usize, *const net.Stream) anyerror!void,
    stream: *const net.Stream,
};

// We expect slice so we can dealloc
const Jobs = std.atomic.Queue([]Job);
var jobs = Jobs.init();

const Worker = struct {
    thread: std.Thread,

    pub fn init(id: usize) !Worker {
        return .{
            .thread = try std.Thread.spawn(.{}, workerFn, .{id}),
        };
    }

    fn workerFn(id: usize) void {
        _ = allocator;
        while (true) {
            var node = jobs.get();
            if (node != null) {
                var job = node.?.*.data;
                job[0].handler(
                    id,
                    job[0].stream,
                ) catch |err| {
                    std.log.err("Error while handling connection: {}", .{err});
                    // job.*.stream.close();
                };

                allocator.free(job);
            }
        }
    }
};

const Workers = std.ArrayList(Worker);

const JobManager = struct {
    const Self = @This();

    workers: Workers,

    pub fn init(count: usize) !Self {
        var workers = Workers.init(allocator);

        for (0..count) |id| {
            try workers.append(try Worker.init(
                id,
            ));
        }

        return .{
            .workers = workers,
        };
    }

    // Assuming job is allocated on heap
    pub fn execute(job: []Job) !void {
        var nodes = try allocator.alloc(std.TailQueue([]Job).Node, 1);
        nodes[0].data = job;
        jobs.put(&nodes[0]);
    }

    pub fn join(self: *Self) void {
        while (self.workers.popOrNull()) |worker| {
            worker.thread.join();
        }
    }
};

fn handleConnection(thread_id: usize, stream: *const net.Stream) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    var buffer: [512]u8 = undefined;
    _ = try stream.readAtLeast(&buffer, buffer.len);

    var lines = std.mem.split(u8, &buffer, "\r\n");
    var path = lines.next().?;

    const hello_world = "Hello World";
    const respone = try std.fmt.allocPrint(
        arena_allocator,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: {}\r\n" ++
            "\r\n{s}",
        .{ hello_world.len, hello_world },
    );

    _ = stream.write(respone) catch |err| {
        std.log.err("Cannot write on stream {}", .{err});
    };
    stream.close();

    std.log.info("Served {s} on thread {} ", .{ path, thread_id });
}

pub fn main() anyerror!void {
    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("Memory leak occured", .{});
        }
    }

    var manager = try JobManager.init(4);
    defer manager.join();

    const self_addr = try std.net.Address.parseIp("127.0.0.1", 9000);
    var listener = std.net.StreamServer.init(.{});
    try (&listener).listen(self_addr);

    std.log.info("Listening on http://{}; press Ctrl-C to exit...", .{self_addr});

    while ((&listener).accept()) |conn| {
        const job = try allocator.alloc(Job, 1);
        job[0].handler = handleConnection;
        job[0].stream = &conn.stream;

        JobManager.execute(job) catch |err| {
            std.log.err("Failed to serve client: {}", .{err});
        };
    } else |err| {
        return err;
    }
}
