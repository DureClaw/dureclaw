"""여러 화면 폭(모바일~대형)에서 페이지마다 가로 넘침이 없는지 측정한다.

    python3 test/web/mobile_overflow.py http://localhost:8799
"""
import sys

from playwright.sync_api import sync_playwright

base = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://localhost:8799"
paths = ["/", "/start/", "/how/", "/showcase/", "/developers/", "/changelog/"]
WIDTHS = [390, 768, 1024, 1440, 1920]

bad = []
with sync_playwright() as p:
    browser = p.chromium.launch()
    for path in paths:
      for WIDTH in WIDTHS:
        page = browser.new_page(viewport={"width": WIDTH, "height": 900})
        page.goto(base + path, wait_until="networkidle")
        page.wait_for_timeout(400)
        sw = page.evaluate("document.documentElement.scrollWidth")
        offenders = page.evaluate(
            """(w) => [...document.querySelectorAll('body *')]
                 .filter(e => e.getBoundingClientRect().right > w + 1 && !e.closest('.nav-links'))
                 .slice(0, 5)
                 .map(e => e.tagName.toLowerCase() + (e.className ? '.' + String(e.className).split(' ')[0] : ''))""",
            WIDTH,
        )
        print(f"{path:14} {WIDTH:>5}px  scrollWidth={sw}")
        if sw > WIDTH:
            bad.append((path, WIDTH, sw, offenders))
        page.close()
    browser.close()

for path, width, sw, off in bad:
    print(f"OVERFLOW {path}: {sw}px > {width}px  ({', '.join(off)})")
sys.exit(1 if bad else 0)
