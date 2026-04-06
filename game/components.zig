// components.zig — Game-specific components (extends engine core).
// Add your custom components here and include them in the `all` tuple.

const core = @import("core_components");

pub const all = core.withExtra(.{});
