const std = @import("std");
const SpeedMeasurement = @import("bandwidth.zig").SpeedMeasurement;

/// Generic progress callback interface using comptime for type safety
pub fn ProgressCallback(comptime Context: type) type {
    return struct {
        context: Context,
        updateFn: *const fn (context: Context, measurement: SpeedMeasurement) void,

        const Self = @This();

        pub fn call(self: Self, measurement: SpeedMeasurement) void {
            self.updateFn(self.context, measurement);
        }
    };
}

/// Helper to create a progress callback from context and function
pub fn createCallback(context: anytype, comptime updateFn: anytype) ProgressCallback(@TypeOf(context)) {
    const ContextType = @TypeOf(context);
    const wrapper = struct {
        fn call(ctx: ContextType, measurement: SpeedMeasurement) void {
            updateFn(ctx, measurement);
        }
    };

    return ProgressCallback(ContextType){
        .context = context,
        .updateFn = wrapper.call,
    };
}

/// Check if a value is a valid progress callback at comptime
pub fn isProgressCallback(comptime T: type) bool {
    return @hasDecl(T, "call") and @hasField(T, "context");
}
