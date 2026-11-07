// Тот же window.yoru, что даёт preload.js в Electron, но вызовы идут в Rust (src-tauri/src).
(() => {
  // Объект Tauri берём при каждом вызове: при загрузке страницы его может ещё не быть.
  const invoke = (cmd, args) => window.__TAURI__.core.invoke(cmd, args);
  const listen = (ch, fn) => window.__TAURI__.event.listen(ch, fn);
  const wrap = p => p.then(data => ({ data }), e => ({ error: String(e) }));
  const on = ch => fn => { const un = listen(ch, e => Array.isArray(e.payload) ? fn(...e.payload) : fn(e.payload)); return () => un.then(f => f()); };
  const nav = navigator.userAgent;
  const platform = /Mac/.test(nav) ? 'darwin' : /Win/.test(nav) ? 'win32' : 'linux';
  window.yoru = {
    platform,
    api: (path, params, auth) => wrap(invoke('api', { path, params: params || {}, auth: !!auth })),
    login: (email, password) => wrap(invoke('login', { email, password })),
    logout: () => wrap(invoke('logout')),
    signedIn: () => invoke('signed_in'),
    text: url => wrap(invoke('text', { url })),
    openExternal: url => invoke('open_external', { url }),
    version: () => invoke('version'),
    fullscreen: on => invoke('fullscreen', { on: on ?? null }),
    download: (url, name) => invoke('download', { url, name }),
    showFile: file => invoke('show_file', { file }),
    checkUpdate: () => wrap(invoke('check_update')),
    installUpdate: (url, name) => wrap(invoke('install_update', { url, name })),
    onUpdateProgress: on('updateProgress'),
    onDownloadProgress: on('downloadProgress'),
    hasBattery: () => invoke('has_battery'),
    serverSpeed: url => invoke('server_speed', { url }),
    saveData: json => invoke('save_data', { json, last: false }).catch(() => {}),
    dl: {
      list: () => invoke('dl_list'),
      enqueue: meta => wrap(invoke('dl_enqueue', { meta })),
      retry: id => invoke('dl_retry', { id }),
      remove: ids => invoke('dl_remove', { ids }),
      text: id => wrap(invoke('dl_text', { id })),
      space: () => invoke('dl_space'),
      onChanged: on('dlChanged'),
      onDone: on('dlDone'),
      onServerFailed: on('serverFailed')
    },
    // Скачанные серии отдаёт Rust по своей схеме; WebView2 на Windows видит её как http://yoru.localhost.
    dlUrl: name => (platform === 'win32' ? 'http://yoru.localhost/dl/' : 'yoru://dl/') + encodeURIComponent(name),
    onFullscreen: on('fullscreenChanged')
  };
  // Закрытие окна и выход: Rust просит сохранить прогресс и настройки в файл, затем приложение закрывается.
  const dump = () => {
    try {
      const data = {};
      for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); data[k] = localStorage.getItem(k); }
      return JSON.stringify({ format: 1, saved: Date.now(), data });
    } catch { return ''; }
  };
  window.__yoruFlush = () => invoke('save_data', { json: dump(), last: true });
  // Выход из Dock или при завершении сеанса проходит мимо приложения, но перед ним окно теряет фокус.
  addEventListener('blur', () => invoke('save_data', { json: dump(), last: false }).catch(() => {}));
  // В WebKit нет -webkit-app-region, поэтому заголовок окна на Mac делаем сами: верхняя полоса 40 px
  // по всей ширине (и в плеере), кроме кнопок и полей. Двойной щелчок разворачивает окно, как в macOS.
  if (platform !== 'darwin') return;
  const win = () => window.__TAURI__.window.getCurrentWindow();
  addEventListener('mousedown', e => {
    if (e.button !== 0 || e.clientY > 40 || e.target.closest('button, a, input, select, textarea, label, [data-a], .menu, .p-seek')) return;
    e.preventDefault();
    if (e.detail === 2) win().toggleMaximize(); else win().startDragging();
  });
})();
