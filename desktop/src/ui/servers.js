// Видеосерверы Anime 365. Сайт в каждой ссылке даёт случайный сервер (ru-NNNNNN.<домен>), и любой из них
// отдаёт тот же файл по той же ссылке. Скорость у них разная, поэтому приложение запоминает серверы,
// которые встречало, проверяет их скорость и подставляет самый быстрый; ссылка сайта остаётся запасной.
import { S, api, makeURL } from './data.js';

export const auto = () => S.get('server-auto', true);
export const setAuto = on => S.set('server-auto', on);
export const best = () => S.get('server-best');
export const seen = () => S.get('servers-seen', []);
export const speeds = () => S.get('servers-mbit', {});
export const tested = () => S.get('servers-tested', 0);
const host = u => { try { return new URL(u).host; } catch { return ''; } };
const isVideo = h => /^ru-/.test(h) && h.split('.').length >= 3;

// Запоминаем серверы из каждого ответа сайта (не больше 12 последних).
export function remember(urls) {
  const list = seen();
  for (const h of urls.map(host)) if (isVideo(h) && !list.includes(h)) list.unshift(h);
  S.set('servers-seen', list.slice(0, 12));
}
// Ссылка через самый быстрый сервер первой, ссылка сайта — запасной.
export function preferred(url) {
  const b = best(), h = host(url);
  if (!auto() || !b || !isVideo(h) || h === b) return [url];
  const u = new URL(url); u.host = b;
  return [u.href, url];
}
// Сервер не ответил — больше не подставляем его, пока не будет новой проверки.
export function failed(url) { if (host(url) === best()) S.del('server-best'); }

// Файл для проверки — серия, которую включали последней, в качестве ближе всего к 720p.
async function sample() {
  const t = S.get('lp-translation');
  if (!(+t?.id > 0)) throw new Error('Сначала включите любую серию — по ней проверяются серверы');
  const d = await api('translations/embed/' + t.id, {}, true) || {};
  const streams = (d.stream || []).map(s => ({ height: +s.height || 0, url: makeURL((s.urls || [])[0] || '') })).filter(s => s.url);
  remember(streams.map(s => s.url));
  if (!streams.length) throw new Error('Сайт не дал ссылку на видео — проверьте подписку');
  return streams.reduce((a, b) => Math.abs(b.height - 720) < Math.abs(a.height - 720) ? b : a).url;
}

// Проверка: один и тот же файл (первые 4 МБ) с каждого сервера, по очереди.
export async function test(each) {
  const url = await sample();
  const hosts = seen();
  if (!hosts.includes(host(url))) hosts.unshift(host(url));
  const out = [];
  for (const h of hosts) {
    const u = new URL(url); u.host = h;
    const r = await window.yoru.serverSpeed(u.href);
    const res = { host: h, mbit: r.mbit ?? null, error: r.error || '' };
    out.push(res); each(res);
  }
  const ok = out.filter(r => r.mbit != null).sort((a, b) => b.mbit - a.mbit);
  S.set('servers-mbit', Object.fromEntries(ok.map(r => [r.host, r.mbit]))); S.set('servers-tested', Date.now());
  // Неработающие серверы забываем, быстрые — в начало списка.
  S.set('servers-seen', ok.map(r => r.host));
  if (ok.length) S.set('server-best', ok[0].host); else S.del('server-best');
  return out;
}
