// Yoru Anime для компьютера: окно, сеть к Anime 365 и обновления. Интерфейс — в src/ui.
// Сеть идёт из основного процесса: у сайта нет CORS, а токен не попадает в страницу.
const { app, BrowserWindow, ipcMain, net, protocol, safeStorage, session, shell, nativeTheme, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

const BASE = 'https://smotret-anime.app';
const UA = `NightAnime/1.0 (${process.platform === 'darwin' ? 'macOS' : process.platform === 'win32' ? 'Windows' : 'Linux'})`;
const REPO = 'porwatkinoff-it/yoru-anime';
const UI = path.join(__dirname, 'ui');

protocol.registerSchemesAsPrivileged([{ scheme: 'yoru', privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true } }]);
if (!app.requestSingleInstanceLock()) app.quit();

let win;
// Токен входа Anime 365. На Mac шифрование Electron держит свой ключ в связке ключей, а приложение подписано без
// сертификата Apple: после каждого обновления macOS заново просит пароль от связки, а при отказе вход ломается.
// Поэтому на Mac токен лежит в файле, который может читать только этот пользователь; на Windows и Linux — как раньше.
const plainToken = process.platform === 'darwin';
const tokenFile = () => path.join(app.getPath('userData'), plainToken ? 'token' : 'token.bin');
function readToken() {
  try {
    if (plainToken) {
      // token.bin прошлых версий без связки ключей не прочитать: удаляем его, и войти нужно один раз заново.
      fs.rmSync(path.join(app.getPath('userData'), 'token.bin'), { force: true });
      return fs.readFileSync(tokenFile(), 'utf8').trim();
    }
    const b = fs.readFileSync(tokenFile());
    return safeStorage.isEncryptionAvailable() ? safeStorage.decryptString(b) : b.toString('utf8');
  } catch { return ''; }
}
function saveToken(t) {
  try {
    if (!t) return fs.rmSync(tokenFile(), { force: true });
    const data = plainToken ? t : safeStorage.isEncryptionAvailable() ? safeStorage.encryptString(t) : Buffer.from(t);
    fs.writeFileSync(tokenFile(), data, { mode: 0o600 });
  } catch {}
}
let token = '';

async function api(p, params = {}, auth = false) {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null && v !== '') q.append(k, String(v));
  if (auth) { if (!token) throw new Error('Войдите в аккаунт Anime 365'); q.append('access_token', token); }
  const qs = q.toString();
  const url = BASE + '/api/' + p + (qs ? (p.includes('?') ? '&' : '?') + qs : '');
  let res;
  try { res = await net.fetch(url, { headers: { 'User-Agent': UA }, cache: 'no-store' }); }
  catch { throw new Error('Не удалось подключиться к Anime 365. Проверьте интернет и повторите.'); }
  let j;
  try { j = await res.json(); } catch { throw new Error('Сайт вернул неожиданный ответ. Повторите позже.'); }
  if (j && j.error) throw new Error(j.error.message || 'Ошибка Anime 365');
  if (!j || j.data === undefined) throw new Error('Пустой ответ Anime 365');
  return j.data;
}
const wrap = fn => async (_e, ...a) => { try { return { data: await fn(...a) }; } catch (e) { return { error: e.message || String(e) }; } };

ipcMain.handle('api', wrap((p, params, auth) => api(p, params, auth)));
ipcMain.handle('login', wrap(async (email, password) => {
  const d = await api('login', { email, password, app: 'universal' });
  if (!d || !d.access_token) throw new Error('Не удалось выполнить вход');
  token = d.access_token; saveToken(token); return true;
}));
ipcMain.handle('logout', wrap(async () => { token = ''; saveToken(''); return true; }));
ipcMain.handle('signedIn', () => !!token);
// Текст по ссылке сайта: субтитры .ass и страница каталога (для сезонов).
ipcMain.handle('text', wrap(async url => {
  const u = new URL(url, BASE);
  if (!/^https?:$/.test(u.protocol)) throw new Error('Неверная ссылка');
  const res = await net.fetch(u.href, { headers: { 'User-Agent': UA } });
  if (!res.ok) throw new Error('HTTP ' + res.status);
  return await res.text();
}));
// Скорость видеосервера: первые 4 МБ одного и того же файла (как в Android- и iOS-версиях).
ipcMain.handle('serverSpeed', async (_e, url) => {
  const u = new URL(url);
  if (u.protocol !== 'https:' || !/^ru-[^.]+\./.test(u.host)) return { error: 'недоступен' };
  const ctrl = new AbortController(), timer = setTimeout(() => ctrl.abort(), 15000);
  const start = Date.now();
  try {
    const res = await net.fetch(u.href, { headers: { 'User-Agent': UA, Range: 'bytes=0-4194303' }, cache: 'no-store', signal: ctrl.signal });
    if (!res.ok) return { error: `не отдал файл (${res.status})` };
    const size = (await res.arrayBuffer()).byteLength;
    if (size <= 100000) return { error: `не отдал файл (${res.status})` };
    return { mbit: size * 8 / 1e6 / Math.max((Date.now() - start) / 1000, 0.001) };
  } catch { return { error: ctrl.signal.aborted ? 'слишком медленно' : 'недоступен' }; }
  finally { clearTimeout(timer); }
});
ipcMain.handle('openExternal', (_e, url) => { if (/^https:\/\//.test(url)) shell.openExternal(url); });
ipcMain.handle('version', () => app.getVersion());
ipcMain.handle('fullscreen', (_e, on) => { if (win) win.setFullScreen(on ?? !win.isFullScreen()); return win?.isFullScreen(); });

// Скачивание серии: папка «Загрузки/Yoru Anime», прогресс уходит в интерфейс.
ipcMain.handle('download', (_e, url, name) => {
  const dir = path.join(app.getPath('downloads'), 'Yoru Anime');
  fs.mkdirSync(dir, { recursive: true });
  pendingNames.set(url, path.join(dir, name.replace(/[\\/:*?"<>|]+/g, ' ').trim()));
  win.webContents.downloadURL(url);
});
ipcMain.handle('showFile', (_e, f) => shell.showItemInFolder(f));
const pendingNames = new Map();
// Загрузки внутри приложения (ноутбуки): src/downloads.js.
const offline = require('./downloads')({ api, UA, wrap, send: (ch, ...a) => win?.webContents.send(ch, ...a) });

// ---------- Обновления из GitHub Releases ----------
const numeric = v => String(v).replace(/^v/, '').split('.').map(n => parseInt(n, 10) || 0);
const newer = (a, b) => { const x = numeric(a), y = numeric(b); for (let i = 0; i < Math.max(x.length, y.length); i++) { if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0); } return false; };
function assetFor(assets) {
  const arch = process.arch === 'arm64' ? 'arm64' : 'x64';
  const find = re => assets.find(a => re.test(a.name));
  if (process.platform === 'darwin') return find(new RegExp(`-mac-${arch}\\.zip$`));
  if (process.platform === 'win32') return find(new RegExp(`-win-${arch}-setup\\.exe$`)) || find(/-win-.*setup\.exe$/);
  if (process.env.APPIMAGE) return find(new RegExp(`-linux-${arch === 'x64' ? 'x86_64' : 'arm64'}\\.AppImage$`));
  return null;
}
ipcMain.handle('checkUpdate', wrap(async () => {
  const res = await net.fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { 'User-Agent': UA, Accept: 'application/vnd.github+json' } });
  if (!res.ok) throw new Error('GitHub не ответил (' + res.status + ')');
  const r = await res.json();
  const version = String(r.tag_name || '').replace(/^v/, '');
  const asset = assetFor(r.assets || []);
  return { version, current: app.getVersion(), available: newer(version, app.getVersion()), notes: r.body || '', page: r.html_url, asset: asset ? { name: asset.name, url: asset.browser_download_url, size: asset.size } : null, auto: !!asset && app.isPackaged };
}));
async function fetchFile(url, file, onProgress) {
  const res = await net.fetch(url, { headers: { 'User-Agent': UA } });
  if (!res.ok) throw new Error('HTTP ' + res.status);
  const total = +res.headers.get('content-length') || 0;
  const out = fs.createWriteStream(file);
  const reader = res.body.getReader();
  let done = 0, last = 0;
  for (;;) {
    const { value, done: end } = await reader.read();
    if (end) break;
    if (!out.write(Buffer.from(value.buffer, value.byteOffset, value.byteLength))) await new Promise(r => out.once('drain', r));
    done += value.length;
    if (done - last > 1 << 20) { last = done; onProgress(done, total); }
  }
  await new Promise((r, j) => out.end(e => e ? j(e) : r()));
}
ipcMain.handle('installUpdate', wrap(async (url, name) => {
  const tmp = fs.mkdtempSync(path.join(app.getPath('temp'), 'yoru-update-'));
  const file = path.join(tmp, name);
  await fetchFile(url, file, (d, t) => win?.webContents.send('updateProgress', d, t));
  const pid = process.pid;
  if (process.platform === 'darwin') {
    // Приложение заменяется целиком после выхода; файл скачан самим приложением, поэтому без карантина.
    const bundle = path.resolve(process.execPath, '../../..');
    const unpack = path.join(tmp, 'app');
    await new Promise((r, j) => spawn('/usr/bin/ditto', ['-x', '-k', file, unpack]).on('exit', c => c === 0 ? r() : j(new Error('Не удалось распаковать обновление'))));
    const fresh = fs.readdirSync(unpack).find(n => n.endsWith('.app'));
    if (!fresh) throw new Error('В архиве нет приложения');
    const script = `while kill -0 ${pid} 2>/dev/null; do sleep 0.3; done; rm -rf "${bundle}" && mv "${path.join(unpack, fresh)}" "${bundle}"; open "${bundle}"; rm -rf "${tmp}"`;
    spawn('/bin/sh', ['-c', script], { detached: true, stdio: 'ignore' }).unref();
  } else if (process.platform === 'win32') {
    spawn(file, ['/S', '--force-run'], { detached: true, stdio: 'ignore' }).unref();
  } else {
    const target = process.env.APPIMAGE;
    fs.chmodSync(file, 0o755);
    const script = `while kill -0 ${pid} 2>/dev/null; do sleep 0.3; done; mv -f "${file}" "${target}" && "${target}" & `;
    spawn('/bin/sh', ['-c', script], { detached: true, stdio: 'ignore' }).unref();
  }
  setTimeout(() => app.quit(), 300);
  return true;
}));

// ---------- Окно ----------
function serve() {
  protocol.handle('yoru', req => {
    const u = new URL(req.url);
    if (u.host === 'dl') return offline.serve(req);
    const rel = decodeURIComponent(u.pathname).replace(/^\/+/, '') || 'index.html';
    const file = path.normalize(path.join(UI, rel));
    if (!file.startsWith(UI)) return new Response('Not found', { status: 404 });
    return net.fetch('file://' + file);
  });
}
function createWindow() {
  win = new BrowserWindow({
    width: 1360, height: 860, minWidth: 900, minHeight: 600,
    backgroundColor: '#0a101c', title: 'Yoru Anime', show: false,
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    autoHideMenuBar: true,
    icon: path.join(__dirname, '..', 'build', 'icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true, nodeIntegration: false }
  });
  win.removeMenu?.();
  win.once('ready-to-show', () => win.show());
  win.webContents.once('did-finish-load', () => offline.start());
  win.loadURL('yoru://app/index.html');
  win.on('enter-full-screen', () => win.webContents.send('fullscreenChanged', true));
  win.on('leave-full-screen', () => win.webContents.send('fullscreenChanged', false));
  // Внешние ссылки — в браузере, внутри окна остаётся только приложение.
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https:\/\//.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith('yoru://')) e.preventDefault(); });
}

app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
app.whenReady().then(() => {
  nativeTheme.themeSource = 'dark';
  token = readToken();
  serve();
  const s = session.defaultSession;
  // Видео и постеры просим с тем же User-Agent, что у мобильных версий.
  s.webRequest.onBeforeSendHeaders({ urls: ['https://*/*'] }, (d, cb) => {
    if (!/github|googleapis|gstatic/.test(d.url)) d.requestHeaders['User-Agent'] = UA;
    cb({ requestHeaders: d.requestHeaders });
  });
  s.setPermissionRequestHandler((_wc, perm, cb) => cb(['fullscreen', 'local-fonts'].includes(perm)));
  s.on('will-download', (_e, item) => {
    const target = pendingNames.get(item.getURL());
    pendingNames.delete(item.getURL());
    if (target) item.setSavePath(target);
    const id = item.getURL();
    // Прогресс в окно — не чаще раза в секунду.
    let last = 0;
    item.on('updated', () => {
      if (Date.now() - last < 1000) return;
      last = Date.now();
      win?.webContents.send('downloadProgress', { id, name: path.basename(item.getSavePath()), received: item.getReceivedBytes(), total: item.getTotalBytes() });
    });
    item.once('done', (_ev, state) => win?.webContents.send('downloadProgress', { id, name: path.basename(item.getSavePath()), state, file: item.getSavePath() }));
  });
  createWindow();
  app.on('activate', () => { if (!BrowserWindow.getAllWindows().length) createWindow(); });
});
app.on('window-all-closed', () => app.quit());
