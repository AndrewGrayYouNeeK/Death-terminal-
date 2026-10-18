# libssh2 1.11.1 (vendored)

- Source: https://libssh2.org/download/libssh2-1.11.1.tar.gz
- SHA-256 of the tarball: `d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7`
- License: BSD-3-Clause (COPYING)
- Kept: `include/`, the portable sources in `src/` plus the OpenSSL backend
  (`openssl.c`). `agent_win.c` and `blowfish.c` are kept because other files
  #include them; they are not compiled on their own. Dropped: the mbedTLS/libgcrypt/WinCNG/OS400 backends,
  examples, tests, docs and the autotools/CMake build.
- `src/libssh2_config.h` is hand-written for Linux/glibc; `build.zig`
  compiles everything with `-DHAVE_CONFIG_H` and links the system
  `libcrypto` (OpenSSL 1.1.1 or 3.x).
- No local patches. Helpers that need the private headers live in
  `src/ssh/libssh2_extra.c` (keepalive-reply bookkeeping: libssh2 queues
  replies to `keepalive@openssh.com` until a global request takes one, which
  would make the next `tcpip-forward` read a stale FAILURE).
