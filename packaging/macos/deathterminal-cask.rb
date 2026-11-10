# Homebrew cask for the .app zip from packaging/macos/make-app.sh.
# Not submittable as committed: version and sha256 placeholders are filled by
# packaging/update-manifests.sh into packaging/dist/. The url is
# example.invalid until that dist copy is edited after a real file exists.
# Do not point this at a GitHub Release that has not been published.
cask "deathterminal" do
  arch arm: "aarch64", intel: "x86_64"

  version "@@VERSION@@"
  sha256 arm:   "@@SHA256:DeathTerminal-@@VERSION@@-aarch64.zip@@",
         intel: "@@SHA256:DeathTerminal-@@VERSION@@-x86_64.zip@@"

  url "https://example.invalid/pending-release/DeathTerminal-#{version}-#{arch}.zip"
  name "YouNeeK Death Terminal"
  desc "The terminal that is both fast and smart without becoming a browser"
  homepage "https://andrewgrayyouneek.github.io/Death-terminal-/"

  depends_on macos: ">= :big_sur"

  app "YouNeeK Death Terminal.app"
  binary "#{appdir}/YouNeeK Death Terminal.app/Contents/MacOS/deathterminal"
  manpage "#{appdir}/YouNeeK Death Terminal.app/Contents/Resources/share/man/man1/deathterminal.1"

  zap trash: "~/.config/death-terminal"
end
