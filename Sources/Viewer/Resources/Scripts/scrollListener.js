// Debounced scroll listener. Loaded by ScrollBridge.swift via
// `Bundle.requiredString(forResource:withExtension:)`. Trailing-edge
// — emits the resting position once the user pauses scrolling.
// Injected at `documentEnd` so `window.scrollY` is meaningful by the
// time it runs.
//
// Message name is hardcoded; must match `ScrollBridge.messageName`
// ("scroll").

(function () {
  var timer = null;
  window.addEventListener('scroll', function () {
    if (timer !== null) clearTimeout(timer);
    timer = setTimeout(function () {
      timer = null;
      window.webkit.messageHandlers.scroll.postMessage(
        JSON.stringify({ y: window.scrollY }));
    }, 150);
  }, { passive: true });
})();
