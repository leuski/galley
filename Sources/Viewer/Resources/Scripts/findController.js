// Find-text controller. Loaded by FindBridge.swift via
// `Bundle.requiredString(forResource:withExtension:)`. Re-creates
// the JS find function on every load so a freshly-rendered DOM picks
// up a clean state — old marks are gone with the previous document,
// and re-running a query after a file-watcher reload starts from
// zero.
//
// Highlighting is DOM-mutating so we get a Safari-style "highlight
// every match, scroll to current" experience that `window.find()`
// can't provide. Marks are removed and the DOM normalized on every
// `clear` (and on every fresh `search`), so repeated edits don't
// accumulate stray nodes between renders.

(function() {
  var TEXT_NODE_FILTER = {
    acceptNode: function(node) {
      if (!node.parentNode) return NodeFilter.FILTER_REJECT;
      var tag = node.parentNode.nodeName;
      if (tag === 'SCRIPT' || tag === 'STYLE' ||
          tag === 'NOSCRIPT' || tag === 'MARK') {
        return NodeFilter.FILTER_REJECT;
      }
      if (!node.nodeValue || !node.nodeValue.trim()) {
        return NodeFilter.FILTER_REJECT;
      }
      return NodeFilter.FILTER_ACCEPT;
    }
  };

  function escape(text) {
    return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  window.ourFindFunction = {
    marks: [],
    currentIndex: -1,

    search: function(query, caseSensitive, wholeWord) {
      this.clear();
      if (!query) return { count: 0, index: -1 };
      var flags = caseSensitive ? 'g' : 'gi';
      var body = escape(query);
      if (wholeWord) body = '\\b' + body + '\\b';
      var pattern = new RegExp(body, flags);

      var walker = document.createTreeWalker(
        document.body, NodeFilter.SHOW_TEXT, TEXT_NODE_FILTER);
      var nodes = [];
      var node;
      while ((node = walker.nextNode())) nodes.push(node);

      for (var i = 0; i < nodes.length; i++) {
        var textNode = nodes[i];
        var text = textNode.nodeValue;
        pattern.lastIndex = 0;
        var match;
        var matches = [];
        while ((match = pattern.exec(text)) !== null) {
          matches.push({
            start: match.index, end: match.index + match[0].length });
          if (match[0].length === 0) pattern.lastIndex++;
        }
        if (matches.length === 0) continue;
        var fragment = document.createDocumentFragment();
        var cursor = 0;
        for (var j = 0; j < matches.length; j++) {
          var span = matches[j];
          if (span.start > cursor) {
            fragment.appendChild(document.createTextNode(
              text.slice(cursor, span.start)));
          }
          var mark = document.createElement('mark');
          mark.className = 'galley-find';
          mark.textContent = text.slice(span.start, span.end);
          fragment.appendChild(mark);
          this.marks.push(mark);
          cursor = span.end;
        }
        if (cursor < text.length) {
          fragment.appendChild(document.createTextNode(
            text.slice(cursor)));
        }
        textNode.parentNode.replaceChild(fragment, textNode);
      }

      if (this.marks.length > 0) {
        this.currentIndex = 0;
        this.highlightCurrent(true);
      }
      return { count: this.marks.length, index: this.currentIndex };
    },

    highlightCurrent: function(scroll) {
      for (var i = 0; i < this.marks.length; i++) {
        if (i === this.currentIndex) {
          this.marks[i].classList.add('galley-find-current');
          if (scroll) {
            this.marks[i].scrollIntoView({
              block: 'center', behavior: 'instant' });
          }
        } else {
          this.marks[i].classList.remove('galley-find-current');
        }
      }
    },

    next: function() {
      if (this.marks.length === 0) return -1;
      this.currentIndex =
        (this.currentIndex + 1) % this.marks.length;
      this.highlightCurrent(true);
      return this.currentIndex;
    },

    prev: function() {
      if (this.marks.length === 0) return -1;
      this.currentIndex =
        (this.currentIndex - 1 + this.marks.length) %
        this.marks.length;
      this.highlightCurrent(true);
      return this.currentIndex;
    },

    clear: function() {
      for (var i = 0; i < this.marks.length; i++) {
        var mark = this.marks[i];
        if (!mark.parentNode) continue;
        var text = document.createTextNode(mark.textContent);
        mark.parentNode.replaceChild(text, mark);
      }
      this.marks = [];
      this.currentIndex = -1;
      if (document.body) document.body.normalize();
    }
  };
})();
