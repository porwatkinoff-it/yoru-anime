// Серии для просмотра без интернета — только на компьютерах с батареей, как на телефоне.
// Файлы и index.json лежат в userData/Downloads; ссылка на видео берётся заново при каждом запуске
// загрузки (ссылки сайта быстро устаревают), а недокачанный файл продолжается с того же места.
const { app, ipcMain, net } = require('electron');
const path = require('path');
const fs = require('fs');
const { execFile } = require('child_process');

module.exports = function downloads({ api, UA, send, wrap }) {
  const dir = path.join(app.getPath('userData'), 'Downloads');
  const indexFile = path.join(dir, 'index.json');
  fs.mkdirSync(dir, { recursive: true });
  let items = [];
  try { items = JSON.parse(fs.readFileSync(indexFile, 'utf8')); } catch {}
  // После перезапуска незаконченные снова встают в очередь.
  for (const d of items) if (d.state === 'running') d.state = 'queued';
  let active = null;  // { id, abort }

  const save = () => { try { fs.writeFileSync(indexFile + '.tmp', JSON.stringify(items)); fs.renameSync(indexFile + '.tmp', indexFile); } catch {} };
  const publish = () => send('dlChanged', items);
  const changed = () => { save(); publish(); };
  const find = id => items.find(d => d.id === id);
  const file = name => path.join(dir, path.basename(name));

  // ---------- Батарея ----------
  let battery = null;
  function hasBattery() {
    if (battery) return battery;
    battery = new Promise(resolve => {
      if (process.platform === 'darwin') execFile('/usr/bin/pmset', ['-g', 'batt'], (e, out) => resolve(!e && /InternalBattery/.test(out)));
      else if (process.platform === 'win32') execFile('powershell.exe', ['-NoProfile', '-Command', '(Get-CimInstance Win32_Battery | Measure-Object).Count'], { windowsHide: true }, (e, out) => resolve(!e && +String(out).trim() > 0));
      else {
        try { resolve(fs.readdirSync('/sys/class/power_supply').some(n => { try { return fs.readFileSync(`/sys/class/power_supply/${n}/type`, 'utf8').trim() === 'Battery'; } catch { return false; } })); }
        catch { resolve(false); }
      }
    });
    return battery;
  }

  // ---------- Очередь ----------
  function pickStream(embed, quality) {
    const list = (embed.stream || []).map(s => ({ height: +s.height || 0, url: (s.urls || [])[0] })).filter(s => s.url);
    // Запасной вариант — ссылки «download»: без входа на сайте в браузере они часто дают 403.
    if (!list.length) for (const s of embed.download || []) if (s.url) list.push({ height: +s.height || 0, url: s.url });
    list.sort((a, b) => b.height - a.height);
    return list.find(s => s.height <= quality) || list[list.length - 1];
  }
  async function fetchSubs(url) {
    const res = await net.fetch(new URL(url, 'https://smotret-anime.app').href, { headers: { 'User-Agent': UA } });
    if (!res.ok) throw httpError(res.status);
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length > 8 << 20) throw new Error('bad-subs');
    let text = buf.toString('utf8');
    if (text.includes('�')) text = new TextDecoder('windows-1251').decode(buf);
    if (text.includes('[Events]')) return { text, ext: 'ass' };
    if (text.includes('-->')) return { text, ext: /^﻿?WEBVTT/.test(text) ? 'vtt' : 'srt' };
    throw new Error('bad-subs');
  }
  const httpError = status => Object.assign(new Error('HTTP ' + status), { status });
  function message(e) {
    if (e.status === 403 || e.status === 404 || e.status === 410) return 'Ссылка устарела — нажмите, чтобы повторить';
    if (e.code === 'ENOSPC') return 'Не хватает места на устройстве';
    if (e.message === 'bad-subs') return 'Субтитры не скачались — нажмите, чтобы повторить';
    if (/ERR_INTERNET|ERR_NAME|ERR_NETWORK|ERR_CONNECTION|ERR_ADDRESS|Не удалось подключиться/.test(e.message)) return 'Нет сети — повторите позже';
    return e.userMessage || 'Загрузка прервалась';
  }

  async function run(d) {
    const ctrl = new AbortController();
    active = { id: d.id, abort: () => ctrl.abort() };
    d.state = 'running'; d.error = ''; changed();
    try {
      let embed;
      try { embed = await api('translations/embed/' + d.translationId, {}, true) || {}; }
      catch (e) { throw Object.assign(new Error(e.message), { userMessage: e.message }); }
      const s = pickStream(embed, d.quality);
      if (!s) throw Object.assign(new Error('no-video'), { userMessage: 'Сайт не вернул видео для этого перевода' });
      // Субтитры — первыми: серия с субтитрами без них бесполезна.
      if (embed.subtitlesUrl && !d.subtitles) {
        const sub = await fetchSubs(embed.subtitlesUrl);
        d.subtitles = `${d.id}.${sub.ext}`;
        fs.writeFileSync(file(d.subtitles), sub.text);
      }
      if (d.translationKind.startsWith('sub') && !d.subtitles) throw Object.assign(new Error('no-subs'), { userMessage: 'Для этого перевода нет субтитров' });
      // Другое качество — другой файл: начинаем заново.
      const part = file(d.video + '.part');
      if (d.height && d.height !== s.height) fs.rmSync(part, { force: true });
      d.height = s.height;
      let have = 0; try { have = fs.statSync(part).size; } catch {}
      const site = new URL(s.url, 'https://smotret-anime.app');
      const get = u => net.fetch(u.href, { headers: { 'User-Agent': UA, ...(have ? { Range: `bytes=${have}-` } : {}) }, signal: ctrl.signal });
      // Через самый быстрый из проверенных серверов; не ответил — по ссылке сайта.
      let res = null;
      if (d.server && /^ru-/.test(site.host) && site.host !== d.server) {
        const fast = new URL(site.href); fast.host = d.server;
        try { res = await get(fast); if (!res.ok) res = null; } catch { if (ctrl.signal.aborted) throw new Error('aborted'); }
        if (!res) { send('serverFailed', d.server); d.server = ''; }
      }
      res = res || await get(site);
      if (res.status === 416) { have = 0; fs.rmSync(part, { force: true }); throw httpError(410); }
      if (!res.ok) throw httpError(res.status);
      if (res.status !== 206) have = 0;
      const len = +res.headers.get('content-length') || 0;
      d.total = len ? have + len : 0; d.bytes = have;
      const out = fs.createWriteStream(part, { flags: have ? 'a' : 'w' });
      let failed = null; out.on('error', e => { failed = e; });
      const reader = res.body.getReader();
      let last = 0;
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          if (failed) throw failed;
          // Буфер пишется как есть, без копии; проценты в окно — раз в секунду.
          if (!out.write(Buffer.from(value.buffer, value.byteOffset, value.byteLength))) await new Promise(r => out.once('drain', r));
          d.bytes += value.length;
          if (Date.now() - last > 1000) { last = Date.now(); publish(); }
        }
      } finally { await new Promise(r => out.end(r)); }
      if (failed) throw failed;
      if (d.total && d.bytes < d.total) throw new Error('short');
      fs.renameSync(part, file(d.video));
      d.state = 'done'; d.total = d.bytes; d.finished = Date.now();
      changed();
      send('dlDone', d);
    } catch (e) {
      if (!find(d.id)) return;  // удалили во время загрузки
      if (ctrl.signal.aborted) { d.state = 'queued'; return; }
      d.state = 'failed'; d.error = message(e); changed();
    } finally {
      if (active?.id === d.id) active = null;
      setImmediate(next);
    }
  }
  function next() {
    if (active) return;
    const d = items.find(x => x.state === 'queued');
    if (d) run(d);
  }

  function remove(ids) {
    for (const id of ids) {
      const d = find(id); if (!d) continue;
      if (active?.id === id) active.abort();
      items = items.filter(x => x !== d);
      for (const f of [d.video, d.video + '.part', d.subtitles]) if (f) fs.rmSync(file(f), { force: true });
    }
    changed();
  }

  ipcMain.handle('hasBattery', () => hasBattery());
  ipcMain.handle('dlList', () => items);
  ipcMain.handle('dlEnqueue', wrap(async meta => {
    const old = find(meta.id);
    if (old && old.state !== 'failed') return old;
    if (old) remove([old.id]);
    const d = {
      id: meta.id, seriesId: meta.seriesId, series: meta.series, episodeTitle: meta.episodeTitle, episodeNumber: meta.episodeNumber,
      translationId: meta.translationId, translationTitle: meta.translationTitle, translationKind: meta.translationKind, translationSignature: meta.translationSignature,
      quality: meta.quality || 720, server: meta.server || '', height: 0, video: `${meta.id}.mp4`, subtitles: '', bytes: 0, total: 0, state: 'queued', error: '', created: Date.now()
    };
    items.push(d); changed(); next();
    return d;
  }));
  ipcMain.handle('dlRetry', (_e, id) => { const d = find(id); if (d && d.state === 'failed') { d.state = 'queued'; d.error = ''; changed(); next(); } });
  ipcMain.handle('dlRemove', (_e, ids) => remove([].concat(ids)));
  ipcMain.handle('dlText', wrap(async id => { const d = find(id); if (!d?.subtitles) throw new Error('Нет субтитров'); return fs.readFileSync(file(d.subtitles), 'utf8'); }));
  ipcMain.handle('dlSpace', () => {
    let free = 0;
    try { const s = fs.statfsSync(dir); free = s.bavail * s.bsize; } catch {}
    return { used: items.reduce((n, d) => n + (d.bytes || 0), 0), free };
  });

  // Файлы отдаются странице как yoru://dl/<имя>, с поддержкой перемотки (Range).
  function serve(req) {
    const name = path.basename(decodeURIComponent(new URL(req.url).pathname));
    const f = path.join(dir, name);
    let size;
    try { size = fs.statSync(f).size; } catch { return new Response('Not found', { status: 404 }); }
    const type = name.endsWith('.mp4') ? 'video/mp4' : 'text/plain; charset=utf-8';
    const m = /bytes=(\d*)-(\d*)/.exec(req.headers.get('range') || '');
    let start = 0, end = size - 1, status = 200;
    if (m) {
      start = m[1] ? +m[1] : Math.max(0, size - +m[2]);
      end = m[1] && m[2] ? Math.min(+m[2], size - 1) : size - 1;
      if (start > end || start >= size) return new Response('', { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
      status = 206;
    }
    // Куски по 1 МБ без копирования: в 16 раз меньше пробуждений, чем со стандартными 64 КБ.
    const stream = fs.createReadStream(f, { start, end, highWaterMark: 1 << 20 });
    const body = new ReadableStream({
      start(c) { stream.on('data', b => { c.enqueue(new Uint8Array(b.buffer, b.byteOffset, b.byteLength)); if (c.desiredSize <= 0) stream.pause(); }); stream.on('end', () => c.close()); stream.on('error', e => c.error(e)); },
      pull() { stream.resume(); },
      cancel() { stream.destroy(); }
    });
    return new Response(body, { status, headers: { 'Content-Type': type, 'Content-Length': String(end - start + 1), 'Accept-Ranges': 'bytes', ...(status === 206 ? { 'Content-Range': `bytes ${start}-${end}/${size}` } : {}) } });
  }

  return { serve, start: () => { publish(); next(); } };
};
