const std = @import("std");
const Thread = std.Thread;

/// Blocking Value Store
pub fn BlockingStore(comptime T: type) type {
    return struct {
        val: ?T = null,
        m: Thread.Mutex = Thread.Mutex{},
        notConsumed: Thread.Condition = Thread.Condition{},
        const Self = @This();
        /// Put a value, block till the receiver consumes the value
        pub fn put(self: *Self, new: T) void {
            self.m.lock();
            defer self.m.unlock();

            while (self.val != null) {
                self.notConsumed.wait(&self.m);
            }
            self.val = new;
        }
        /// Consume the currently pushed value
        /// returns null if no value has been pushed
        pub fn consumeOrNull(self: *Self) ?T {
            self.m.lock();
            defer self.m.unlock();
            const val = if (self.val) |v| v else return null;
            self.val = null;
            self.notConsumed.broadcast();
            return val;
        }
    };
}
