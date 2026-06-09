// Forces a non-scalable viewport meta tag so the WebView ignores
// touch pinch gestures on visionOS. Replaces any existing tag
// rather than appending, so a template-provided viewport doesn't
// keep its `user-scalable=yes` (the default).

(function() {
   var head = document.head || document.getElementsByTagName('head')[0];
   if (!head) { return; }
   var meta = head.querySelector('meta[name="viewport"]');
   if (!meta) {
     meta = document.createElement('meta');
     meta.name = 'viewport';
     head.appendChild(meta);
   }
   meta.setAttribute(
                     'content',
                     'width=device-width, initial-scale=1.0, ' +
                     'maximum-scale=1.0, minimum-scale=1.0, user-scalable=no');
 })();
