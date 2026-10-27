// The device switcher: tabs with arrow keys. Without script every panel shows.
(() => {
  const tabs = [...document.querySelectorAll('.screens [role="tab"]')];
  const select = (tab, focus) => {
    for (const other of tabs) {
      const on = other === tab;
      other.setAttribute('aria-selected', String(on));
      other.tabIndex = on ? 0 : -1;
      document.getElementById(other.getAttribute('aria-controls'))?.classList.toggle('on', on);
    }
    if (focus) tab.focus();
  };
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => select(tab, false));
    tab.addEventListener('keydown', (event) => {
      const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
      if (!step) return;
      event.preventDefault();
      select(tabs[(index + step + tabs.length) % tabs.length], true);
    });
  });

  // Lead with the visitor's own system; the other buttons stay.
  const platform = /Windows/i.test(navigator.userAgent) ? 'windows'
    : /Android/i.test(navigator.userAgent) ? 'android' : null;
  const actions = document.querySelector('.hero .actions');
  const own = platform && actions?.querySelector(`[data-platform="${platform}"]`);
  const lead = actions?.querySelector('.btn-primary');
  if (own && lead && own !== lead) {
    lead.classList.remove('btn-primary');
    own.classList.add('btn-primary');
    actions.prepend(own);
  }
})();
