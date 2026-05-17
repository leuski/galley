// Single combined click handler for cmd-click → editor and plain
// click → in-window navigation. Loaded by EditorBridge.swift via
// `Bundle.requiredString(forResource:withExtension:)`. Routing both
// cases through one `addEventListener` removes ambiguity around
// capture-phase ordering between two scripts, and
// `stopImmediatePropagation` guarantees we don't fall through to a
// duplicate listener that could survive across navigations.
//
// Message names are hardcoded — they must match
// `EditorBridge.messageName` ("editor") and `LinkBridge.messageName`
// ("linkclick"). If either changes, update this file too.

function __mdEyeSourceLine(el) {
  var node = el && el.closest && el.closest(
    '[data-source-line], [data-pos], [data-sourcepos]');
  if (!node) return null;
  if (node.dataset.sourceLine) {
    var n = parseInt(node.dataset.sourceLine, 10);
    return Number.isNaN(n) ? null : n;
  }
  var raw = node.dataset.pos || node.dataset.sourcepos || '';
  var m = raw.match(/(\d+):\d+/);
  if (!m) return null;
  var n = parseInt(m[1], 10);
  return Number.isNaN(n) ? null : n;
}
document.addEventListener('click', (event) => {
  if (event.metaKey) {
    const line = __mdEyeSourceLine(event.target);
    if (line !== null) {
      event.preventDefault();
      event.stopImmediatePropagation();
      window.webkit.messageHandlers.editor.postMessage({ line });
      return;
    }
    // Cmd-click missed a source-line target — still suppress any
    // default WebView action (e.g. open-in-new-window for links).
    event.preventDefault();
    event.stopImmediatePropagation();
    return;
  }
  const link = event.target.closest('a[href]');
  if (!link) return;
  const href = link.getAttribute('href');
  if (!href || href.startsWith('#')) return;
  event.preventDefault();
  event.stopImmediatePropagation();
  window.webkit.messageHandlers.linkclick.postMessage({ href });
}, true);
