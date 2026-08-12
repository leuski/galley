// Measures the width the laid-out document actually wants, so the
// Quick Look panel can be sized to the template's reading column
// rather than to an arbitrary fraction of the screen.
//
// Returns the smaller of two upper bounds, since which one is tight
// depends on where the template declares its column:
//
//   * The union of the body's content rects, plus the body's padding.
//     This is the tight one when a centered wrapper holds the column
//     (the GitHub template's `.markdown-body`). A Range over the
//     body's contents yields boxes for contained *elements* as well as
//     text lines, so that wrapper reports its own border box; the
//     body's padding is added back because it sits outside those rects.
//   * The body's own border box. This is the tight one when the column
//     is declared on `body` itself, as most bundled templates do.
//
// The body's *margin* is deliberately not added: `margin: 0 auto`
// computes to a used value of half the leftover viewport, so adding it
// back reconstructs the whole viewport and every template measures as
// full width.
//
// A block that scrolls on its own (`pre { overflow-x: auto }`) does not
// widen the result — the horizontal scroll stays inside that block,
// which is what the template asked for.
//
// Returns null when the page has no usable geometry; the caller falls
// back to its ceiling width.
//
// Loaded by PreviewViewController.swift and evaluated via
// `WKWebView.callJavaScript`, which wraps the source in an async
// function and captures a top-level `return`. Do NOT wrap this in an
// IIFE — its return value would be discarded.

var body = document.body;
if (!body) return null;

var range = document.createRange();
range.selectNodeContents(body);
var rects = range.getClientRects();
var left = Infinity;
var right = -Infinity;
for (var i = 0; i < rects.length; i++) {
  var rect = rects[i];
  if (rect.width <= 0 || rect.height <= 0) continue;
  left = Math.min(left, rect.left);
  right = Math.max(right, rect.right);
}
if (!isFinite(left) || !isFinite(right)) return null;

var style = getComputedStyle(body);
var padding = (parseFloat(style.paddingLeft) || 0)
  + (parseFloat(style.paddingRight) || 0);
var fromContent = (right - left) + padding;
var fromBody = body.getBoundingClientRect().width;
return Math.ceil(Math.min(fromContent, fromBody));
