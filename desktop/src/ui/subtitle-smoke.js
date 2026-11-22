import { openPlayer } from './player.js';

const report = (message, success) => window.__TAURI__.core.invoke('qa_report', { message, success });
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
const expect = (condition, message) => { if (!condition) throw new Error(message); };
async function until(condition, limit, message) {
  const deadline = performance.now() + limit;
  while (!condition() && performance.now() < deadline) await wait(50);
  expect(condition(), message);
}

function measure(data) {
  let white = 0, yellow = 0, green = 0;
  for (let index = 0; index < data.length; index += 4) {
    const r = data[index], g = data[index + 1], b = data[index + 2], a = data[index + 3];
    if (a < 160) continue;
    if (r > 180 && g > 180 && b > 180) white++;
    if (r > 150 && g > 150 && b < 90) yellow++;
    if (r < 90 && g > 150 && b < 90) green++;
  }
  return { white, yellow, green };
}

const frames = [];
const Renderer = window.JASSUB;
window.JASSUB = class extends Renderer {
  constructor(options) {
    super(options);
    this.ready = this.ready.then(() => {
      const original = this.renderer;
      const tested = new Set();
      this.renderer = new Proxy(original, {
        get: (target, key) => {
          if (key !== '_draw') return Reflect.get(target, key);
          return async (time, repaint) => {
            await target._draw(time, repaint);
            const section = time >= 5 ? 'second' : 'first';
            if (tested.has(section)) return;
            tested.add(section);
            const bitmap = await target._drawCapture(time);
            frames.push({ section, time, ...measure(bitmap.data) });
          };
        }
      });
    });
  }
};
addEventListener('unhandledrejection', event => report(String(event.reason), false));
addEventListener('error', event => report(event.message, false));

try {
  const videoResponse = await fetch('./subtitle-probe.mp4');
  const videoURL = URL.createObjectURL(new Blob([await videoResponse.arrayBuffer()], { type: 'video/mp4' }));
  const captions = await (await fetch('./subtitle-probe.ass')).text();
  const playback = {
    options: [{ height: 216, url: videoURL, alternatives: [] }], title: 'Субтитры', episodeTitle: 'Проверка',
    subtitles: 'probe', loadSubs: async () => captions, downloads: [], key: 'qa-player', offline: true, episodeId: 1
  };
  openPlayer(playback, { onClose() {} });
  const video = document.querySelector('video');
  video.addEventListener('error', () => report(video.error.message, false));
  await until(() => frames.length >= 1, 18000, 'No subtitle frame on playback start');
  const first = frames[0];
  expect(first.section === 'first' && first.white > 100 && first.yellow > 100,
         `First ASS caption is blank or lost its style: ${JSON.stringify(first)}`);
  await until(() => frames.length >= 2, 12000, 'No subtitle frame on dialogue change');
  const second = frames[1];
  expect(second.section === 'second' && second.white > 100 && second.green > 100,
         `Second ASS caption is blank or lost its style: ${JSON.stringify(second)}`);

  video.pause();
  document.querySelector('[data-a=subs]').click();
  document.querySelector('[data-on="0"]').click();
  expect(!document.querySelector('.JASSUB'), 'Subtitle toggle left an overlay');
  document.querySelector('[data-on="1"]').click();
  await until(() => frames.length >= 3, 12000, 'No subtitle frame when enabled on pause');
  expect(frames[2].green > 100, 'The paused caption is blank');
  video.currentTime = 2;
  await until(() => frames.length >= 4, 12000, 'No subtitle frame after seeking on pause');
  expect(frames[3].yellow > 100, 'Seeking kept the old caption');
  await report(JSON.stringify(frames), true);
} catch (error) {
  await report(String(error) + '\n' + JSON.stringify(frames), false);
}
