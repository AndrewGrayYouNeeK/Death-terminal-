# GitHub Actions workflows

These files are installed at `.github/workflows/`. This directory is the
copy to edit; keep the installed files identical:

```sh
cp packaging/ci/ci.yml packaging/ci/release.yml .github/workflows/
```

| File | Installed at | What it does |
|------|--------------|--------------|
| `ci.yml` | `.github/workflows/ci.yml` | Linux build + tests with the full dependency list, plus compile-only checks for Windows and macOS |
| `release.yml` | `.github/workflows/release.yml` | On a `v*` tag: Linux tarball, AppImage, .deb and .rpm; Windows zip and NSIS setup exe; macOS tarball, `.app` zip and `.dmg`; SHA256SUMS; a draft GitHub release. Unsigned (see `packaging/SIGNING.md`) |

## CI dependencies

- `libfreetype-dev libharfbuzz-dev libfontconfig-dev`: FreeType, HarfBuzz and
  fontconfig. Without them `zig build` cannot find `freetype2`, `harfbuzz`
  or `fontconfig`.
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
  `packaging/linux/build-packages.sh`). The cross job also installs `nsis`
  (Windows setup exe) and `genisoimage` plus `zlib1g-dev` (macOS `.dmg`).

`release.yml` uses `softprops/action-gh-release@v2` and needs
`permissions: contents: write`. The release is created as a draft titled `YouNeeK Death Terminal` plus the ref, for review.
