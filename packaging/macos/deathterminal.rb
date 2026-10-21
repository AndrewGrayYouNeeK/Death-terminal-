# Homebrew formula skeleton (build from source). UNTESTED on macOS.
# brew install --build-from-source ./packaging/macos/deathterminal.rb
class Deathterminal < Formula
  desc "YouNeeK Death Terminal: brutalist GPU terminal emulator with AI suggestions, built-in SSH and Lua plugins"
  homepage "https://github.com/AndrewGrayYouNeeK/Death-terminal-"
  url "https://github.com/AndrewGrayYouNeeK/Death-terminal-/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "Unlicense"

  depends_on "zig@0.13" => :build
  depends_on "molten-vk"
  depends_on "vulkan-loader"

  def install
    system "zig", "build", "-Doptimize=ReleaseFast", "-Dversion=#{version}", "--prefix", prefix, "--summary", "none"
    man1.install "packaging/linux/deathterminal.1"
    doc.install "README.md", "CHANGELOG.md", "config.example.lua"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/deathterminal --version")
  end
end
