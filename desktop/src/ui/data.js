// Данные Anime 365 и прогресс просмотра: те же правила и ключи, что в Android- и iOS-версиях.
export const BASE = 'https://smotret-anime.app';
export const CARD_FIELDS = 'id,titles,posterUrl,posterUrlSmall,typeTitle,year,myAnimeListScore,season,genres,isHentai';

import * as Sv from './servers.js';

// ---------- Хранилище (localStorage окна приложения) ----------
export const S = {
  get(k, d = null) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
  del(k) { try { localStorage.removeItem(k); } catch {} }
};
export const now = () => Date.now();

export async function api(path, params = {}, auth = false) {
  const r = await window.yoru.api(path, params, auth);
  if (r.error) throw new Error(r.error);
  return r.data;
}

// ---------- Модели ----------
const cardKeys = ['id', 'titles', 'posterUrl', 'posterUrlSmall', 'typeTitle', 'year', 'myAnimeListScore', 'season', 'genres'];
export function item(v) {
  const t = v.titles || {};
  const year = +v.year || 0, kind = v.typeTitle || '';
  // Описания с Шикимори размечены BB-кодами вида [character=1]Имя[/character] — оставляем только текст.
  const text = ((v.descriptions || []).map(d => d.value).find(Boolean) || '').replace(/\[[^\]]*\]/g, '').trim();
  const raw = {}; for (const k of cardKeys) if (v[k] !== undefined) raw[k] = v[k];
  return {
    id: +v.id || 0, title: t.ru || t.romaji || v.title || 'Аниме', year, kind,
    subtitle: [kind, year > 0 ? String(year) : ''].filter(Boolean).join(' · '),
    poster: v.posterUrl || v.posterUrlSmall || '', posterSmall: v.posterUrlSmall || v.posterUrl || '',
    season: v.season || '', score: +v.myAnimeListScore || 0,
    genres: (v.genres || []).filter(g => g && g.id).map(g => ({ id: +g.id, title: g.title || '' })),
    summary: text, raw
  };
}
export const scoreText = s => s > 0 ? s.toFixed(1).replace('.', ',') : '';
export const scoreClass = s => s >= 8 ? 'high' : s >= 6.5 ? 'mid' : 'low';
// Время на сайте — московское.
export const moscow = s => s ? new Date(String(s).replace(' ', 'T') + '+03:00') : null;
export function episode(d) {
  const kind = d.episodeType || '';
  return { id: +d.id || 0, title: d.episodeFull || 'Серия', number: +d.episodeInt || 0, uploaded: moscow(d.firstUploadedDateTime), kind, trailer: kind === 'preview' };
}
// «Серии» без трейлеров и спецвыпусков (SP): только они считаются в «Серии · N» и в досмотренности.
export function regular(list) {
  const tv = list.some(e => e.kind === 'tv');
  return new Set(list.filter(e => tv ? e.kind === 'tv' : e.kind !== 'preview' && e.kind !== 'special').map(e => e.id));
}

const GROUPS = { subRu: 'Русские субтитры', voiceRu: 'Русская озвучка', raw: 'Оригинал', subEn: 'Английские субтитры', subJa: 'Японские субтитры', subUk: 'Украинские субтитры', voiceEn: 'Английская озвучка', voiceJa: 'Японская озвучка', voiceUk: 'Украинская озвучка' };
export function translation(d) {
  const kind = d.type || '';
  const height = +d.height || 0, priority = +d.priority || 0, bd = d.qualityType === 'bd';
  const group = GROUPS[kind] || (kind.startsWith('sub') ? 'Субтитры на другом языке' : kind.startsWith('voice') ? 'Озвучка на другом языке' : 'Оригинал');
  // Сайт иногда пишет в авторах «- Opus 2.0» или пустую строку — чистим.
  const authors = String(d.authorsSummary ?? (d.authorsList || []).join(', ')).replace(/^[\s\-–]+|[\s\-–]+$/g, '');
  const name = authors === 'Original' ? '' : authors;
  return {
    id: +d.id || 0, kind, signature: kind + '|' + (d.authorsSummary || ''), group, name, height, priority, bd,
    main: ['subRu', 'voiceRu', 'raw'].includes(kind),
    title: [group, name, bd ? 'BD' : '', height >= 2160 ? '4K' : ''].filter(Boolean).join(' · ')
  };
}
const cmp = (a, b) => { for (let i = 0; i < a.length; i++) { if (a[i] < b[i]) return -1; if (a[i] > b[i]) return 1; } return 0; };
// Только настоящие варианты: одна строка на команду и вид перевода (в лучшем качестве), один «Оригинал»;
// выбранный раньше перевод — первым.
export function cleanTranslations(list, remembered) {
  const best = new Map();
  for (const t of list) {
    if (!(t.kind === 'raw' || t.name || t.signature === remembered)) continue;
    const key = (t.kind === 'raw' && t.signature !== remembered ? 'raw' : t.signature) + (t.bd ? '|bd' : '');
    const b = best.get(key);
    if (!b || cmp([t.height, t.priority], [b.height, b.priority]) > 0) best.set(key, t);
  }
  const order = ['subRu', 'voiceRu', 'raw'];
  const rank = t => t.signature === remembered ? -1 : (order.indexOf(t.kind) + 1 || 4) - 1;
  return [...best.values()].sort((a, b) => cmp([rank(a), a.bd ? 0 : 1, -a.priority, a.id], [rank(b), b.bd ? 0 : 1, -b.priority, b.id]));
}

// ---------- Запросы ----------
const visible = a => (a || []).filter(o => !+o.isHentai).map(item);
export async function shelf(params, offset = 0, limit = 24) {
  const p = { ...params, limit, offset, isActive: 1 };
  if (!p.fields) p.fields = CARD_FIELDS;
  return visible(await api('series', p));
}
export async function details(id) {
  const d = await api('series/' + id) || {};
  const all = (d.episodes || []).filter(e => +e.isActive === 1).map(episode);
  const reg = regular(all);
  // Трейлеры и спецвыпуски — в конце.
  const episodes = all.sort((a, b) => cmp([reg.has(a.id) ? 0 : 1, a.number], [reg.has(b.id) ? 0 : 1, b.number]));
  rememberEpisodes(id, episodes, reg);
  return { item: item(d), episodes, regular: reg };
}
// Досмотренным считается аниме, у которого просмотрена последняя из вышедших серий.
function rememberEpisodes(id, episodes, reg) {
  const last = [...episodes].reverse().find(e => reg.has(e.id));
  S.set('final-' + id, last ? last.id : 0); S.set('final-ts-' + id, now());
}
export const finished = it => { const f = S.get('final-' + it.id, 0); return f !== 0 && isDone(f); };
export async function refreshFinished() {
  const stale = history().filter(it => lastEpisode(it) && now() - S.get('final-ts-' + it.id, 0) > 12 * 3600e3).slice(0, 20);
  let changed = false;
  for (const it of stale) { const was = finished(it); try { await details(it.id); changed ||= was !== finished(it); } catch {} }
  return changed;
}

// Сезоны франшизы — из блока связанных частей на странице каталога (в API его нет).
const seasonCache = new Map();
export async function seasons(it) {
  if (seasonCache.has(it.id)) return seasonCache.get(it.id);
  const r = await window.yoru.text('https://smotret-anime.co/catalog/' + it.id);
  if (r.error) return [];
  const rx = /<li class="m-connections-list__item( m-connections-list__item_current)?"><a href="\/catalog\/[^"]*?-(\d+)">[\s\S]*?<\/a>\s*<span class="m-connections-list__type">([\s\S]*?)<\/span>[^<]*(?:<span class="m-connections-list__type">([\s\S]*?)<\/span>,\s*)?<span class="m-connections-list__year">(\d*)<\/span>/g;
  const order = [], years = new Map(); let current = 0;
  for (const m of r.data.matchAll(rx)) {
    const cur = !!m[1], rel = m[4], sid = +m[2];
    if (m[3] !== 'ТВ сериал' || !(cur || rel == null || ['основная история', 'продолжение', 'предыстория'].includes(rel)) || !sid) continue;
    if (cur) current = sid;
    if (!years.has(sid)) { order.push(sid); years.set(sid, +m[5] || 0); }
  }
  if (order.length < 2 || !current) { seasonCache.set(it.id, []); return []; }
  let list;
  try { list = await api('series?fields=' + CARD_FIELDS + ',descriptions' + order.map(id => '&id[]=' + id).join('')); } catch { return []; }
  const items = new Map(list.map(o => [+o.id, item(o)]));
  const y = id => years.get(id) || Infinity;
  const sorted = order.filter(id => items.has(id)).map((id, i) => [id, i]).sort((a, b) => cmp([y(a[0]), a[1]], [y(b[0]), b[1]])).map(a => a[0]);
  const out = sorted.map((sid, i) => {
    const a = items.get(sid); const n = a.title.match(/(\d+)\s*сезон/);
    return { id: sid, label: n ? n[1] + ' сезон' : i === 0 ? '1 сезон' : a.title, current: sid === current, item: a };
  });
  const result = out.length > 1 ? out : [];
  seasonCache.set(it.id, result);
  return result;
}

// Расписание: аниме, которые сейчас выходят, по дню недели последней вышедшей серии.
export async function schedule() {
  const raw = await api('series', { isAiring: 1, isActive: 1, limit: 60, fields: CARD_FIELDS + ',episodes' });
  const days = new Map();
  for (const o of raw || []) {
    if (+o.isHentai) continue;
    const eps = (o.episodes || []).map(episode).filter(e => e.uploaded);
    const last = eps.reduce((a, e) => !a || e.uploaded > a.uploaded ? e : a, null);
    if (!last || last.uploaded < now() - 21 * 86400e3) continue;
    const d = last.uploaded.getDay();
    if (!days.has(d)) days.set(d, []);
    days.get(d).push([item(o), last]);
  }
  const today = new Date().getDay();
  const out = [];
  for (let i = 0; i < 7; i++) { const d = (today - i + 7) % 7; if (days.has(d)) out.push({ weekday: d, items: days.get(d).sort((a, b) => b[1].uploaded - a[1].uploaded) }); }
  return out;
}

export async function translations(ep, it) {
  const a = await api('translations', { episodeId: ep.id, isActive: 1, limit: 100 });
  return cleanTranslations((a || []).map(translation), rememberedTranslation(it));
}
export const makeURL = s => { try { const u = new URL(s, BASE); return /^https?:$/.test(u.protocol) ? u.href : null; } catch { return null; } };
export async function playback(t, ep, it) {
  const d = await api('translations/embed/' + t.id, {}, true) || {};
  const options = [];
  for (const s of d.stream || []) {
    const h = +s.height || 0;
    const site = (s.urls || []).map(makeURL).filter(Boolean);
    Sv.remember(site);
    // Самый быстрый сервер первым, ссылки сайта — запасные.
    const urls = [...new Set(site.flatMap(Sv.preferred))];
    if (urls.length) options.push({ id: 'stream-' + h, url: urls[0], height: h, alternatives: urls.slice(1) });
  }
  const downloads = [];
  for (const s of d.download || []) {
    const u = makeURL(s.url || ''); if (!u) continue;
    const h = +s.height || 0;
    downloads.push({ height: h, url: u });
    const o = options.find(o => o.height === h);
    if (o) o.alternatives.push(u); else options.push({ id: 'direct-' + h, url: u, height: h, alternatives: [] });
  }
  if (!options.length) throw new Error('Сайт не вернул видео для этого перевода. Проверьте подписку или выберите другой перевод.');
  options.sort((a, b) => b.height - a.height);
  downloads.sort((a, b) => b.height - a.height);
  const subtitles = d.subtitlesUrl ? makeURL(d.subtitlesUrl) : null;
  if (t.kind.startsWith('sub') && !subtitles) throw new Error('Для этого перевода нет ссылки на субтитры. Выберите другой перевод.');
  remember(t, ep, it);
  return { options, downloads, subtitles, title: it.title, episodeTitle: ep.title, key: 'position-' + t.id, episodeId: ep.id };
}

// ---------- Прогресс, избранное, история ----------
export const favorites = () => S.get('favorites', []).map(item);
export const history = () => S.get('history', []).map(item);
export function isFavorite(it) { return S.get('favorites', []).some(o => +o.id === it.id); }
export function toggleFavorite(it) {
  let list = S.get('favorites', []);
  if (list.some(o => +o.id === it.id)) list = list.filter(o => +o.id !== it.id); else list.unshift(it.raw);
  S.set('favorites', list); S.set('t-favorites', now());
}
export function watched(it) {
  const list = S.get('history', []).filter(o => +o.id !== it.id);
  list.unshift(it.raw);
  S.set('history', list.slice(0, 50)); S.set('t-history', now());
}
export const lastEpisode = it => S.get('last-' + it.id, 0);
export const isDone = ep => S.get('done-' + ep, false) === true;
export const markDone = ep => S.set('done-' + ep, true);
export const fraction = ep => isDone(ep) ? 1 : +S.get('watch-' + ep, 0) || 0;
export const rememberedTranslation = it => S.get('tr-' + it.id, '');
export function lastEpisodeTitle(it) { const o = S.get('lp-episode'); return o && +o.id === lastEpisode(it) ? o.episodeFull : null; }
// Серия, с которой продолжать: последняя начатая, а если она досмотрена — следующая.
export function resumeEpisode(it, episodes) {
  const last = lastEpisode(it);
  const i = episodes.findIndex(e => e.id === last && !e.trailer);
  if (i < 0) return episodes.find(e => !e.trailer) || episodes[0];
  return isDone(last) && i + 1 < episodes.length && !episodes[i + 1].trailer ? episodes[i + 1] : episodes[i];
}
export function remember(t, ep, it) {
  watched(it);
  S.set('last-' + it.id, ep.id); S.set('tr-' + it.id, t.signature); S.set('stamp-' + it.id, now());
  S.set('lp-item', it.raw); S.set('lp-episode', { id: ep.id, episodeFull: ep.title, episodeInt: ep.number });
  S.set('lp-translation', { id: t.id, type: t.kind, authorsSummary: t.signature.split('|').slice(1).join('|') }); S.set('lp-t', now());
}
export function savePosition(key, ms) { S.set(key, Math.round(ms)); S.set('ts-' + key, now()); }
// Новые серии в избранном: count — сколько серий на сайте, known — сколько было при последнем открытии аниме.
export function hasNew(it) { const k = S.get('known-' + it.id); return k != null && S.get('count-' + it.id, 0) > k; }
export function seen(it, count) { S.set('count-' + it.id, count); S.set('known-' + it.id, count); }
export async function checkNewEpisodes() {
  if (now() - S.get('checked', 0) < 3600e3) return false;
  S.set('checked', now());
  for (const it of favorites().slice(0, 30)) {
    try {
      const n = (await details(it.id)).episodes.length;
      S.set('count-' + it.id, n); if (S.get('known-' + it.id) == null) S.set('known-' + it.id, n);
    } catch {}
  }
  return true;
}
