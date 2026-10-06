const std = @import("std");
const Speed = @import("bandwidth.zig").Speed;

/// Generic progress callback interface using comptime for type safety
pub fn ProgressCallback(comptime Context: type) type {
    return struct {
        context: Context,
        updateFn: *const fn (context: Context, speed: Speed) void,

        const Self = @This();

        pub fn call(self: Self, speed: Speed) void {
            self.updateFn(self.context, speed);
        }
    };
}

/// Helper to create a progress callback from context and function
pub fn createCallback(context: anytype, comptime updateFn: anytype) ProgressCallback(@TypeOf(context)) {
    const ContextType = @TypeOf(context);
    const wrapper = struct {
        fn call(ctx: ContextType, speed: Speed) void {
            updateFn(ctx, speed);
        }
    };

    return ProgressCallback(ContextType){
        .context = context,
        .updateFn = wrapper.call,
    };
}

test "progress callbacks preserve canonical speed" {
    var received: ?Speed = null;
    const Receiver = struct {
        fn update(result: *?Speed, speed: Speed) void {
            result.* = speed;
        }
    };

    const callback = createCallback(&received, Receiver.update);
    callback.call(Speed.fromBitsPerSecond(2_500_000_000));

    try std.testing.expectEqual(@as(f64, 2_500_000_000), received.?.bits_per_second);
}
