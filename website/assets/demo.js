/* Light/dark switch for the hero screenshots. Pictures only; nothing connects. */
(function () {
  'use strict';
  var root = document.getElementById('nikodesk-demo');
  if (!root) return;
  var zh = root.dataset.lang === 'zh';
  var group = document.createElement('div');
  group.className = 'nd-switch';
  group.setAttribute('role', 'group');
  group.setAttribute('aria-label', zh ? '界面主题' : 'Interface theme');
  var buttons = [['dark', zh ? '暗色' : 'Dark'], ['light', zh ? '亮色' : 'Light']].map(function (entry) {
    var button = document.createElement('button');
    button.type = 'button';
    button.textContent = entry[1];
    button.addEventListener('click', function () { show(entry[0]); });
    button.dataset.theme = entry[0];
    group.appendChild(button);
    return button;
  });
  function show(theme) {
    root.dataset.theme = theme;
    buttons.forEach(function (button) {
      button.setAttribute('aria-pressed', String(button.dataset.theme === theme));
    });
  }
  root.appendChild(group);
  show(root.dataset.theme || 'dark');
})();
