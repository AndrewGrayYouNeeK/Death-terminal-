# Homebrew cask for the macOS disk image produced by packaging/macos/make-app.sh.
# version and sha256 are placeholders. packaging/update-manifests.sh fills
# them, and only then writes a GitHub Releases URL. Do not submit this file
# while those placeholders are still here.
cask "deathterminal" do
  arch arm: "aarch64", intel: "x86_64"

  version "__VERSION__"
  sha256 arm:   "__SHA256_MACOS_DMG_AARCH64__",
         intel: "__SHA256_MACOS_DMG_X86_64__"

  url "__URL_MACOS_DMG__"
  name "YouNeeK Death Terminal"
  desc "Brutalist GPU terminal emulator with AI suggestions, SSH and Lua plugins"
  homepage "https://github.com/AndrewGrayYouNeeK/Death-terminal-"

  # Homebrew's current floor is macOS 11 (Big Sur), same as LSMinimumSystemVersion.
  depends_on :macos

  # Dock icon is Contents/Resources/deathterminal.icns inside this app
  # (CFBundleIconFile = deathterminal). The cask does not build the bundle.
  app "YouNeeK Death Terminal.app"
  binary "#{appdir}/YouNeeK Death Terminal.app/Contents/MacOS/deathterminal"
  manpage "#{appdir}/YouNeeK Death Terminal.app/Contents/Resources/share/man/man1/deathterminal.1"

  zap trash: [
    "~/.config/death-terminal",
    "~/.local/share/death-terminal",
    "~/.local/state/death-terminal",
  ]

  caveats <<~EOS
    GPU rendering uses the MoltenVK dylib in Contents/Frameworks when the
    release build set MOLTENVK_DIR. Without that dylib, install molten-vk
    or the app stays on the software renderer.
  EOS
end
