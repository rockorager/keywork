//! Frontend-neutral output identity shared by layout policy and adapters.

const slot_map = @import("slot_map.zig");

pub const IdentityTag = enum { output };
const IdentityStore = slot_map.SlotMap(void, IdentityTag);
pub const Id = IdentityStore.Id;
