const assHeader = `[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Liberation Sans,48,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2.5,1,2,60,60,40,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
`;

function assTime(timestamp) {
  const match = /^(?:(\d+):)?(\d{1,2}):(\d{1,2})[.,](\d{1,3})(?=\s|$)/.exec(timestamp.trimStart());
  if (!match) return null;
  const [, hours = '0', minutes, seconds, milliseconds] = match;
  return `${Number(hours)}:${minutes.padStart(2, '0')}:${seconds.padStart(2, '0')}.${milliseconds.padEnd(3, '0').slice(0, 2)}`;
}

// JASSUB читает ASS. Для SRT и WebVTT используем тот же рендерер онлайн и в загрузках.
export function toAss(text) {
  const source = text.replace(/^\uFEFF/, '');
  if (source.includes('[Events]')) return source;

  const cues = [];
  for (const block of source.replace(/\r\n?/g, '\n').split(/\n[ \t]*\n/)) {
    const lines = block.split('\n');
    if (/^(NOTE|STYLE|REGION)(?:\s|$)/.test(lines[0])) continue;
    const index = lines.findIndex(line => line.includes('-->'));
    if (index < 0) continue;
    const [start, end] = lines[index].split('-->').map(assTime);
    const body = lines.slice(index + 1).map(line => line.replace(/<[^>]+>/g, '')).join('\\N');
    if (start && end && body.trim()) cues.push(`Dialogue: 0,${start},${end},Default,,0,0,0,,${body}`);
  }
  if (!cues.length) throw new Error('Формат субтитров не распознан');
  return assHeader + cues.join('\n') + '\n';
}
