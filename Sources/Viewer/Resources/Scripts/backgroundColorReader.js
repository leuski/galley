// Reads the rendered page's computed background color (`html`
// preferred, falling back to `body`) and posts it back to SwiftUI so
// the host can paint a matching color behind translucent toolbar /
// sidebar chrome — creating the illusion that the document extends
// edge-to-edge under the chrome.
//
// Loaded by BackgroundColorBridge.swift. Message name is hardcoded
// here and must match `BackgroundColorBridge.messageName`
// ("backgroundColor"). Posts `{ color: "rgb(...)" }` (or "rgba(...)")
// when the page declares an opaque background; posts `{ color: null }`
// when both `html` and `body` are transparent so the host can fall
// back to the system default.

(function () {
  function isTransparent(value) {
    if (!value) return true;
    var stripped = value.replace(/\s+/g, '');
    return stripped === 'transparent' || stripped === 'rgba(0,0,0,0)';
  }

  function reportBackground() {
    var post = function (color) {
      if (window.webkit
          && window.webkit.messageHandlers
          && window.webkit.messageHandlers.backgroundColor) {
        window.webkit.messageHandlers.backgroundColor.postMessage(
          { color: color });
      }
    };

    var html = document.documentElement;
    var body = document.body;
    if (!html || !body) { post(null); return; }

    var htmlBg = getComputedStyle(html).backgroundColor;
    if (!isTransparent(htmlBg)) { post(htmlBg); return; }

    var bodyBg = getComputedStyle(body).backgroundColor;
    if (!isTransparent(bodyBg)) { post(bodyBg); return; }

    post(null);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', reportBackground);
  } else {
    reportBackground();
  }
})();
