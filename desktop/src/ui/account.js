// Аккаунт Yoru: история, избранное, прогресс, чтение манги и входы в сервисы на своём сервере.
// Формат состояния — тот же, что на Android, ТВ и iPhone. Шифрование и запросы — в Rust (account.rs),
// здесь — экспорт и слияние localStorage и экраны. В Electron-версии (2.1.0) аккаунта нет: всё скрыто.
import { esc, toast, modal } from './app.js';
import * as D from './data.js';

const $ = (s, el = document) => el.querySelector(s);
const A = () => window.yoru?.account;
export const available = () => !!A();
const S = D.S;
const ls = () => { const out = []; try { for (let i = 0; i < localStorage.length; i++) out.push(localStorage.key(i)); } catch {} return out; };

// ---------- Экспорт и слияние ----------
const LISTS = ['favorites', 'history'];
const isMangaKey = k => k.startsWith('m-pos-') || k.startsWith('m-read-') || k.startsWith('m-ts-') || (k.startsWith('m-page-') && k.includes('|'));
const mangaId = k => k.startsWith('m-pos-') ? k.slice(6) : k.startsWith('m-read-') ? k.slice(7) : k.startsWith('m-ts-') ? k.slice(5) : k.slice(7, k.lastIndexOf('|'));

export function exportState() {
  const o = { v: 1 };
  for (const k of LISTS) o[k] = { t: S.get('t-' + k, 0), items: S.get(k, []) };
  const series = {}, done = [], positions = {}, fractions = {}, ids = new Set();
  for (const k of ls()) {
    if (/^done-\d+$/.test(k)) { if (S.get(k) === true) done.push(+k.slice(5)); }
    else if (/^last-\d+$/.test(k)) { const sid = k.slice(5); series[sid] = { last: +S.get(k, 0) || 0, tr: S.get('tr-' + sid, '') || '', t: S.get('stamp-' + sid, 0) }; }
    else if (k.startsWith('position-')) { const v = S.get(k); if (typeof v === 'number') positions[k] = { v: Math.round(v), t: S.get('ts-' + k, 0) }; }
    else if (/^watch-\d+$/.test(k)) { const v = S.get(k); if (typeof v === 'number') fractions[k] = { v, t: Math.max(S.get('ts-' + k, 0), 1) }; }
    else if (isMangaKey(k)) ids.add(mangaId(k));
  }
  Object.assign(o, { series, done, positions, fractions });
  const lp = S.get('lp-item');
  if (lp) o.lastPlay = { item: lp, episode: S.get('lp-episode', {}), translation: S.get('lp-translation', {}), t: S.get('lp-t', 0) };
  const manga = {}, keys = ls();
  for (const id of ids) {
    const e = { t: Math.max(S.get('m-ts-' + id, 0), 1), read: S.get('m-read-' + id, []), pages: {} };
    const pos = S.get('m-pos-' + id); if (pos) e.pos = pos;
    const pre = 'm-page-' + id + '|';
    for (const k of keys) if (k.startsWith(pre)) { const n = S.get(k); if (typeof n === 'number') e.pages[k.slice(pre.length)] = n; }
    manga[id] = e;
  }
  o.manga = manga;
  o.mangaRecent = { t: S.get('m-recent-t', 0), items: S.get('m-recent', []) };
  return o;
}

let merging = false;
function put(k, v) { S.set(k, v); }
// Как State.merge и Manga.mergeSync на Android: свежая отметка побеждает, просмотренные серии объединяются,
// пустой список (новая установка) берётся с сервера. Возвращает true, если что-то поменялось.
export function mergeState(st) {
  if (!st || typeof st !== 'object') return false;
  let changed = false;
  const set = (k, v) => { if (JSON.stringify(S.get(k)) !== JSON.stringify(v)) { put(k, v); changed = true; } };
  merging = true;
  try {
    const list = (k, tk, l) => {
      if (!l || !Array.isArray(l.items)) return;
      const lt = S.get(tk, 0), mine = S.get(k, []);
      if ((+l.t || 0) > lt || (!mine.length && l.items.length)) { set(k, l.items); set(tk, Math.max(+l.t || 0, lt)); }
    };
    for (const k of LISTS) list(k, 't-' + k, st[k]);
    for (const [sid, s] of Object.entries(st.series || {})) {
      if (!s || !(+s.t > S.get('stamp-' + sid, 0))) continue;
      set('last-' + sid, +s.last || 0); if (s.tr) set('tr-' + sid, s.tr); set('stamp-' + sid, +s.t);
    }
    for (const id of st.done || []) if (Number.isInteger(id) && S.get('done-' + id) !== true) set('done-' + id, true);
    for (const [k, p] of Object.entries(st.positions || {})) {
      if (!k.startsWith('position-') || !p || !(+p.t > S.get('ts-' + k, 0))) continue;
      set(k, +p.v || 0); set('ts-' + k, +p.t);
    }
    for (const [k, p] of Object.entries(st.fractions || {})) {
      if (!/^watch-\d+$/.test(k) || !p || !(+p.t > S.get('ts-' + k, 0))) continue;
      set(k, Math.min(1, +p.v || 0)); set('ts-' + k, +p.t);
    }
    const lp = st.lastPlay;
    if (lp && lp.item && +lp.t > S.get('lp-t', 0)) { set('lp-item', lp.item); set('lp-episode', lp.episode || {}); set('lp-translation', lp.translation || {}); set('lp-t', +lp.t); }
    const keys = ls();
    for (const [id, v] of Object.entries(st.manga || {})) {
      if (!v || !(+v.t > S.get('m-ts-' + id, 0))) continue;
      if (v.pos) set('m-pos-' + id, v.pos); else if (S.get('m-pos-' + id) != null) { S.del('m-pos-' + id); changed = true; }
      set('m-read-' + id, Array.isArray(v.read) ? v.read.map(String) : []);
      const pre = 'm-page-' + id + '|', pages = v.pages || {};
      for (const k of keys) if (k.startsWith(pre) && !(k.slice(pre.length) in pages)) { S.del(k); changed = true; }
      for (const [ch, n] of Object.entries(pages)) set(pre + ch, +n || 0);
      set('m-ts-' + id, +v.t);
    }
    list('m-recent', 'm-recent-t', st.mangaRecent);
  } finally { merging = false; }
  return changed;
}

// ---------- Синхронизация ----------
// Изменения уходят на сервер через 3 с тишины, но не реже раза в минуту (в плеере прогресс пишется постоянно).
const SYNCED = /^(favorites|history|t-|last-|tr-|stamp-|done-|position-|ts-|watch-|lp-|m-pos-|m-read-|m-page-|m-ts-|m-recent)/;
let timer = 0, first = 0, busy = false, again = false, signed = false, lastError = null;
let hooks = { rerender() {}, anime365() {}, signedOut() {} };
function schedule(ms = 3000) {
  if (!signed) return;
  clearTimeout(timer);
  const now = Date.now();
  if (!first) first = now;
  timer = setTimeout(syncNow, Math.max(0, Math.min(ms, first + 60000 - now)));
}
export async function syncNow() {
  clearTimeout(timer); timer = 0; first = 0;
  if (!A()) return { error: 'Нет аккаунта' };
  if (busy) { again = true; return {}; }
  busy = true; paint();
  let r;
  try {
    r = await A().sync(exportState());
    if (r.error) lastError = r.error;
    else {
      lastError = null;
      const d = r.data || {};
      if (d.state && mergeState(d.state)) hooks.rerender();
      if ((d.installed || []).includes('anime365')) hooks.anime365();
    }
  } finally {
    busy = false;
    await status();
    if (again) { again = false; schedule(500); }
  }
  return r;
}
async function status() {
  const s = await A()?.status().catch(() => null);
  signed = !!s?.signedIn;
  paint(s);
  return s;
}

export async function init(h) {
  hooks = { ...hooks, ...h };
  if (!A()) return;
  D.onStore(k => { if (!merging && signed && SYNCED.test(k)) schedule(); });
  window.yoru.onAccountChanged(kind => {
    if (kind === 'dirty') schedule();
    else if (kind === 'signedOut') { signed = false; toast('Вход в аккаунт Yoru завершён. Войдите снова.'); hooks.signedOut(); paint(); }
    else if (kind === 'installed:anime365') hooks.anime365();
    else if (String(kind).startsWith('installed:')) hooks.rerender(true);
  });
  let focused = 0;
  addEventListener('focus', () => { if (signed && Date.now() - focused > 60000) { focused = Date.now(); syncNow(); } });
  if ((await status())?.signedIn) syncNow();
}

// Выход из сервиса: только на этом Mac или на всех устройствах аккаунта (вход стирается из аккаунта).
export async function askLogout(svc, title) {
  if (!signed) return true;
  return new Promise(res => {
    const m = modal(`<h3>Выйти из ${esc(title)}?</h3><p class="hint">Вход сохранён в аккаунте Yoru. Выход на всех устройствах удалит его из аккаунта.</p>
      <div class="actions"><button class="btn primary" data-a="here">Только здесь</button><button class="btn" data-a="all">На всех устройствах</button><button class="btn" data-a="no">Отмена</button></div>`);
    let done = false;
    const finish = v => { if (done) return; done = true; m.close(); res(v); };
    $('[data-a=here]', m.el).onclick = () => finish(true);
    $('[data-a=all]', m.el).onclick = async () => { await A().forget(svc); schedule(1500); finish(true); };
    $('[data-a=no]', m.el).onclick = () => finish(false);
    new MutationObserver((_, o) => { if (!m.el.isConnected) { o.disconnect(); finish(false); } }).observe(m.el.parentNode, { childList: true });
  });
}

// ---------- Экран ----------
let panel = null;
const nfc = s => String(s || '').normalize('NFC');
const ago = t => {
  if (!t) return 'ещё нет';
  const m = Math.round((t - Date.now()) / 60000), f = new Intl.RelativeTimeFormat('ru', { numeric: 'auto' });
  return Math.abs(m) < 1 ? 'только что' : Math.abs(m) < 60 ? f.format(m, 'minute') : Math.abs(m) < 1440 ? f.format(Math.round(m / 60), 'hour') : new Date(t).toLocaleString('ru', { day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' });
};
function paint(s) {
  if (!panel?.isConnected) return;
  if (s) draw(panel, s); else status();
}

export function Panel(host) {
  if (!A()) return;
  panel = document.createElement('div'); panel.className = 'panel'; host.prepend(panel);
  status();
}

let me = null;
async function draw(el, s) {
  if (!s.signedIn) {
    me = null;
    el.innerHTML = `<h2>Аккаунт Yoru</h2><p>Войдите, чтобы история и загрузки не пропадали при переустановке и были общими на iPhone, Android, ТВ и Mac. Для регистрации нужен код приглашения.</p>
      <div class="actions"><button class="btn primary" data-a="in">Войти</button><button class="btn" data-a="reg">Регистрация</button><button class="btn" data-a="server">Сервер</button></div>`;
    $('[data-a=in]', el).onclick = signIn;
    $('[data-a=reg]', el).onclick = register;
    $('[data-a=server]', el).onclick = () => server(s);
    return;
  }
  el.innerHTML = `<h2>Аккаунт Yoru</h2>
    <div class="kv"><span>Логин</span><b>${esc(s.login)}</b></div>
    <div class="kv"><span>Почта</span><b data-f="email">${me ? esc(me.email) + (me.emailVerified ? '' : ' · не подтверждена') : '…'}</b></div>
    <div class="kv"><span>Синхронизация</span><b>${busy ? 'Синхронизация…' : lastError ? esc(lastError) : esc(ago(s.synced))}</b></div>
    <div class="actions" style="margin-top:16px"><button class="btn primary" data-a="sync"${busy ? ' disabled' : ''}>Синхронизировать</button><button class="btn" data-a="devices">Устройства</button>
    ${me && !me.emailVerified ? '<button class="btn" data-a="verify">Подтвердить почту</button>' : ''}<button class="btn" data-a="more">Ещё…</button></div>`;
  $('[data-a=sync]', el).onclick = async () => { const r = await syncNow(); if (r?.error) toast(r.error); else if (r?.data) toast('Синхронизировано'); };
  $('[data-a=devices]', el).onclick = devices;
  $('[data-a=verify]', el)?.addEventListener('click', verify);
  $('[data-a=more]', el).onclick = () => more(s);
  if (!me) {
    const r = await A().me();
    if (!r.error && el.isConnected) { me = r.data; draw(el, s); }
  }
}

// Окно с полями: fields — [name, подпись, type, autocomplete]; run(values) → текст ошибки или ничего.
function form(title, hint, fields, button, run, extra = '') {
  const m = modal(`<form><h3>${esc(title)}</h3>${hint ? `<p class="hint">${hint}</p>` : ''}
    ${fields.map(([n, l, t = 'text', ac = 'off']) => `<label class="field"><span>${esc(l)}</span><input name="${n}" type="${t}" autocomplete="${ac}" autocapitalize="off" spellcheck="false"></label>`).join('')}
    <p class="error" hidden></p><div class="actions"><button class="btn primary" type="submit">${esc(button)}</button>${extra}<button class="btn" type="button" data-a="cancel">Отмена</button></div></form>`);
  const f = $('form', m.el), err = $('.error', f), btn = $('[type=submit]', f);
  $('[data-a=cancel]', f).onclick = m.close;
  setTimeout(() => f.querySelector('input')?.focus(), 0);
  f.addEventListener('submit', async e => {
    e.preventDefault();
    const v = Object.fromEntries(fields.map(([n]) => [n, f[n].value]));
    btn.disabled = true; const label = btn.textContent; btn.textContent = 'Подождите…'; err.hidden = true;
    let msg;
    try { msg = await run(v); } catch (x) { msg = String(x?.message || x); }
    if (!m.el.isConnected) return;
    if (msg) { err.textContent = msg; err.hidden = false; btn.disabled = false; btn.textContent = label; } else m.close();
  });
  return m;
}
const res = r => r.error ? r.error : null;
async function afterSignIn(text) {
  me = null; signed = true; toast(text);
  await status();
  await syncNow();
}

function signIn() {
  const m = form('Вход в Yoru', 'История, избранное, чтение манги и входы в сервисы сохранятся в аккаунте — и после переустановки, и на iPhone, ТВ и Mac.',
    [['login', 'Логин', 'text', 'username'], ['password', 'Пароль Yoru', 'password', 'current-password']], 'Войти', async v => {
      if (!v.login.trim() || !v.password) return 'Введите логин и пароль';
      const r = await A().signIn(v.login.trim(), nfc(v.password));
      if (r.error) return r.error;
      afterSignIn('Вы вошли в аккаунт Yoru');
    }, '<button class="btn" type="button" data-a="forgot">Забыли пароль?</button>');
  $('[data-a=forgot]', m.el).onclick = () => { const l = m.el.querySelector('[name=login]').value; m.close(); forgot(l); };
}

function register() {
  form('Новый аккаунт', 'Почта нужна, чтобы восстановить пароль. Код приглашения выдаёт владелец сервера.',
    [['login', 'Логин', 'text', 'username'], ['email', 'Почта', 'email', 'email'], ['invite', 'Код приглашения'], ['password', 'Пароль (от 8 символов)', 'password', 'new-password'], ['again', 'Повторите пароль', 'password', 'new-password']], 'Создать', async v => {
      if (!v.login.trim()) return 'Введите логин';
      if (v.password.length < 8) return 'Пароль — не короче 8 символов';
      if (v.password !== v.again) return 'Пароли не совпадают';
      const r = await A().register(v.login.trim(), v.email.trim(), v.invite.trim(), nfc(v.password));
      if (r.error) return r.error;
      afterSignIn(r.data?.mailed ? `Аккаунт создан. Мы отправили код на ${v.email.trim()}` : 'Аккаунт создан');
    });
}

function forgot(login = '') {
  const m = form('Восстановление пароля', 'Код придёт на почту, подтверждённую в аккаунте. Входы в сервисы после смены пароля по почте нужно будет повторить.',
    [['login', 'Логин или почта', 'text', 'username']], 'Прислать код', async v => {
      if (!v.login.trim()) return 'Введите логин';
      const r = await A().forgot(v.login.trim());
      if (r.error) return r.error;
      toast(typeof r.data === 'string' ? r.data : 'Код отправлен');
      reset(v.login.trim());
    }, '<button class="btn" type="button" data-a="have">У меня есть код</button>');
  m.el.querySelector('[name=login]').value = login;
  $('[data-a=have]', m.el).onclick = () => { const l = m.el.querySelector('[name=login]').value.trim(); if (!l) return; m.close(); reset(l); };
}

function reset(login) {
  form('Новый пароль', `Логин: ${esc(login)}. Входы в сервисы были зашифрованы старым паролем — их придётся повторить.`,
    [['code', 'Код из письма'], ['password', 'Новый пароль (от 8 символов)', 'password', 'new-password'], ['again', 'Повторите новый пароль', 'password', 'new-password']], 'Сменить и войти', async v => {
      if (v.password.length < 8) return 'Пароль — не короче 8 символов';
      if (v.password !== v.again) return 'Пароли не совпадают';
      const r = await A().reset(login, v.code.trim(), nfc(v.password));
      if (r.error) return r.error;
      afterSignIn('Пароль изменён. Войдите в сервисы заново.');
    });
}

function verify() {
  const m = form('Подтвердите почту', me ? `Мы отправили код на ${esc(me.email)}.` : '', [['code', 'Код из письма']], 'Подтвердить', async v => {
    const r = await A().verifyEmail(v.code.trim());
    if (r.error) return r.error;
    toast('Почта подтверждена'); me = null; status();
  }, '<button class="btn" type="button" data-a="resend">Прислать ещё раз</button>');
  $('[data-a=resend]', m.el).onclick = async () => { const r = await A().resend(); toast(r.error || 'Код отправлен'); };
}

function server(s) {
  const m = form('Адрес сервера', `Пусто — сервер по умолчанию (${esc(s.defaultServer)}).`, [['server', 'Адрес сервера', 'url']], 'Сохранить', async v => {
    await A().setServer(v.server.trim()); toast('Адрес сохранён');
  });
  m.el.querySelector('[name=server]').value = s.server || '';
}

async function devices() {
  const m = modal(`<h3>Устройства</h3><div data-f="list"><p class="hint">Загружаю…</p></div><div class="actions" style="margin-top:12px"><button class="btn" data-a="all">Выйти везде</button><button class="btn" data-a="close">Закрыть</button></div>`);
  $('[data-a=close]', m.el).onclick = m.close;
  $('[data-a=all]', m.el).onclick = () => { m.close(); signOutAll(); };
  const fill = async () => {
    const r = await A().me();
    const box = $('[data-f=list]', m.el);
    if (!m.el.isConnected) return;
    if (r.error) { box.innerHTML = `<p class="error">${esc(r.error)}</p>`; return; }
    me = r.data;
    box.innerHTML = (me.devices || []).map(d => `<div class="kv"><span>${esc(d.name)}${d.current ? ' · это устройство' : `<br><small>Был в сети ${esc(ago(d.last * 1000))}</small>`}</span>${d.current ? '' : `<button class="btn" data-id="${esc(d.id)}">Отключить</button>`}</div>`).join('');
    box.querySelectorAll('[data-id]').forEach(b => b.onclick = async () => { b.disabled = true; const x = await A().removeDevice(b.dataset.id); if (x.error) toast(x.error); fill(); });
  };
  fill();
}

function more(s) {
  const m = modal(`<h3>Аккаунт Yoru</h3><p class="hint">Выход из аккаунта Yoru не выходит из Anime 365, MangaLib и Com-X на этом устройстве.</p>
    <div class="actions"><button class="btn" data-a="pass">Сменить пароль</button><button class="btn" data-a="mail">Сменить почту</button><button class="btn" data-a="server">Сервер</button>
    <button class="btn" data-a="out">Выйти</button><button class="btn" data-a="del">Удалить аккаунт</button><button class="btn" data-a="close">Закрыть</button></div>`);
  const go = f => () => { m.close(); f(); };
  $('[data-a=close]', m.el).onclick = m.close;
  $('[data-a=pass]', m.el).onclick = go(changePassword);
  $('[data-a=mail]', m.el).onclick = go(changeEmail);
  $('[data-a=server]', m.el).onclick = go(() => server(s));
  $('[data-a=out]', m.el).onclick = go(signOut);
  $('[data-a=del]', m.el).onclick = go(remove);
}

function changePassword() {
  form('Смена пароля', 'Входы в сервисы перешифруются новым паролем. На других устройствах войдите в аккаунт заново.',
    [['old', 'Текущий пароль', 'password', 'current-password'], ['password', 'Новый пароль (от 8 символов)', 'password', 'new-password'], ['again', 'Повторите новый пароль', 'password', 'new-password']], 'Сменить пароль', async v => {
      if (v.password.length < 8) return 'Пароль — не короче 8 символов';
      if (v.password !== v.again) return 'Пароли не совпадают';
      const r = await A().changePassword(nfc(v.old), nfc(v.password));
      if (r.error) return r.error;
      toast('Пароль изменён');
    });
}

function changeEmail() {
  form('Сменить почту', 'На новую почту придёт код подтверждения.', [['email', 'Новая почта', 'email', 'email'], ['password', 'Текущий пароль', 'password', 'current-password']], 'Сохранить', async v => {
    const r = await A().changeEmail(v.email.trim(), nfc(v.password));
    if (r.error) return r.error;
    me = null; status(); verify();
  });
}

function signOut() {
  const m = modal(`<h3>Выйти из аккаунта Yoru?</h3><p class="hint">Входы в сервисы на этом Mac останутся, а синхронизация остановится до нового входа.</p>
    <div class="actions"><button class="btn primary" data-a="here">Выйти</button><button class="btn" data-a="all">Выйти везде</button><button class="btn" data-a="no">Отмена</button></div>`);
  $('[data-a=no]', m.el).onclick = m.close;
  $('[data-a=here]', m.el).onclick = async () => { await syncNow(); await A().signOut(false); m.close(); after(); };
  $('[data-a=all]', m.el).onclick = () => { m.close(); signOutAll(); };
}
function signOutAll() {
  const m = modal(`<h3>Выйти из аккаунта Yoru на всех устройствах?</h3><p class="hint">Входы в сервисы на устройствах останутся, а синхронизация остановится до нового входа.</p>
    <div class="actions"><button class="btn primary" data-a="yes">Выйти везде</button><button class="btn" data-a="no">Отмена</button></div>`);
  $('[data-a=no]', m.el).onclick = m.close;
  $('[data-a=yes]', m.el).onclick = async () => { await syncNow(); await A().signOut(true); m.close(); after(); };
}
function after() { signed = false; me = null; clearTimeout(timer); toast('Вы вышли из аккаунта Yoru'); status(); }

function remove() {
  form('Удалить аккаунт Yoru?', 'С сервера удалятся история, прогресс и входы в сервисы этого аккаунта. На этом Mac всё останется.',
    [['password', 'Текущий пароль', 'password', 'current-password']], 'Удалить', async v => {
      const r = await A().remove(nfc(v.password));
      if (r.error) return r.error;
      after();
    });
}
