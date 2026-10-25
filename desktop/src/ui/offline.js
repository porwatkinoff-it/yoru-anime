// «Загрузки»: серии без интернета на ноутбуках. Файлы качает основной процесс (src/downloads.js),
// здесь — вкладка, значки на сериях, настройки и запуск скачанной серии в обычном плеере.
import * as D from './data.js';
import { openPlayer } from './player.js';
import { esc, toast, plural, chooseTranslation } from './app.js';

const $ = (s, el = document) => el.querySelector(s);
let enabled = false, items = [];
const listeners = new Set();
export const isEnabled = () => enabled;
export const find = id => items.find(d => d.id === id);
export const onChange = fn => { listeners.add(fn); return () => listeners.delete(fn); };

const QUALITIES = [[480, '480p'], [720, '720p'], [1080, '1080p'], [100000, 'Лучшее']];
const quality = () => D.S.get('dl-quality', 720);
const autoDelete = () => D.S.get('dl-autodelete', false);
const size = n => n >= 1e9 ? (n / 1e9).toFixed(1).replace('.', ',') + ' ГБ' : (n ? Math.max(1, Math.round(n / 1e6)) : 0) + ' МБ';
const ico = {
  dl: '<svg viewBox="0 0 24 24"><path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/></svg>',
  ok: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
  wait: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M12 8v4l2.5 2.5"/></svg>',
  warn: '<svg viewBox="0 0 24 24"><path d="M12 4 2.5 20h19z"/><path d="M12 10v4.5M12 17.5v.5"/></svg>',
  play: '<svg class="fill" viewBox="0 0 24 24"><path d="M7 4.8v14.4a1 1 0 0 0 1.5.86l12-7.2a1 1 0 0 0 0-1.72l-12-7.2A1 1 0 0 0 7 4.8z"/></svg>',
  trash: '<svg viewBox="0 0 24 24"><path d="M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13"/></svg>',
  retry: '<svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.4-5.7M20 4v4h-4"/></svg>'
};

export async function init() {
  enabled = await window.yoru.hasBattery();
  if (!enabled) return;
  $('#nav-downloads').hidden = false;
  items = await window.yoru.dl.list();
  window.yoru.dl.onChanged(list => { items = list; paint(); });
  window.yoru.dl.onDone(d => toast(`Скачано: ${D.item(d.series).title} — ${d.episodeTitle}`));
  cleanWatched();
  paint();
}
function paint() {
  const busy = items.filter(d => d.state === 'queued' || d.state === 'running').length;
  const c = $('#nav-downloads .count'); c.hidden = !busy; c.textContent = busy;
  paintMarks();
  listeners.forEach(fn => fn());
}

// Значок загрузки на карточке серии: скачать / в очереди / проценты / готово / ошибка.
export function mark(epId) {
  if (!enabled) return '';
  const d = find(epId);
  const [cls, inner, title] = !d ? ['', ico.dl, 'Скачать серию']
    : d.state === 'done' ? ['ok', ico.ok, 'Скачано — смотреть без интернета']
    : d.state === 'failed' ? ['bad', ico.warn, d.error]
    : d.state === 'running' && d.total ? ['run', `<b>${Math.floor(d.bytes / d.total * 100)}</b>`, 'Скачивается']
    : ['run', ico.wait, 'В очереди'];
  return `<span class="ep-dl ${cls}" data-dl="${epId}" title="${esc(title)}">${inner}</span>`;
}
function paintMarks() { document.querySelectorAll('.ep-dl[data-dl]').forEach(el => { el.outerHTML = mark(+el.dataset.dl); }); }

// Клик по значку на странице аниме.
export async function episodeClick(it, ep) {
  const d = find(ep.id);
  if (d?.state === 'done') return play(d);
  if (d?.state === 'failed') return window.yoru.dl.retry(d.id);
  if (d) return toast('Серия уже скачивается — смотрите вкладку «Загрузки»');
  if (!(await window.yoru.signedIn())) return toast('Войдите в аккаунт Anime 365, чтобы скачивать');
  let list;
  try { list = await D.translations(ep, it); } catch (e) { return toast(e.message); }
  if (!list.length) return toast('Для этой серии пока нет переводов');
  chooseTranslation(ep, list, D.rememberedTranslation(it), t => download(it, ep, t));
}
export async function download(it, ep, t) {
  const r = await window.yoru.dl.enqueue({
    id: ep.id, seriesId: it.id, series: it.raw, episodeTitle: ep.title, episodeNumber: ep.number,
    translationId: t.id, translationTitle: t.name || t.group, translationKind: t.kind, translationSignature: t.signature, quality: quality()
  });
  if (r.error) return toast(r.error);
  // Перевод запоминаем, но аниме не считаем начатым — как на телефоне.
  D.S.set('tr-' + it.id, t.signature);
  toast(r.data.state === 'done' ? 'Эта серия уже скачана' : `«${ep.title}» скачивается — без интернета она будет во вкладке «Загрузки»`);
}

// Просмотренные удаляются сами, если включено в настройках.
export function cleanWatched() {
  if (!enabled || !autoDelete()) return;
  const ids = items.filter(d => d.state === 'done' && D.isDone(d.id)).map(d => d.id);
  if (ids.length) window.yoru.dl.remove(ids);
}

// ---------- Просмотр скачанной серии ----------
// SRT и VTT переводим в ASS, чтобы субтитры рисовал тот же JASSUB.
function toAss(text) {
  const t = s => { const m = /(\d+):(\d+):(\d+)[.,](\d+)/.exec(s) || /()(\d+):(\d+)[.,](\d+)/.exec(s); if (!m) return '0:00:00.00'; return `${+m[1] || 0}:${m[2].padStart(2, '0')}:${m[3].padStart(2, '0')}.${m[4].padEnd(3, '0').slice(0, 2)}`; };
  const cues = [];
  for (const block of text.replace(/\r/g, '').split(/\n\n+/)) {
    const lines = block.split('\n'), i = lines.findIndex(l => l.includes('-->'));
    if (i < 0) continue;
    const [a, b] = lines[i].split('-->');
    const body = lines.slice(i + 1).join('\\N').replace(/<[^>]+>/g, '');
    if (body.trim()) cues.push(`Dialogue: 0,${t(a)},${t(b)},Default,,0,0,0,,${body}`);
  }
  return `[Script Info]\nScriptType: v4.00+\nPlayResX: 1280\nPlayResY: 720\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Liberation Sans,48,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2.5,1,2,60,60,40,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n${cues.join('\n')}\n`;
}
export function play(d) {
  const it = D.item(d.series);
  const ep = { id: d.id, title: d.episodeTitle, number: d.episodeNumber };
  const t = { id: d.translationId, kind: d.translationKind, signature: d.translationSignature || d.translationKind + '|' };
  D.remember(t, ep, it);
  // Следующая — следующая по номеру скачанная серия этого аниме.
  const next = items.filter(x => x.seriesId === d.seriesId && x.state === 'done' && x.episodeNumber > d.episodeNumber).sort((a, b) => a.episodeNumber - b.episodeNumber)[0];
  openPlayer({
    options: [{ id: 'local', url: 'yoru://dl/' + encodeURIComponent(d.video), height: d.height, alternatives: [] }],
    downloads: [], offline: true,
    subtitles: d.subtitles || null,
    loadSubs: async () => { const r = await window.yoru.dl.text(d.id); if (r.error) throw new Error(r.error); return d.subtitles.endsWith('.ass') ? r.data : toAss(r.data); },
    title: it.title, episodeTitle: ep.title, key: 'position-' + t.id, episodeId: ep.id
  }, {
    next: next ? next.episodeTitle : null,
    onClose: goNext => { cleanWatched(); if (goNext && next) play(next); }
  });
}

// ---------- Вкладка «Загрузки» ----------
export function DownloadsView(_r, alive, main) {
  const page = document.createElement('div'); page.className = 'page'; main.append(page);
  let space = null;
  const refreshSpace = () => window.yoru.dl.space().then(s => { space = s; if (alive()) draw(); });
  const state = d => d.state === 'done' ? `${d.height ? d.height + 'p · ' : ''}${size(d.total || d.bytes)}`
    : d.state === 'failed' ? `<span class="bad">${esc(d.error)}</span>`
    : d.state === 'running' ? (d.total ? `${Math.floor(d.bytes / d.total * 100)}% · ${size(d.bytes)} из ${size(d.total)}` : 'Подготовка…')
    : 'В очереди';
  const row = d => `<div class="dl-row ${d.state}"><button class="dl-main" data-act="${d.state === 'done' ? 'play' : d.state === 'failed' ? 'retry' : ''}" data-id="${d.id}">
      <span class="dl-ico">${d.state === 'done' ? ico.play : d.state === 'failed' ? ico.retry : ico.wait}</span>
      <span style="min-width:0"><b>${esc(d.episodeTitle)}</b><small>${esc(d.translationTitle)} · ${state(d)}</small></span>
      ${d.state === 'running' && d.total ? `<i class="dl-bar" style="width:${d.bytes / d.total * 100}%"></i>` : ''}</button>
    <button class="btn icon" data-act="remove" data-id="${d.id}" title="Удалить">${ico.trash}</button></div>`;
  const draw = () => {
    const groups = new Map();
    for (const d of items) { if (!groups.has(d.seriesId)) groups.set(d.seriesId, []); groups.get(d.seriesId).push(d); }
    page.innerHTML = `<div class="page-head"><h1>Загрузки</h1></div>
      ${items.length ? [...groups.values()].map(list => {
        const it = D.item(list[0].series);
        list.sort((a, b) => a.episodeNumber - b.episodeNumber || a.created - b.created);
        const done = list.filter(d => d.state === 'done').length;
        return `<section class="dl-series"><div class="dl-head"><img src="${esc(it.posterSmall)}" alt=""><div style="min-width:0"><h2>${esc(it.title)}</h2><span>Скачано: ${done} ${plural(done, 'серия', 'серии', 'серий')}${done < list.length ? ` · ещё ${list.length - done} не готово` : ''}</span></div>
          <button class="btn" data-act="remove-series" data-id="${it.id}">Удалить все</button></div>${list.map(row).join('')}</section>`;
      }).join('') : `<div class="state"><div><b>Здесь пока пусто</b>Нажмите ${ico.dl.replace('<svg', '<svg class="inline"')} на серии, чтобы смотреть её без интернета.</div></div>`}
      <div class="panel"><h2>Настройки загрузок</h2>
        <div class="kv"><span>Качество</span><div class="seg">${QUALITIES.map(([q, l]) => `<button data-q="${q}" class="${quality() === q ? 'on' : ''}">${l}</button>`).join('')}</div></div>
        <label class="kv"><span>Удалять просмотренные</span><input type="checkbox" id="autodel" ${autoDelete() ? 'checked' : ''}></label>
        ${space ? `<div class="kv"><span>Занято</span><b>${size(space.used)}</b></div><div class="kv"><span>Свободно на диске</span><b>${space.free ? size(space.free) : '—'}</b></div>` : ''}
      </div>`;
    $('#autodel', page).onchange = e => { D.S.set('dl-autodelete', e.target.checked); cleanWatched(); };
  };
  page.addEventListener('click', e => {
    const q = e.target.closest('[data-q]'); if (q) { D.S.set('dl-quality', +q.dataset.q); draw(); toast('Новое качество — для следующих загрузок'); return; }
    const b = e.target.closest('[data-act]'); if (!b || !b.dataset.act) return;
    const id = +b.dataset.id, d = find(id);
    if (b.dataset.act === 'play' && d) play(d);
    if (b.dataset.act === 'retry') window.yoru.dl.retry(id);
    if (b.dataset.act === 'remove') window.yoru.dl.remove(id).then(refreshSpace);
    if (b.dataset.act === 'remove-series') window.yoru.dl.remove(items.filter(x => x.seriesId === id).map(x => x.id)).then(refreshSpace);
  });
  const off = onChange(() => { if (!alive()) return off(); const y = main.scrollTop; draw(); main.scrollTop = y; });
  draw(); refreshSpace();
}
