// Экраны Yoru: аниме (главная, поиск, «Моё», расписание, страница аниме), манга и аккаунты.
import * as D from './data.js';
import { openPlayer } from './player.js';
import * as O from './offline.js';
import * as Sv from './servers.js';
import * as Mg from './manga.js';
import * as Acc from './account.js';
import * as Sh from './shiki.js';

const $ = (s, el = document) => el.querySelector(s);
const main = $('#main');
export const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const icon = {
  play: '<svg class="fill" viewBox="0 0 24 24"><path d="M7 4.8v14.4a1 1 0 0 0 1.5.86l12-7.2a1 1 0 0 0 0-1.72l-12-7.2A1 1 0 0 0 7 4.8z"/></svg>',
  heart: '<svg viewBox="0 0 24 24"><path d="M12 20.5s-7.5-4.6-7.5-10.2A4.3 4.3 0 0 1 12 7.6a4.3 4.3 0 0 1 7.5 2.7c0 5.6-7.5 10.2-7.5 10.2z"/></svg>',
  back: '<svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg>',
  left: '<svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg>',
  right: '<svg viewBox="0 0 24 24"><path d="M9 5l7 7-7 7"/></svg>',
  search: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>',
  globe: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z"/></svg>'
};
export { icon };

// ---------- Общие мелочи ----------
let toastTimer;
export function toast(text) { const t = $('#toast'); t.textContent = text; t.classList.add('show'); clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('show'), 3200); }
const known = new Map();  // id → карточка аниме, для кликов по карточкам
const keep = it => { known.set(it.id, it); return it; };
function img(src, cls = '') { return src ? `<img class="${cls}" src="${esc(src)}" loading="lazy" decoding="async" alt="">` : ''; }
// Размытый фон рисуется один раз в маленький холст: живой CSS blur() пересчитывался в каждом кадре прокрутки.
const backdrops = new Map();
function backdrop(src, filter) {
  const key = src + ' ' + filter;
  let c = backdrops.get(key);
  if (!c) {
    c = document.createElement('canvas'); c.className = 'bg'; c.width = 120; c.height = 180;
    const im = new Image(); im.src = src;
    // Постер шире холста, чтобы размытие не темнело к краям. Не загрузился — не запоминаем, в следующий раз попробуем снова.
    im.decode().then(() => { const x = c.getContext('2d'); x.filter = filter; x.drawImage(im, -16, -24, c.width + 32, c.height + 48); }, () => { if (backdrops.get(key) === c) backdrops.delete(key); });
    backdrops.set(key, c);
    if (backdrops.size > 6) backdrops.delete(backdrops.keys().next().value);
  }
  return c;
}
function card(it, { progress = null, fresh = false } = {}) {
  keep(it);
  const p = progress != null ? `<div class="progress"><i style="width:${Math.round(progress * 100)}%"></i></div>` : '';
  return `<button class="card" data-open="${it.id}"><div class="poster">${img(it.posterSmall)}${Sh.uhdBadge(it)}${fresh ? '<span class="badge-new">НОВАЯ СЕРИЯ</span>' : ''}${p}</div><div class="t">${esc(it.title)}</div>${Sh.capHTML(it)}</button>`;
}
function wideCard(it, label, progress) {
  keep(it);
  return `<button class="card wide" data-open="${it.id}" data-resume="1"><div class="poster">${img(it.poster)}<div class="progress"><i style="width:${Math.round(progress * 100)}%"></i></div><span class="play-mark">${icon.play}</span></div><div class="t">${esc(it.title)}</div><div class="s">${esc(label)}</div></button>`;
}
const loadingState = () => `<div class="state"><div class="spinner"></div></div>`;
const errorState = (msg, retry = true) => `<div class="state"><div><b>Не получилось загрузить</b>${esc(msg)}${retry ? '<br><button class="btn" data-retry>Повторить</button>' : ''}</div></div>`;
const skeletonRow = () => `<div class="row">${'<div class="skel-card skeleton"></div>'.repeat(8)}</div>`;

// Постеры проявляются после загрузки; битые убираем (инлайн-обработчики запрещены CSP).
document.addEventListener('load', e => { if (e.target.tagName === 'IMG') e.target.classList.add('loaded'); }, true);
document.addEventListener('error', e => { if (e.target.tagName === 'IMG' && e.target.closest('.card')) e.target.remove(); }, true);

// ---------- Навигация ----------
// Каждая вкладка хранит свой стек экранов; «Назад» возвращает и прокрутку.
const stacks = { home: [{ view: 'home' }], search: [{ view: 'search' }], mine: [{ view: 'mine' }], schedule: [{ view: 'schedule' }], downloads: [{ view: 'downloads' }], account: [{ view: 'account' }],
  manga: [{ view: 'mangaHome' }], mangaMine: [{ view: 'mangaMine' }] };
let tab = 'home';
// Разделы «Аниме» и «Манга»: у каждого свои вкладки в боковой панели, раздел помнит свою последнюю вкладку.
// Аккаунты общие и открываются из любого раздела.
const MODE_OF = { home: 'anime', search: 'anime', mine: 'anime', schedule: 'anime', downloads: 'anime', manga: 'manga', mangaMine: 'manga' };
const lastTab = { anime: 'home', manga: 'manga' };
function setMode(m) {
  $('#nav').dataset.mode = m;
  document.querySelectorAll('[data-mode]').forEach(b => b.classList.toggle('on', b.dataset.mode === m));
  D.S.set('mode', m);
}
const top = () => stacks[tab][stacks[tab].length - 1];
function setTab(t) {
  if (t === tab) { if (stacks[t].length > 1) { stacks[t].length = 1; render(); } else main.scrollTo({ top: 0, behavior: 'smooth' }); return; }
  top().scroll = main.scrollTop;
  tab = t;
  const md = MODE_OF[t]; if (md) { lastTab[md] = t; setMode(md); }
  document.querySelectorAll('[data-tab]').forEach(b => b.classList.toggle('active', b.dataset.tab === t));
  render(top().scroll || 0);
}
export function push(route) { top().scroll = main.scrollTop; stacks[tab].push(route); render(0); }
function back() { if (stacks[tab].length > 1) { stacks[tab].pop(); render(top().scroll || 0); } }
let renderId = 0;
function render(scroll = 0) {
  const r = top(); const id = ++renderId;
  const alive = () => id === renderId;
  main.innerHTML = '';
  const view = { home: Home, search: Search, mine: Mine, schedule: Schedule, account: Account, detail: Detail, downloads: (r, a) => O.DownloadsView(r, a, main),
    mangaHome: Mg.MangaHome, mangaMine: Mg.MangaMine, mangaTitle: Mg.MangaTitle }[r.view];
  view(r, alive, main);
  requestAnimationFrame(() => { main.scrollTop = scroll; });
}
document.addEventListener('click', e => {
  const t = e.target.closest('[data-tab]'); if (t) return setTab(t.dataset.tab);
  const md = e.target.closest('[data-mode]'); if (md) return setTab(lastTab[md.dataset.mode]);
  const o = e.target.closest('[data-open]');
  if (o) { const it = known.get(+o.dataset.open); if (it) push({ view: 'detail', item: it, resume: !!o.dataset.resume }); return; }
  if (e.target.closest('[data-back]')) back();
});
document.addEventListener('mouseup', e => { if (e.button === 3) back(); });
document.addEventListener('keydown', e => {
  if ($('#player, #reader') || e.target.matches('input')) return;
  if ((e.key === 'Escape' || e.key === 'Backspace' || (e.altKey && e.key === 'ArrowLeft') || (e.metaKey && e.key === '[')) && !$('.modal-back')) back();
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); setTab($('#nav').dataset.mode === 'manga' ? 'manga' : 'search'); if (stacks[tab].length > 1) { stacks[tab].length = 1; render(); } setTimeout(() => $('.search-box input')?.focus(), 0); }
});

// Стрелки переводят фокус на ближайшую кнопку в эту сторону, Enter её нажимает.
// Так приложением можно пользоваться с пульта телевизора и без мыши.
// Подсветку рисуем своим классом .kf: WebKitGTK в Tauri иногда считает окно неактивным и не применяет :focus.
let kf = null;
function markFocus(el) { kf?.classList.remove('kf'); kf = el; el?.classList.add('kf'); }
document.addEventListener('focusin', e => { if (document.body.classList.contains('keys')) markFocus(e.target); });
const DIRS = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
const focusable = 'button:not([disabled]), a[href], input, select, [tabindex]:not([tabindex="-1"])';
function moveFocus([dx, dy]) {
  const scope = $('.modal-back') || document;
  const visible = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden'; };
  const all = [...scope.querySelectorAll(focusable)].filter(visible);
  const ae = document.activeElement && document.activeElement !== document.body ? document.activeElement : kf?.isConnected ? kf : null;
  const cur = ae && scope.contains(ae) && visible(ae) ? ae : null;
  if (!cur) {
    // Фокус пропал (сменилась страница): вернуться на карточку, которую открывали, иначе — первая кнопка на экране.
    const inView = el => { const r = el.getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight; };
    const prev = lastOpen && [...main.querySelectorAll('[data-open]')].find(el => el.dataset.open === lastOpen && visible(el));
    const play = $('#play');
    return prev || (play && visible(play) ? play : null) || all.find(el => main.contains(el) && inView(el)) || all.find(el => main.contains(el)) || all[0];
  }
  const a = cur.getBoundingClientRect(), ax = a.left + a.width / 2, ay = a.top + a.height / 2;
  // Вверх-вниз не выходим из своей части экрана (меню слева или содержимое), пока там есть куда идти.
  const area = el => el.closest('#sidebar, #main, .modal-back');
  const same = dy ? all.filter(el => area(el) === area(cur)) : all;
  let best = null, bestScore = Infinity;
  for (const el of same) {
    if (el === cur) continue;
    const b = el.getBoundingClientRect();
    // Элемент должен лежать по ту сторону от текущего; главное расстояние — вдоль направления, сдвиг вбок дороже.
    const along = dx ? (dx > 0 ? b.left - a.right : a.left - b.right) : (dy > 0 ? b.top - a.bottom : a.top - b.bottom);
    if (along < -4) continue;
    const side = dx ? Math.max(0, Math.abs((b.top + b.height / 2) - ay) - (a.height + b.height) / 4)
                    : Math.max(0, Math.abs((b.left + b.width / 2) - ax) - (a.width + b.width) / 4);
    const score = Math.max(0, along) + side * (dx ? 4 : 2);
    if (score < bestScore) { bestScore = score; best = el; }
  }
  return best;
}
document.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !$('#player, #reader') && kf?.isConnected && document.body.classList.contains('keys') && !kf.matches('input, select, textarea')) {
    e.preventDefault(); kf.click(); return;
  }
  const d = DIRS[e.key];
  if (!d || $('#player, #reader') || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
  if (e.target.matches('input, select, textarea') && d[0]) return;  // в поле ввода влево-вправо двигают курсор
  document.body.classList.add('keys');
  const el = moveFocus(d);
  if (!el) return;
  e.preventDefault();
  el.focus({ preventScroll: true });
  markFocus(el);
  el.scrollIntoView({ block: el.closest('#nav') ? 'nearest' : 'center', inline: 'nearest', behavior: 'smooth' });
});
document.addEventListener('mousedown', () => { document.body.classList.remove('keys'); markFocus(null); });
let lastOpen = null;
document.addEventListener('focusin', e => { if (e.target.dataset?.open && main.contains(e.target)) lastOpen = e.target.dataset.open; });

// ---------- Главная ----------
const year = new Date().getFullYear();
const SHELVES = [
  { title: `Лучшее ${year} года`, params: { year } },
  { title: 'Фильмы', params: { type: 'movie' } },
  { title: 'Экшен', params: { genres: 1 } },
  { title: 'Романтика', params: { genres: 22 } },
  { title: `Лучшее ${year - 1} года`, params: { year: year - 1 } },
  { title: 'Комедия', params: { genres: 4 } },
  { title: 'Исекай', params: { genres: 62 } },
  { title: 'Повседневность', params: { genres: 36 } },
  { title: 'Фэнтези', params: { genres: 10 } },
  { title: 'Детективы', params: { genres: 7 } }
];
const shelfCache = new Map();
const loadShelf = params => { const k = JSON.stringify(params); if (!shelfCache.has(k)) shelfCache.set(k, D.shelf(params).catch(e => { shelfCache.delete(k); throw e; })); return shelfCache.get(k); };

function Home(_r, alive) {
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  // Баннера наверху больше нет (как на телефонах): сразу «Продолжить просмотр» и полки.
  page.innerHTML = `<div style="height:14px"></div><div id="continue"></div><div id="favs"></div><div id="shelves"></div>`;
  // «Продолжить просмотр»: начатые и недосмотренные.
  const cont = D.history().filter(it => D.lastEpisode(it) && !D.finished(it)).slice(0, 20);
  if (cont.length) $('#continue', page).innerHTML = `<section class="shelf"><div class="shelf-head"><h2>Продолжить просмотр</h2>${arrows()}</div><div class="row wide-row">${cont.map(it => wideCard(it, D.lastEpisodeTitle(it) || 'Продолжить', D.fraction(D.lastEpisode(it)))).join('')}</div></section>`;
  const favs = D.favorites().filter(D.hasNew);
  if (favs.length) $('#favs', page).innerHTML = `<section class="shelf"><div class="shelf-head"><h2>Новые серии в избранном</h2>${arrows()}</div><div class="row">${favs.map(it => card(it, { fresh: true })).join('')}</div></section>`;
  const list = $('#shelves', page);
  const all = [{ title: 'Сейчас выходят', params: { isAiring: 1 } }, ...SHELVES];
  for (const s of all) {
    const sec = document.createElement('section'); sec.className = 'shelf';
    sec.innerHTML = `<div class="shelf-head"><h2>${esc(s.title)}</h2>${arrows()}</div>${skeletonRow()}`;
    list.append(sec);
    const fill = () => loadShelf(s.params).then(items => {
      if (!alive()) return;
      sec.querySelector('.row, .state')?.remove();
      sec.insertAdjacentHTML('beforeend', items.length ? `<div class="row">${items.map(it => card(it)).join('')}</div>` : `<div class="state">Пусто</div>`);
    }).catch(e => { if (!alive()) return; sec.querySelector('.row, .state')?.remove(); sec.insertAdjacentHTML('beforeend', errorState(e.message)); sec.querySelector('[data-retry]').onclick = () => { sec.querySelector('.state').outerHTML = skeletonRow(); fill(); }; });
    fill();
  }
  bindArrows(page);
}
function arrows() { return `<div class="arrows"><button data-scroll="-1" aria-label="Назад">${icon.left}</button><button data-scroll="1" aria-label="Вперёд">${icon.right}</button></div>`; }
function bindArrows(root) {
  root.addEventListener('click', e => {
    const b = e.target.closest('[data-scroll]'); if (!b) return;
    const row = b.closest('.shelf').querySelector('.row');
    row?.scrollBy({ left: +b.dataset.scroll * row.clientWidth * .85 });
  });
}
// ---------- Поиск ----------
const GENRES = [[1, 'Экшен'], [2, 'Приключения'], [4, 'Комедия'], [8, 'Драма'], [10, 'Фэнтези'], [22, 'Романтика'], [24, 'Фантастика'], [36, 'Повседневность'], [62, 'Исекай'], [7, 'Детектив'], [37, 'Сверхъестественное'], [23, 'Школа'], [30, 'Спорт'], [18, 'Меха'], [40, 'Психологическое'], [41, 'Триллер'], [13, 'Исторический'], [19, 'Музыка'], [63, 'Злодейка'], [76, 'Гурман']];
function Search(r, alive) {
  r.query ??= ''; r.genre ??= 0;
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  const manga = Mg.available();
  page.innerHTML = `<div class="page-head"><h1>Поиск</h1></div>
    <label class="search-box">${icon.search}<input type="search" placeholder="${manga ? 'Аниме, манга или ссылка Шикимори' : 'Название аниме или ссылка Шикимори'}" value="${esc(r.query)}" spellcheck="false"><span class="spinner small" hidden></span></label>
    <div class="chips">${GENRES.map(([id, t]) => `<button class="chip ${r.genre === id ? 'on' : ''}" data-genre="${id}">${t}</button>`).join('')}</div>
    <div id="m-results"></div><div id="results"></div>`;
  const input = $('input', page), out = $('#results', page), mOut = $('#m-results', page), spin = $('.search-box .spinner', page);
  let items = [], offset = 0, done = false, busy = false, gen = 0, q = '', note = '';
  const params = () => q ? { query: q } : r.genre ? { genres: r.genre } : { isAiring: 1 };
  const heading = () => note || (q ? 'Аниме' : r.genre ? GENRES.find(g => g[0] === r.genre)[1] : 'Сейчас выходят');
  // Манга по тому же запросу — строкой над аниме (MangaLib; Com-X — во вкладке «Манга»).
  async function loadManga(g, text) {
    mOut.innerHTML = '';
    if (!manga || !text) return;
    try {
      const p = await Mg.search('mangalib', text, 1);
      if (g !== gen || !alive() || !p.items.length) return;
      mOut.innerHTML = `<section class="shelf"><div class="shelf-head"><h2>Манга</h2>${arrows()}</div><div class="row">${p.items.slice(0, 20).map(Mg.cardHTML).join('')}</div></section>`;
    } catch {}
  }
  async function load(reset) {
    if (reset) {
      items = []; offset = 0; done = false; gen++; note = ''; q = r.query.trim();
      out.innerHTML = loadingState(); mOut.innerHTML = '';
      const g = gen, l = q && Sh.link(q);
      if (l) {
        // Ссылка Шикимори: аниме ищем по id MyAnimeList, мангу — по названию.
        spin.hidden = false;
        const f = await Sh.resolve(l).catch(() => null);
        if (g !== gen || !alive()) return;
        spin.hidden = true;
        if (f?.anime) { done = true; out.innerHTML = `<div class="section-title" style="margin-top:0">Найдено по ссылке Шикимори</div><div class="grid">${card(f.anime)}</div>`; return; }
        if (!f) { done = true; out.innerHTML = `<div class="state"><div><b>Ссылка не открылась</b>Шикимори не ответил или такой страницы нет.</div></div>`; return; }
        q = f.title; note = f.kind === 'manga' ? '' : 'Похожее по названию';
        if (f.kind === 'manga') { done = true; out.innerHTML = ''; await loadManga(g, f.title); if (g === gen && !mOut.innerHTML) out.innerHTML = `<div class="state"><div><b>Манга не найдена</b>«${esc(f.title)}» нет на MangaLib — попробуйте вкладку «Манга» (Com-X).</div></div>`; return; }
      } else loadManga(g, q);
    }
    if (busy && !reset || done) return;
    const g = gen; busy = true;
    try {
      const more = await D.shelf(params(), offset);
      if (g !== gen || !alive()) return;
      items.push(...more.filter(m => !items.some(i => i.id === m.id))); offset += 24; done = more.length < 24;
      out.innerHTML = items.length ? `<div class="section-title" style="margin-top:0">${esc(heading())}</div><div class="grid">${items.map(it => card(it)).join('')}</div>` : `<div class="state"><div><b>${manga ? 'Аниме не нашлось' : 'Ничего не нашлось'}</b>Попробуйте другое название — можно по-русски, по-английски или ромадзи.</div></div>`;
    } catch (e) { if (g === gen && alive()) { out.innerHTML = errorState(e.message); $('[data-retry]', out).onclick = () => load(true); } }
    finally { if (g === gen) busy = false; }
  }
  let t;
  input.addEventListener('input', () => { r.query = input.value; clearTimeout(t); t = setTimeout(() => load(true), 350); });
  page.addEventListener('click', e => { const c = e.target.closest('[data-genre]'); if (!c) return; const id = +c.dataset.genre; r.genre = r.genre === id ? 0 : id; page.querySelectorAll('.chip').forEach(x => x.classList.toggle('on', +x.dataset.genre === r.genre)); if (r.genre) { r.query = ''; input.value = ''; } load(true); });
  bindArrows(page);
  const onScroll = () => { if (!alive()) return main.removeEventListener('scroll', onScroll); if (main.scrollTop + main.clientHeight > main.scrollHeight - 600) load(false); };
  main.addEventListener('scroll', onScroll);
  load(true);
  if (!r.query) setTimeout(() => input.focus(), 50);
}

// ---------- Моё ----------
function Mine(r) {
  r.part ??= 'favorites';
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  const draw = () => {
    if (r.part === 'shiki' && !Sh.acc.signedIn) r.part = 'favorites';
    const tabs = `<div class="page-head"><h1>Моё</h1></div>
      <div class="tabs"><button data-part="favorites" class="${r.part === 'favorites' ? 'on' : ''}">Избранное</button><button data-part="history" class="${r.part === 'history' ? 'on' : ''}">История</button>${Sh.acc.signedIn ? `<button data-part="shiki" class="${r.part === 'shiki' ? 'on' : ''}">Шикимори</button>` : ''}</div>`;
    if (r.part === 'shiki') { page.innerHTML = tabs + shikiList(r); return; }
    const list = r.part === 'favorites' ? D.favorites() : D.history();
    page.innerHTML = tabs + `
      ${list.length ? `<div class="grid">${list.map(it => card(it, { fresh: r.part === 'favorites' && D.hasNew(it), progress: r.part === 'history' && D.lastEpisode(it) ? D.fraction(D.lastEpisode(it)) : null })).join('')}</div>`
        : `<div class="state"><div><b>${r.part === 'favorites' ? 'Здесь пока пусто' : 'Вы ещё ничего не смотрели'}</b>${r.part === 'favorites' ? 'Нажмите ♡ на странице аниме, чтобы добавить его сюда.' : 'Начатые аниме появятся здесь.'}</div></div>`}`;
  };
  page.addEventListener('click', e => {
    const b = e.target.closest('[data-part]'); if (b) { r.part = b.dataset.part; draw(); return; }
    const f = e.target.closest('[data-sfilter]'); if (f) { r.filter = f.dataset.sfilter; draw(); return; }
    const o = e.target.closest('[data-smal]'); if (o) openShikiRate(+o.dataset.smal, o);
  });
  const off = Sh.onAcc(() => { if (!document.contains(page)) return off(); if (r.part === 'shiki' && !Sh.acc.syncing) draw(); });
  draw();
}
// Список с Шикимори: фильтр по статусу, постер, прогресс, оценки.
function shikiList(r) {
  const all = Sh.list(), f = r.filter || 'all';
  const rows = f === 'all' ? all : all.filter(x => x.status === f);
  const count = s => all.filter(x => x.status === s).length;
  const chips = `<div class="chips"><button class="chip ${f === 'all' ? 'on' : ''}" data-sfilter="all">Все · ${all.length}</button>${Sh.STATUSES.filter(([s]) => count(s)).map(([s, t]) => `<button class="chip ${f === s ? 'on' : ''}" data-sfilter="${s}">${t} · ${count(s)}</button>`).join('')}</div>`;
  if (!all.length) return `<div class="state">${Sh.acc.loading || Sh.acc.syncing ? '<div class="spinner"></div>' : `<div><b>Список пуст</b>${esc(Sh.acc.message || 'На Шикимори пока нет отмеченных аниме.')}</div>`}</div>`;
  return chips + `<div class="shiki-list">${rows.map(x => `<button class="shiki-row" data-smal="${x.malId}"><img src="${esc(x.poster)}" loading="lazy" decoding="async" alt=""><div style="min-width:0"><b>${esc(x.title)}</b><span>${esc(Sh.statusTitle(x.status))}${x.episodes ? ` · ${x.episodes}${x.total ? ' из ' + x.total : ''} сер.` : ''}</span></div><div class="shiki-sc">${x.siteScore ? `<span class="sc">Shiki ${x.siteScore.toFixed(2)}</span>` : ''}${x.score ? `<span class="mine">★ ${x.score}</span>` : ''}</div></button>`).join('')}</div>`;
}
// Открыть аниме из списка Шикимори: ищем его в Anime 365 по id MyAnimeList.
async function openShikiRate(mal, btn) {
  btn.classList.add('busy');
  try {
    const map = D.S.get('shiki-map', {});
    let item = null;
    if (map[mal]) item = (await D.details(map[mal]).catch(() => null))?.item;
    if (!item) { const f = await D.shelf({ myAnimeListId: mal }, 0, 1); item = f[0]; if (item) { map[mal] = item.id; D.S.set('shiki-map', map); } }
    if (!item) { toast('Этого аниме нет в Anime 365'); return; }
    push({ view: 'detail', item });
  } catch (e) { toast(e.message); } finally { btn.classList.remove('busy'); }
}

// ---------- Расписание ----------
const WEEKDAYS = ['Воскресенье', 'Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота'];
let scheduleCache = null;
function Schedule(_r, alive) {
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  page.innerHTML = `<div class="page-head"><h1>Расписание</h1></div><div id="days">${loadingState()}</div>`;
  const out = $('#days', page);
  const load = () => {
    scheduleCache ??= D.schedule().catch(e => { scheduleCache = null; throw e; });
    scheduleCache.then(days => {
      if (!alive()) return;
      const today = new Date().getDay();
      out.innerHTML = days.length ? days.map(d => `<section class="day"><h2>${d.weekday === today ? 'Сегодня' : d.weekday === (today + 6) % 7 ? 'Вчера' : WEEKDAYS[d.weekday]}<small>${d.items.length} ${plural(d.items.length, 'аниме', 'аниме', 'аниме')}</small></h2><div class="sched">${d.items.map(([it, ep]) => {
        keep(it);
        const fresh = Date.now() - ep.uploaded < 86400e3;
        return `<button data-open="${it.id}"><img src="${esc(it.posterSmall)}" loading="lazy" decoding="async" alt=""><div style="min-width:0"><b>${esc(it.title)}</b><span class="${fresh ? 'fresh' : ''}">${esc(ep.title)} · ${ep.uploaded.toLocaleTimeString('ru', { hour: '2-digit', minute: '2-digit' })}</span></div></button>`;
      }).join('')}</div></section>`).join('') : `<div class="state">Нет выходящих аниме</div>`;
    }).catch(e => { if (!alive()) return; out.innerHTML = errorState(e.message); $('[data-retry]', out).onclick = () => { out.innerHTML = loadingState(); load(); }; });
  };
  load();
}
export const plural = (n, one, few, many) => { const a = n % 10, b = n % 100; return a === 1 && b !== 11 ? one : a >= 2 && a <= 4 && (b < 12 || b > 14) ? few : many; };

// ---------- Аккаунт ----------
let account = null;
async function refreshAccount() {
  if (!(await window.yoru.signedIn())) { account = null; paintAccount(); return; }
  try {
    const d = await D.api('me', {}, true);
    account = { name: d.name || 'Аккаунт', premium: d.isPremium === true || +d.isPremium === 1, until: D.moscow(d.premiumUntil) };
  } catch { account = account || { name: 'Аккаунт' }; }
  paintAccount();
}
function paintAccount() {
  $('#account-button .who').textContent = account ? account.name : 'Аккаунты';
  $('#account-button .avatar').textContent = account ? account.name.trim().charAt(0).toUpperCase() : '';
}
function Account(_r, alive) {
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  const draw = async () => {
    const signed = await window.yoru.signedIn();
    const version = await window.yoru.version();
    if (!alive()) return;
    page.innerHTML = `<div class="page-head"><h1>Аккаунты</h1></div><div id="yoru-acc"></div>` + (signed ? `<div class="panel"><h2>Anime 365</h2>
      <div class="kv"><span>Аккаунт</span><b>${esc(account?.name || 'Вход выполнен')}</b></div>
      <div class="kv"><span>Подписка</span><b>${account?.premium ? 'Активна' + (account.until ? ' до ' + account.until.toLocaleDateString('ru') : '') : account?.premium === false ? 'Нет' : '…'}</b></div>
      <div class="actions" style="margin-top:16px"><button class="btn" id="site">${icon.globe}Anime 365</button><button class="btn" id="logout">Выйти</button></div></div>
`
      : `<form class="panel" id="login"><h2>Вход в Anime 365</h2><p>Нужен аккаунт с подпиской — без неё сайт не даёт видео. Пароль уходит только на сайт, приложение хранит лишь ключ входа.</p>
      <label class="field"><span>Почта</span><input name="email" type="email" autocomplete="username" required></label>
      <label class="field"><span>Пароль</span><input name="password" type="password" autocomplete="current-password" required></label>
      <p class="error" hidden></p><button class="btn primary" type="submit">Войти</button></form>`) +
      `<div id="shiki-acc"></div><div id="manga-acc"></div><div class="panel"><h2>Yoru ${esc(version)}</h2><p id="upd-text">Обновления проверяются автоматически.</p><div class="actions"><button class="btn" id="check">Проверить обновления</button></div></div>`;
    $('#site', page)?.addEventListener('click', () => window.yoru.openExternal('https://smotret-anime.app/'));
    $('#logout', page)?.addEventListener('click', async () => { if (!await Acc.askLogout('anime365', 'Anime 365')) return; await window.yoru.logout(); account = null; paintAccount(); draw(); });
    $('#login', page)?.addEventListener('submit', async e => {
      e.preventDefault();
      const f = e.target, err = $('.error', f), btn = $('button', f);
      btn.disabled = true; btn.textContent = 'Вход…'; err.hidden = true;
      const r = await window.yoru.login(f.email.value.trim(), f.password.value);
      if (r.error) { err.textContent = r.error; err.hidden = false; btn.disabled = false; btn.textContent = 'Войти'; return; }
      await refreshAccount(); if (alive()) draw(); toast('Вы вошли в Anime 365');
    });
    $('#check', page).addEventListener('click', () => checkUpdate(true));
    Mg.AccountPanels($('#manga-acc', page), alive);
    Acc.Panel($('#yoru-acc', page));
    ShikiPanel($('#shiki-acc', page), alive);
  };
  draw();
}

// Шикимори: ключи приложения (один раз) → вход на сайте → оценки, статусы и перенос просмотренного в обе стороны.
function ShikiPanel(box, alive) {
  if (!Sh.acc.available) return;
  let editing = false, error = '';
  const a = Sh.acc;
  const draw = () => {
    if (!alive() || !document.contains(box)) return off();
    const busy = a.syncing ? `<div class="shiki-step"><div class="spinner small"></div>${esc(a.step || 'Синхронизация…')}</div>` : '';
    if (!a.configured || editing) {
      box.innerHTML = `<form class="panel" id="shiki-keys"><h2>Шикимори</h2>
        <p>Оценки, статусы и просмотренные серии синхронизируются с вашим списком на Шикимори. Если вы уже вошли в Шикимори на другом устройстве с аккаунтом Yoru, вход придёт сюда сам — достаточно войти в аккаунт Yoru. Иначе один раз создайте приложение на сайте:</p>
        <ol class="steps"><li>Откройте <button type="button" class="link" id="shiki-apps">shikimori.io/oauth/applications</button> и нажмите «Новое приложение».</li>
        <li>Название — «Yoru», Redirect URI — <code>yoru://shikimori</code>, право — <b>user_rates</b>.</li>
        <li>Вставьте сюда Client ID и Client Secret.</li></ol>
        <label class="field"><span>Client ID</span><input name="id" autocomplete="off" spellcheck="false" required></label>
        <label class="field"><span>Client Secret</span><input name="secret" type="password" autocomplete="off" spellcheck="false" required></label>
        <p class="error" ${error ? '' : 'hidden'}>${esc(error)}</p>
        <div class="actions"><button class="btn primary" type="submit">Сохранить</button>${a.configured ? '<button class="btn" type="button" id="shiki-cancel">Отмена</button>' : ''}</div></form>`;
      $('#shiki-apps', box).onclick = () => window.yoru.openExternal(Sh.SITE + '/oauth/applications');
      $('#shiki-cancel', box)?.addEventListener('click', () => { editing = false; error = ''; draw(); });
      $('#shiki-keys', box).onsubmit = async e => {
        e.preventDefault(); const f = e.target, b = $('[type=submit]', f);
        b.classList.add('busy'); b.disabled = true;
        try { await Sh.setKeys(f.id.value, f.secret.value); editing = false; error = ''; } catch (x) { error = String(x); }
        draw();
      };
      return;
    }
    if (!a.signedIn) {
      box.innerHTML = `<div class="panel"><h2>Шикимори</h2><p>Войдите, чтобы ставить оценки и вести список. Досмотренные серии будут отмечаться на Шикимори, а отмеченное там — появляться просмотренным в Yoru.</p>
        <p class="error" ${error ? '' : 'hidden'}>${esc(error)}</p>
        <div class="actions"><button class="btn primary" id="shiki-login">Войти через Шикимори</button><button class="btn" id="shiki-edit">Изменить ключи приложения</button></div></div>`;
      $('#shiki-edit', box).onclick = () => { editing = true; error = ''; draw(); };
      $('#shiki-login', box).onclick = async e => {
        const b = e.currentTarget; b.classList.add('busy'); b.disabled = true; b.lastChild.textContent = 'Окно входа открыто…';
        try { await Sh.login(); error = ''; toast('Вы вошли в Шикимори'); } catch (x) { error = String(x); }
        draw();
      };
      return;
    }
    const n = Object.keys(a.rates).length;
    box.innerHTML = `<div class="panel"><h2>Шикимори</h2>
      <div class="kv"><span>Аккаунт</span><b>${esc(a.nickname || 'Вход выполнен')}</b></div>
      <div class="kv"><span>В списке</span><b>${a.loading && !n ? '…' : n + ' ' + plural(n, 'аниме', 'аниме', 'аниме')}</b></div>
      ${busy}${!a.syncing && (a.result || a.message) ? `<p class="${a.message ? 'error' : 'shiki-ok'}" style="margin-top:12px">${esc(a.message || a.result)}</p>` : ''}
      <div class="actions" style="margin-top:16px"><button class="btn ${a.syncing ? 'busy' : ''}" id="shiki-sync" ${a.syncing ? 'disabled' : ''}>Синхронизировать просмотренное</button><button class="btn" id="shiki-site">${icon.globe}Профиль</button><button class="btn" id="shiki-out">Выйти из Шикимори</button></div></div>`;
    $('#shiki-sync', box).onclick = () => Sh.syncBoth(true);
    $('#shiki-site', box).onclick = () => window.yoru.openExternal(Sh.SITE + '/' + encodeURIComponent(a.nickname));
    $('#shiki-out', box).onclick = async () => { if (!await Acc.askLogout('shikimori', 'Шикимори')) return; await Sh.logout(); toast('Вы вышли из Шикимори'); };
  };
  const off = Sh.onAcc(draw);
  draw();
}

// Видеосерверы пользователь больше не видит: раз в сутки приложение само проверяет их скорость
// (по последней включённой серии) и подставляет самый быстрый; если он не ответит — ссылку сайта.
async function autoServers() {
  Sv.setAuto(true);
  if (Date.now() - Sv.tested() < 86400e3 || !(await window.yoru.signedIn())) return;
  try { await Sv.test(() => {}); } catch {}
}

// ---------- Страница аниме ----------
function Detail(r, alive) {
  const it = r.item;
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  const back = `<div class="top-bar"><button class="back" data-back aria-label="Назад">${icon.back}</button></div>`;
  let data = r.data, seasonList = r.seasons, shikiText = r.shikiText || '';
  Sh.wantNow(it);
  const draw = () => {
    const full = data ? data.item : it;
    const fav = D.isFavorite(it);
    const eps = data ? data.episodes : [];
    const reg = data ? data.regular : new Set();
    const resume = data ? D.resumeEpisode(it, eps) : null;
    const started = D.lastEpisode(it) !== 0;
    const regCount = eps.filter(e => reg.has(e.id)).length;
    const current = D.lastEpisode(it);
    const trSig = D.rememberedTranslation(it);
    const epHTML = e => {
      const f = D.fraction(e.id);
      const date = e.uploaded ? e.uploaded.toLocaleDateString('ru', { day: 'numeric', month: 'short', year: e.uploaded.getFullYear() !== year ? 'numeric' : undefined }) : '';
      return `<button class="ep ${D.isDone(e.id) ? 'done' : ''} ${e.id === current ? 'current' : ''}" data-ep="${e.id}"><span class="n">${D.isDone(e.id) ? '✓' : e.number > 0 && reg.has(e.id) ? e.number : '•'}</span><span style="min-width:0"><div class="et">${esc(e.title)}</div><div class="ed">${e.id === current && !D.isDone(e.id) ? 'Смотрите сейчас' : esc(date)}</div></span>${O.mark(e.id)}${f > 0 && f < 1 ? `<span class="bar" style="width:${f * 100}%"></span>` : ''}</button>`;
    };
    const firstExtra = eps.findIndex(e => !reg.has(e.id));
    page.innerHTML = back + `<div class="detail-hero"><div class="shade"></div>
      <div class="detail-top"><div class="poster"><img src="${esc(full.poster || it.poster)}" alt=""></div><div style="min-width:0;padding-bottom:6px">
      <h1>${esc(full.title)}</h1>${full.raw.titles?.romaji && full.raw.titles.romaji !== full.title ? `<div class="sub">${esc(full.raw.titles.romaji)}</div>` : ''}
      <div class="meta">${Sh.scoresLine(full)}${full.kind ? `<span>${esc(full.kind)}</span>` : ''}${full.season ? `<span>${esc(full.season)}</span>` : full.year ? `<span>${full.year}</span>` : ''}${regCount ? `<span>${regCount} ${plural(regCount, 'серия', 'серии', 'серий')}</span>` : ''}</div>
      <div class="genres">${full.genres.map(g => `<span>${esc(g.title)}</span>`).join('')}</div>
      <div class="actions">${data ? (resume ? `<button class="btn primary" id="play">${icon.play}${started ? 'Продолжить · ' + esc(resume.title) : 'Смотреть · ' + esc(resume.title)}</button>` : '') : `<button class="btn primary" disabled>${icon.play}Загрузка…</button>`}
      <button class="btn icon ${fav ? 'on' : ''}" id="fav" title="${fav ? 'Убрать из избранного' : 'В избранное'}">${icon.heart}</button>
      <button class="btn" id="shiki" title="Открыть страницу на Шикимори">${icon.globe}Шикимори</button></div>
      <div id="shiki-rate"></div>
      ${trSig && data && (resume || eps[0]) ? `<div class="tr-line" title="Серии включаются с этим переводом. Правый щелчок по серии — выбрать другой.">Перевод: <b>${esc(D.translationLabel(trSig))}</b><button class="link" id="tr-change">Сменить</button></div>` : ''}</div></div></div>
      ${(shikiText || full.summary) ? `<div class="summary clamp">${esc(shikiText || full.summary)}</div><button class="more" hidden>Ещё</button>` : ''}
      ${seasonList?.length ? `<div class="section-title">Сезоны</div><div class="seasons">${seasonList.map(s => (keep(s.item), `<button class="chip ${s.current ? 'on' : ''}" ${s.current ? '' : `data-season="${s.id}"`}>${esc(s.label)}</button>`)).join('')}</div>` : ''}
      <div id="eps">${data ? (eps.length ? `<div class="section-title">Серии <small>${regCount}</small></div><div class="episodes">${eps.map((e, i) => (i === firstExtra && i > 0 ? '<div class="ep-sep">Трейлеры и спецвыпуски</div>' : '') + epHTML(e)).join('')}</div>` : `<div class="state">Серий пока нет</div>`) : r.error ? errorState(r.error) : loadingState()}</div>`;
    const bg = full.poster || it.poster;
    if (bg) $('.detail-hero', page).prepend(backdrop(bg, 'blur(5px) saturate(1.3) brightness(.45)'));
    const sum = $('.summary', page);
    if (sum && sum.scrollHeight > sum.clientHeight + 2) { const m = $('.more', page); m.hidden = false; m.onclick = () => { sum.classList.remove('clamp'); m.remove(); }; }
    $('#fav', page).onclick = () => { D.toggleFavorite(it); if (data) D.seen(it, data.episodes.length); draw(); toast(D.isFavorite(it) ? 'Добавлено в избранное' : 'Убрано из избранного'); };
    $('#play', page)?.addEventListener('click', () => play(resume, true));
    $('#shiki', page).onclick = e => { const b = e.currentTarget; b.classList.add('busy'); setTimeout(() => b.classList.remove('busy'), 1500); window.yoru.openExternal(Sh.url(full.malId ? full : it)); };
    $('#tr-change', page)?.addEventListener('click', () => play(resume || eps[0], false));
    paintRate();
    $('[data-retry]', page)?.addEventListener('click', () => { r.error = null; draw(); load(); });
  };
  page.addEventListener('click', e => {
    const s = e.target.closest('[data-season]');
    if (s) { const season = seasonList.find(x => x.id === +s.dataset.season); stacks[tab][stacks[tab].length - 1] = { view: 'detail', item: season.item }; render(0); return; }
    const dl = e.target.closest('[data-dl]');
    if (dl && data) { O.episodeClick(it, data.episodes.find(x => x.id === +dl.dataset.dl)); return; }
    const b = e.target.closest('[data-ep]');
    if (b && data) play(data.episodes.find(x => x.id === +b.dataset.ep), true);
  });
  // Щелчок по серии включает запомненный перевод; правый щелчок — сначала показывает выбор.
  page.addEventListener('contextmenu', e => {
    const b = e.target.closest('[data-ep]'); if (!b || !data) return;
    e.preventDefault(); play(data.episodes.find(x => x.id === +b.dataset.ep), false);
  });
  const play = (ep, quick) => startEpisode(it, data, ep, quick, () => { if (alive()) draw(); });
  // Моя оценка и статус на Шикимори (id MyAnimeList есть только в полной карточке).
  const watchedCount = () => data ? Math.max(0, ...data.episodes.filter(e => data.regular.has(e.id) && D.isDone(e.id)).map(e => e.number)) : 0;
  const paintRate = () => {
    const box = $('#shiki-rate', page), full = data ? data.item : it;
    if (!box || !Sh.acc.available || !(full.malId > 0)) { if (box) box.innerHTML = ''; return; }
    if (!Sh.acc.signedIn) { box.innerHTML = `<button class="link shiki-cta" id="shiki-cta">Оценить и отмечать просмотренное на Шикимори</button>`; $('#shiki-cta', box).onclick = () => setTab('account'); return; }
    const rt = Sh.rate(full), sc = rt?.score || 0;
    box.innerHTML = `<div class="shiki-rate"><span class="lbl">Моя оценка${sc ? ' · ' + sc : ''}</span><span class="stars">${Array.from({ length: 10 }, (_, i) => `<button data-star="${i + 1}" class="${i < sc ? 'on' : ''}" title="${i + 1}">★</button>`).join('')}</span>
      <select id="shiki-status" title="Статус на Шикимори">${rt ? '' : '<option value="">Не в списке</option>'}${Sh.STATUSES.map(([s, t]) => `<option value="${s}" ${rt?.status === s ? 'selected' : ''}>${t}${rt?.status === s && rt.episodes ? ' · ' + rt.episodes + ' сер.' : ''}</option>`).join('')}</select></div>`;
    if (!rt) $('#shiki-status', box).value = '';
    $('.stars', box).onclick = async e => {
      const b = e.target.closest('[data-star]'); if (!b) return;
      const n = +b.dataset.star === sc ? 0 : +b.dataset.star;
      box.classList.add('busy-row'); await Sh.setScore(full, n, watchedCount()); box.classList.remove('busy-row');
      if (Sh.acc.message) toast(Sh.acc.message);
    };
    $('#shiki-status', box).onchange = async e => {
      const v = e.target.value; if (!v) { paintRate(); return; }
      box.classList.add('busy-row'); await Sh.setStatus(full, v); box.classList.remove('busy-row');
      toast(Sh.acc.message || 'Статус на Шикимори: ' + Sh.statusTitle(v));
    };
  };
  const offRate = Sh.onAcc(() => { if (!alive()) return offRate(); if (!Sh.acc.syncing) paintRate(); });
  const load = async () => {
    try {
      data = r.data = await D.details(it.id);
      if (D.isFavorite(it)) D.seen(it, data.episodes.length);
      markAlmostWatched(data.episodes);
      // Описание с Шикимори аккуратнее, чем у Anime 365 (id MyAnimeList есть только в полной карточке).
      if (!shikiText && data.item.malId) Sh.text(data.item).then(t => { if (!t) return; shikiText = r.shikiText = t; if (alive()) { const y = main.scrollTop; draw(); main.scrollTop = y; } });
      if (data.item.malId) Sh.wantNow(data.item);
      if (!alive()) return;
      draw();
      if (r.resume) { r.resume = false; const ep = D.resumeEpisode(it, data.episodes); if (ep) play(ep, true); }
    } catch (e) { r.error = e.message; if (alive()) draw(); }
  };
  draw();
  if (!data) load();
  if (!seasonList) D.seasons(it).then(s => { seasonList = r.seasons = s; if (alive() && s.length) { const y = main.scrollTop; draw(); main.scrollTop = y; } });
}

// Серии, досмотренные до титров (≥ 90%), но не засчитанные по старому правилу (93% или < 2 мин), — засчитываем.
function markAlmostWatched(eps) {
  for (const e of eps) if (!D.isDone(e.id) && D.fraction(e.id) >= .9) D.markDone(e.id);
}

// Выбор перевода и запуск серии. «Смотреть» и щелчок по серии сразу берут запомненный перевод; «Сменить» — показывает выбор.
export async function startEpisode(it, data, ep, quick, onClose) {
  if (!(await window.yoru.signedIn())) { toast('Войдите в аккаунт Anime 365, чтобы смотреть'); setTab('account'); return; }
  let list;
  const wait = modal(`<h3>${esc(ep.title)}</h3><p class="hint">Загружаем переводы…</p><div class="state" style="padding:20px"><div class="spinner"></div></div>`);
  try { list = await D.translations(ep, it); } catch (e) { wait.close(); toast(e.message); return; }
  wait.close();
  if (!list.length) { toast('Для этой серии пока нет переводов'); return; }
  const remembered = D.rememberedTranslation(it);
  const go = t => launch(it, data, ep, t, onClose);
  if (quick && remembered && list[0].signature === remembered) return go(list[0]);
  chooseTranslation(ep, list, remembered, go);
}
export function chooseTranslation(ep, list, remembered, go) {
  const mainList = list.filter(t => t.main || t.signature === remembered), other = list.filter(t => !(t.main || t.signature === remembered));
  const groups = [];
  for (const t of mainList) { let g = groups.find(g => g.name === (t.signature === remembered ? 'Вы смотрели' : t.group)); if (!g) groups.push(g = { name: t.signature === remembered ? 'Вы смотрели' : t.group, items: [] }); g.items.push(t); }
  const row = t => `<button class="tr" data-tr="${t.id}"><span class="name">${esc(t.name || t.group)}</span>${t.signature === remembered ? '<span class="tag last">последний</span>' : ''}${t.bd ? '<span class="tag">BD</span>' : ''}${t.height ? `<span class="tag">${t.height >= 2160 ? '4K' : t.height + 'p'}</span>` : ''}</button>`;
  const m = modal(`<h3>${esc(ep.title)}</h3><p class="hint">Выберите перевод — в следующий раз он включится сам.</p>
    ${groups.map(g => `<div class="tr-group">${esc(g.name)}</div>${g.items.map(row).join('')}`).join('')}
    ${other.length ? `<button class="tr" id="other"><span class="name">Другие языки</span><span class="tag">${other.length}</span></button><div id="other-list" hidden>${other.map(t => `<div class="tr-group" style="margin-top:8px">${esc(t.group)}</div>${row(t)}`).join('')}</div>` : ''}`);
  m.el.addEventListener('click', e => {
    if (e.target.closest('#other')) { $('#other-list', m.el).hidden = false; e.target.closest('#other').remove(); return; }
    const b = e.target.closest('[data-tr]'); if (!b) return;
    m.close(); go(list.find(t => t.id === +b.dataset.tr));
  });
}
async function launch(it, data, ep, t, onClose) {
  const wait = modal(`<h3>${esc(ep.title)}</h3><p class="hint">${esc(t.title)}</p><div class="state" style="padding:20px"><div class="spinner"></div></div>`);
  let pb;
  try { pb = await D.playback(t, ep, it); } catch (e) { wait.close(); toast(e.message); return; }
  wait.close();
  const eps = data?.episodes || [];
  const i = eps.findIndex(e => e.id === ep.id);
  const next = i >= 0 && i + 1 < eps.length && !eps[i + 1].trailer && data.regular.has(eps[i + 1].id) === data.regular.has(ep.id) ? eps[i + 1] : null;
  openPlayer(pb, {
    next: next ? next.title : null,
    download: O.isEnabled() ? () => O.download(it, ep, t) : null,
    onClose: goNext => {
      if (data && D.isDone(ep.id) && data.regular.has(ep.id) && ep.number > 0) Sh.episodeDone(data.item, ep.number);
      onClose?.();
      if (goNext && next) playNext(it, data, next, t, onClose);
    }
  });
}
// Следующая серия: тот же перевод, если он есть; иначе — выбор.
async function playNext(it, data, ep, prev, onClose) {
  let list;
  try { list = await D.translations(ep, it); } catch (e) { toast(e.message); return; }
  const same = list.find(t => t.signature === prev.signature) || null;
  if (same) launch(it, data, ep, same, onClose); else if (list.length) chooseTranslation(ep, list, D.rememberedTranslation(it), t => launch(it, data, ep, t, onClose)); else toast('Для следующей серии пока нет переводов');
}

export function modal(html) {
  const back = document.createElement('div'); back.className = 'modal-back';
  back.innerHTML = `<div class="modal" role="dialog">${html}</div>`;
  $('#modal-root').append(back);
  const close = () => { back.remove(); document.removeEventListener('keydown', key, true); };
  const key = e => { if (e.key === 'Escape') { e.stopPropagation(); close(); } };
  document.addEventListener('keydown', key, true);
  back.addEventListener('mousedown', e => { if (e.target === back) close(); });
  return { el: back, close };
}

// ---------- Обновления ----------
let update = null;
async function checkUpdate(manual) {
  const r = await window.yoru.checkUpdate();
  const text = $('#upd-text');
  if (r.error) { if (manual) toast('Не удалось проверить обновления: ' + r.error); return; }
  update = r.data.available ? r.data : null;
  const chip = $('#update-chip');
  chip.hidden = !update;
  if (update) chip.textContent = update.toArm ? 'Версия для Apple Silicon' : `Обновить до ${update.version}`;
  if (text) text.textContent = update ? (update.toArm ? 'Установлена версия для Intel — доступна родная версия для Apple Silicon.' : `Доступна версия ${update.version}.`) : 'Установлена последняя версия.';
  if (manual) update ? showUpdate() : toast('Установлена последняя версия');
}
function showUpdate() {
  if (!update) return;
  const m = modal(`<h3>Yoru ${esc(update.version)}</h3><p class="hint">${update.toArm ? 'Сейчас установлена версия для Intel. Родная версия для Apple Silicon работает быстрее, тратит меньше энергии и будет открываться в следующих macOS.' : `Сейчас установлена ${esc(update.current)}.`}</p>
    <div class="summary" style="margin:0 0 18px;max-height:240px;overflow:auto">${esc(update.notes.replace(/[#*`]/g, '').trim() || 'Исправления и улучшения.')}</div>
    <p class="error" hidden></p><div class="actions">${update.auto ? `<button class="btn primary" id="install">Скачать и перезапустить</button>` : `<button class="btn primary" id="page">Открыть страницу загрузки</button>`}<button class="btn" id="later">Позже</button></div>`);
  $('#later', m.el).onclick = m.close;
  $('#page', m.el)?.addEventListener('click', () => { window.yoru.openExternal(update.page); m.close(); });
  $('#install', m.el)?.addEventListener('click', async e => {
    const b = e.target.closest('button'); b.disabled = true; b.textContent = 'Скачивается…';
    window.yoru.onUpdateProgress((d, t) => { b.textContent = t ? `Скачивается… ${Math.round(d / t * 100)}%` : 'Скачивается…'; });
    D.exportData();
    const r = await window.yoru.installUpdate(update.asset.url, update.asset.name);
    if (r.error) { const err = $('.error', m.el); err.textContent = 'Не удалось обновиться: ' + r.error; err.hidden = false; b.disabled = false; b.textContent = 'Повторить'; }
    else b.textContent = 'Перезапуск…';
  });
}
$('#update-chip').addEventListener('click', showUpdate);

// ---------- Загрузки серий ----------
const downloads = new Map();
window.yoru.onDownloadProgress(p => {
  const box = $('#downloads');
  if (p.state) {
    downloads.delete(p.id);
    if (p.state === 'completed') toast(`Скачано: ${p.name}`); else if (p.state !== 'cancelled') toast(`Не удалось скачать ${p.name}`);
  } else downloads.set(p.id, p);
  box.innerHTML = [...downloads.values()].map(d => `<div class="dl"><b>${esc(d.name)}</b><div class="bar"><i style="width:${d.total ? d.received / d.total * 100 : 0}%"></i></div></div>`).join('');
});

// ---------- Запуск ----------
document.documentElement.classList.add('platform-' + window.yoru.platform);
if (!Mg.available()) $('#modes').hidden = true;
else { Mg.init(); if (D.S.get('mode') === 'manga') tab = 'manga'; }
document.querySelectorAll('[data-tab]').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
$('#nav').dataset.mode = MODE_OF[tab];
document.querySelectorAll('[data-mode]').forEach(b => b.classList.toggle('on', b.dataset.mode === MODE_OF[tab]));
render();
O.init();
refreshAccount();
// Аккаунт Yoru: после синхронизации перерисовываем экран, если на нём ничего не вводят и не смотрят.
const quiet = () => !$('#player, #reader, .modal-back') && !document.activeElement?.matches('input, textarea');
const LIVE = new Set(['home', 'mine', 'mangaHome', 'mangaMine', 'account', 'detail', 'mangaTitle']);
Acc.init({
  rerender: () => { if (quiet() && LIVE.has(top().view)) render(main.scrollTop); },
  anime365: async () => { await refreshAccount(); if (quiet() && top().view === 'account') render(main.scrollTop); },
  signedOut: () => { if (quiet() && top().view === 'account') render(main.scrollTop); }
});
checkUpdate(false);
// Шикимори: при запуске тихо переносим просмотренное в обе стороны; итог ручной синхронизации — во всплывашке.
Sh.onAcc(a => { if (!a.syncing && a.got && quiet() && LIVE.has(top().view)) { a.got = 0; render(main.scrollTop); } });
let shikiReport = false;
Sh.onAcc(a => { if (a.reporting) shikiReport = true; else if (shikiReport && !a.syncing) { shikiReport = false; if (a.result) toast(a.result); } });
Sh.refreshStatus().then(a => setTimeout(() => Sh.syncBoth(false), 6000));
setTimeout(autoServers, 20000);
setInterval(autoServers, 6 * 3600e3);
setInterval(() => checkUpdate(false), 6 * 3600e3);
setTimeout(async () => {
  const a = await D.refreshFinished(), b = await D.checkNewEpisodes();
  if ((a || b) && tab === 'home' && stacks.home.length === 1) render(main.scrollTop);
}, 4000);
