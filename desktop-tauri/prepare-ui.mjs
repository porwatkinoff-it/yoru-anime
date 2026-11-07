// Интерфейс общий с Electron-версией: копируем desktop/src/ui и подключаем мост к Rust вместо preload.js.
import { cpSync, readFileSync, writeFileSync, rmSync, copyFileSync } from 'fs';
const src = new URL('../desktop/src/ui/', import.meta.url), out = new URL('./dist-ui/', import.meta.url);
rmSync(out, { recursive: true, force: true });
cpSync(src, out, { recursive: true });
copyFileSync(new URL('./web/bridge.js', import.meta.url), new URL('bridge.js', out));
const index = new URL('index.html', out);
let html = readFileSync(index, 'utf8');
// WebKit не считает своей страницу со схемой tauri://, поэтому 'self' дополняем адресами Tauri.
html = html.replace(/'self'/g, "'self' tauri: http://tauri.localhost")
           .replace("connect-src 'self'", "connect-src ipc: http://ipc.localhost 'self'")
           .replace('<script type="module" src="vendor/jassub.js">', '<script src="bridge.js"></script>\n<script type="module" src="vendor/jassub.js">');
if (!html.includes('bridge.js')) throw new Error('не удалось подключить bridge.js');
writeFileSync(index, html);
// JASSUB узнаёт WebKit по User-Agent Safari, а у нас он «NightAnime/1.0 (macOS)», как у мобильных версий.
// Без этого он отдаёт WebGL кусок памяти, который WebKit не принимает, и субтитры не рисуются.
// На Mac и Linux Tauri всегда работает на WebKit, на Windows — на Chromium (WebView2).
const worker = new URL('vendor/jassub-worker.js', out);
const safari = 'Na=/applewebkit\\/[\\d.]+ \\(khtml, like gecko\\)(?!.*chrome\\/)/.test(rr)';
const js = readFileSync(worker, 'utf8');
if (!js.includes(safari)) throw new Error('JASSUB изменился: проверьте определение WebKit в jassub-worker.js');
writeFileSync(worker, js.replace(safari, safari + '||/^nightanime\\/[\\d.]+ \\((macos|linux)\\)/.test(rr)'));
console.log('dist-ui готов');
