// Review switches for the 3.0 comps: ?mode=dark|light, ?state=<region state>, ?role=controller, ?device=touch.
(() => {
  document.documentElement.classList.add('js');
  const q = new URLSearchParams(location.search);
  const root = document.documentElement;
  const mode = q.get('mode');
  if (mode === 'dark' || mode === 'light') root.dataset.mode = mode;
  if (q.get('role') === 'controller') root.dataset.role = 'controller';
  if (q.get('device') === 'touch') root.dataset.device = 'touch';
  const state = q.get('state');
  if (state) document.querySelectorAll('[data-region]').forEach((r) => { r.dataset.state = state; });
  document.querySelectorAll('[data-region]').forEach((r) => { const v = q.get(r.dataset.region); if (v) r.dataset.state = v; });

  // Keep the review switches when moving between screens.
  const keep = ['mode', 'role', 'device'].filter((k) => q.has(k));
  if (keep.length) {
    document.querySelectorAll('a[href$=".html"], a[href*=".html#"]').forEach((a) => {
      const url = new URL(a.getAttribute('href'), location.href);
      keep.forEach((k) => url.searchParams.set(k, q.get(k)));
      a.href = url.href;
    });
  }

  document.querySelectorAll('[data-copy]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(btn.dataset.copy); } catch { return; }
      const label = btn.getAttribute('aria-label');
      btn.setAttribute('aria-label', '已复制');
      btn.dataset.state = 'copied';
      setTimeout(() => { btn.setAttribute('aria-label', label); delete btn.dataset.state; }, 2500);
    });
  });

  document.querySelectorAll('[data-reveal-secret]').forEach((btn) => {
    const target = document.getElementById(btn.dataset.revealSecret);
    btn.addEventListener('click', () => {
      const shown = btn.getAttribute('aria-pressed') === 'true';
      btn.setAttribute('aria-pressed', String(!shown));
      btn.setAttribute('aria-label', shown ? '显示密码' : '隐藏密码');
      target.textContent = shown ? '••••••••' : target.dataset.secret;
    });
  });

  document.querySelectorAll('[data-open]').forEach((btn) => {
    const dialog = document.getElementById(btn.dataset.open);
    btn.addEventListener('click', (e) => { e.preventDefault(); dialog.showModal(); });
  });
  document.querySelectorAll('dialog [data-close]').forEach((btn) => {
    btn.addEventListener('click', () => btn.closest('dialog').close());
  });

  document.querySelectorAll('[role="tablist"]').forEach((list) => {
    const tabs = [...list.querySelectorAll('[role="tab"]')];
    const select = (tab) => tabs.forEach((t) => {
      const on = t === tab;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
    });
    tabs.forEach((tab, i) => {
      tab.addEventListener('click', () => select(tab));
      tab.addEventListener('keydown', (e) => {
        const step = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
        if (!step) return;
        const next = tabs[(i + step + tabs.length) % tabs.length];
        select(next);
        next.focus();
      });
    });
  });
})();
