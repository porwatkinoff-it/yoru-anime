// Выполняется внутри страницы com-x.life в скрытом WebView: запросы идут с cookies, которые выдала проверка сайта.
// Тело асинхронной функции: args.op — что сделать, ответ — объект; {challenge:true} — сайт снова проверяет браузер.
const parseList = html => {
  const d = new DOMParser().parseFromString(html, 'text/html');
  if (!d.querySelector('.short') && !html.includes('dle_root')) return {challenge: true};
  const abs = s => { if (!s) return ''; try { return new URL(s, location.origin).href } catch (e) { return '' } };
  return {more: !!d.querySelector('.pagination__pages a, .navigation a, .pagination a[href*="/page/"]') && !!html.match(/page\/(\d+)\//),
    items: [...d.querySelectorAll('.short')].map(e => {
      const a = e.querySelector('.readed__title a') || e.querySelector('h3 a') || e.querySelector('a.readed__img');
      const img = e.querySelector('img');
      const name = (a && a.textContent.trim()) || (img && img.getAttribute('alt')) || '';
      return {href: a ? abs(a.getAttribute('href')) : '', title: name,
              cover: abs(img && (img.getAttribute('data-src') || img.getAttribute('src'))),
              meta: [...e.querySelectorAll('.readed__meta-item')].map(x => x.textContent.trim()).filter(Boolean).join(' · ')};
    }).filter(x => x.href)};
};
// window.__DATA__ = {…}; за объектом в том же <script> идёт код, поэтому вырезаем объект по скобкам.
const dataOf = html => {
  const at = html.indexOf('window.__DATA__');
  if (at < 0) return null;
  const start = html.indexOf('{', at); let depth = 0, inStr = false, esc = false, end = -1;
  for (let i = start; i >= 0 && i < html.length; i++) {
    const c = html[i];
    if (inStr) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === '"') inStr = false; continue; }
    if (c === '"') inStr = true; else if (c === '{') depth++; else if (c === '}') { depth--; if (depth === 0) { end = i; break; } }
  }
  if (end > start) { try { return JSON.parse(html.slice(start, end + 1)) } catch (e) {} }
  return null;
};
const page = async path => { const r = await fetch(path); return await r.text(); };
const ops = {
  async list(a) { return parseList(await page(a.path)); },
  async search(a) {
    const body = new URLSearchParams({do: 'search', subaction: 'search', story: a.q, search_start: String(a.page), full_search: '0', result_from: String((a.page - 1) * 20 + 1)});
    const r = await fetch('/index.php?do=search', {method: 'POST', body});
    return parseList(await r.text());
  },
  async details(a) {
    const html = await page(a.path);
    if (!html.includes('__DATA__') && !html.includes('dle_root')) return {challenge: true};
    const data = dataOf(html);
    const d = new DOMParser().parseFromString(html, 'text/html');
    const t = s => { const e = d.querySelector(s); return e ? e.textContent.trim() : '' };
    const img = d.querySelector('.page__poster img');
    return {data, title: t('h1'), original: t('.page__title-original'), text: t('.page__text'),
            cover: img ? new URL(img.getAttribute('data-src') || img.getAttribute('src'), location.origin).href : '',
            tags: [...d.querySelectorAll('.page__tags a')].map(a => a.textContent.trim()),
            info: [...d.querySelectorAll('.page__list li')].map(li => li.textContent.replace(/\s+/g, ' ').trim())};
  },
  async pages(a) {
    const html = await page(a.path);
    if (!html.includes('__DATA__') && !html.includes('dle_root')) return {challenge: true};
    const data = dataOf(html);
    return {images: data && data.images ? data.images : [], logged: data ? !!data.is_logged : false};
  }
};
return await ops[args.op](args);
