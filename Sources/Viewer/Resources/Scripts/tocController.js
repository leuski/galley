// Heading extraction + scroll-driven active-heading tracker. Loaded
// by TOCBridge.swift via
// `Bundle.requiredString(forResource:withExtension:)`. Walks
// `<h1>…<h6>` once per load, slugifies text into a unique id for any
// heading without one, posts the flat list back, and then installs a
// rAF-throttled scroll listener that posts the active heading id
// whenever it changes.
//
// Message name is hardcoded; must match `TOCBridge.messageName`
// ("toc"). The 100px active threshold matches `activeThresholdPx`
// in the Swift bridge — a touch below the typical title-bar /
// toolbar inset and what GitBook / MDN use.

(function() {
  function slugify(text, used) {
    var base = text.trim().toLowerCase()
      .replace(/[^a-z0-9\s-]/g, '')
      .replace(/\s+/g, '-')
      .replace(/-+/g, '-')
      .replace(/^-|-$/g, '');
    if (!base) base = 'section';
    var id = base, counter = 1;
    while (used.has(id)) {
      counter += 1;
      id = base + '-' + counter;
    }
    used.add(id);
    return id;
  }
  var used = new Set();
  document.querySelectorAll('[id]').forEach(function(el) {
    used.add(el.id);
  });
  var nodes = document.querySelectorAll('h1, h2, h3, h4, h5, h6');
  var items = [];
  var headingEls = [];
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i];
    var text = (node.textContent || '').replace(/\s+/g, ' ').trim();
    if (!text) continue;
    if (!node.id) {
      node.id = slugify(text, used);
    }
    items.push({
      id: node.id,
      level: parseInt(node.tagName.substring(1), 10),
      text: text
    });
    headingEls.push(node);
  }
  window.webkit.messageHandlers.toc.postMessage(
    JSON.stringify({ items: items }));

  var threshold = 100;
  var lastActive = undefined;
  var ticking = false;
  function recomputeActive() {
    ticking = false;
    var newActive = null;
    for (var j = 0; j < headingEls.length; j++) {
      var top = headingEls[j].getBoundingClientRect().top;
      if (top <= threshold) {
        newActive = headingEls[j].id;
      } else {
        break;
      }
    }
    if (newActive !== lastActive) {
      lastActive = newActive;
      window.webkit.messageHandlers.toc.postMessage(
        JSON.stringify({ activeId: newActive }));
    }
  }
  function onScroll() {
    if (!ticking) {
      ticking = true;
      requestAnimationFrame(recomputeActive);
    }
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll, { passive: true });
  recomputeActive();
})();
