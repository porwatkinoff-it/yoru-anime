// Манга: каталоги MangaLib и Com-X, страница тайтла, читалка и скачанные главы — как в Android- и iOS-версиях.
// Запросы делает Rust (manga.rs): MangaLib — через API с ключом входа, Com-X — в скрытом окне сайта.
import { esc, toast, push, modal, plural } from './app.js';
import * as D from './data.js';
import * as Acc from './account.js';

const $ = (s, el = document) => el.querySelector(s);
const M = () => window.yoru.manga;
export const available = () => !!window.yoru?.manga;
const S = D.S;
const errText = e => String(e?.message ?? e ?? 'Ошибка');

// ---------- Картинки ----------
const b64 = s => btoa(String.fromCharCode(...new TextEncoder().encode(s))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
// Картинки идут через схему mimg: Rust подставляет нужный Referer и кладёт их в кэш; скачанные — с диска.
export const imgURL = u => !u ? '' : u.startsWith('f/') ? M().base + u : M().base + 'i/' + b64(u);

// ---------- Данные ----------
const SOURCES = [['mangalib', 'MangaLib'], ['comx', 'Com-X']];
const IMAGES = 'https://img3.cdnlibs.org/';
const EN = 'qwertyuiop[]asdfghjkl;\'zxcvbnm,.`QWERTYUIOP{}ASDFGHJKL:"ZXCVBNM<>~';
const RU = 'йцукенгшщзхъфывапролджэячсмитьбюёЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮЁ';
const swapLayout = s => [...s].map(c => { const i = EN.indexOf(c), j = RU.indexOf(c); return i >= 0 ? RU[i] : j >= 0 ? EN[j] : c; }).join('');
const num = v => v == null ? '' : typeof v === 'number' ? String(v) : String(v).trim();
export const mid = m => m.source + ':' + m.key;
const chId = ch => String(ch.id);
export function chapterTitle(ch) {
  const h = [ch.volume ? 'Том ' + ch.volume : '', ch.number ? 'Глава ' + ch.number : ''].filter(Boolean).join(' · ');
  return h ? (ch.name ? h + ' — ' + ch.name : h) : ch.name || 'Глава';
}
export const chapterShort = ch => ch.number ? 'Глава ' + ch.number : ch.name || 'Глава';
const item = (source, key, title, subtitle, cover, meta) => ({ source, key, title, subtitle, cover, meta });

function libItem(d) {
  const rus = d.rus_name || '', name = d.name || '', c = d.cover || {};
  const meta = [d.rating?.averageFormated ? '★ ' + d.rating.averageFormated : '', d.type?.label || '', (d.releaseDateString || '').length >= 4 ? d.releaseDateString.slice(0, 4) : ''].filter(Boolean);
  return item('mangalib', d.slug_url || '', rus || name, rus ? name : '', c.default || c.md || c.thumbnail || '', meta.join(' · '));
}
const slug = m => encodeURIComponent(m.key).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
function plainText(n) {
  if (n == null) return '';
  if (typeof n === 'string') return n;
  if (typeof n.text === 'string') return n.text;
  if (n.type === 'hardBreak') return '\n';
  return (n.content || []).map(plainText).join(n.type === 'doc' ? '\n\n' : '');
}
async function libSearchOnce(q, page) {
  const query = [['site_id[]', '1'], ['page', String(page)], ['fields[]', 'rate_avg'], ['fields[]', 'rate'], q ? ['q', q] : ['sort_by', 'views']];
  const j = await M().lib('/manga', query) || {};
  return { items: (j.data || []).map(libItem).filter(m => m.key), more: !!j.meta?.has_next_page };
}
async function comxSearch(q, page) {
  const r = q ? await M().comx({ op: 'search', q, page }) : await M().comx({ op: 'list', path: page > 1 ? `/comix-read/manga-read/page/${page}/` : '/comix-read/manga-read/' });
  const seen = new Set(), items = [];
  for (const e of r.items || []) {
    let path = ''; try { path = new URL(e.href).pathname; } catch {}
    if (!path || seen.has(path)) continue; seen.add(path);
    const parts = String(e.title || '').split(' / ');
    const title = (parts.length > 1 ? parts.slice(1).join(' / ') : parts[0]).trim();
    items.push(item('comx', path, title || 'Комикс', parts.length > 1 ? parts[0].trim() : '', e.cover || '', e.meta || ''));
  }
  return { items, more: q ? (r.items || []).length >= 20 : !!r.more };
}
export async function search(source, q, page) {
  if (source === 'comx') return comxSearch(q, page);
  const p = await libSearchOnce(q, page);
  // «Тфкгещ» вместо «Наруто»: если ничего нет, пробуем ту же строку в другой раскладке.
  if (page === 1 && !p.items.length && q) { const s = swapLayout(q); if (s !== q) return libSearchOnce(s, page); }
  return p;
}
export async function details(m) {
  if (m.source === 'comx') {
    const d = await M().comx({ op: 'details', path: m.key });
    const data = d.data;
    if (!data || data.news_id == null) throw new Error('Не удалось прочитать страницу Com-X');
    const it = { ...m };
    if (d.title) { const parts = d.title.split(' / '); it.title = parts.length > 1 ? parts.slice(1).join(' / ') : d.title; if (parts.length > 1) it.subtitle = parts[0]; }
    if (d.original) it.subtitle = d.original;
    if (d.cover) it.cover = d.cover;
    const chapters = (data.chapters || []).slice().reverse().map(c => {
      const v = num(c.volume), n = num(c.number);
      return { id: data.news_id + '/' + num(c.id), volume: v === '0' ? '' : v, number: n === '0' ? '' : n, name: String(c.title || '').trim().replace(/^\d+(\.\d+)?\s*-\s*\d+(\.\d+)?\s*/, '') };
    });
    return { item: it, summary: d.text || '', tags: (d.tags || []).map(s => String(s).trim()).filter(Boolean), info: (d.info || []).map(s => String(s).trim()).filter(Boolean).slice(0, 5), chapters };
  }
  const fields = ['summary', 'genres', 'tags', 'releaseDate', 'authors', 'status_id'].map(f => ['fields[]', f]);
  const [dj, cj] = await Promise.all([M().lib('/manga/' + slug(m), fields), M().lib('/manga/' + slug(m) + '/chapters', [])]);
  const d = dj?.data || {};
  let it = libItem(d); if (!it.key) it = { ...m }; if (!it.cover) it.cover = m.cover;
  const info = [d.status?.label, (d.authors || []).map(a => a.name).filter(Boolean).join(', ')].filter(Boolean);
  const chapters = (cj?.data || []).map(ch => {
    const o = { id: num(ch.id), volume: num(ch.volume), number: num(ch.number), name: ch.name == null || ch.name === 'null' ? '' : String(ch.name).trim() };
    const b = ch.branches?.[0]; if (b && b.branch_id != null) o.branch = b.branch_id;
    return o;
  });
  return { item: it, summary: plainText(d.summary).trim(), tags: (d.genres || []).map(g => g.name).filter(Boolean), info, chapters };
}
export async function pages(m, ch) {
  if (m.source === 'comx') {
    const d = await M().comx({ op: 'pages', path: '/readcomix/' + ch.id + '.html' });
    const out = (d.images || []).filter(Boolean).map(p => p.startsWith('http') ? p : 'https://img.com-x.life/comix/' + p.replace(/^\/+/, ''));
    if (!out.length) throw new Error(d.logged ? 'В этой главе нет страниц' : 'Com-X не показал страницы. Возможно, глава доступна только после входа.');
    return out;
  }
  const q = [['number', ch.number], ['volume', ch.volume]];
  if (ch.branch != null) q.push(['branch_id', String(ch.branch)]);
  const d = (await M().lib('/manga/' + slug(m) + '/chapter', q))?.data;
  const out = (d?.pages || []).map(p => p.url).filter(Boolean).map(u => u.startsWith('http') ? u : IMAGES + u.replace(/^\/+/, ''));
  if (!out.length) throw new Error('В этой главе нет страниц');
  return out;
}

// ---------- Прогресс чтения ----------
const position = m => S.get('m-pos-' + mid(m));
const savedPage = (m, ch) => S.get('m-page-' + mid(m) + '|' + chId(ch), 0);
const readSet = m => new Set(S.get('m-read-' + mid(m), []));
const isRead = (m, ch) => readSet(m).has(chId(ch));
function savePage(m, ch, page, count) {
  S.set('m-page-' + mid(m) + '|' + chId(ch), page);
  S.set('m-pos-' + mid(m), { chapter: chId(ch), page, count, title: chapterShort(ch) });
  if (page >= count - 1) { const r = readSet(m); if (!r.has(chId(ch))) { r.add(chId(ch)); S.set('m-read-' + mid(m), [...r]); } }
  S.set('m-ts-' + mid(m), Date.now());
}
function toggleRead(m, ch) { const r = readSet(m); if (!r.delete(chId(ch))) r.add(chId(ch)); S.set('m-read-' + mid(m), [...r]); S.set('m-ts-' + mid(m), Date.now()); }
const recent = () => S.get('m-recent', []);
function addRecent(m) { S.set('m-recent', [m, ...recent().filter(o => mid(o) !== mid(m))].slice(0, 30)); S.set('m-recent-t', Date.now()); }
// С какой главы продолжать: начатая, а если дочитана — следующая.
function resumeChapter(d) {
  const p = position(d.item), chs = d.chapters;
  if (!p) return chs[0];
  const i = chs.findIndex(c => chId(c) === p.chapter);
  if (i < 0) return chs[0];
  return p.page >= p.count - 1 && i + 1 < chs.length ? chs[i + 1] : chs[i];
}

// ---------- Скачанные главы ----------
let saved = new Map();          // id → {details, chapters: {chId: [файлы]}, size}
const queue = [], progress = new Map(), listeners = new Set();
let pumping = false;
const notify = () => listeners.forEach(fn => fn());
const watch = (alive, fn) => { const f = () => { if (!alive()) return listeners.delete(f); fn(); }; listeners.add(f); };
async function refreshSaved() { try { saved = new Map((await M().saved()).map(s => [mid(s.details.item), s])); } catch {} notify(); }
const savedFiles = (m, ch) => saved.get(mid(m))?.chapters?.[chId(ch)] || null;
const dlKey = (m, ch) => mid(m) + '|' + chId(ch);
function enqueue(d, chapters) {
  let n = 0;
  for (const ch of chapters) {
    const k = dlKey(d.item, ch);
    if (savedFiles(d.item, ch) || progress.has(k)) continue;
    progress.set(k, { done: 0, total: 0 }); queue.push({ d, ch }); n++;
  }
  notify(); pump();
  return n;
}
async function pump() {
  if (pumping) return; pumping = true;
  while (queue.length) {
    const { d, ch } = queue.shift(), k = dlKey(d.item, ch);
    if (!progress.has(k)) continue;     // отменили, пока ждала в очереди
    try { await M().save(d, ch, await pages(d.item, ch)); }
    catch (e) { if (errText(e) !== 'Отменено') toast(`Не удалось скачать ${chapterShort(ch)}: ${errText(e)}`); }
    progress.delete(k);
    await refreshSaved();
  }
  pumping = false;
}
function cancel(m, ch) { const k = dlKey(m, ch); if (!progress.has(k)) return; progress.delete(k); M().cancel(mid(m), chId(ch)); notify(); }
const size = n => n >= 1e9 ? (n / 1e9).toFixed(1).replace('.', ',') + ' ГБ' : Math.max(1, Math.round(n / 1e6)) + ' МБ';

export function init() {
  if (!available()) return;
  M().onProgress(p => { if (progress.has(p.key)) { progress.set(p.key, { done: p.done, total: p.total }); notify(); } });
  refreshSaved();
}

// ---------- Карточки ----------
const known = new Map();
const keep = m => { known.set(mid(m), m); return m; };
const cover = (src, cls = '') => src ? `<img class="${cls}" src="${esc(imgURL(src))}" loading="lazy" decoding="async" alt="">` : '';
function card(m, sub, progressFrac) {
  keep(m);
  const p = progressFrac != null ? `<div class="progress"><i style="width:${Math.round(progressFrac * 100)}%"></i></div>` : '';
  return `<button class="card" data-manga="${esc(mid(m))}"><div class="poster">${cover(m.cover)}${p}</div><div class="t">${esc(m.title || 'Манга')}</div><div class="s">${esc(sub ?? m.meta ?? m.subtitle ?? '')}</div></button>`;
}
// Карточка для общего поиска на вкладке «Поиск».
export const cardHTML = m => card(m);
document.addEventListener('click', e => {
  const c = e.target.closest('[data-manga]'); if (!c) return;
  const m = known.get(c.dataset.manga); if (m) push({ view: 'mangaTitle', item: m, resume: !!c.dataset.resume });
});
const loading = () => `<div class="state"><div class="spinner"></div></div>`;
const failed = msg => `<div class="state"><div><b>Не получилось загрузить</b>${esc(msg)}<br><button class="btn" data-retry>Повторить</button></div></div>`;
function continueShelf() {
  const list = recent().filter(m => position(m)).slice(0, 20);
  if (!list.length) return '';
  return `<section class="shelf"><div class="shelf-head"><h2>Продолжить чтение</h2></div><div class="row">${list.map(m => {
    const p = position(m); return card(m, `${p.title} · стр. ${p.page + 1} из ${p.count}`, p.count ? (p.page + 1) / p.count : 0).replace('data-manga', 'data-resume="1" data-manga');
  }).join('')}</div></section>`;
}

// ---------- Каталог ----------
export function MangaHome(r, alive, main) {
  r.source ??= S.get('m-source', 'mangalib'); r.query ??= '';
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  page.innerHTML = `<div class="page-head"><h1>Манга</h1></div>
    <div class="seg big" id="src">${SOURCES.map(([k, t]) => `<button data-src="${k}" class="${r.source === k ? 'on' : ''}">${t}</button>`).join('')}</div>
    <label class="search-box"><svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><input type="search" placeholder="Название манги" value="${esc(r.query)}" spellcheck="false"></label>
    <div id="m-cont">${r.query ? '' : continueShelf()}</div><div id="results"></div>`;
  const input = $('input', page), out = $('#results', page);
  let items = [], pageNo = 0, more = true, busy = false, gen = 0;
  async function load(reset) {
    if (reset) { items = []; pageNo = 0; more = true; gen++; out.innerHTML = loading(); $('#m-cont', page).innerHTML = r.query.trim() ? '' : continueShelf(); }
    if ((busy && !reset) || !more) return;
    const g = gen; busy = true;
    try {
      const p = await search(r.source, r.query.trim(), pageNo + 1);
      if (g !== gen || !alive()) return;
      pageNo++; more = p.more && p.items.length > 0;
      items.push(...p.items.filter(m => !items.some(i => mid(i) === mid(m))));
      out.innerHTML = items.length ? `<div class="section-title" style="margin-top:0">${r.query.trim() ? 'Результаты' : 'Популярное'}</div><div class="grid">${items.map(m => card(m)).join('')}</div>`
        : `<div class="state"><div><b>Ничего не нашлось</b>Попробуйте другое название или другой источник.</div></div>`;
      if (more && main.scrollHeight <= main.clientHeight + 600) setTimeout(() => load(false), 0);
    } catch (e) { if (g === gen && alive()) { if (!items.length) { out.innerHTML = failed(errText(e)); $('[data-retry]', out).onclick = () => load(true); } else toast(errText(e)); more = !items.length ? more : false; } }
    finally { if (g === gen) busy = false; }
  }
  let t;
  input.addEventListener('input', () => { r.query = input.value; clearTimeout(t); t = setTimeout(() => load(true), 400); });
  $('#src', page).addEventListener('click', e => { const b = e.target.closest('[data-src]'); if (!b || b.dataset.src === r.source) return; r.source = b.dataset.src; S.set('m-source', r.source); page.querySelectorAll('[data-src]').forEach(x => x.classList.toggle('on', x === b)); load(true); });
  const onScroll = () => { if (!alive()) return main.removeEventListener('scroll', onScroll); if (main.scrollTop + main.clientHeight > main.scrollHeight - 600) load(false); };
  main.addEventListener('scroll', onScroll);
  load(true);
}

// ---------- Моя манга: история и скачанное ----------
export function MangaMine(r, alive, main) {
  r.part ??= 'history';
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  const draw = () => {
    const tabs = `<div class="page-head"><h1>Моя манга</h1></div><div class="tabs"><button data-part="history" class="${r.part === 'history' ? 'on' : ''}">История</button><button data-part="saved" class="${r.part === 'saved' ? 'on' : ''}">Скачанное</button></div>`;
    if (r.part === 'history') {
      const list = recent();
      page.innerHTML = tabs + (list.length ? `<div class="grid">${list.map(m => { const p = position(m); return card(m, p ? `${p.title} · стр. ${p.page + 1} из ${p.count}` : m.meta, p && p.count ? (p.page + 1) / p.count : null); }).join('')}</div>`
        : `<div class="state"><div><b>Вы ещё ничего не читали</b>Открытая манга появится здесь.</div></div>`);
      return;
    }
    const list = [...saved.values()];
    const busy = progress.size;
    page.innerHTML = tabs + (busy ? `<p class="hint">Скачивается: ${busy} ${plural(busy, 'глава', 'главы', 'глав')}</p>` : '') + (list.length ? list.map(s => {
      const m = keep(s.details.item), n = Object.keys(s.chapters).length;
      return `<section class="dl-series"><div class="dl-head"><img src="${esc(imgURL(m.cover))}" alt=""><div style="min-width:0"><h2>${esc(m.title)}</h2><span>${n} ${plural(n, 'глава', 'главы', 'глав')} · ${size(s.size)}</span></div>
        <button class="btn" data-manga="${esc(mid(m))}">Открыть</button><button class="btn" data-del="${esc(mid(m))}">Удалить</button></div></section>`;
    }).join('') : `<div class="state"><div><b>Здесь пока пусто</b>Скачайте главы на странице манги, чтобы читать без интернета.</div></div>`);
  };
  page.addEventListener('click', e => {
    const b = e.target.closest('[data-part]'); if (b) { r.part = b.dataset.part; draw(); return; }
    const d = e.target.closest('[data-del]');
    if (d) { const s = saved.get(d.dataset.del); if (!s) return; const m = modal(`<h3>Удалить «${esc(s.details.item.title)}»?</h3><p class="hint">Скачанные главы удалятся с компьютера. Прогресс чтения останется.</p><div class="actions"><button class="btn primary" id="yes">Удалить</button><button class="btn" id="no">Отмена</button></div>`);
      $('#no', m.el).onclick = m.close; $('#yes', m.el).onclick = async () => { m.close(); await M().remove(d.dataset.del); refreshSaved(); }; }
  });
  watch(alive, () => { if (r.part === 'saved') { const y = main.scrollTop; draw(); main.scrollTop = y; } });
  draw(); refreshSaved();
}

// ---------- Страница тайтла ----------
const ico = {
  dl: '<svg viewBox="0 0 24 24"><path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/></svg>',
  ok: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
  back: '<svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg>',
  sort: '<svg viewBox="0 0 24 24"><path d="M7 4v16M3.5 16.5 7 20l3.5-3.5M17 20V4M13.5 7.5 17 4l3.5 3.5"/></svg>',
  book: '<svg viewBox="0 0 24 24"><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5zM4 20.5A2.5 2.5 0 0 0 6.5 23H20v-5"/></svg>'
};
export function MangaTitle(r, alive, main) {
  const m = r.item;
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  let d = r.details, offline = false;
  r.desc ??= S.get('m-desc', false);
  addRecent(m);
  const draw = () => {
    const it = d ? d.item : m;
    const chs = d ? d.chapters : [];
    const rs = readSet(m), pos = position(m), resume = d && chs.length ? resumeChapter(d) : null;
    const nSaved = d ? chs.filter(c => savedFiles(m, c)).length : 0;
    const ordered = r.desc ? chs.slice().reverse() : chs;
    const chRow = c => {
      const k = dlKey(m, c), pr = progress.get(k), files = savedFiles(m, c), p = savedPage(m, c), cur = pos && pos.chapter === chId(c);
      const mark = files ? `<span class="ep-dl ok" data-dl="${esc(chId(c))}" title="Скачано — нажмите, чтобы удалить">${ico.ok}</span>`
        : pr ? `<span class="ep-dl run" data-dl="${esc(chId(c))}" title="Отменить">${pr.total ? `<b>${Math.floor(pr.done / pr.total * 100)}%</b>` : '<b>…</b>'}</span>`
        : `<span class="ep-dl" data-dl="${esc(chId(c))}" title="Скачать">${ico.dl}</span>`;
      const sub = rs.has(chId(c)) ? 'Прочитано' : cur ? `Читаете · стр. ${pos.page + 1} из ${pos.count}` : p ? `стр. ${p + 1}` : '';
      return `<button class="ep ${rs.has(chId(c)) ? 'done' : ''} ${cur ? 'current' : ''}" data-ch="${esc(chId(c))}"><span class="n">${rs.has(chId(c)) ? '✓' : esc(c.number || '•')}</span><span style="min-width:0"><div class="et">${esc(chapterTitle(c))}</div><div class="ed">${esc(sub)}</div></span>${mark}</button>`;
    };
    page.innerHTML = `<div class="top-bar"><button class="back" data-back aria-label="Назад">${ico.back}</button></div>
      <div class="detail-hero"><div class="shade"></div><div class="detail-top"><div class="poster">${cover(it.cover)}</div><div style="min-width:0;padding-bottom:6px">
      <h1>${esc(it.title || 'Манга')}</h1>${it.subtitle ? `<div class="sub">${esc(it.subtitle)}</div>` : ''}
      <div class="meta"><span>${it.source === 'comx' ? 'Com-X' : 'MangaLib'}</span>${it.meta ? `<span>${esc(it.meta)}</span>` : ''}${chs.length ? `<span>${chs.length} ${plural(chs.length, 'глава', 'главы', 'глав')}</span>` : ''}${offline ? '<span class="fresh">Без сети — скачанные главы</span>' : ''}</div>
      ${d?.tags?.length ? `<div class="genres">${d.tags.map(g => `<span>${esc(g)}</span>`).join('')}</div>` : '<div style="height:16px"></div>'}
      <div class="actions">${d ? (resume ? `<button class="btn primary" id="read">${ico.book}${pos ? 'Продолжить · ' : 'Читать · '}${esc(chapterShort(resume))}</button>` : '') : `<button class="btn primary" disabled>Загрузка…</button>`}
      ${d && chs.length && !offline ? `<button class="btn" id="dl-all">${ico.dl}${nSaved ? `Скачано ${nSaved} из ${chs.length}` : 'Скачать главы'}</button>` : ''}</div></div></div></div>
      ${d?.info?.length ? `<div class="m-info">${d.info.map(s => `<span>${esc(s)}</span>`).join('')}</div>` : ''}
      ${d?.summary ? `<div class="summary clamp">${esc(d.summary)}</div><button class="more" hidden>Ещё</button>` : ''}
      <div id="chs">${d ? (chs.length ? `<div class="section-title">Главы <small>${chs.length}</small><button class="link" id="order">${ico.sort}${r.desc ? 'Сначала новые' : 'Сначала первые'}</button></div><div class="episodes">${ordered.map(chRow).join('')}</div>` : `<div class="state">Глав пока нет</div>`) : r.error ? failed(r.error) : loading()}</div>`;
    const sum = $('.summary', page);
    if (sum && sum.scrollHeight > sum.clientHeight + 2) { const mo = $('.more', page); mo.hidden = false; mo.onclick = () => { sum.classList.remove('clamp'); mo.remove(); }; }
    $('#read', page)?.addEventListener('click', () => open(resume));
    $('[data-retry]', page)?.addEventListener('click', () => { r.error = null; draw(); load(); });
  };
  const open = ch => { if (!ch) return; const i = d.chapters.indexOf(ch); openReader(d, i, savedPage(m, ch), offline, () => { if (alive()) { const y = main.scrollTop; draw(); main.scrollTop = y; } }); };
  page.addEventListener('click', e => {
    if (!d) return;
    if (e.target.closest('#order')) { r.desc = !r.desc; S.set('m-desc', r.desc); draw(); return; }
    if (e.target.closest('#dl-all')) { downloadDialog(d); return; }
    const dl = e.target.closest('[data-dl]');
    if (dl) {
      e.stopPropagation();
      const ch = d.chapters.find(c => chId(c) === dl.dataset.dl); if (!ch) return;
      if (savedFiles(m, ch)) { M().remove(mid(m), chId(ch)).then(refreshSaved); toast('Скачанная глава удалена'); }
      else if (progress.has(dlKey(m, ch))) cancel(m, ch);
      else if (offline) toast('Нет сети');
      else enqueue(d, [ch]);
      return;
    }
    const b = e.target.closest('[data-ch]');
    if (b) open(d.chapters.find(c => chId(c) === b.dataset.ch));
  });
  // Правый щелчок по главе — отметить прочитанной или снять отметку.
  page.addEventListener('contextmenu', e => {
    const b = e.target.closest('[data-ch]'); if (!b || !d) return;
    e.preventDefault();
    const ch = d.chapters.find(c => chId(c) === b.dataset.ch); toggleRead(m, ch);
    toast(isRead(m, ch) ? 'Отмечено как прочитанное' : 'Отметка снята'); draw();
  });
  watch(alive, () => { if (d) { const y = main.scrollTop; draw(); main.scrollTop = y; } });
  const load = async () => {
    try { d = r.details = await details(m); offline = false; addRecent(d.item); }
    catch (e) {
      // Нет сети или сайт не ответил — открываем то, что скачано.
      const s = saved.get(mid(m));
      if (s) { offline = true; d = { ...s.details, chapters: s.details.chapters.filter(c => s.chapters[chId(c)]) }; }
      else r.error = errText(e);
    }
    if (!alive()) return;
    draw();
    if (r.resume && d?.chapters.length) { r.resume = false; open(resumeChapter(d)); }
  };
  draw();
  if (!d) load();
}
function downloadDialog(d) {
  const m = d.item, left = d.chapters.filter(c => !savedFiles(m, c) && !progress.has(dlKey(m, c)));
  const unread = left.filter(c => !isRead(m, c));
  const pos = position(m), from = pos ? Math.max(0, d.chapters.findIndex(c => chId(c) === pos.chapter)) : 0;
  const next10 = left.filter(c => d.chapters.indexOf(c) >= from).slice(0, 10);
  if (!left.length) return toast(progress.size ? 'Главы уже скачиваются' : 'Все главы уже скачаны');
  const md = modal(`<h3>Скачать главы</h3><p class="hint">Скачанные главы читаются без интернета. Они хранятся в папке приложения.</p>
    ${next10.length ? `<button class="tr" data-n="next"><span class="name">Следующие ${next10.length} ${plural(next10.length, 'глава', 'главы', 'глав')}</span></button>` : ''}
    ${unread.length && unread.length !== next10.length ? `<button class="tr" data-n="unread"><span class="name">Все непрочитанные</span><span class="tag">${unread.length}</span></button>` : ''}
    <button class="tr" data-n="all"><span class="name">Все нескачанные</span><span class="tag">${left.length}</span></button>`);
  md.el.addEventListener('click', e => {
    const b = e.target.closest('[data-n]'); if (!b) return;
    md.close();
    const n = enqueue(d, b.dataset.n === 'next' ? next10 : b.dataset.n === 'unread' ? unread : left);
    toast(`В очереди: ${n} ${plural(n, 'глава', 'главы', 'глав')}`);
  });
}

// ---------- Читалка ----------
// Одна страница на экране. Соседние страницы заранее декодируются, поэтому листание мгновенное.
// ← → / Пробел / PgUp PgDn / щелчок по краям — листать; Esc — закрыть.
function openReader(d, index, startPage, offline, onClose) {
  const m = d.item;
  const el = document.createElement('div'); el.id = 'reader'; el.tabIndex = -1;
  el.innerHTML = `<div class="r-pages"></div><div class="r-msg"></div>
    <div class="r-top"><button class="pbtn" data-r="close" aria-label="Закрыть">${ico.back}</button><div class="titles"><b>${esc(m.title)}</b><span class="r-ch"></span></div><div class="p-spacer"></div>
    <button class="pbtn" data-r="prevch">‹ Глава</button><button class="pbtn" data-r="nextch">Глава ›</button></div>
    <div class="r-bottom"><input type="range" class="r-slider" min="1" value="1"><span class="r-count"></span></div>`;
  document.body.append(el); el.focus();
  const box = $('.r-pages', el), msg = $('.r-msg', el), slider = $('.r-slider', el);
  let urls = [], cur = 0, ch = null, gen = 0, imgs = new Map(), hideT;
  const showChrome = () => { el.classList.remove('idle'); clearTimeout(hideT); hideT = setTimeout(() => el.classList.add('idle'), 2500); };
  const imgAt = i => {
    let im = imgs.get(i);
    if (!im) { im = new Image(); im.decoding = 'async'; im.className = 'r-img'; im.draggable = false; im.src = urls[i]; im.onerror = () => { if (i === cur) msg.textContent = 'Страница не загрузилась. Нажмите, чтобы повторить.'; }; imgs.set(i, im); box.append(im); im.decode?.().catch(() => {}); }
    return im;
  };
  const show = i => {
    cur = Math.max(0, Math.min(urls.length - 1, i));
    msg.textContent = '';
    for (let k = cur - 2; k <= cur + 2; k++) if (k >= 0 && k < urls.length) imgAt(k);
    for (const [k, im] of imgs) { im.classList.toggle('on', k === cur); if (Math.abs(k - cur) > 4) { im.remove(); imgs.delete(k); } }
    $('.r-count', el).textContent = `${cur + 1} / ${urls.length}`;
    slider.max = urls.length; slider.value = cur + 1;
    savePage(m, ch, cur, urls.length);
  };
  const chapters = () => offline ? d.chapters.filter(c => savedFiles(m, c)) : d.chapters;
  async function loadChapter(i, pageNo) {
    const list = chapters();
    if (i < 0 || i >= list.length) return;
    const g = ++gen; index = i; ch = list[i];
    $('.r-ch', el).textContent = chapterTitle(ch);
    $('[data-r=prevch]', el).disabled = i <= 0; $('[data-r=nextch]', el).disabled = i >= list.length - 1;
    imgs.forEach(im => im.remove()); imgs = new Map(); urls = [];
    msg.innerHTML = '<div class="spinner"></div>';
    try {
      const files = savedFiles(m, ch);
      const u = files ? files.map(imgURL) : (await pages(m, ch)).map(imgURL);
      if (g !== gen) return;
      urls = u; show(pageNo === -1 ? urls.length - 1 : Math.min(pageNo || 0, urls.length - 1));
    } catch (e) { if (g === gen) msg.textContent = errText(e); }
  }
  const next = () => { if (!urls.length) return; if (cur < urls.length - 1) show(cur + 1); else if (index < chapters().length - 1) loadChapter(index + 1, 0); else { showChrome(); toast('Это последняя глава'); } };
  const prev = () => { if (!urls.length) return; if (cur > 0) show(cur - 1); else if (index > 0) loadChapter(index - 1, -1); };
  const close = () => { gen++; el.remove(); document.removeEventListener('keydown', key, true); clearTimeout(hideT); onClose?.(); };
  const key = e => {
    if ($('.modal-back')) return;
    const k = e.key;
    if (k === 'Escape' || k === 'Backspace') close();
    else if (k === 'ArrowRight' || k === 'ArrowDown' || k === 'PageDown' || (k === ' ' && !e.shiftKey)) next();
    else if (k === 'ArrowLeft' || k === 'ArrowUp' || k === 'PageUp' || (k === ' ' && e.shiftKey)) prev();
    else if (k === 'Home' && urls.length) show(0);
    else if (k === 'End' && urls.length) show(urls.length - 1);
    else if (k === 'f' || k === 'F') { el.requestFullscreen ? (document.fullscreenElement ? document.exitFullscreen() : el.requestFullscreen()) : null; }
    else return;
    e.preventDefault(); e.stopPropagation();
  };
  document.addEventListener('keydown', key, true);
  el.addEventListener('mousemove', showChrome);
  el.addEventListener('click', e => {
    const b = e.target.closest('[data-r]');
    if (b) { const a = b.dataset.r; if (a === 'close') close(); if (a === 'prevch') loadChapter(index - 1, 0); if (a === 'nextch') loadChapter(index + 1, 0); return; }
    if (e.target.closest('.r-top, .r-bottom')) return;
    if (msg.textContent.startsWith('Страница не')) { const im = imgs.get(cur); if (im) { im.src = urls[cur] + (urls[cur].includes('?') ? '&' : '?') + 'r=' + Date.now(); msg.textContent = ''; } return; }
    // Левые 30 % — назад, правые 30 % — вперёд, середина — показать или скрыть панели.
    const x = e.clientX / innerWidth;
    if (x < .3) prev(); else if (x > .7) next(); else el.classList.toggle('idle');
  });
  el.addEventListener('wheel', e => { if (Math.abs(e.deltaY) < 30) return; e.preventDefault(); (e.deltaY > 0 ? next : prev)(); }, { passive: false });
  slider.addEventListener('input', () => show(+slider.value - 1));
  showChrome();
  const list = chapters(), target = d.chapters[index];
  loadChapter(Math.max(0, list.indexOf(target)), startPage);
}

// ---------- Аккаунты MangaLib и Com-X ----------
export async function AccountPanels(host, alive) {
  if (!available()) return;
  const lib = document.createElement('div'), cx = document.createElement('div');
  lib.className = cx.className = 'panel';
  host.append(lib, cx);
  const drawLib = async () => {
    const s = await M().libStatus().catch(() => ({ logged: false }));
    if (!alive()) return;
    lib.innerHTML = `<h2>MangaLib</h2>` + (s.logged ? `<div class="kv"><span>Аккаунт</span><b>${esc(s.name || 'Вход выполнен')}</b></div><div class="actions" style="margin-top:16px"><button class="btn" data-a="out">Выйти</button></div>`
      : `<p>Без входа MangaLib скрывает часть тайтлов и глав. Вход откроется в окне сайта: там вводится логин и пароль, или можно войти через VK и Яндекс. Приложение хранит только ключ входа.</p><p class="error" hidden></p><div class="actions"><button class="btn primary" data-a="in">Войти в MangaLib</button><button class="btn" data-a="in" data-p="vkontakte">Через VK</button><button class="btn" data-a="in" data-p="yandex">Через Яндекс</button></div>`);
    $('[data-a=out]', lib)?.addEventListener('click', async () => { if (!await Acc.askLogout('mangalib', 'MangaLib')) return; await M().libLogout(); toast('Вы вышли из MangaLib'); drawLib(); });
    lib.querySelectorAll('[data-a=in]').forEach(btn => btn.addEventListener('click', async e => {
      const b = e.target.closest('button'); lib.querySelectorAll('[data-a=in]').forEach(x => { x.disabled = true; }); b.textContent = 'Окно входа открыто…';
      try { const name = await M().libLogin(b.dataset.p); toast(name ? `Вы вошли в MangaLib как ${name}` : 'Вы вошли в MangaLib'); }
      catch (err) { if (alive()) { const p = $('.error', lib); p.textContent = errText(err); p.hidden = false; } }
      if (alive()) drawLib();
    }));
  };
  const drawCx = async () => {
    const logged = await M().comxStatus().catch(() => false);
    if (!alive()) return;
    cx.innerHTML = `<h2>Com-X</h2>` + (logged ? `<div class="kv"><span>Аккаунт</span><b>Вход выполнен</b></div><div class="actions" style="margin-top:16px"><button class="btn" data-a="out">Выйти</button></div>`
      : `<p>Некоторые главы Com-X открываются только после входа. Откроется окно сайта: войдите там и закройте его.</p><p class="error" hidden></p><div class="actions"><button class="btn primary" data-a="in">Войти в Com-X</button></div>`);
    $('[data-a=out]', cx)?.addEventListener('click', async () => { if (!await Acc.askLogout('comx', 'Com-X')) return; await M().comxLogout().catch(() => {}); toast('Вы вышли из Com-X'); drawCx(); });
    $('[data-a=in]', cx)?.addEventListener('click', async e => {
      const b = e.target.closest('button'); b.disabled = true; b.textContent = 'Окно входа открыто…';
      try { if (await M().comxLogin()) toast('Вы вошли в Com-X'); }
      catch (err) { if (alive()) { const p = $('.error', cx); p.textContent = errText(err); p.hidden = false; } }
      if (alive()) drawCx();
    });
  };
  drawLib(); drawCx();
}
