# Homebrew formula for the Linux archive from `zig build release`.
# On macOS, install the cask (the .app) instead. This file is a template:
# packaging/update-manifests.sh fills version and sha256 into packaging/dist/.
# The url stays https://example.invalid until the archive exists.
class Deathterminal < Formula
  desc "The terminal that is both fast and smart without becoming a browser"
  homepage "https://andrewgrayyouneek.github.io/Death-terminal-/"
  license "Unlicense"
  version "@@VERSION@@"

  on_intel do
    url "https://example.invalid/pending-release/deathterminal-@@VERSION@@-x86_64-linux.tar.gz"
    sha256 "@@SHA256:deathterminal-@@VERSION@@-x86_64-linux.tar.gz@@"
  end
  on_arm do
    url "https://example.invalid/pending-release/deathterminal-@@VERSION@@-aarch64-linux.tar.gz"
    sha256 "@@SHA256:deathterminal-@@VERSION@@-aarch64-linux.tar.gz@@"
  end

  def install
    odie "On macOS, brew install --cask deathterminal" if OS.mac?
    prefix_dir = "deathterminal-#{version}-#{Hardware::CPU.arm? ? "aarch64" : "x86_64"}-linux"
    bin.install "#{prefix_dir}/bin/deathterminal"
    man1.install "#{prefix_dir}/share/man/man1/deathterminal.1"
    doc.install Dir["#{prefix_dir}/share/doc/deathterminal/*"]
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/deathterminal --version")
  end
end
