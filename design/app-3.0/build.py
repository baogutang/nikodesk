#!/usr/bin/env python3
"""Build the comps: src/<page>.html -> <page>.html, inlining the icon sprite
(<!-- icons -->) and the sidebar (<!-- side:<page> --> marks the current page)."""
import pathlib
import re

here = pathlib.Path(__file__).resolve().parent
sprite = (here / "src" / "icons.svg").read_text().strip()
NAV = [
    ("home", "远程控制", "i-remote"),
    ("devices", "设备", "i-devices"),
    ("history", "会话记录", "i-history"),
    ("settings", "设置", "i-settings"),
]


def side(current):
    links = "\n".join(
        f'      <a href="{page}.html"{" aria-current=\"page\"" if page == current else ""}>'
        f'<svg class="icon icon-l" aria-hidden="true"><use href="#{icon}"/></svg>{label}</a>'
        for page, label, icon in NAV
    )
    return f"""<aside class="side" aria-label="导航">
    <a class="brand" href="home.html" aria-label="NikoDesk 首页"><img src="logo.png" alt="" width="24" height="24">NikoDesk</a>
    <button class="side-search" type="button" aria-keyshortcuts="Meta+K"><svg class="icon" aria-hidden="true"><use href="#i-search"/></svg>搜索设备和命令<kbd>⌘K</kbd></button>
    <nav class="nav" aria-label="主导航">
{links}
    </nav>
    <div class="side-foot">
      <span class="server live" data-live="on" role="status">已连接 desk.example.net</span>
      <span class="version">NikoDesk 3.0.0</span>
    </div>
  </aside>"""


for page in sorted((here / "src").glob("*.html")):
    text = page.read_text().replace("<!-- icons -->", sprite)
    text = re.sub(r"<!-- side:(\w+) -->", lambda m: side(m.group(1)), text)
    (here / page.name).write_text(text)
    print("built", page.name)
