// Document-start CSS for find highlights. Loaded by FindBridge.swift
// via `Bundle.requiredString(forResource:withExtension:)`. Runs
// before the renderer's body markup is parsed; avoids a flash of
// unstyled `<mark>` on the very first match after a reload.

(function() {
  var id = 'galley-find-style';
  if (document.getElementById(id)) return;
  var style = document.createElement('style');
  style.id = id;
  style.textContent =
    'mark.galley-find{background:#ffe066;color:inherit;' +
    'border-radius:2px;padding:0 1px;}' +
    'mark.galley-find.galley-find-current{' +
    'background:#ff8c1a;color:#000;}';
  (document.head || document.documentElement).appendChild(style);
})();
