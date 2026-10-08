/* A local UI example with invented data. It never opens a remote session. */
(function () {
  'use strict';
  var root = document.getElementById('nikodesk-demo');
  if (!root) return;
  var zh = root.dataset.lang === 'zh';
  function t(en, cn) { return zh ? cn : en; }
  function el(tag, text, cls) {
    var node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (cls) node.className = cls;
    return node;
  }
  var state = { page:'devices', theme:'light', query:'', filter:'all', mapping:true, space:0, device:0 };
  var devices = [
    { name:t('Studio Mac', '工作室 Mac'), os:'macOS', group:t('Work', '工作'), favorite:true },
    { name:t('Home desktop', '家用电脑'), os:'Windows', group:t('Home', '家庭'), favorite:false },
    { name:t('Linux workstation', 'Linux 工作站'), os:'Linux', group:t('Work', '工作'), favorite:false }
  ];
  var spaces = [t('Desktop', '桌面'), t('Safari · full screen', 'Safari · 全屏'), t('Editor · full screen', '编辑器 · 全屏')];
  function button(label, action, callback, cls) {
    var b = el('button', label, cls);
    b.type = 'button'; b.dataset.action = action;
    b.addEventListener('click', callback);
    return b;
  }
  root.textContent = '';
  var top = el('div', undefined, 'nd-top');
  var brand = el('div', undefined, 'nd-brand');
  var brandIcon = el('img', undefined, 'nd-brand-mark');
  brandIcon.src = new URL('logo.png', document.currentScript.src).href;
  brandIcon.alt = '';
  brand.append(brandIcon, el('span', 'NikoDesk'));
  top.append(brand, el('span', t('INTERACTIVE EXAMPLE · INVENTED DATA', '交互示例 · 虚构数据'), 'nd-example'));
  var themes = el('div', undefined, 'nd-theme');
  themes.setAttribute('role','group'); themes.setAttribute('aria-label', t('Example theme','示例主题'));
  ['light','dark'].forEach(function (theme) {
    var b = button(theme === 'light' ? t('Light','明亮') : t('Dark','暗黑'), theme, function () {
      state.theme = theme; root.dataset.theme = theme;
      updateTheme(); say(t('Example theme changed.','示例主题已切换。'));
    });
    themes.append(b);
  });
  top.append(themes);
  var body = el('div', undefined, 'nd-body');
  var nav = el('nav', undefined, 'nd-nav');
  nav.setAttribute('aria-label', t('Example workspace','示例工作区'));
  var pageNames = { devices:t('Devices','设备'), session:t('Session tools','会话工具'), settings:t('Preferences','偏好设置') };
  Object.keys(pageNames).forEach(function (page) {
    nav.append(button(pageNames[page], page, function () {
      state.page = page; render(); say(t('Example panel: ','示例面板：') + pageNames[page]);
    }));
  });
  nav.append(el('p', t('Explore the workflow. Nothing leaves this page.','体验操作流程，数据仅在本页使用。'), 'nd-nav-note'));
  var main = el('div', undefined, 'nd-main');
  var status = el('p', undefined, 'nd-status');
  status.setAttribute('role','status'); status.setAttribute('aria-live','polite'); status.setAttribute('aria-atomic','true');
  body.append(nav, main); root.append(top, body, status);
  function say(message) { status.textContent = message; }
  function updateTheme() {
    themes.querySelectorAll('button').forEach(function (b) { b.setAttribute('aria-pressed',String(b.dataset.action === state.theme)); });
  }
  function selectButton(label, action, value, callback) {
    var b = button(label,action,callback);
    b.setAttribute('aria-pressed',String(value));
    return b;
  }
  function renderDevices() {
    main.append(el('h2',t('Your devices','我的设备')),el('p',t('Example directory · search by name, group or system','示例目录 · 按名称、分组或系统搜索'),'nd-muted'));
    var search = el('label',undefined,'nd-search');
    search.append(el('span',t('Search devices','搜索设备')));
    var input = el('input'); input.type='search'; input.value=state.query;
    input.placeholder=t('Try Mac, Home or Linux','试试 Mac、家庭或 Linux');
    search.append(input); main.append(search);
    var filters = el('div',undefined,'nd-filters');
    filters.setAttribute('role','group'); filters.setAttribute('aria-label',t('Device filter','设备筛选'));
    ['all','favorites'].forEach(function (f) {
      filters.append(selectButton(f === 'all' ? t('All devices','全部设备') : t('Favorites','收藏'),f,state.filter === f,function () {
        state.filter=f; render(); say(t('Filter changed.','筛选已切换。'));
      }));
    });
    main.append(filters);
    var cards=el('div',undefined,'nd-devices'); main.append(cards);
    function fill() {
      cards.textContent='';
      devices.forEach(function (d,index) {
        if (state.filter === 'favorites' && !d.favorite) return;
        if ((d.name+' '+d.os+' '+d.group).toLowerCase().indexOf(state.query.trim().toLowerCase()) === -1) return;
        var card=el('article',undefined,'nd-device');
        var row=el('div',undefined,'nd-device-top'); row.append(el('h3',d.name));
        var star=selectButton(d.favorite ? '★' : '☆','favorite-'+index,d.favorite,function () {
          d.favorite=!d.favorite; fill();
          say(d.name + (d.favorite ? t(' added to example favorites.','已加入示例收藏。') : t(' removed from example favorites.','已移出示例收藏。')));
          var target=cards.querySelector('[data-action="favorite-'+index+'"]') || filters.querySelector('[aria-pressed="true"]');
          if (target) target.focus();
        });
        star.className='nd-star'; star.setAttribute('aria-label',(d.favorite ? t('Unfavorite ','取消收藏 ') : t('Favorite ','收藏 '))+d.name); row.append(star);
        card.append(row,el('p',d.os+' / '+d.group,'nd-os'),el('p',t('Example data · no online query','示例数据 · 未查询在线状态'),'nd-muted'));
        card.append(button(t('Explore session tools','体验会话工具'),'open-'+index,function () {
          state.device=index; state.space=0; state.page='session'; render();
          say(t('Example session only. No connection or input is sent.','仅为会话示例，未建立连接或发送按键。'));
        },'nd-primary'));
        cards.append(card);
      });
      if (!cards.children.length) cards.append(el('p',t('No example devices match. Try a different search or filter.','没有匹配的示例设备，请调整搜索或筛选。'),'nd-empty'));
    }
    input.addEventListener('input',function () { state.query=input.value; fill(); }); fill();
  }
  function renderSession() {
    var mac=devices[state.device].os === 'macOS';
    var head=el('div',undefined,'nd-session-head'); head.append(el('h2',t('Session tools','会话工具')));
    var chips=el('div',undefined,'nd-chips');
    chips.append(el('span',t('Example controller: Windows','示例主控：Windows'),'nd-chip'),el('span',t('Remote: ','远端：')+devices[state.device].os,'nd-chip'));
    head.append(chips); main.append(head);
    if (mac) {
      var field=el('fieldset'); field.append(el('legend',t('Keyboard semantics','键盘操作含义')));
      var modes=el('div',undefined,'nd-filters');
      [true,false].forEach(function (mapping) {
        modes.append(selectButton(mapping ? t('Ctrl editing → Command','Ctrl 编辑 → Command') : t('Original keys','原始按键'),'mapping-'+mapping,state.mapping === mapping,function () {
          state.mapping=mapping; render(); say(mapping ? t('Common editing shortcuts use Command in this example.','示例常用编辑快捷键对应 Command。') : t('Original Ctrl is preserved, including terminal interrupts.','保留原始 Ctrl，包括终端中断。'));
        }));
      });
      field.append(modes); main.append(field);
    }
    var space=el('div',undefined,'nd-space');
    space.append(el('p',mac ? t('Illustrated remote Space','远端空间示意') : t('Illustrated remote workspace','远端工作区示意'),'nd-muted'),el('h3',mac ? spaces[state.space] : devices[state.device].name));
    if (mac) {
      var track=el('div',undefined,'nd-spaces');
      spaces.forEach(function (_,index) { track.append(el('span',undefined,index === state.space ? 'active' : '')); }); space.append(track);
    }
    space.append(el('p',t('Visual example; no remote app is running here.','界面示意，这里没有实际运行的远程应用。'),'nd-muted')); main.append(space);
    var actions=el('div',undefined,'nd-actions');
    function action(name,code,id,callback) {
      var b=button('',id,function () { if (callback) callback(); else say(t('Example shortcut: ','示例快捷键：')+code+t(' · no keys sent.',' · 未发送按键。')); });
      b.append(el('span',name),el('code',code)); actions.append(b);
    }
    ['C','V','A','Z','S'].forEach(function (key,index) {
      var names=[t('Copy','复制'),t('Paste','粘贴'),t('Select all','全选'),t('Undo','撤销'),t('Save','保存')];
      action(names[index],'Ctrl+'+key+' → '+(mac && state.mapping ? 'Cmd+' : 'Ctrl+')+key,'key-'+key);
    });
    action(t('Switch app','切换应用'),mac ? 'Cmd+Tab' : 'Alt+Tab','switch-app');
    if (mac) {
      [-1,1].forEach(function (step) {
        action(step < 0 ? t('Previous Space','上一个空间') : t('Next Space','下一个空间'),step < 0 ? 'Control+←' : 'Control+→','space-'+step,function () {
          state.space=(state.space+step+spaces.length)%spaces.length; render();
          say(t('Illustration switched to ','示意已切换至 ')+spaces[state.space]+t('. No remote keys sent.','，未发送远程按键。'));
        });
      });
      action(t('Mission Control','调度中心'),'Control+↑','mission-control');
      action(t('App windows','当前应用窗口'),'Control+↓','app-windows');
    }
    main.append(actions,el('p',mac ? t('Space and app shortcuts depend on the remote Mac’s settings. Use original keys for terminal Ctrl+C.','空间与应用快捷键受远端 Mac 设置影响。终端 Ctrl+C 请切换原始按键。') : t('The native app selects shortcuts for the remote system and checks current session permissions.','软件按远端系统选择组合键，并复查当前会话权限。'),'nd-muted'));
  }
  function renderSettings() {
    main.append(el('h2',t('Preferences','偏好设置')),el('p',t('Local example preferences, reset when you reload.','本页示例偏好，刷新后重置。'),'nd-muted'));
    var row=el('div',undefined,'nd-setting'); var description=el('div');
    description.append(el('h3',t('Warm light theme','暖纸亮色主题')),el('p',t('Paper surfaces, terracotta actions and warm ink.','暖纸表面、陶土按钮与棕灰文字。'),'nd-muted')); row.append(description);
    row.append(button(t('Switch theme','切换主题'),'preference-theme',function () {
      state.theme=state.theme === 'light' ? 'dark' : 'light'; root.dataset.theme=state.theme; updateTheme(); say(t('Example theme changed.','示例主题已切换。'));
    })); main.append(row);
    var info=el('div',undefined,'nd-setting'); var text=el('div');
    text.append(el('h3',t('Your own server','使用自己的服务器')),el('p',t('The app stores your private-server settings separately from RustDesk. This demo accepts no credentials or server addresses.','软件的私服设置与 RustDesk 隔离。本示例不收集凭据或服务器地址。'),'nd-muted')); info.append(text); main.append(info);
    main.append(button(t('Reset example','重置示例'),'reset',function () {
      state={page:'devices',theme:'light',query:'',filter:'all',mapping:true,space:0,device:0};
      devices.forEach(function (d,index) { d.favorite=index === 0; }); root.dataset.theme='light'; updateTheme(); render(); say(t('Example reset.','示例已重置。'));
    }));
  }
  function render() {
    var focused=document.activeElement;
    var action=root.contains(focused) ? focused.dataset.action : undefined;
    main.textContent='';
    nav.querySelectorAll('button').forEach(function (b) {
      if (b.dataset.action === state.page) b.setAttribute('aria-current','page'); else b.removeAttribute('aria-current');
    });
    if (state.page === 'devices') renderDevices(); else if (state.page === 'session') renderSession(); else renderSettings();
    if (action) {
      var replacement=root.querySelector('[data-action="'+action+'"]');
      if (!replacement) replacement=nav.querySelector('[aria-current="page"]');
      if (replacement) replacement.focus({preventScroll:true});
    }
  }
  updateTheme(); render();
  say(t('Interactive example ready. Try searching for a device or exploring the session tools.','交互示例已就绪，试试搜索设备或体验会话工具。'));
})();
