// Finds the smallest source line of any block currently in (or just
// above) the viewport. Reads the same three attribute flavors
// EditorBridge understands (data-source-line, data-pos, data-sourcepos).
// Returns null when the active renderer doesn't emit source positions,
// or when no positioned block is visible (very short docs, mostly).
//
// Loaded by DocumentModel.swift and evaluated via
// `WebPage.callJavaScript`, which wraps the source in an async function
// and captures a top-level `return`. Do NOT wrap this in an IIFE — its
// return value would be discarded.

var nodes = document.querySelectorAll(
  '[data-source-line], [data-pos], [data-sourcepos]');
for (var i = 0; i < nodes.length; i++) {
  var node = nodes[i];
  var rect = node.getBoundingClientRect();
  // Skip blocks fully above the viewport — behind the user's
  // reading position. First with bottom >= 0 is what we want.
  if (rect.bottom < 0) continue;
  var n = NaN;
  if (node.dataset.sourceLine) {
    n = parseInt(node.dataset.sourceLine, 10);
  } else {
    var raw = node.dataset.pos || node.dataset.sourcepos || '';
    var m = raw.match(/(\d+):\d+/);
    if (m) n = parseInt(m[1], 10);
  }
  if (Number.isNaN(n)) continue;
  return n;
}
return null;
