#!/usr/bin/env python3
"""Erzeugt App-Icons (Android, iOS, Web) und die Statusleisten-Icons.

App-Logo: Stoppuhr (MDI „timer-outline“) mit Schraubenschlüssel (MDI „wrench“),
Material Design Icons, Apache License 2.0 – https://pictogrammers.com
Hintergrund: Akzentfarbe der App (Seed-Farbe in lib/main.dart).

Voraussetzung: ImageMagick 7 (`magick`). Aufruf aus dem Projektverzeichnis:
    python3 scripts/generate_icons.py
"""

import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ACCENT = '#00796B'

TIMER = ('M12,20A7,7 0 0,1 5,13A7,7 0 0,1 12,6A7,7 0 0,1 19,13A7,7 0 0,1 12,20'
         'M19.03,7.39L20.45,5.97C20,5.46 19.55,5 19.04,4.56L17.62,6C16.07,4.74 '
         '14.12,4 12,4A9,9 0 0,0 3,13A9,9 0 0,0 12,22C17,22 21,17.97 21,13C21,'
         '10.88 20.26,8.93 19.03,7.39M11,14H13V8H11M15,1H9V3H15V1Z')
WRENCH = ('M22.7,19L13.6,9.9C14.5,7.6 14,4.9 12.1,3C10.1,1 7.1,0.6 4.7,1.7L9,6'
          'L6,9L1.6,4.7C0.4,7.1 0.9,10.1 2.9,12.1C4.8,14 7.5,14.5 9.8,13.6L18.9,'
          '22.7C19.3,23.1 19.9,23.1 20.3,22.7L22.6,20.4C23.1,20 23.1,19.3 22.7,19Z')
WRENCH_SCALE = 0.55
WRENCH_TRANSFORM = f'translate(24,10) scale(-{WRENCH_SCALE},{WRENCH_SCALE})'
# Rahmen um den Schraubenschlüssel in Akzentfarbe (Aussparung), so breit wie
# der Ring der Stoppuhr (Radius 9 außen, 7 innen = 2 Einheiten).
RING_WIDTH = 2


# Stoppuhr mit Pause-Balken (MDI „timer-pause-outline“)
TIMER_PAUSE = ('M21 13.35C20.36 13.13 19.7 13 19 13C19 9.13 15.87 6 12 6S5 9.13 '
               '5 13 8.13 20 12 20C12.37 20 12.72 19.96 13.08 19.91C13.18 20.6 '
               '13.4 21.25 13.71 21.83C13.16 21.94 12.59 22 12 22C7.03 22 3 '
               '17.97 3 13S7.03 4 12 4C14.12 4 16.07 4.74 17.62 6L19.04 4.56C'
               '19.55 5 20 5.46 20.45 5.97L19.03 7.39C20.26 8.93 21 10.88 21 13'
               'C21 13.12 21 13.23 21 13.35M11 14H13V8H11V14M15 1H9V3H15V1M19.63 '
               '16.5V21.5H21.5V16.5H19.63M16.5 21.5H18.38V16.5H16.5V21.5Z')


def magick(*args):
    subprocess.run(['magick', *args], check=True)


def svg(path_attrs):
    return ("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' "
            f"width='2048' height='2048'>{path_attrs}</svg>")


def render_glyph(tmp):
    """Weißes Logo auf transparentem Grund, 2048 px."""
    parts = {
        'timer': f"<path fill='#fff' d='{TIMER}'/>",
        'wrench': f"<path fill='#fff' transform='{WRENCH_TRANSFORM}' d='{WRENCH}'/>",
    }
    for name, body in parts.items():
        with open(os.path.join(tmp, f'{name}.svg'), 'w') as f:
            f.write(svg(body))
        magick('-background', 'none', os.path.join(tmp, f'{name}.svg'),
               '-resize', '2048x2048', os.path.join(tmp, f'{name}.png'))
    # Aussparung = Schraubenschlüssel um RING_WIDTH erweitert (Distanz-
    # Transformation; ImageMagicks SVG-Renderer ignoriert dicke Konturen).
    gap_px = RING_WIDTH * 2048 / 24
    magick(os.path.join(tmp, 'wrench.png'), '-alpha', 'extract', '-negate',
           '-morphology', 'Distance:-1', 'Euclidean:4,1',
           '-threshold', f'{gap_px:.0f}', '-negate',
           '-background', '#fff', '-alpha', 'shape', os.path.join(tmp, 'gap.png'))
    glyph = os.path.join(tmp, 'glyph.png')
    magick(os.path.join(tmp, 'timer.png'), os.path.join(tmp, 'gap.png'),
           '-compose', 'DstOut', '-composite',
           os.path.join(tmp, 'wrench.png'), '-compose', 'Over', '-composite',
           glyph)
    return glyph


def icon(glyph, out, size, scale, background=ACCENT, shape='square'):
    """Logo zentriert mit Anteil [scale] an der Kantenlänge."""
    os.makedirs(os.path.dirname(out), exist_ok=True)
    inner = max(1, round(size * scale))
    big = size * 4
    if background is None:
        magick('-size', f'{size}x{size}', 'xc:none', '(', glyph, '-resize',
               f'{inner}x{inner}', ')', '-gravity', 'center', '-composite', out)
        return
    if shape == 'circle':
        base = ['-size', f'{big}x{big}', 'xc:none', '-fill', background,
                '-draw', f'circle {big / 2},{big / 2} {big / 2},{big * 0.02}']
    elif shape == 'rounded':
        r = big * 0.18
        base = ['-size', f'{big}x{big}', 'xc:none', '-fill', background,
                '-draw', f'roundrectangle {big * 0.04},{big * 0.04} '
                         f'{big * 0.96},{big * 0.96} {r},{r}']
    else:
        base = ['-size', f'{big}x{big}', f'xc:{background}']
    magick(*base, '(', glyph, '-resize', f'{inner * 4}x{inner * 4}', ')',
           '-gravity', 'center', '-composite', '-resize', f'{size}x{size}',
           *(['-alpha', 'off'] if shape == 'square' else []), out)


def android(glyph):
    res = os.path.join(ROOT, 'android/app/src/main/res')
    densities = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
    for d, f in densities.items():
        # Legacy-Icon (48 dp) für Android < 8
        icon(glyph, f'{res}/mipmap-{d}/ic_launcher.png', round(48 * f), 0.6,
             shape='rounded')
        icon(glyph, f'{res}/mipmap-{d}/ic_launcher_round.png', round(48 * f),
             0.58, shape='circle')
        # Adaptive Icon: Vordergrund 108 dp, sichtbarer Bereich ~66 dp
        icon(glyph, f'{res}/mipmap-{d}/ic_launcher_foreground.png',
             round(108 * f), 0.5, background=None)
    os.makedirs(f'{res}/mipmap-anydpi-v26', exist_ok=True)
    adaptive = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
'''
    for name in ('ic_launcher', 'ic_launcher_round'):
        with open(f'{res}/mipmap-anydpi-v26/{name}.xml', 'w') as f:
            f.write(adaptive)


def ios(glyph):
    d = os.path.join(ROOT, 'ios/Runner/Assets.xcassets/AppIcon.appiconset')
    for name in os.listdir(d):
        if not name.endswith('.png'):
            continue
        # z. B. Icon-App-83.5x83.5@2x.png
        spec = name[len('Icon-App-'):-len('.png')]
        pt, mult = spec.split('@')
        size = round(float(pt.split('x')[0]) * int(mult.rstrip('x')))
        icon(glyph, os.path.join(d, name), size, 0.62)


def web(glyph):
    d = os.path.join(ROOT, 'web')
    icon(glyph, f'{d}/favicon.png', 32, 0.74, shape='rounded')
    for s in (192, 512):
        icon(glyph, f'{d}/icons/Icon-{s}.png', s, 0.6, shape='rounded')
        icon(glyph, f'{d}/icons/Icon-maskable-{s}.png', s, 0.5)


# --- Statusleisten-Icons (Vector Drawables, weiß) ---------------------------

# Flüssige Drehung: ~30 Bilder/s, 2,67° pro Bild. 33 ms entsprechen genau
# 2 Bildwechseln bei 60 Hz bzw. 4 bei 120 Hz, dadurch gleichmäßige Schritte.
FRAMES = 135
FRAME_MS = 33        # eine Umdrehung ≈ 4,5 s

CLOCK = '''    <path
        android:strokeColor="#FFFFFFFF"
        android:strokeWidth="1.8"
        android:pathData="M12,6.6a5.4,5.4 0,1 1,0 10.8a5.4,5.4 0,1 1,0 -10.8z"/>
    <path
        android:strokeColor="#FFFFFFFF"
        android:strokeWidth="1.6"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:pathData="M12,9.2V12L14,13.4"/>
'''

ARROW = '''    <group
        android:pivotX="12"
        android:pivotY="12"
        android:rotation="{rot}">
        <path
            android:strokeColor="#FFFFFFFF"
            android:strokeWidth="1.9"
            android:strokeLineCap="round"
            android:pathData="M12,2.6A9.4,9.4 0,1 1,2.6 12"/>
        <path
            android:fillColor="#FFFFFFFF"
            android:pathData="M2.6,8.6L5.1,12.9L0.1,12.9Z"/>
    </group>
'''


def vector(body):
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<!-- Generiert von scripts/generate_icons.py -->\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            '    android:width="24dp"\n    android:height="24dp"\n'
            '    android:viewportWidth="24"\n    android:viewportHeight="24">\n'
            f'{body}</vector>\n')


def status_icons():
    d = os.path.join(ROOT, 'android/app/src/main/res/drawable')
    os.makedirs(d, exist_ok=True)
    for name in os.listdir(d):
        if name.startswith('ic_stat_running_'):
            os.remove(os.path.join(d, name))
    items = []
    for i in range(FRAMES):
        rot = round(i * 360 / FRAMES, 3)
        with open(f'{d}/ic_stat_running_{i:03d}.xml', 'w') as f:
            f.write(vector(CLOCK + ARROW.format(rot=f'{rot:g}')))
        items.append(f'    <item android:drawable="@drawable/ic_stat_running_{i:03d}" '
                     f'android:duration="{FRAME_MS}"/>')
    with open(f'{d}/ic_stat_running.xml', 'w') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<!-- Generiert von scripts/generate_icons.py: der äußere Pfeil '
                'dreht sich langsam um die Uhr -->\n'
                '<animation-list xmlns:android="http://schemas.android.com/apk/res/android"\n'
                '    android:oneshot="false">\n' + '\n'.join(items) +
                '\n</animation-list>\n')
    with open(f'{d}/ic_stat_paused.xml', 'w') as f:
        f.write(vector('    <path\n        android:fillColor="#FFFFFFFF"\n'
                       f'        android:pathData="{TIMER_PAUSE}"/>\n'))


def main():
    with tempfile.TemporaryDirectory() as tmp:
        glyph = render_glyph(tmp)
        android(glyph)
        ios(glyph)
        web(glyph)
    status_icons()


if __name__ == '__main__':
    main()
