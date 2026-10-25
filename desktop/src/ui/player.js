// Плеер: видео с запасными ссылками, качество, скорость, субтитры ASS, пропуск заставки и следующая серия.
import * as D from './data.js';

const SPEEDS = [0.75, 1, 1.25, 1.5, 2];
const SKIP = 88, NEXT_AT = 90, COUNTDOWN = 10;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmt = s => { s = Math.max(0, Math.floor(s || 0)); const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = String(s % 60).padStart(2, '0'); return h ? `${h}:${String(m).padStart(2, '0')}:${x}` : `${m}:${x}`; };
const svg = {
  play: '<svg class="fill" viewBox="0 0 24 24"><path d="M7 4.8v14.4a1 1 0 0 0 1.5.86l12-7.2a1 1 0 0 0 0-1.72l-12-7.2A1 1 0 0 0 7 4.8z"/></svg>',
  pause: '<svg class="fill" viewBox="0 0 24 24"><rect x="6" y="4.5" width="4.2" height="15" rx="1.2"/><rect x="13.8" y="4.5" width="4.2" height="15" rx="1.2"/></svg>',
  back10: '<svg viewBox="0 0 24 24"><path d="M4 12a8 8 0 1 0 2.4-5.7M4 4v4h4"/><text x="12" y="15.5" font-size="7" text-anchor="middle" fill="currentColor" stroke="none" font-weight="700">10</text></svg>',
  fwd10: '<svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.4-5.7M20 4v4h-4"/><text x="12" y="15.5" font-size="7" text-anchor="middle" fill="currentColor" stroke="none" font-weight="700">10</text></svg>',
  close: '<svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg>',
  vol: '<svg viewBox="0 0 24 24"><path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path d="M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"/></svg>',
  mute: '<svg viewBox="0 0 24 24"><path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path d="m16 9.5 5 5M21 9.5l-5 5"/></svg>',
  subs: '<svg viewBox="0 0 24 24"><rect x="3" y="5.5" width="18" height="13" rx="2.5"/><path d="M7 13.5h4M13 13.5h4M7 10h10"/></svg>',
  gear: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>',
  skip: '<svg viewBox="0 0 24 24"><path d="M5 6l7 6-7 6zM13 6l7 6-7 6z"/></svg>',
  dl: '<svg viewBox="0 0 24 24"><path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/></svg>',
  fs: '<svg viewBox="0 0 24 24"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></svg>',
  unfs: '<svg viewBox="0 0 24 24"><path d="M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5"/></svg>',
  next: '<svg class="fill" viewBox="0 0 24 24"><path d="M5 5.5v13a1 1 0 0 0 1.5.86L16 13.7V18a1 1 0 0 0 2 0V6a1 1 0 0 0-2 0v4.3L6.5 4.64A1 1 0 0 0 5 5.5z"/></svg>'
};

let current = null;
export function openPlayer(pb, opts) { current?.close(false); current = new Player(pb, opts); }

class Player {
  constructor(pb, { next, onClose, download }) {
    this.pb = pb; this.nextTitle = next; this.onClose = onClose; this.saveOffline = download;
    this.options = pb.options;
    const want = D.S.get('quality', 0);
    this.option = (want && this.options.find(o => o.height <= want)) || this.options[0];
    this.urls = [this.option.url, ...this.option.alternatives]; this.urlIndex = 0;
    this.subsOn = !!pb.subtitles; this.subDelay = 0;
    this.countdown = null; this.dismissedNext = false; this.lastSave = 0; this.closed = false;
    this.build();
    this.load(this.resumeAt());
  }
  resumeAt() {
    const ms = D.S.get(this.pb.key, 0);
    return ms > 5000 ? ms / 1000 : 0;
  }
  build() {
    const el = this.el = document.createElement('div');
    el.id = 'player';
    el.innerHTML = `<video playsinline preload="auto"></video>
      <div class="p-chrome">
        <div class="p-top"><button class="pbtn" data-a="close" title="Назад (Esc)">${svg.close}</button><div class="titles"><b>${esc(this.pb.title)}</b><span>${esc(this.pb.episodeTitle)}</span></div></div>
        <div class="p-bottom">
          <div class="p-seek"><div class="track"><div class="buf"></div><div class="fill"></div><div class="knob"></div></div><div class="tip"></div></div>
          <div class="p-row">
            <button class="pbtn big" data-a="toggle" title="Пауза (пробел)">${svg.pause}</button>
            <button class="pbtn" data-a="back" title="−10 с (←)">${svg.back10}</button>
            <button class="pbtn" data-a="fwd" title="+10 с (→)">${svg.fwd10}</button>
            <button class="pbtn" data-a="mute" title="Звук (M)">${svg.vol}</button><input class="p-volume" type="range" min="0" max="1" step="0.02">
            <span class="time">0:00 / 0:00</span>
            <div class="p-spacer"></div>
            <button class="pbtn" data-a="skip" title="Пропустить заставку (S)">${svg.skip}<span>+${SKIP} с</span></button>
            ${this.nextTitle ? `<button class="pbtn" data-a="next" title="Следующая серия (N)">${svg.next}</button>` : ''}
            ${this.pb.subtitles ? `<button class="pbtn" data-a="subs" title="Субтитры">${svg.subs}</button>` : ''}
            <button class="pbtn" data-a="settings" title="Качество и скорость">${svg.gear}</button>
            ${this.saveOffline || this.pb.downloads.length ? `<button class="pbtn" data-a="download" title="Скачать серию">${svg.dl}</button>` : ''}
            <button class="pbtn" data-a="fs" title="Во весь экран (F)">${svg.fs}</button>
          </div>
        </div>
      </div>
      <button class="pill" data-a="next">${svg.next}<span></span></button>
      <div class="p-flash"></div>`;
    document.body.append(el);
    const v = this.v = el.querySelector('video');
    v.volume = D.S.get('volume', 1); v.muted = D.S.get('muted', false);
    v.playbackRate = D.S.get('speed', 1);
    el.querySelector('.p-volume').value = v.volume;
    this.listen();
    this.poke();
  }
  load(at) {
    const v = this.v;
    this.error(null);
    v.src = this.urls[this.urlIndex];
    v.playbackRate = D.S.get('speed', 1);
    const start = () => { if (at > 0 && at < v.duration - 60) v.currentTime = at; v.play().catch(() => {}); this.attachSubs(); };
    v.addEventListener('loadedmetadata', start, { once: true });
  }
  // Ошибка источника: следующая ссылка того же качества, затем качество ниже.
  fallback() {
    const at = this.v.currentTime || this.resumeAt();
    if (this.urlIndex + 1 < this.urls.length) { this.urlIndex++; return this.load(at); }
    const i = this.options.indexOf(this.option);
    if (i + 1 < this.options.length) { this.option = this.options[i + 1]; this.urls = [this.option.url, ...this.option.alternatives]; this.urlIndex = 0; this.flash(`Переключаемся на ${this.option.height}p`); return this.load(at); }
    this.error('Видео не загружается. Попробуйте другой перевод или проверьте интернет.');
  }
  error(msg) {
    this.el.querySelector('.p-error')?.remove();
    if (!msg) return;
    this.el.insertAdjacentHTML('beforeend', `<div class="p-error"><div><b>Не удалось воспроизвести</b><br>${esc(msg)}<br><br><button class="btn" data-a="retry">Повторить</button> <button class="btn" data-a="close">Закрыть</button></div></div>`);
  }
  async attachSubs() {
    if (!this.pb.subtitles || this.subs || !this.subsOn) return;
    try {
      if (!this.subText) {
        if (this.pb.loadSubs) this.subText = await this.pb.loadSubs();
        else { const r = await window.yoru.text(this.pb.subtitles); if (r.error) throw new Error(r.error); this.subText = r.data; }
      }
      if (this.closed || this.subs || !this.subsOn) return;
      // Пути — абсолютные: воркер лежит в vendor/ и относительные считал бы от себя.
      const vendor = f => new URL('vendor/' + f, location.href).href;
      this.subs = new window.JASSUB({
        video: this.v, subContent: this.subText,
        workerUrl: vendor('jassub-worker.js'), wasmUrl: vendor('jassub-worker.wasm'), modernWasmUrl: vendor('jassub-worker-modern.wasm'),
        availableFonts: { 'liberation sans': vendor('default.woff2') }, fallbackFont: 'liberation sans',
        timeOffset: this.subDelay
      });
    } catch (e) { this.flash('Субтитры не загрузились'); console.error(e); }
  }
  detachSubs() { try { this.subs?.destroy(); } catch {} this.subs = null; }

  listen() {
    const v = this.v, el = this.el;
    v.addEventListener('error', () => { if (!this.closed && v.src) this.fallback(); });
    v.addEventListener('play', () => this.paintPlay());
    v.addEventListener('pause', () => { this.paintPlay(); this.save(); this.poke(); });
    v.addEventListener('timeupdate', () => this.tick());
    v.addEventListener('progress', () => this.paintBuffer());
    v.addEventListener('ended', () => this.ended());
    v.addEventListener('volumechange', () => { D.S.set('volume', v.volume); D.S.set('muted', v.muted); el.querySelector('[data-a=mute]').innerHTML = v.muted || !v.volume ? svg.mute : svg.vol; });
    v.addEventListener('click', () => this.toggle());
    v.addEventListener('dblclick', () => this.fullscreen());
    el.querySelector('.p-volume').addEventListener('input', e => { v.volume = +e.target.value; v.muted = false; });
    el.addEventListener('mousemove', () => this.poke());
    el.addEventListener('click', e => {
      const b = e.target.closest('[data-a]');
      if (!e.target.closest('.menu') && !e.target.closest('[data-a=settings],[data-a=subs]')) this.closeMenu();
      if (!b) return;
      ({
        close: () => this.close(false), toggle: () => this.toggle(), back: () => this.seek(-10), fwd: () => this.seek(10),
        mute: () => { v.muted = !v.muted; }, skip: () => this.seek(SKIP, true), next: () => this.close(true),
        subs: () => this.subsMenu(b), settings: () => this.settingsMenu(b), download: () => this.downloadMenu(b),
        fs: () => this.fullscreen(), retry: () => { this.urlIndex = 0; this.load(v.currentTime || this.resumeAt()); }
      })[b.dataset.a]?.();
    });
    // Перемотка по полосе.
    const seek = el.querySelector('.p-seek'), tip = seek.querySelector('.tip');
    const at = e => { const r = seek.getBoundingClientRect(); return Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)); };
    seek.addEventListener('mousemove', e => { const f = at(e); tip.style.left = f * 100 + '%'; tip.textContent = fmt(f * (v.duration || 0)); });
    seek.addEventListener('mousedown', e => {
      const move = ev => { if (v.duration) { v.currentTime = at(ev) * v.duration; this.tick(); } };
      move(e);
      const up = () => { window.removeEventListener('mousemove', move); window.removeEventListener('mouseup', up); };
      window.addEventListener('mousemove', move); window.addEventListener('mouseup', up);
    });
    this.keys = e => {
      if (e.target.matches?.('input[type=text],input[type=search]')) return;
      // Буквы — по физической клавише, чтобы работали и в русской раскладке.
      const k = e.code.startsWith('Key') ? e.code.slice(3).toLowerCase() : e.key;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const handled = {
        ' ': () => this.toggle(), k: () => this.toggle(), ArrowLeft: () => this.seek(-10), ArrowRight: () => this.seek(10),
        j: () => this.seek(-10), l: () => this.seek(10),
        ArrowUp: () => { v.volume = Math.min(1, v.volume + .1); v.muted = false; this.flash(`Громкость ${Math.round(v.volume * 100)}%`); },
        ArrowDown: () => { v.volume = Math.max(0, v.volume - .1); this.flash(`Громкость ${Math.round(v.volume * 100)}%`); },
        f: () => this.fullscreen(), m: () => { v.muted = !v.muted; }, s: () => this.seek(SKIP, true),
        n: () => this.nextTitle && this.close(true),
        Escape: () => { if (this.menu) this.closeMenu(); else if (this.fs) this.fullscreen(false); else this.close(false); }
      }[k];
      if (handled) { e.preventDefault(); e.stopPropagation(); handled(); this.poke(); }
    };
    document.addEventListener('keydown', this.keys, true);
    this.offFs = window.yoru.onFullscreen(on => { this.fs = on; el.classList.toggle('fs', on); el.querySelector('[data-a=fs]').innerHTML = on ? svg.unfs : svg.fs; });
  }
  poke() {
    this.el.classList.remove('idle');
    clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => { if (!this.v.paused && !this.menu) this.el.classList.add('idle'); }, 2800);
  }
  toggle() { const v = this.v; if (v.paused) v.play().catch(() => {}); else v.pause(); }
  seek(d, skip) {
    const v = this.v; if (!v.duration) return;
    v.currentTime = Math.min(v.duration - 1, Math.max(0, v.currentTime + d));
    this.flash(skip ? `Заставка пропущена · ${fmt(v.currentTime)}` : (d > 0 ? '+' : '−') + Math.abs(d) + ' с');
    this.tick();
  }
  fullscreen(on = !this.fs) { window.yoru.fullscreen(on); }
  flash(text) {
    const f = this.el.querySelector('.p-flash'); f.textContent = text; f.classList.add('show');
    clearTimeout(this.flashTimer); this.flashTimer = setTimeout(() => f.classList.remove('show'), 1400);
  }
  paintPlay() { this.el.querySelector('[data-a=toggle]').innerHTML = this.v.paused ? svg.play : svg.pause; }
  paintBuffer() {
    const v = this.v, b = v.buffered;
    for (let i = 0; i < b.length; i++) if (b.start(i) <= v.currentTime + 1) this.el.querySelector('.buf').style.width = (v.duration ? b.end(i) / v.duration * 100 : 0) + '%';
  }
  tick() {
    const v = this.v, d = v.duration || 0, t = v.currentTime;
    const f = d ? t / d : 0;
    this.el.querySelector('.fill').style.width = f * 100 + '%';
    this.el.querySelector('.knob').style.left = f * 100 + '%';
    this.el.querySelector('.time').textContent = `${fmt(t)} / ${fmt(d)}`;
    this.paintBuffer();
    if (!d) return;
    if (Date.now() - this.lastSave > 5000) this.save();
    if (f > .93 || d - t < 120) D.markDone(this.pb.episodeId);
    // «Следующая серия» в последние 90 секунд.
    const pill = this.el.querySelector('.pill');
    const show = this.nextTitle && !this.dismissedNext && d - t < NEXT_AT && d > NEXT_AT * 3;
    pill.classList.toggle('show', !!show || this.countdown != null);
    if (show && this.countdown == null) pill.querySelector('span').textContent = this.nextTitle;
  }
  save() {
    const v = this.v, d = v.duration; if (!d) return;
    this.lastSave = Date.now();
    const t = v.currentTime;
    // У самого конца позицию не храним — серия начнётся сначала.
    D.savePosition(this.pb.key, d - t < 60 ? 0 : t * 1000);
    if (!D.isDone(this.pb.episodeId)) D.S.set('watch-' + this.pb.episodeId, Math.min(1, t / d));
  }
  ended() {
    this.save(); D.markDone(this.pb.episodeId);
    if (!this.nextTitle) { this.paintPlay(); this.poke(); return; }
    let left = COUNTDOWN;
    const pill = this.el.querySelector('.pill'), label = pill.querySelector('span');
    const paint = () => { label.textContent = `${this.nextTitle} через ${left}`; };
    this.countdown = setInterval(() => { left--; if (left <= 0) this.close(true); else paint(); }, 1000);
    paint(); pill.classList.add('show');
    this.el.classList.remove('idle');
  }

  // ---------- Меню ----------
  closeMenu() { this.menu?.remove(); this.menu = null; }
  openMenu(anchor, html, onClick) {
    const was = this.menu?.dataset.for === anchor.dataset.a;
    this.closeMenu(); if (was) return;
    const m = this.menu = document.createElement('div');
    m.className = 'menu'; m.dataset.for = anchor.dataset.a; m.innerHTML = html;
    this.el.querySelector('.p-bottom').append(m);
    const r = anchor.getBoundingClientRect();
    m.style.right = Math.max(12, window.innerWidth - r.right - 40) + 'px';
    m.addEventListener('click', e => { e.stopPropagation(); const b = e.target.closest('button'); if (b) onClick(b); });
  }
  settingsMenu(anchor) {
    const v = this.v;
    const draw = () => `<div class="mh">Качество</div>${this.options.map((o, i) => `<button data-q="${i}" class="${o === this.option ? 'on' : ''}">${o.height >= 2160 ? '4K' : o.height ? o.height + 'p' : 'Авто'}</button>`).join('')}
      <div class="mh">Скорость</div>${SPEEDS.map(s => `<button data-s="${s}" class="${v.playbackRate === s ? 'on' : ''}">${s === 1 ? 'Обычная' : String(s).replace('.', ',') + '×'}</button>`).join('')}`;
    this.openMenu(anchor, draw(), b => {
      if (b.dataset.q) {
        const o = this.options[+b.dataset.q];
        if (o !== this.option) { const at = v.currentTime, playing = !v.paused; this.option = o; this.urls = [o.url, ...o.alternatives]; this.urlIndex = 0; D.S.set('quality', o.height); this.detachSubs(); this.load(at); if (!playing) v.addEventListener('playing', () => v.pause(), { once: true }); }
      } else { v.playbackRate = +b.dataset.s; D.S.set('speed', v.playbackRate); }
      this.menu.innerHTML = draw();
    });
  }
  subsMenu(anchor) {
    const draw = () => `<div class="mh">Субтитры</div><button data-on="1" class="${this.subsOn ? 'on' : ''}">Включены</button><button data-on="0" class="${this.subsOn ? '' : 'on'}">Выключены</button>
      <div class="mh">Задержка</div><div class="delay"><button data-d="-0.5">−</button><span>${this.subDelay > 0 ? '+' : ''}${this.subDelay.toFixed(1).replace('.', ',')} с</span><button data-d="0.5">+</button></div>`;
    this.openMenu(anchor, draw(), b => {
      if (b.dataset.on) { this.subsOn = b.dataset.on === '1'; if (this.subsOn) this.attachSubs(); else this.detachSubs(); }
      if (b.dataset.d) { this.subDelay = Math.round((this.subDelay + +b.dataset.d) * 10) / 10; if (this.subs) this.subs.timeOffset = this.subDelay; }
      this.menu.innerHTML = draw();
    });
  }
  downloadMenu(anchor) {
    // На ноутбуке — в «Загрузки» приложения; на остальных компьютерах — файлом в папку.
    if (this.saveOffline) { this.saveOffline(); return; }
    this.openMenu(anchor, `<div class="mh">Скачать серию</div>${this.pb.downloads.map((d, i) => `<button data-i="${i}">${d.height ? d.height + 'p' : 'Видео'}</button>`).join('')}`, b => {
      const d = this.pb.downloads[+b.dataset.i];
      const name = `${this.pb.title} — ${this.pb.episodeTitle} (${d.height}p).mp4`.replace(/[\\/:*?"<>|]/g, ' ');
      window.yoru.download(d.url, name);
      this.flash('Скачивание началось — в папку «Загрузки/Yoru Anime»');
      this.closeMenu();
    });
  }

  close(goNext) {
    if (this.closed) return;
    this.closed = true;
    this.save();
    clearInterval(this.countdown); clearTimeout(this.idleTimer);
    document.removeEventListener('keydown', this.keys, true);
    this.offFs?.();
    this.detachSubs();
    this.v.pause(); this.v.removeAttribute('src'); this.v.load();
    if (this.fs) window.yoru.fullscreen(false);
    this.el.remove();
    if (current === this) current = null;
    this.onClose?.(goNext);
  }
}
