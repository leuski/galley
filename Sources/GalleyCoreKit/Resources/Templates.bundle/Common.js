// Promote `<pre><code class="language-mermaid">…</code></pre>` blocks to
// `<div class="mermaid">…</div>` so Mermaid's auto-detect picks them up
// regardless of which Markdown processor produced them. Pandoc emits
// `<pre class="mermaid">`; swift-markdown / cmark-gfm emit
// `<pre><code class="language-mermaid">`. Handle both.
(function () {
  document.querySelectorAll('pre > code.language-mermaid').forEach(function (code) {
    var div = document.createElement('div');
    div.className = 'mermaid';
    div.textContent = code.textContent;
    code.parentElement.replaceWith(div);
  });
  document.querySelectorAll('pre.mermaid').forEach(function (pre) {
    var div = document.createElement('div');
    div.className = 'mermaid';
    div.textContent = pre.textContent;
    pre.replaceWith(div);
  });
})();
