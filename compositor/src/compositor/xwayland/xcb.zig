//! Shared XCB declarations for Xwayland integration.

pub const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/composite.h");
    @cInclude("xcb/xcb_icccm.h");
    @cInclude("xcb/res.h");
    @cInclude("xcb/xfixes.h");
});
