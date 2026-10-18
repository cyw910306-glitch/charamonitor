#!/usr/bin/env python3
"""Mac App Store screenshots (2880x1800, 16:10), 4 per language, from the MAS build's QA renders.

Renders (sandboxed, so the output must sit in the container; docs/appstore/xcode-archive.md 1):
    scripts/build_mas.sh --debug
    A=build.noindex/mas/CharaMonitor.app/Contents/MacOS/CharaMonitor
    C=~/Library/Containers/com.jelly.charamonitor.mas/Data/tmp
    for l in ko en; do
      QA_ONLY=picker $A --render-dashboard $C/shots-$l -AppleLanguages "($l)"
      QA_ONLY=pages  $A --render-dashboard $C/shots-$l -AppleLanguages "($l)"
    done
    $A --render-sprites $C/shots-sprites
Then: python3 tools/appstore/shots.py $C   (writes docs/appstore/screenshots/{ko,en}/0N-*.png)

Only MAS renders go in (no cleaner or security tiles). The picker shot is the 동물 tab.
"""
import sys
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

W, H = 2880, 1800
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/appstore/screenshots"
SD = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
SF = "/System/Library/Fonts/SFNS.ttf"

# (file, background top-left, bottom-right, ko headline, ko sub, en headline, en sub). Copy follows metadata.md.
SHOTS = [
    ("01-menubar", "#FFF5EC", "#F9DFCB",
     "맥이 바쁘면\n캐릭터가 뛰어요", "CPU·메모리·배터리를\n메뉴바에서 한눈에",
     "Your Mac's mood,\nin your menu bar", "CPU, memory and battery\nat a glance."),
    ("02-characters", "#EFF8F2", "#D5EEDF",
     "강아지, 고양이,\n오리지널 캐릭터", "귀·꼬리·털 색까지\n직접 꾸며요",
     "Dogs, cats\nand originals", "Customize ears, tail\nand coat colors."),
    ("03-pet-room", "#FFF9E8", "#F7E7C1",
     "방을 꾸미고\n함께 성장해요", "밥 주고, 쓰다듬고,\n미션으로 코인을 모아요",
     "Decorate its room\nand grow together", "Feed it, pet it, and earn\ncoins with daily missions."),
    ("04-assistant", "#F0F5FF", "#D9E5FB",
     "“지금 왜 느려?”\n물어보세요", "앱이 잰 실제 숫자로\n캐릭터가 답해요",
     "Ask why your\nMac is slow", "Your character answers with\nthe real numbers the app measured."),
]
CLOCK = {"ko": "10월 9일 (목)  오전 9:41", "en": "Thu Oct 9  9:41 AM"}


def font(lang, size, bold):
    if lang == "ko":
        return ImageFont.truetype(SD, size, index=6 if bold else 2)
    f = ImageFont.truetype(SF, size)
    f.set_variation_by_axes([100, 28 if size < 60 else 96, 400, 700 if bold else 400])
    return f


def hexrgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def gradient(a, b):
    a, b = hexrgb(a), hexrgb(b)
    small = Image.new("RGB", (64, 40))
    px = small.load()
    for y in range(40):
        for x in range(64):
            t = (x / 63 + y / 39) / 2
            px[x, y] = tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))
    return small.resize((W, H), Image.BICUBIC)


def sprite(sprites):
    """The 젤리 sprint frame from sheet-jelly.png (row 5, first cell), its flat cell background made transparent."""
    cell = Image.open(sprites / "sheet-jelly.png").convert("RGB").crop((12, 872, 284, 1032))
    alpha = ImageChops.difference(cell, Image.new("RGB", cell.size, cell.getpixel((2, 2)))).convert("L").point(lambda v: 255 if v else 0)
    cell.putalpha(alpha)
    return cell.crop(alpha.getbbox())


def rounded(panel, radius):
    mask = Image.new("L", panel.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, panel.width - 1, panel.height - 1), radius, fill=255)
    panel = panel.convert("RGBA")
    panel.putalpha(mask)
    return panel


def chat_panel(src):
    """AI 비서: the header and the first question with its answer (number chips + 활성 상태 보기 button), then the
    input bar. The rest of the sample chat shows the cleaner and 문자, which the App Store build does not have."""
    im = Image.open(src).convert("RGB")
    px = im.load()
    blue = [y for y in range(250, im.height) if any(px[x, y][2] > 200 and px[x, y][0] < 40 for x in range(700, 770))]
    second = next(y for a, y in zip(blue, blue[1:]) if y - a > 40)   # top of the second question bubble
    top = im.crop((0, 0, im.width, second - 14))
    # A chip cut by the row's right edge (Korean labels are longer): paint it out. On the chips' top line only the
    # rounded corners are dark, left and right in turns, so an odd count means the last chip has no right end.
    g = top.convert("L").load()
    y = next(y for y in range(300, top.height) if g[30, y] < 240 and g[40, y] >= 240)
    corners, x = [], 0
    while x < top.width:
        if g[x, y] < 240:
            corners.append(x)
            while x < top.width and g[x, y] < 240:
                x += 1
        x += 1
    if len(corners) % 2:
        ImageDraw.Draw(top).rectangle((corners[-1] - 8, y - 8, top.width, y + 32), fill=top.getpixel((top.width - 4, y + 12)))
    bar = im.crop((0, im.height - 84, im.width, im.height))
    out = Image.new("RGB", (im.width, top.height + bar.height), top.getpixel((5, 5)))
    out.paste(top, (0, 0))
    out.paste(bar, (0, top.height))
    return out


def panels(d):
    picker = Image.open(d / "picker-dog-light.png").convert("RGB")
    g = picker.convert("L").load()
    # Cut above the row of cards the popover's scroll clips at the bottom.
    white = [all(g[x, y] > 245 for x in range(30, 770)) for y in range(picker.height)]
    # The lowest white gap with cards above and below it (the cards below are the clipped row).
    gaps = [y for y in range(900, picker.height - 13) if all(white[y:y + 12]) and not white[y - 1] and not all(white[y + 12:])]
    cut = gaps[-1] + 14
    return [
        (Image.open(d / "dashboard-light.png").convert("RGB"), 36),
        (picker.crop((0, 0, picker.width, cut)), 36),
        (Image.open(d / "pet-missions-light.png").convert("RGB"), 36),
        (chat_panel(d / "assistant-chat-light.png"), 36),
    ]


def compose(lang, idx, panel, radius, run):
    name, c0, c1 = SHOTS[idx][:3]
    head, sub = SHOTS[idx][3:5] if lang == "ko" else SHOTS[idx][5:7]
    canvas = gradient(c0, c1).convert("RGBA")

    # Menu bar: translucent strip, the character, the clock.
    bar_h = 74
    canvas.alpha_composite(Image.new("RGBA", (W, bar_h), (255, 255, 255, 150)))
    canvas.alpha_composite(Image.new("RGBA", (W, 2), (0, 0, 0, 18)), (0, bar_h))
    d = ImageDraw.Draw(canvas)
    clock = font(lang, 34, False)
    cw = d.textlength(CLOCK[lang], font=clock)
    d.text((W - 60 - cw, bar_h / 2), CLOCK[lang], font=clock, fill="#1d1d1f", anchor="lm")

    # The popover, under the character and centred below the menu bar: scaled at most 1.25x so the text stays sharp.
    scale = min(1.25, 1560 / panel.height)
    p = panel.resize((round(panel.width * scale), round(panel.height * scale)), Image.LANCZOS)
    p = rounded(p, round(radius * scale))
    px0, py0 = W - 300 - p.width, bar_h + max(34, (H - bar_h - p.height) // 2)
    shadow = Image.new("RGBA", (p.width + 240, p.height + 240), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 46), (120, 120), p.getchannel("A"))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(44)), (px0 - 120, py0 - 120 + 26))
    edge = Image.new("RGBA", p.size, (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle((0, 0, p.width - 1, p.height - 1), round(radius * scale), outline=(0, 0, 0, 28), width=2)
    canvas.alpha_composite(p, (px0, py0))
    canvas.alpha_composite(edge, (px0, py0))

    dog = run.resize((round(run.width * 54 / run.height), 54), Image.NEAREST)
    canvas.alpha_composite(dog, (px0 + p.width // 2 - dog.width // 2, (bar_h - 54) // 2))

    # Headline and one supporting line, left column, centred on the canvas below the menu bar.
    d = ImageDraw.Draw(canvas)
    hf, sf = font(lang, 132 if lang == "ko" else 128, True), font(lang, 56, False)
    hb = d.multiline_textbbox((0, 0), head, font=hf, spacing=34)
    sb = d.multiline_textbbox((0, 0), sub, font=sf, spacing=22)
    block = hb[3] + 64 + sb[3]
    y = bar_h + (H - bar_h - block) // 2
    x = 240
    assert x + max(hb[2], sb[2]) < px0 - 120, f"{lang}/{name}: text runs into the panel"
    d.multiline_text((x, y), head, font=hf, fill="#1d1d1f", spacing=34)
    d.multiline_text((x, y + hb[3] + 64), sub, font=sf, fill="#6e6e73", spacing=22)

    out = OUT / lang / f"{name}.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(out, optimize=True)
    return out


def main():
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "~/Library/Containers/com.jelly.charamonitor.mas/Data/tmp").expanduser()
    run = sprite(src / "shots-sprites")
    for lang in ("ko", "en"):
        for i, (panel, radius) in enumerate(panels(src / f"shots-{lang}")):
            out = compose(lang, i, panel, radius, run)
            assert Image.open(out).size == (W, H)
            print(out.relative_to(ROOT))


if __name__ == "__main__":
    main()
