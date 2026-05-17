// Computes word / character / heading counts from the rendered DOM
// and posts them to SwiftUI once per page load. Loaded by
// StatsBridge.swift via `Bundle.requiredString(...)`. Message name is
// hardcoded; must match `StatsBridge.messageName` ("stats").
//
// Word count uses `Intl.Segmenter` when available so CJK and other
// non-whitespace-delimited scripts return meaningful counts; falls
// back to whitespace splitting when the API is unavailable. The
// character count counts non-whitespace characters — matches the
// "characters (no spaces)" convention most writing tools surface.
//
// Reads `document.body.innerText` rather than `textContent` so
// CSS-hidden chrome (anchors injected by templates, copy-button
// glyphs, etc.) is excluded from the count.

(function () {
  function countWordsByWhitespace(text) {
    var trimmed = text.replace(/\s+/g, ' ').trim();
    if (!trimmed) return 0;
    return trimmed.split(' ').length;
  }

  function countWords(text) {
    if (typeof Intl !== 'undefined'
        && typeof Intl.Segmenter === 'function') {
      try {
        var segmenter = new Intl.Segmenter(
          undefined, { granularity: 'word' });
        var count = 0;
        var iter = segmenter.segment(text)[Symbol.iterator]();
        var step = iter.next();
        while (!step.done) {
          if (step.value.isWordLike) count += 1;
          step = iter.next();
        }
        return count;
      } catch (err) {
        // Fall through to the whitespace fallback.
      }
    }
    return countWordsByWhitespace(text);
  }

  function countNonWhitespace(text) {
    var count = 0;
    for (var i = 0; i < text.length; i++) {
      if (!/\s/.test(text.charAt(i))) count += 1;
    }
    return count;
  }

  function readStats() {
    var body = document.body;
    var text = body
      ? (body.innerText || body.textContent || '')
      : '';
    var headings = document.querySelectorAll(
      'h1, h2, h3, h4, h5, h6').length;
    post({
      words: countWords(text),
      characters: countNonWhitespace(text),
      headings: headings
    });
  }

  function post(payload) {
    if (window.webkit
        && window.webkit.messageHandlers
        && window.webkit.messageHandlers.stats) {
      window.webkit.messageHandlers.stats.postMessage(payload);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', readStats);
  } else {
    readStats();
  }
})();
