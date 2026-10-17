# Workflow files to drop in

These are GitHub Actions workflows for `.github/workflows/`. They live here
because this PR was not allowed to edit `.github/workflows` directly.

| File | Copy to | What it does |
|------|---------|--------------|
| `ci.yml` | `.github/workflows/ci.yml` (replaces the current one) | Linux build + tests with the full dependency list, plus compile-only checks for Windows and macOS |
| `release.yml` | `.github/workflows/release.yml` (new) | On a `v*` tag: Linux tarball, AppImage, .deb and .rpm; Windows zip; macOS tarballs and `.app` zips; SHA256SUMS; a draft GitHub release |

```sh
cp packaging/ci/ci.yml packaging/ci/release.yml .github/workflows/
```

## CI dependency changes (compared with the current ci.yml)

- `libfreetype-dev libharfbuzz-dev libfontconfig-dev`: needed since the font
  work in #26. The current ci.yml doesn't install them, so `zig build` there
  can't find `freetype2` / `harfbuzz` / `fontconfig`.
- `libssl-dev`: libcrypto for the vendored libssh2 (built-in SSH).
- `pkg-config`: used by `linkSystemLibrary` to find the libraries above.
- `fonts-dejavu-core`, `vttest`: optional. Font fallback tests and VT checks
  use them when present.
- Vulkan headers are now vendored (`vendor/vulkan-headers`), so
  `libvulkan-dev` is only needed for the loader at run time.
- Windows/macOS cross builds download FreeType 2.13.3 and HarfBuzz 10.1.0 as
  lazy `build.zig.zon` dependencies (network access at build time; Linux
  builds never fetch them).
- The release job downloads `nfpm` and `appimagetool` (see
  `packaging/linux/build-packages.sh`).

`release.yml` uses `softprops/action-gh-release@v2` and needs
`permissions: contents: write`. The release is created as a draft for review.
