// Шикимори и 4K — как в iOS-версии. id на Шикимори совпадает с id MyAnimeList (myAnimeListId у Anime 365).
// Запросы идут через Rust (window.yoru.text), без CORS. Карточки просят оценку, когда появляются на экране:
// id копятся и уходят пачками до 50 (Шикимори пускает ~5 запросов в секунду); ответ хранится 3 дня.
// Есть ли 4K, узнаём по переводам сериала (не больше трёх запросов сразу), ответ хранится двое суток.
import * as D from './data.js';

export const SITE = 'https://shikimori.io';
const S = D.S;
const DAY = 86400e3;

async function json(path) {
  for (let i = 0; i < 3; i++) {
    const r = await window.yoru.text(SITE + path);
    if (!r.error) return JSON.parse(r.data);
    if (!/429/.test(r.error) || i === 2) throw new Error(r.error);
    await new Promise(f => setTimeout(f, 700 * (i + 1)));
  }
}
const fresh = (map, ttl) => { const now = Date.now(), out = {}; for (const [k, v] of Object.entries(map || {})) if (now - v[1] < ttl) out[k] = v; return out; };

// ---------- Оценки ----------
const scores = fresh(S.get('shiki-scores', {}), 3 * DAY);   // malId → [оценка, время]
const asked = new Set(), queue = new Set();
let running = false, saveTimer = 0;
export const score = it => it.malId > 0 && scores[it.malId] ? scores[it.malId][0] : null;
const keep = () => { clearTimeout(saveTimer); saveTimer = setTimeout(() => S.set('shiki-scores', scores), 2000); };
function want(mal) {
  if (!(mal > 0) || scores[mal] || asked.has(mal)) return;
  asked.add(mal); queue.add(mal);
  if (!running) { running = true; setTimeout(drain, 400); }
}
async function drain() {
  while (queue.size) {
    const ids = [...queue].slice(0, 50); ids.forEach(id => queue.delete(id));
    try {
      const list = await json('/api/animes?limit=50&ids=' + ids.join(','));
      const now = Date.now(), got = {};
      for (const o of list || []) got[o.id] = +o.score || 0;
      // Нет у Шикимори — запоминаем 0, чтобы не спрашивать снова.
      for (const id of ids) scores[id] = [got[id] || 0, now];
      paint('shiki', ids);
    } catch { ids.forEach(id => asked.delete(id)); }
    await new Promise(f => setTimeout(f, 400));
  }
  running = false; keep();
}

// ---------- 4K ----------
const uhd = fresh(S.get('uhd-cache', {}), 2 * DAY);   // id сериала → [1/0, время]
const uhdAsked = new Set(), uhdQueue = [];
let uhdRunning = 0, uhdTimer = 0;
export const hasUhd = id => uhd[id]?.[0] === 1;
function wantUhd(id) {
  if (!(id > 0) || uhd[id] || uhdAsked.has(id)) return;
  uhdAsked.add(id); uhdQueue.push(id); pump();
}
function pump() {
  while (uhdRunning < 3 && uhdQueue.length) {
    const id = uhdQueue.shift(); uhdRunning++;
    D.api('translations', { seriesId: id, isActive: 1, limit: 1000, fields: 'height' })
      .then(list => { uhd[id] = [(list || []).some(t => +t.height >= 2160) ? 1 : 0, Date.now()]; paint('uhd', [id]); }, () => uhdAsked.delete(id))
      .finally(() => { uhdRunning--; clearTimeout(uhdTimer); uhdTimer = setTimeout(() => S.set('uhd-cache', uhd), 2000); pump(); });
  }
}

// ---------- Разметка ----------
// Подпись карточки: «365 8,1 · Shiki 8,3 · ТВ» — год прячем, когда видны обе оценки (иначе строка не влезает).
const num = s => s > 0 ? s.toFixed(1).replace('.', ',') : '';
const sc = (label, s) => s > 0 ? `<span class="sc ${D.scoreClass(s)}"><i>${label}</i>${num(s)}</span>` : '';
export function caption(it) {
  const sh = score(it);
  const parts = [sc('365', it.score), sc('Shiki', sh)].filter(Boolean);
  const rest = parts.length > 1 ? it.kind : it.subtitle;
  return parts.join('') + (rest ? `<span class="rest">${escText(rest)}</span>` : '');
}
const escText = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export const capHTML = it => (remember(it), `<div class="s cap" data-sk="${it.id}" data-mal="${it.malId || 0}">${caption(it)}</div>`);
export const uhdBadge = it => `<span class="badge-4k" data-uhd="${it.id}" ${hasUhd(it.id) ? '' : 'hidden'}>4K</span>`;
export function scoresLine(it) {
  const sh = score(it);
  return `<span class="score-text" data-skd="${it.id}" data-mal="${it.malId || 0}">${sc('365', it.score)}${sc('Shiki', sh)}</span>${hasUhd(it.id) ? '<span class="tag-4k">4K</span>' : ''}`;
}

// Карточки, попавшие в DOM, ждут показа на экране; тогда спрашиваем оценку и 4K.
const items = new Map();
export const remember = it => { items.set(it.id, it); return it; };
const io = new IntersectionObserver(entries => {
  for (const e of entries) {
    if (!e.isIntersecting) continue;
    io.unobserve(e.target);
    const id = +e.target.dataset.sk, mal = +e.target.dataset.mal;
    want(mal); wantUhd(id);
  }
}, { rootMargin: '300px' });
new MutationObserver(list => {
  for (const m of list) for (const n of m.addedNodes) {
    if (n.nodeType !== 1) continue;
    if (n.matches?.('[data-sk]')) io.observe(n);
    n.querySelectorAll?.('[data-sk]').forEach(el => io.observe(el));
  }
}).observe(document.body, { childList: true, subtree: true });

function paint(kind, ids) {
  for (const id of ids) {
    if (kind === 'shiki') {
      document.querySelectorAll(`[data-mal="${id}"]`).forEach(el => {
        const it = items.get(+(el.dataset.sk || el.dataset.skd)); if (!it) return;
        el.innerHTML = el.dataset.sk ? caption(it) : sc('365', it.score) + sc('Shiki', score(it));
      });
    } else document.querySelectorAll(`[data-uhd="${id}"]`).forEach(el => { el.hidden = !hasUhd(id); });
  }
}
// Страница аниме: оценка и 4K нужны сразу, без ожидания прокрутки.
export function wantNow(it) { remember(it); want(it.malId); wantUhd(it.id); }

// ---------- Описание ----------
export async function text(it) {
  const id = it.malId; if (!(id > 0)) return '';
  const c = S.get('shiki-text-' + id);
  if (c && Date.now() - c[1] < 7 * DAY) return c[0];
  try {
    const o = await json('/api/animes/' + id);
    const t = String(o.description || '').replace(/\[[^\]]*\]/g, '').replace(/\r/g, '').trim();
    S.set('shiki-text-' + id, [t, Date.now()]);
    if (+o.score > 0) { scores[id] = [+o.score, Date.now()]; keep(); paint('shiki', [id]); }
    return t;
  } catch { return ''; }
}

// ---------- Ссылки ----------
export const url = it => it.malId > 0 ? `${SITE}/animes/${it.malId}` : `${SITE}/animes?search=${encodeURIComponent(it.title)}`;
// Ссылка, вставленная в поиск: shikimori.one/animes/z52991-sousou-no-frieren, /mangas/2-berserk, /ranobe/….
export function link(q) {
  const t = q.trim(); if (!/shikimori/i.test(t)) return null;
  let u; try { u = new URL(t.includes('://') ? t : 'https://' + t); } catch { return null; }
  if (!/shikimori/i.test(u.host)) return null;
  const parts = u.pathname.split('/').filter(Boolean);
  const id = parts.length >= 2 ? +(parts[1].replace(/^\D+/, '').match(/^\d+/) || [0])[0] : 0;
  if (!(id > 0)) return null;
  return parts[0] === 'animes' ? { kind: 'anime', id } : parts[0] === 'mangas' || parts[0] === 'ranobe' ? { kind: 'manga', id } : null;
}
// Аниме — та же запись на Anime 365 по id MyAnimeList; иначе — название для обычного поиска.
export async function resolve(l) {
  if (l.kind === 'anime') {
    const found = await D.shelf({ myAnimeListId: l.id }, 0, 1).catch(() => []);
    if (found[0]) return { anime: found[0] };
    const o = await json('/api/animes/' + l.id).catch(() => null);
    return o ? { title: o.russian || o.name, kind: 'anime' } : null;
  }
  let o = await json('/api/mangas/' + l.id).catch(() => null);
  if (!o) o = await json('/api/ranobe/' + l.id).catch(() => null);
  return o ? { title: o.russian || o.name, alt: o.name, kind: 'manga' } : null;
}

// ---------- Аккаунт Шикимори ----------
// Как в iOS-версии: вход через сайт (OAuth, окно открывает Rust), оценка и статус на странице аниме,
// досмотренные серии уходят в список, а отмеченное на Шикимори становится просмотренным в Yoru.
const A = () => window.yoru.shiki;
export const STATUSES = [['watching', 'Смотрю'], ['rewatching', 'Пересматриваю'], ['completed', 'Просмотрено'], ['planned', 'Запланировано'], ['on_hold', 'Отложено'], ['dropped', 'Брошено']];
export const statusTitle = s => (STATUSES.find(x => x[0] === s) || [0, s])[1];
export const acc = { available: !!window.yoru?.shiki, configured: false, signedIn: false, nickname: '', userId: 0, rates: S.get('shiki-rates', {}), loading: false, syncing: false, reporting: false, step: '', message: '' };
const listeners = new Set();
export const onAcc = f => (listeners.add(f), () => listeners.delete(f));
const changed = () => listeners.forEach(f => { try { f(acc); } catch {} });
const errText = e => String(e?.message || e || 'Ошибка').replace(/^Error: /, '');
const saveRates = () => S.set('shiki-rates', acc.rates);

export async function refreshStatus() {
  if (!acc.available) return acc;
  try { Object.assign(acc, await A().status()); } catch {}
  if (!acc.signedIn && Object.keys(acc.rates).length) { acc.rates = {}; saveRates(); }
  changed(); return acc;
}
export async function setKeys(id, secret) { Object.assign(acc, await A().setKeys(id, secret)); changed(); }
export async function login() { Object.assign(acc, await A().login()); acc.message = ''; changed(); syncBoth(true); }
// Вход пришёл из аккаунта Yoru (вошли на другом устройстве) или стёрт там — обновляем и синхронизируем список.
window.yoru?.onAccountChanged?.(k => { if (k === 'installed:shikimori') refreshStatus().then(a => { if (a.signedIn) syncBoth(false); }); });
export async function logout() {
  Object.assign(acc, await A().logout()); acc.rates = {}; acc.message = '';
  for (const k of ['shiki-rates', 'shiki-pushed', 'shiki-pulled']) S.del(k);
  changed();
}

function rateOf(o) {
  const a = o?.anime; if (!(+o?.id > 0) || !a || !(+a.id > 0)) return null;
  const img = a.image?.original || '';
  return {
    id: +o.id, malId: +a.id, title: a.russian || a.name || '', subtitle: a.name || '',
    poster: img ? (img.startsWith('http') ? img : SITE + img) : '', kind: a.kind || '', total: +a.episodes || 0,
    score: +o.score || 0, status: o.status || '', episodes: +o.episodes || 0, siteScore: +a.score || 0, updated: o.updated_at || ''
  };
}
export const rate = it => it?.malId > 0 ? acc.rates[it.malId] || null : null;
export const list = () => Object.values(acc.rates).sort((a, b) => (b.updated > a.updated) - (b.updated < a.updated));

export async function refreshRates() {
  if (!acc.signedIn) return;
  acc.loading = true; changed();
  try {
    const a = await A().call('GET', `/api/users/${acc.userId}/anime_rates?limit=5000`);
    const out = {}; for (const o of a || []) { const r = rateOf(o); if (r) out[r.malId] = r; }
    acc.rates = out; saveRates(); acc.message = '';
  } catch (e) { acc.message = errText(e); await refreshStatus(); }
  acc.loading = false; changed();
}

// «Просмотрено», если тайтл вышел целиком и досмотрены все серии; иначе «Смотрю».
function statusFor(it, watched) {
  const total = +it.raw?.numberOfEpisodes || 0, airing = !!+it.raw?.isAiring;
  return (!airing && total > 0 && watched >= total) || watched === 0 ? 'completed' : 'watching';
}
async function write(it, fields) {
  try {
    const old = acc.rates[it.malId];
    const o = old ? await A().call('PATCH', `/api/v2/user_rates/${old.id}`, { user_rate: fields })
      : await A().call('POST', '/api/v2/user_rates', { user_rate: { ...fields, user_id: acc.userId, target_id: it.malId, target_type: 'Anime' } });
    if (!(+o?.id > 0)) return;
    const r = old || { id: +o.id, malId: it.malId, title: it.title, subtitle: it.raw?.titles?.romaji || '', poster: it.poster, kind: it.kind, total: +it.raw?.numberOfEpisodes || 0, score: 0, status: '', episodes: 0, siteScore: score(it) || 0, updated: '' };
    r.id = +o.id; r.score = o.score ?? r.score; r.status = o.status || r.status; r.episodes = o.episodes ?? r.episodes;
    r.updated = o.updated_at || new Date().toISOString();
    acc.rates[it.malId] = r; saveRates(); acc.message = '';
  } catch (e) { acc.message = errText(e); }
  changed();
}
export async function setScore(it, n, watched) {
  if (!acc.signedIn || !(it.malId > 0)) return;
  const old = acc.rates[it.malId], f = { score: n };
  if (!old || old.status === 'planned') f.status = statusFor(it, watched);
  if (watched > (old?.episodes || 0)) f.episodes = watched;
  await write(it, f);
}
export const setStatus = (it, status) => acc.signedIn && it.malId > 0 ? write(it, { status }) : null;
// Серия досмотрена: прогресс растёт, «Смотрю» → «Просмотрено» на последней серии вышедшего тайтла.
export async function episodeDone(it, number) {
  if (!acc.signedIn || !(it?.malId > 0) || !(number > 0)) return;
  const old = acc.rates[it.malId];
  if (!(number > (old?.episodes || 0) || old?.status === 'planned')) return;
  const f = { episodes: Math.max(number, old?.episodes || 0) };
  if (old?.status !== 'completed' && old?.status !== 'rewatching') f.status = statusFor(it, number);
  await write(it, f);
}

// Yoru → Шикимори: история (до 60 тайтлов); проверяются только те, где с прошлого раза что-то смотрели
// (метка stamp-) или изменилась запись на Шикимори. Прогресс только растёт.
async function importLocal(all) {
  const pushed = S.get('shiki-pushed', {}); let sent = 0;
  try {
    for (const h of D.history().slice(0, 60)) {
      const r0 = acc.rates[h.malId];
      const stamp = `${S.get('stamp-' + h.id, '')}|${r0?.status || ''}:${r0?.episodes || 0}`;
      if (!all && pushed[h.id] === stamp) continue;
      pushed[h.id] = stamp;
      if (r0 && (r0.status === 'completed' || r0.status === 'rewatching')) continue;
      let d; try { d = await D.details(h.id); } catch { delete pushed[h.id]; continue; }
      const it = d.item; if (!(it.malId > 0)) continue;
      const old = acc.rates[it.malId];
      if (old && (old.status === 'completed' || old.status === 'rewatching')) continue;
      const done = Math.max(0, ...d.episodes.filter(e => d.regular.has(e.id) && D.isDone(e.id)).map(e => e.number));
      if (done > 0 && (done > (old?.episodes || 0) || !old || old.status === 'planned')) { await episodeDone(it, done); sent++; }
      else if (done === 0 && D.lastEpisode(it) && (!old || old.status === 'planned')) { await write(it, { status: 'watching' }); sent++; }
    }
  } finally { S.set('shiki-pushed', pushed); }
  return sent;
}
// Шикимори → Yoru: «Просмотрено» — все серии, «Смотрю»/«Отложено»/«Брошено» — первые N.
// Аниме в процессе попадает в историю и «Продолжить просмотр». За раз — до 40 тайтлов.
async function pullToApp() {
  const pulled = S.get('shiki-pulled', {}), map = S.get('shiki-map', {});
  let got = 0, budget = 40;
  try {
    for (const r of list()) {
      if (r.status === 'planned' || !(r.episodes > 0 || r.status === 'completed')) continue;
      const stamp = `${r.status}:${r.episodes}`;
      if (pulled[r.malId] === stamp || budget <= 0) continue;
      budget--;
      let id = map[r.malId];
      if (!id) { const f = await D.shelf({ myAnimeListId: r.malId }, 0, 1).catch(() => null); if (!f) continue; if (!f[0]) { pulled[r.malId] = stamp; continue; } id = f[0].id; map[r.malId] = id; }
      let d; try { d = await D.details(id); } catch { continue; }
      if (!d.episodes.length) continue;
      const all = r.status === 'completed' || (r.status === 'rewatching' && r.episodes === 0);
      const eps = d.episodes.filter(e => d.regular.has(e.id)).sort((a, b) => a.number - b.number);
      let marked = false;
      for (const e of eps) if ((all || e.number <= r.episodes) && !D.isDone(e.id)) { D.markDone(e.id); marked = true; }
      if (marked) got++;
      if ((r.status === 'watching' || r.status === 'rewatching') && !all && !D.lastEpisode(d.item)) {
        const next = eps.find(e => e.number > r.episodes);
        if (next) {
          S.set('last-' + d.item.id, next.id); S.set('stamp-' + d.item.id, Date.now());
          if (!S.get('history', []).some(o => +o.id === d.item.id)) D.watched(d.item);
        }
      }
      pulled[r.malId] = stamp;
    }
  } finally { S.set('shiki-pulled', pulled); S.set('shiki-map', map); }
  return got;
}
// Двусторонний перенос: при запуске (тихо) и по кнопке или после входа (с итогом).
export async function syncBoth(report = false) {
  if (!acc.signedIn || acc.syncing) return;
  acc.syncing = true; acc.reporting = report; if (report) acc.message = '';
  const step = s => { acc.step = s; changed(); };
  let got = 0, sent = 0;
  try {
    step('Шикимори: загружаю ваш список…'); await refreshRates();
    if (acc.signedIn) {
      step('Шикимори: переношу просмотренное в Yoru…'); got = await pullToApp();
      step('Шикимори: отправляю просмотренное из Yoru…'); sent = await importLocal(report);
    }
  } catch (e) { acc.message = errText(e); }
  acc.syncing = false; acc.reporting = false; acc.step = '';
  if (report && !acc.message) {
    const parts = []; if (got) parts.push('из Шикимори: ' + got); if (sent) parts.push('на Шикимори: ' + sent);
    acc.result = parts.length ? 'Перенесено ' + parts.join(', ') : 'Всё уже совпадает с Шикимори';
  } else acc.result = report ? acc.message : '';
  acc.got = got;
  changed();
}
