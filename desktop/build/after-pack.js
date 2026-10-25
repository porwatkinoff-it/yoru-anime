// macOS спрашивает про микрофон, когда звук идёт через устройство со встроенным микрофоном
// (аудиоинтерфейс, гарнитура). Без текста запроса в Info.plist система сразу отказывает
// без окна, а звук работает как обычно — поэтому убираем тексты, которые добавляет Electron.
const { execFileSync } = require('child_process');
const path = require('path');

exports.default = async function afterPack(ctx) {
  if (ctx.electronPlatformName !== 'darwin') return;
  const plist = path.join(ctx.appOutDir, `${ctx.packager.appInfo.productFilename}.app`, 'Contents', 'Info.plist');
  for (const key of ['NSMicrophoneUsageDescription', 'NSAudioCaptureUsageDescription']) {
    try { execFileSync('/usr/libexec/PlistBuddy', ['-c', `Delete :${key}`, plist], { stdio: 'ignore' }); } catch {}
  }
};
