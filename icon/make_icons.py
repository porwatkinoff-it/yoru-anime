# Значок Night Anime в палитре Anime 365: зелёный Material #1B5E20, светлый #E8F5E9, оранжевый #FF9800.
from pathlib import Path
here = Path(__file__).parent

def eye(scale=1.0, cx=512, cy=540):
    # Аниме-глаз: миндалевидная форма, крупная радужка, зрачок-«плей», блик и ресницы.
    return f'''<g transform="translate({cx} {cy}) scale({scale}) translate(-512 -540)">
  <clipPath id="almond"><path d="M152,540 Q512,250 872,540 Q512,830 152,540Z"/></clipPath>
  <path d="M152,540 Q512,250 872,540 Q512,830 152,540Z" fill="#E8F5E9"/>
  <g clip-path="url(#almond)">
    <circle cx="512" cy="540" r="182" fill="#2E7D32"/>
    <circle cx="512" cy="540" r="150" fill="#43A047"/>
    <circle cx="512" cy="590" r="120" fill="#66BB6A" opacity="0.55"/>
    <circle cx="512" cy="540" r="92" fill="#0B3D10"/>
    <path d="M482,488 L572,540 L482,592Z" fill="#FFFFFF"/>
    <circle cx="430" cy="455" r="34" fill="#FFFFFF" opacity="0.95"/>
    <circle cx="590" cy="630" r="14" fill="#FFFFFF" opacity="0.8"/>
  </g>
  <path d="M120,560 Q300,330 512,318 Q740,310 912,505" fill="none" stroke="#0B2E0E" stroke-width="40" stroke-linecap="round"/>
  <path d="M836,440 L930,388 M872,478 L962,450 M790,404 L860,330" stroke="#0B2E0E" stroke-width="30" stroke-linecap="round"/>
  <path d="M250,690 Q512,820 774,690" fill="none" stroke="#0B2E0E" stroke-width="16" stroke-linecap="round" opacity="0.55"/>
</g>'''

def sparkle(x, y, r, color="#FF9800"):
    return f'<path d="M{x},{y-r} Q{x+r*0.14},{y-r*0.14} {x+r},{y} Q{x+r*0.14},{y+r*0.14} {x},{y+r} Q{x-r*0.14},{y+r*0.14} {x-r},{y} Q{x-r*0.14},{y-r*0.14} {x},{y-r}Z" fill="{color}"/>'

background = '''<defs><linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1">
  <stop offset="0" stop-color="#388E3C"/><stop offset="0.55" stop-color="#1B5E20"/><stop offset="1" stop-color="#0F3D13"/></linearGradient>
  <radialGradient id="glow" cx="0.3" cy="0.2" r="0.7"><stop offset="0" stop-color="#A5D6A7" stop-opacity="0.35"/><stop offset="1" stop-color="#A5D6A7" stop-opacity="0"/></radialGradient></defs>'''

def svg(w, h, body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{body}</svg>'

files = {
    # iOS: квадрат во весь холст, углы скругляет система.
    "icon-ios.svg": svg(1024, 1024, background + '<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#glow)"/>' + eye(0.95, 512, 540) + sparkle(800, 210, 78) + sparkle(905, 300, 34, "#FFCC80")),
    # Компьютер: скруглённый квадрат с полями по сетке macOS (824 из 1024), вокруг прозрачно.
    "icon-desktop.svg": svg(1024, 1024, background + '<clipPath id="squircle"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath><g clip-path="url(#squircle)"><g transform="translate(100 100) scale(0.8047)"><rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#glow)"/>' + eye(0.95, 512, 540) + sparkle(800, 210, 78) + sparkle(905, 300, 34, "#FFCC80") + '</g></g>'),
    # Android adaptive icon: фон и передний план отдельно, рисунок внутри безопасной зоны 66/108.
    "icon-bg.svg": svg(1024, 1024, background + '<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#glow)"/>'),
    "icon-fg.svg": svg(1024, 1024, eye(0.66, 512, 530) + sparkle(700, 330, 52) + sparkle(770, 390, 22, "#FFCC80")),
    # Баннер для Android TV / Night TV.
    # Quick Look отрисовывает только квадрат, поэтому баннер 1280×720 лежит по центру квадратного холста и потом обрезается.
    "banner.svg": svg(1280, 1280, '<g transform="translate(0 280)">' + background.replace('x2="0.35"', 'x2="0.6"') + '<rect width="1280" height="720" fill="url(#bg)"/><rect width="1280" height="720" fill="url(#glow)"/>'
        + eye(0.62, 330, 360) + sparkle(560, 180, 46) + sparkle(615, 228, 20, "#FFCC80")
        + '<text x="640" y="350" font-family="Roboto, Helvetica Neue, Arial, sans-serif" font-weight="700" font-size="112" fill="#FFFFFF">Yoru</text>'
        + '<text x="640" y="480" font-family="Roboto, Helvetica Neue, Arial, sans-serif" font-weight="700" font-size="112" fill="#E8F5E9">Anime</text>'
        + '<rect x="644" y="512" width="150" height="10" rx="5" fill="#FF9800"/></g>'),
}
for name, text in files.items():
    (here / name).write_text(text)
print("\n".join(files))
