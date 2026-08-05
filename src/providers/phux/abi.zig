//! Single source of C declarations for the stable Phux client ABI.

pub const c = @cImport({
    @cInclude("phux/client.h");
});
