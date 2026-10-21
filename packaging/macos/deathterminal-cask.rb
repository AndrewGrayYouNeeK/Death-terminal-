# Homebrew cask skeleton for the .app zip made by make-app.sh. UNTESTED.
# Goes to a tap as Casks/deathterminal.rb.
cask "deathterminal" do
  arch arm: "aarch64", intel: "x86_64"

  version "0.1.0"
  sha256 arm:   "0000000000000000000000000000000000000000000000000000000000000000",
         intel: "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/AndrewGrayYouNeeK/Death-terminal-/releases/download/v#{version}/DeathTerminal-#{version}-#{arch}.zip"
  name "YouNeeK Death Terminal"
  desc "Brutalist GPU terminal emulator with AI suggestions, built-in SSH and Lua plugins"
  homepage "https://github.com/AndrewGrayYouNeeK/Death-terminal-"

  depends_on macos: ">= :big_sur"
  depends_on formula: "molten-vk"

  app "YouNeeK Death Terminal.app"
  binary "#{appdir}/YouNeeK Death Terminal.app/Contents/MacOS/deathterminal"
  manpage "#{appdir}/YouNeeK Death Terminal.app/Contents/Resources/share/man/man1/deathterminal.1"

  zap trash: "~/.config/death-terminal"
end
