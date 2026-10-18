//! libssh2 C API (vendored, see vendor/libssh2-1.11.1).
pub const c = @cImport({
    @cInclude("libssh2.h");
});
