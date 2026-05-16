// Reads the rendered page's computed background color (`html`
// preferred, falling back to `body`) and posts it back to SwiftUI so
// the host can paint a matching color behind translucent toolbar /
// sidebar chrome — creating the illusion that the document extends
// edge-to-edge under the chrome.
//
// Loaded by BackgroundColorBridge.swift. Message name is hardcoded
// here and must match `BackgroundColorBridge.messageName`
// ("backgroundColor"). Posts `{ color, templateID }` where `color`
// is `"rgb(...)"` / `"rgba(...)"` for opaque backgrounds or `null`
// when both `html` and `body` are transparent, and `templateID` is
// the id of the template that produced this page (read from the
// `<meta name="galley-template-id">` injected by
// `Template.composeHTML`). The Swift side uses `templateID` to
// route the post to the cache slot of the template that is actually
// painted in the WebView right now — which can differ from the
// currently-selected template during the gap between picking a new
// template and the new HTML finishing its first paint.

(function () {
  function isTransparent(value) {
    if (!value) return true;
    var stripped = value.replace(/\s+/g, '');
    return stripped === 'transparent' || stripped === 'rgba(0,0,0,0)';
  }

  function currentTemplateID() {
    var meta = document.querySelector(
      'meta[name="galley-template-id"]');
    return meta ? meta.getAttribute('content') : null;
  }

  function reportBackground() {
    var post = function (color) {
      if (window.webkit
          && window.webkit.messageHandlers
          && window.webkit.messageHandlers.backgroundColor) {
        window.webkit.messageHandlers.backgroundColor.postMessage(
          { color: color, templateID: currentTemplateID() });
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

  // Defer the post until WebKit has actually committed a paint
  // frame for the current layout. `atDocumentEnd` (and even
  // DOMContentLoaded) fire BEFORE the first paint — reporting then
  // would let SwiftUI drop its anti-flash overlay while the WebView
  // is still painting white. Double-rAF is the standard trick: the
  // first callback runs before the next paint, the second runs from
  // inside that callback so it fires AFTER the paint commits.
  function reportAfterPaint() {
    requestAnimationFrame(function () {
      requestAnimationFrame(reportBackground);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', reportAfterPaint);
  } else {
    reportAfterPaint();
  }
})();
