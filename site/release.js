"use strict";

// Filename contract from packaging/ and .github/workflows/release.yml:
//   DeathTerminal-<ver>-aarch64.dmg          packaging/macos/make-app.sh
//   DeathTerminal-<ver>-x86_64.dmg
//   deathterminal-<ver>-x86_64-setup.exe     packaging/windows/build-installer.sh
//   deathterminal-<ver>-x86_64.AppImage      packaging/linux/build-packages.sh
//   deathterminal_<ver>-1_amd64.deb
//   deathterminal-<ver>-1.x86_64.rpm
//   SHA256SUMS                               release.yml publish job
(function (root) {
  var RELEASES_PAGE = "https://github.com/AndrewGrayYouNeeK/Death-terminal-/releases";
  var LATEST_API = "https://api.github.com/repos/AndrewGrayYouNeeK/Death-terminal-/releases/latest";
  var PACKAGE_KEYS = ["macosArm", "macosIntel", "windows", "appimage", "deb", "rpm"];

  var patterns = {
    macosArm: /^DeathTerminal-.+-aarch64\.dmg$/,
    macosIntel: /^DeathTerminal-.+-x86_64\.dmg$/,
    windows: /^deathterminal-.+-x86_64-setup\.exe$/,
    appimage: /^deathterminal-.+-x86_64\.AppImage$/,
    deb: /^deathterminal_.+_amd64\.deb$/,
    rpm: /^deathterminal-.+\.x86_64\.rpm$/,
    sums: /^SHA256SUMS$/,
  };

  function versionFromTag(tag) {
    if (typeof tag !== "string" || tag.length === 0) return "";
    return tag.charAt(0) === "v" ? tag.slice(1) : tag;
  }

  function pick(assets, re, version) {
    var hits = [];
    var i;
    for (i = 0; i < assets.length; i++) {
      var asset = assets[i];
      if (!asset || typeof asset.name !== "string") continue;
      if (!re.test(asset.name)) continue;
      hits.push(asset);
    }
    if (hits.length === 0) return null;
    if (version) {
      var tagged = [];
      for (i = 0; i < hits.length; i++) {
        if (hits[i].name.indexOf(version) !== -1) tagged.push(hits[i]);
      }
      if (tagged.length) hits = tagged;
    }
    hits.sort(function (a, b) {
      if (a.name < b.name) return -1;
      if (a.name > b.name) return 1;
      return 0;
    });
    return hits[hits.length - 1];
  }

  function matchAssets(assets, tag) {
    var list = Array.isArray(assets) ? assets : [];
    var version = versionFromTag(tag);
    var out = {};
    var key;
    for (key in patterns) {
      if (Object.prototype.hasOwnProperty.call(patterns, key)) {
        out[key] = pick(list, patterns[key], version);
      }
    }
    return out;
  }

  function hrefFor(asset) {
    if (!asset || typeof asset.browser_download_url !== "string") return RELEASES_PAGE;
    if (asset.browser_download_url.indexOf("https://github.com/") !== 0) return RELEASES_PAGE;
    return asset.browser_download_url;
  }

  // kind is one of: macos-arm, macos-intel, macos, windows, linux, unknown.
  function classify(info) {
    info = info || {};
    var ua = String(info.ua || "");
    var platform = String(info.platform || "");
    var uaPlatform = String(info.uaPlatform || "");
    var arch = String(info.architecture || "").toLowerCase();
    var renderer = String(info.renderer || "");
    var touch = Number(info.maxTouchPoints) || 0;

    if (/Android/i.test(ua) || uaPlatform === "Android") return "unknown";
    if (/iPhone|iPad|iPod/i.test(ua) || uaPlatform === "iOS") return "unknown";

    var isWindows = uaPlatform === "Windows" || /Windows/i.test(ua) || /^Win/.test(platform);
    if (isWindows) return "windows";

    var isMac = uaPlatform === "macOS" || /Mac/i.test(platform) || /Mac OS X|Macintosh/i.test(ua);
    if (isMac) {
      if (touch > 1 && arch === "") return "unknown";
      if (arch === "arm" || arch.indexOf("aarch") !== -1 || arch === "arm64") return "macos-arm";
      if (arch === "x86" || arch === "x86_64" || arch === "amd64") return "macos-intel";
      if (/Apple M\d|Apple GPU/i.test(renderer)) return "macos-arm";
      if (/Intel|AMD|Radeon|NVIDIA|GeForce/i.test(renderer)) return "macos-intel";
      return "macos";
    }

    var isLinux = uaPlatform === "Linux" || /Linux/i.test(ua) || /Linux/i.test(platform);
    if (isLinux) return "linux";
    return "unknown";
  }

  function primaryTarget(kind) {
    switch (kind) {
      case "macos-arm":
        return "macosArm";
      case "macos-intel":
        return "macosIntel";
      case "windows":
        return "windows";
      case "linux":
        return "appimage";
      case "macos":
      case "unknown":
        return null;
      default:
        return null;
    }
  }

  function primaryLabel(kind) {
    switch (kind) {
      case "macos-arm":
        return "Download · macOS Apple Silicon";
      case "macos-intel":
        return "Download · macOS Intel";
      case "windows":
        return "Download · Windows";
      case "linux":
        return "Download · Linux AppImage";
      case "macos":
        return "Download · macOS";
      case "unknown":
        return "Download";
      default:
        return "Download";
    }
  }

  function detectLine(kind) {
    switch (kind) {
      case "macos-arm":
        return "This browser looks like macOS on Apple Silicon.";
      case "macos-intel":
        return "This browser looks like macOS on Intel.";
      case "macos":
        return "This browser looks like macOS. The chip was not reported. Pick Apple Silicon or Intel.";
      case "windows":
        return "This browser looks like Windows.";
      case "linux":
        return "This browser looks like Linux. Packages are x86_64.";
      case "unknown":
        return "This browser did not report a desktop OS we ship. Pick a build.";
      default:
        return "This browser did not report a desktop OS we ship. Pick a build.";
    }
  }

  function packageCount(matched) {
    var n = 0;
    var i;
    for (i = 0; i < PACKAGE_KEYS.length; i++) {
      if (matched && matched[PACKAGE_KEYS[i]]) n++;
    }
    return n;
  }

  function statusLine(result, matched) {
    if (!result || result.state === "error") {
      return "Couldn't read the latest release. These links open the Releases page.";
    }
    if (result.state === "none") {
      return "No published release yet. Tag builds are uploaded as drafts; publish one and these buttons pick up the files. Until then they open the Releases page.";
    }
    var tag = result.release && result.release.tag_name ? result.release.tag_name : "the latest release";
    var n = packageCount(matched);
    if (n === 0) {
      return tag + " has no desktop packages attached. These links open the Releases page.";
    }
    if (n < PACKAGE_KEYS.length) {
      return tag + ". " + n + " of " + PACKAGE_KEYS.length + " packages are attached. The rest open the Releases page.";
    }
    return tag + ". Downloads point at that release.";
  }

  function formatSize(bytes) {
    if (typeof bytes !== "number" || !isFinite(bytes) || bytes < 0) return "";
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + " KB";
    return (bytes / (1024 * 1024)).toFixed(1) + " MB";
  }

  root.DTRelease = {
    RELEASES_PAGE: RELEASES_PAGE,
    LATEST_API: LATEST_API,
    PACKAGE_KEYS: PACKAGE_KEYS,
    patterns: patterns,
    matchAssets: matchAssets,
    hrefFor: hrefFor,
    classify: classify,
    primaryTarget: primaryTarget,
    primaryLabel: primaryLabel,
    detectLine: detectLine,
    statusLine: statusLine,
    formatSize: formatSize,
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
