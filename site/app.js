"use strict";

(function () {
  function rendererString() {
    try {
      var canvas = document.createElement("canvas");
      var gl = canvas.getContext("webgl") || canvas.getContext("experimental-webgl");
      if (!gl) return "";
      var ext = gl.getExtension("WEBGL_debug_renderer_info");
      var value = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : "";
      var lose = gl.getExtension("WEBGL_lose_context");
      if (lose) lose.loseContext();
      return typeof value === "string" ? value : "";
    } catch (err) {
      return "";
    }
  }

  function readClient() {
    var nav = window.navigator || {};
    var info = {
      ua: nav.userAgent || "",
      platform: nav.platform || "",
      uaPlatform: (nav.userAgentData && nav.userAgentData.platform) || "",
      architecture: "",
      renderer: "",
      maxTouchPoints: nav.maxTouchPoints || 0,
    };
    var high = Promise.resolve();
    if (nav.userAgentData && typeof nav.userAgentData.getHighEntropyValues === "function") {
      high = nav.userAgentData.getHighEntropyValues(["architecture", "platform"]).then(function (values) {
        info.architecture = (values && values.architecture) || "";
        if (values && values.platform) info.uaPlatform = values.platform;
      }, function () {});
    }
    return high.then(function () {
      if (DTRelease.classify(info) === "macos") info.renderer = rendererString();
      return DTRelease.classify(info);
    });
  }

  function loadRelease() {
    return fetch(DTRelease.LATEST_API, { cache: "no-store" }).then(function (res) {
      if (res.status === 404) return { state: "none" };
      if (!res.ok) return { state: "error", status: res.status };
      return res.json().then(function (body) {
        if (!body || !Array.isArray(body.assets)) return { state: "error" };
        return { state: "ok", release: body };
      }, function () {
        return { state: "error" };
      });
    }, function () {
      return { state: "error" };
    });
  }

  function fileText(asset) {
    if (!asset) return "Releases page";
    var size = DTRelease.formatSize(asset.size);
    return size ? asset.name + " · " + size : asset.name;
  }

  function render(kind, result) {
    var release = result.state === "ok" ? result.release : null;
    var tag = release && release.tag_name ? release.tag_name : "";
    var matched = DTRelease.matchAssets(release ? release.assets : [], tag);
    var target = DTRelease.primaryTarget(kind);
    var keys = DTRelease.PACKAGE_KEYS;
    var i;

    for (i = 0; i < keys.length; i++) {
      var key = keys[i];
      var link = document.getElementById("btn-" + key);
      if (!link) continue;
      link.href = DTRelease.hrefFor(matched[key]);
      var file = link.querySelector(".file");
      if (file) file.textContent = fileText(matched[key]);
      link.classList.toggle("is-match", target === key);
    }

    var sums = document.getElementById("sha256");
    if (sums) sums.href = DTRelease.hrefFor(matched.sums);

    var primary = document.getElementById("download-primary");
    if (primary) {
      var label = primary.querySelector(".label");
      var primaryFile = primary.querySelector(".file");
      if (label) label.textContent = DTRelease.primaryLabel(kind);
      if (target && matched[target]) {
        primary.href = DTRelease.hrefFor(matched[target]);
        if (primaryFile) primaryFile.textContent = fileText(matched[target]);
      } else if (kind === "macos") {
        primary.href = "#downloads";
        if (primaryFile) primaryFile.textContent = "Apple Silicon or Intel";
      } else if (target) {
        primary.href = DTRelease.RELEASES_PAGE;
        if (primaryFile) primaryFile.textContent = "Releases page";
      } else {
        primary.href = DTRelease.RELEASES_PAGE;
        if (primaryFile) primaryFile.textContent = "";
      }
    }

    var detect = document.getElementById("detect-line");
    if (detect) detect.textContent = DTRelease.detectLine(kind);
    var status = document.getElementById("release-status");
    if (status) status.textContent = DTRelease.statusLine(result, matched);
  }

  function boot() {
    Promise.all([readClient(), loadRelease()]).then(function (pair) {
      render(pair[0], pair[1]);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
