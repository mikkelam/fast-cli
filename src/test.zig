const std = @import("std");

test "all" {
    // Core lib modules with tests
    _ = @import("lib/fast.zig");
    _ = @import("lib/bandwidth.zig");
    _ = @import("lib/http_latency_tester.zig");
    _ = @import("lib/workers/speed_worker.zig");

    // Dedicated test modules
    _ = @import("lib/tests/measurement_strategy_test.zig");
    _ = @import("lib/tests/worker_manager_test.zig");
}
