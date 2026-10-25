// Экраны Yoru Anime: главная, поиск, «Моё», расписание, аккаунт и страница аниме.
import * as D from './data.js';
import { openPlayer } from './player.js';
import * as O from './offline.js';

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
function card(it, { progress = null, fresh = false } = {}) {
  keep(it);
  const s = it.score > 0 ? `<span class="score ${D.scoreClass(it.score)}">${D.scoreText(it.score)}</span>` : '';
  const p = progress != null ? `<div class="progress"><i style="width:${Math.round(progress * 100)}%"></i></div>` : '';
  return `<button class="card" data-open="${it.id}"><div class="poster">${img(it.posterSmall)}${s}${fresh ? '<span class="badge-new">НОВАЯ СЕРИЯ</span>' : ''}${p}</div><div class="t">${esc(it.title)}</div><div class="s">${esc(it.subtitle)}</div></button>`;
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
const stacks = { home: [{ view: 'home' }], search: [{ view: 'search' }], mine: [{ view: 'mine' }], schedule: [{ view: 'schedule' }], downloads: [{ view: 'downloads' }], account: [{ view: 'account' }] };
let tab = 'home';
const top = () => stacks[tab][stacks[tab].length - 1];
function setTab(t) {
  if (t === tab) { if (stacks[t].length > 1) { stacks[t].length = 1; render(); } else main.scrollTo({ top: 0, behavior: 'smooth' }); return; }
  top().scroll = main.scrollTop;
  tab = t;
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
  const view = { home: Home, search: Search, mine: Mine, schedule: Schedule, account: Account, detail: Detail, downloads: (r, a) => O.DownloadsView(r, a, main) }[r.view];
  view(r, alive);
  requestAnimationFrame(() => { main.scrollTop = scroll; });
}
document.addEventListener('click', e => {
  const t = e.target.closest('[data-tab]'); if (t) return setTab(t.dataset.tab);
  const o = e.target.closest('[data-open]');
  if (o) { const it = known.get(+o.dataset.open); if (it) push({ view: 'detail', item: it, resume: !!o.dataset.resume }); return; }
  if (e.target.closest('[data-back]')) back();
});
document.addEventListener('mouseup', e => { if (e.button === 3) back(); });
document.addEventListener('keydown', e => {
  if ($('#player') || e.target.matches('input')) return;
  if ((e.key === 'Escape' || e.key === 'Backspace' || (e.altKey && e.key === 'ArrowLeft') || (e.metaKey && e.key === '[')) && !$('.modal-back')) back();
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); setTab('search'); setTimeout(() => $('.search-box input')?.focus(), 0); }
});

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
const heroPick = Math.floor(Math.random() * 5);
const loadShelf = params => { const k = JSON.stringify(params); if (!shelfCache.has(k)) shelfCache.set(k, D.shelf(params).catch(e => { shelfCache.delete(k); throw e; })); return shelfCache.get(k); };

function Home(_r, alive) {
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  page.innerHTML = `<div class="hero"><div class="bg"></div><div class="shade"></div></div><div id="continue"></div><div id="favs"></div><div id="shelves"></div>`;
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
      if (s.params.isAiring) hero(page, items);
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
const heroDetails = new Map();
async function hero(page, items) {
  const it = items[Math.min(heroPick, items.length - 1)]; if (!it) return;
  const box = $('.hero', page);
  const paint = summary => {
    box.innerHTML = `<div class="bg" style="background-image:url('${esc(it.poster)}')"></div><div class="shade"></div><div class="art" style="background-image:url('${esc(it.poster)}')"></div>
      <div class="info"><div class="eyebrow">Сейчас выходит</div><h1>${esc(it.title)}</h1>
      <div class="meta">${it.score ? `<span class="score-text" style="color:var(--score-${D.scoreClass(it.score)})">★ ${D.scoreText(it.score)}</span>` : ''}<span>${esc(it.subtitle)}</span>${it.genres.slice(0, 3).map(g => `<span>${esc(g.title)}</span>`).join('')}</div>
      <p>${esc(summary || '')}</p>
      <div class="actions"><button class="btn primary" data-open="${it.id}" data-resume="1">${icon.play}Смотреть</button><button class="btn" data-open="${it.id}">Подробнее</button></div></div>`;
  };
  keep(it); paint(heroDetails.get(it.id) || '');
  if (!heroDetails.has(it.id)) {
    try { const d = await D.details(it.id); heroDetails.set(it.id, d.item.summary); if (box.isConnected) paint(d.item.summary); } catch {}
  }
}

// ---------- Поиск ----------
const GENRES = [[1, 'Экшен'], [2, 'Приключения'], [4, 'Комедия'], [8, 'Драма'], [10, 'Фэнтези'], [22, 'Романтика'], [24, 'Фантастика'], [36, 'Повседневность'], [62, 'Исекай'], [7, 'Детектив'], [37, 'Сверхъестественное'], [23, 'Школа'], [30, 'Спорт'], [18, 'Меха'], [40, 'Психологическое'], [41, 'Триллер'], [13, 'Исторический'], [19, 'Музыка'], [63, 'Злодейка'], [76, 'Гурман']];
function Search(r, alive) {
  r.query ??= ''; r.genre ??= 0;
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  page.innerHTML = `<div class="page-head"><h1>Поиск</h1></div>
    <label class="search-box">${icon.search}<input type="search" placeholder="Название аниме" value="${esc(r.query)}" spellcheck="false"></label>
    <div class="chips">${GENRES.map(([id, t]) => `<button class="chip ${r.genre === id ? 'on' : ''}" data-genre="${id}">${t}</button>`).join('')}</div>
    <div id="results"></div>`;
  const input = $('input', page), out = $('#results', page);
  let items = [], offset = 0, done = false, busy = false, gen = 0;
  const params = () => r.query.trim() ? { query: r.query.trim() } : r.genre ? { genres: r.genre } : { isAiring: 1 };
  const heading = () => r.query.trim() ? 'Результаты' : r.genre ? GENRES.find(g => g[0] === r.genre)[1] : 'Сейчас выходят';
  async function load(reset) {
    if (reset) { items = []; offset = 0; done = false; gen++; out.innerHTML = loadingState(); }
    if (busy && !reset || done) return;
    const g = gen; busy = true;
    try {
      const more = await D.shelf(params(), offset);
      if (g !== gen || !alive()) return;
      items.push(...more.filter(m => !items.some(i => i.id === m.id))); offset += 24; done = more.length < 24;
      out.innerHTML = items.length ? `<div class="section-title" style="margin-top:0">${esc(heading())}</div><div class="grid">${items.map(it => card(it)).join('')}</div>` : `<div class="state"><div><b>Ничего не нашлось</b>Попробуйте другое название — можно по-русски, по-английски или ромадзи.</div></div>`;
    } catch (e) { if (g === gen && alive()) { out.innerHTML = errorState(e.message); $('[data-retry]', out).onclick = () => load(true); } }
    finally { if (g === gen) busy = false; }
  }
  let t;
  input.addEventListener('input', () => { r.query = input.value; clearTimeout(t); t = setTimeout(() => load(true), 350); });
  page.addEventListener('click', e => { const c = e.target.closest('[data-genre]'); if (!c) return; const id = +c.dataset.genre; r.genre = r.genre === id ? 0 : id; page.querySelectorAll('.chip').forEach(x => x.classList.toggle('on', +x.dataset.genre === r.genre)); if (r.genre) { r.query = ''; input.value = ''; } load(true); });
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
    const list = r.part === 'favorites' ? D.favorites() : D.history();
    page.innerHTML = `<div class="page-head"><h1>Моё</h1></div>
      <div class="tabs"><button data-part="favorites" class="${r.part === 'favorites' ? 'on' : ''}">Избранное</button><button data-part="history" class="${r.part === 'history' ? 'on' : ''}">История</button></div>
      ${list.length ? `<div class="grid">${list.map(it => card(it, { fresh: r.part === 'favorites' && D.hasNew(it), progress: r.part === 'history' && D.lastEpisode(it) ? D.fraction(D.lastEpisode(it)) : null })).join('')}</div>`
        : `<div class="state"><div><b>${r.part === 'favorites' ? 'Здесь пока пусто' : 'Вы ещё ничего не смотрели'}</b>${r.part === 'favorites' ? 'Нажмите ♡ на странице аниме, чтобы добавить его сюда.' : 'Начатые аниме появятся здесь.'}</div></div>`}`;
  };
  page.addEventListener('click', e => { const b = e.target.closest('[data-part]'); if (b) { r.part = b.dataset.part; draw(); } });
  draw();
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
        return `<button data-open="${it.id}"><img src="${esc(it.posterSmall)}" loading="lazy" alt=""><div style="min-width:0"><b>${esc(it.title)}</b><span class="${fresh ? 'fresh' : ''}">${esc(ep.title)} · ${ep.uploaded.toLocaleTimeString('ru', { hour: '2-digit', minute: '2-digit' })}</span></div></button>`;
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
  $('#account-button .who').textContent = account ? account.name : 'Войти';
  $('#account-button .avatar').textContent = account ? account.name.trim().charAt(0).toUpperCase() : '';
}
function Account(_r, alive) {
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  const draw = async () => {
    const signed = await window.yoru.signedIn();
    const version = await window.yoru.version();
    if (!alive()) return;
    page.innerHTML = `<div class="page-head"><h1>Аккаунт</h1></div>` + (signed ? `<div class="panel"><h2>${esc(account?.name || 'Аккаунт')}</h2>
      <div class="kv"><span>Подписка</span><b>${account?.premium ? 'Активна' + (account.until ? ' до ' + account.until.toLocaleDateString('ru') : '') : account?.premium === false ? 'Нет' : '…'}</b></div>
      <div class="actions" style="margin-top:16px"><button class="btn" id="site">${icon.globe}Anime 365</button><button class="btn" id="logout">Выйти</button></div></div>`
      : `<form class="panel" id="login"><h2>Вход в Anime 365</h2><p>Нужен аккаунт с подпиской — без неё сайт не даёт видео. Пароль уходит только на сайт, приложение хранит лишь ключ входа.</p>
      <label class="field"><span>Почта</span><input name="email" type="email" autocomplete="username" required></label>
      <label class="field"><span>Пароль</span><input name="password" type="password" autocomplete="current-password" required></label>
      <p class="error" hidden></p><button class="btn primary" type="submit">Войти</button></form>`) +
      `<div class="panel"><h2>Yoru Anime ${esc(version)}</h2><p id="upd-text">Обновления проверяются автоматически.</p><div class="actions"><button class="btn" id="check">Проверить обновления</button></div></div>`;
    $('#site', page)?.addEventListener('click', () => window.yoru.openExternal('https://smotret-anime.app/'));
    $('#logout', page)?.addEventListener('click', async () => { await window.yoru.logout(); account = null; paintAccount(); draw(); });
    $('#login', page)?.addEventListener('submit', async e => {
      e.preventDefault();
      const f = e.target, err = $('.error', f), btn = $('button', f);
      btn.disabled = true; btn.textContent = 'Вход…'; err.hidden = true;
      const r = await window.yoru.login(f.email.value.trim(), f.password.value);
      if (r.error) { err.textContent = r.error; err.hidden = false; btn.disabled = false; btn.textContent = 'Войти'; return; }
      await refreshAccount(); if (alive()) draw(); toast('Вы вошли в Anime 365');
    });
    $('#check', page).addEventListener('click', () => checkUpdate(true));
  };
  draw();
}

// ---------- Страница аниме ----------
function Detail(r, alive) {
  const it = r.item;
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  const back = `<div class="top-bar"><button class="back" data-back aria-label="Назад">${icon.back}</button></div>`;
  let data = r.data, seasonList = r.seasons;
  const draw = () => {
    const full = data ? data.item : it;
    const fav = D.isFavorite(it);
    const eps = data ? data.episodes : [];
    const reg = data ? data.regular : new Set();
    const resume = data ? D.resumeEpisode(it, eps) : null;
    const started = D.lastEpisode(it) !== 0;
    const regCount = eps.filter(e => reg.has(e.id)).length;
    const current = D.lastEpisode(it);
    const epHTML = e => {
      const f = D.fraction(e.id);
      const date = e.uploaded ? e.uploaded.toLocaleDateString('ru', { day: 'numeric', month: 'short', year: e.uploaded.getFullYear() !== year ? 'numeric' : undefined }) : '';
      return `<button class="ep ${D.isDone(e.id) ? 'done' : ''} ${e.id === current ? 'current' : ''}" data-ep="${e.id}"><span class="n">${D.isDone(e.id) ? '✓' : e.number > 0 && reg.has(e.id) ? e.number : '•'}</span><span style="min-width:0"><div class="et">${esc(e.title)}</div><div class="ed">${e.id === current && !D.isDone(e.id) ? 'Смотрите сейчас' : esc(date)}</div></span>${O.mark(e.id)}${f > 0 && f < 1 ? `<span class="bar" style="width:${f * 100}%"></span>` : ''}</button>`;
    };
    const firstExtra = eps.findIndex(e => !reg.has(e.id));
    page.innerHTML = back + `<div class="detail-hero"><div class="bg" style="background-image:url('${esc(full.poster || it.poster)}')"></div><div class="shade"></div>
      <div class="detail-top"><div class="poster"><img src="${esc(full.poster || it.poster)}" alt=""></div><div style="min-width:0;padding-bottom:6px">
      <h1>${esc(full.title)}</h1>${full.raw.titles?.romaji && full.raw.titles.romaji !== full.title ? `<div class="sub">${esc(full.raw.titles.romaji)}</div>` : ''}
      <div class="meta">${full.score ? `<span class="score-text" style="color:var(--score-${D.scoreClass(full.score)})">★ ${D.scoreText(full.score)}</span>` : ''}${full.kind ? `<span>${esc(full.kind)}</span>` : ''}${full.season ? `<span>${esc(full.season)}</span>` : full.year ? `<span>${full.year}</span>` : ''}${regCount ? `<span>${regCount} ${plural(regCount, 'серия', 'серии', 'серий')}</span>` : ''}</div>
      <div class="genres">${full.genres.map(g => `<span>${esc(g.title)}</span>`).join('')}</div>
      <div class="actions">${data ? (resume ? `<button class="btn primary" id="play">${icon.play}${started ? 'Продолжить · ' + esc(resume.title) : 'Смотреть · ' + esc(resume.title)}</button>` : '') : `<button class="btn primary" disabled>${icon.play}Загрузка…</button>`}
      <button class="btn icon ${fav ? 'on' : ''}" id="fav" title="${fav ? 'Убрать из избранного' : 'В избранное'}">${icon.heart}</button></div></div></div></div>
      ${full.summary ? `<div class="summary clamp">${esc(full.summary)}</div><button class="more" hidden>Ещё</button>` : ''}
      ${seasonList?.length ? `<div class="section-title">Сезоны</div><div class="seasons">${seasonList.map(s => (keep(s.item), `<button class="chip ${s.current ? 'on' : ''}" ${s.current ? '' : `data-season="${s.id}"`}>${esc(s.label)}</button>`)).join('')}</div>` : ''}
      <div id="eps">${data ? (eps.length ? `<div class="section-title">Серии <small>${regCount}</small></div><div class="episodes">${eps.map((e, i) => (i === firstExtra && i > 0 ? '<div class="ep-sep">Трейлеры и спецвыпуски</div>' : '') + epHTML(e)).join('')}</div>` : `<div class="state">Серий пока нет</div>`) : r.error ? errorState(r.error) : loadingState()}</div>`;
    const sum = $('.summary', page);
    if (sum && sum.scrollHeight > sum.clientHeight + 2) { const m = $('.more', page); m.hidden = false; m.onclick = () => { sum.classList.remove('clamp'); m.remove(); }; }
    $('#fav', page).onclick = () => { D.toggleFavorite(it); if (data) D.seen(it, data.episodes.length); draw(); toast(D.isFavorite(it) ? 'Добавлено в избранное' : 'Убрано из избранного'); };
    $('#play', page)?.addEventListener('click', () => play(resume, true));
    $('[data-retry]', page)?.addEventListener('click', () => { r.error = null; draw(); load(); });
  };
  page.addEventListener('click', e => {
    const s = e.target.closest('[data-season]');
    if (s) { const season = seasonList.find(x => x.id === +s.dataset.season); stacks[tab][stacks[tab].length - 1] = { view: 'detail', item: season.item }; render(0); return; }
    const dl = e.target.closest('[data-dl]');
    if (dl && data) { O.episodeClick(it, data.episodes.find(x => x.id === +dl.dataset.dl)); return; }
    const b = e.target.closest('[data-ep]');
    if (b && data) play(data.episodes.find(x => x.id === +b.dataset.ep), false);
  });
  const play = (ep, quick) => startEpisode(it, data, ep, quick, () => { if (alive()) draw(); });
  const load = async () => {
    try {
      data = r.data = await D.details(it.id);
      if (D.isFavorite(it)) D.seen(it, data.episodes.length);
      if (!alive()) return;
      draw();
      if (r.resume) { r.resume = false; const ep = D.resumeEpisode(it, data.episodes); if (ep) play(ep, true); }
    } catch (e) { r.error = e.message; if (alive()) draw(); }
  };
  draw();
  if (!data) load();
  if (!seasonList) D.seasons(it).then(s => { seasonList = r.seasons = s; if (alive() && s.length) { const y = main.scrollTop; draw(); main.scrollTop = y; } });
}

// Выбор перевода и запуск серии. «Смотреть» сразу берёт запомненный перевод; клик по серии — показывает выбор.
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
  if (update) chip.textContent = `Обновить до ${update.version}`;
  if (text) text.textContent = update ? `Доступна версия ${update.version}.` : 'Установлена последняя версия.';
  if (manual) update ? showUpdate() : toast('Установлена последняя версия');
}
function showUpdate() {
  if (!update) return;
  const m = modal(`<h3>Yoru Anime ${esc(update.version)}</h3><p class="hint">Сейчас установлена ${esc(update.current)}.</p>
    <div class="summary" style="margin:0 0 18px;max-height:240px;overflow:auto">${esc(update.notes.replace(/[#*`]/g, '').trim() || 'Исправления и улучшения.')}</div>
    <p class="error" hidden></p><div class="actions">${update.auto ? `<button class="btn primary" id="install">Скачать и перезапустить</button>` : `<button class="btn primary" id="page">Открыть страницу загрузки</button>`}<button class="btn" id="later">Позже</button></div>`);
  $('#later', m.el).onclick = m.close;
  $('#page', m.el)?.addEventListener('click', () => { window.yoru.openExternal(update.page); m.close(); });
  $('#install', m.el)?.addEventListener('click', async e => {
    const b = e.target.closest('button'); b.disabled = true; b.textContent = 'Скачивается…';
    window.yoru.onUpdateProgress((d, t) => { b.textContent = t ? `Скачивается… ${Math.round(d / t * 100)}%` : 'Скачивается…'; });
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
render();
O.init();
refreshAccount();
checkUpdate(false);
setInterval(() => checkUpdate(false), 6 * 3600e3);
setTimeout(async () => {
  const a = await D.refreshFinished(), b = await D.checkNewEpisodes();
  if ((a || b) && tab === 'home' && stacks.home.length === 1) render(main.scrollTop);
}, 4000);
