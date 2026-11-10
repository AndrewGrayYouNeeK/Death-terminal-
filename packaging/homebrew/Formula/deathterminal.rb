# Linux x86_64 binary formula for the official release archive.
# The macOS app is the cask in ../Casks/deathterminal.rb.
# This is not a source build. update-manifests.sh only has the binary
# SHA256SUMS, so the formula installs that x86_64 archive.
# packaging/update-manifests.sh fills url and sha256. Homebrew reads the
# version from the archive name, so there is no version stanza.
class Deathterminal < Formula
  desc "Brutalist GPU terminal emulator with AI suggestions, SSH and Lua plugins"
  homepage "https://github.com/AndrewGrayYouNeeK/Death-terminal-"
  url "__URL_LINUX_TARGZ_X86_64__"
  sha256 "__SHA256_LINUX_TARGZ_X86_64__"
  license "Unlicense"

  # Official Linux archives are built on the x86_64 release runner only.
  depends_on arch: :x86_64
  depends_on :linux

  def install
    bin.install "bin/deathterminal"
    man1.install "share/man/man1/deathterminal.1"
  end

  def caveats
    <<~EOS
      This is the Ubuntu release binary. It loads libX11, libwayland-client,
      libxkbcommon, libfreetype, libharfbuzz, libfontconfig, and libssl.so.3
      from the system loader path, not from the Homebrew cellar. Vulkan
      (libvulkan.so.1) is optional; the software renderer is the fallback.
    EOS
  end

  test do
    assert_match "v#{version}", shell_output("#{bin}/deathterminal --version")
  end
end
