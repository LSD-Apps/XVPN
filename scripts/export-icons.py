"""Package the reviewed vector render into platform icon resources.

Requires Pillow. First render design/brand/logo.svg to logo.png with an SVG
renderer (for example sharp). No image-generation service is needed to export.
"""
from pathlib import Path
import json
import struct
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / 'design/brand'
RES = ROOT / 'app/android/app/src/main/res'
NAVY = '#101F30'
source = Image.open(BRAND / 'logo.png').convert('RGBA')
mark = source.crop(source.getchannel('A').getbbox())


def save(im, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path)


def logo(size, fraction=.72, background=None, rounded=False, mono=False):
    # Render large before downsampling to preserve clean edges at tray sizes.
    work = max(1024, size)
    out = Image.new('RGBA', (work, work))
    if background:
        if rounded:
            ImageDraw.Draw(out).rounded_rectangle((0, 0, work-1, work-1),
                                                  radius=work*.225, fill=background)
        else:
            out.paste(background, (0, 0, work, work))
    symbol = mark.copy()
    symbol.thumbnail((round(work*fraction), round(work*fraction)), Image.Resampling.LANCZOS)
    if mono:
        alpha = symbol.getchannel('A')
        symbol = Image.new('RGBA', symbol.size, 'white')
        symbol.putalpha(alpha)
    out.alpha_composite(symbol, ((work-symbol.width)//2, (work-symbol.height)//2))
    return out.resize((size, size), Image.Resampling.LANCZOS)


save(logo(1024, .72, NAVY).convert('RGB'), BRAND / 'app-icon-1024.png')
save(logo(512, .72, NAVY).convert('RGB'), BRAND / 'google-play-512.png')
save(logo(512, .90), ROOT / 'vpn.png')
save(logo(256, .76, NAVY, True), ROOT / 'app/assets/vpn.png')
ico_sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
ico = logo(256, .78, NAVY, True)
ico_path = ROOT / 'app/windows/runner/resources/app_icon.ico'
ico.save(ico_path, sizes=[(s, s) for s in ico_sizes])

for density, scale in [('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2),
                       ('xxhdpi', 3), ('xxxhdpi', 4)]:
    save(logo(round(48*scale), .72, NAVY, True),
         RES / f'mipmap-{density}/ic_launcher.png')
    # 52dp centered on 108dp: extra space inside the official 66dp safe area.
    save(logo(round(108*scale), 52/108),
         RES / f'drawable-{density}/ic_launcher_foreground.png')
    save(logo(round(108*scale), 52/108, mono=True),
         RES / f'drawable-{density}/ic_launcher_monochrome.png')
    save(logo(round(24*scale), .88, mono=True),
         RES / f'drawable-{density}/ic_stat_xvpn.png')

for version in [26, 33]:
    mono = '\n    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />' if version >= 33 else ''
    target = RES / f'mipmap-anydpi-v{version}/ic_launcher.xml'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />{mono}
</adaptive-icon>
''', encoding='utf-8')
(RES / 'values/icon_colors.xml').write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<resources><color name="ic_launcher_background">{NAVY}</color></resources>
''', encoding='utf-8')

# Standalone catalog, ready to copy into a future iOS Runner asset catalog.
catalog = BRAND / 'ios/AppIcon.appiconset'
entries = []
for idiom, sizes in [('iphone', [(20,[2,3]), (29,[2,3]), (40,[2,3]), (60,[2,3])]),
                     ('ipad', [(20,[1,2]), (29,[1,2]), (40,[1,2]), (76,[1,2]), (83.5,[2])])]:
    for points, scales in sizes:
        for scale in scales:
            pixels = round(points*scale)
            filename = f'icon-{pixels}.png'
            save(logo(pixels, .72, NAVY).convert('RGB'), catalog / filename)
            entries.append(dict(idiom=idiom, size=f'{points}x{points}', scale=f'{scale}x', filename=filename))
save(logo(1024, .72, NAVY).convert('RGB'), catalog / 'icon-1024.png')
entries.append(dict(idiom='ios-marketing', size='1024x1024', scale='1x', filename='icon-1024.png'))
(catalog / 'Contents.json').write_text(json.dumps(dict(images=entries, info=dict(version=1, author='xcode')), indent=2)+'\n')

# Visual QA sheet: actual output assets on representative launcher/UI surfaces.
sheet = Image.new('RGB', (1200, 700), '#F2F5F8')
draw = ImageDraw.Draw(sheet)
font_path = Path('C:/Windows/Fonts/segoeui.ttf')
font = ImageFont.truetype(str(font_path), 20) if font_path.exists() else ImageFont.load_default()
title = ImageFont.truetype(str(font_path), 32) if font_path.exists() else font
draw.text((48, 30), 'XVPN / Open passage', fill=NAVY, font=title)
draw.text((48, 80), 'A sheltered entrance. A flowing route. Effortless connection.', fill='#536579', font=font)
for i, (name, bg, radius, mono) in enumerate([
        ('iOS mask preview', NAVY, 46, False),
        ('Android circle', NAVY, 100, False),
        ('Android themed', '#C8EADD', 100, True),
        ('Windows / desktop', NAVY, 46, False)]):
    x, y = 56 + i*288, 154
    icon = logo(200, .72, bg, True, mono)
    if i in (1,2):
        # Android visible viewport is 72 of the 108dp layer canvas.
        icon = logo(300, 52/108, bg, mono=mono).crop((50,50,250,250))
    if i == 2:
        # A representative launcher tint, not white on a pale background.
        alpha = logo(300, 52/108, mono=True).crop((50,50,250,250)).getchannel('A')
        tint = Image.new('RGBA', (200,200), '#28594D')
        tint.putalpha(alpha)
        icon = Image.new('RGBA', (200,200), bg)
        icon.alpha_composite(tint)
    mask = Image.new('L', (200,200))
    ImageDraw.Draw(mask).rounded_rectangle((0,0,199,199), radius=radius, fill=255)
    sheet.paste(icon.convert('RGB'), (x,y), mask)
    draw.text((x, y+220), name, fill=NAVY, font=font)
draw.rounded_rectangle((40, 440, 1160, 650), radius=24, fill='#101722')
draw.text((64, 461), 'Actual small sizes / dark surface', fill='white', font=font)
for i, size in enumerate([16,24,32,48,64]):
    x = 74 + i*120
    small = logo(size, .78, NAVY, True)
    sheet.paste(small, (x,525), small)
    draw.text((x,605), str(size), fill='#BBC9D5', font=font)
sheet.paste(logo(96,.90), (880,510), logo(96,.90))
draw.text((854,605), 'Transparent logo', fill='#BBC9D5', font=font)
save(sheet, BRAND / 'preview.png')

# Verify packaging invariants, including every declared iOS size and ICO frame.
for entry in entries:
    im = Image.open(catalog / entry['filename'])
    expected = round(float(entry['size'].split('x')[0])*int(entry['scale'][0]))
    assert im.size == (expected,expected) and im.mode == 'RGB', entry
assert Image.open(ico_path).ico.sizes() == {(s,s) for s in ico_sizes}
for density, scale in [('mdpi',1),('hdpi',1.5),('xhdpi',2),('xxhdpi',3),('xxxhdpi',4)]:
    im = Image.open(RES / f'drawable-{density}/ic_launcher_foreground.png')
    x0,y0,x1,y1 = im.getchannel('A').getbbox()
    assert x0 >= 21*scale and y0 >= 21*scale and x1 <= 87*scale and y1 <= 87*scale
print(f'Exported and verified Android layers, {len(ico_sizes)} ICO sizes and {len(entries)} iOS catalog entries.')


