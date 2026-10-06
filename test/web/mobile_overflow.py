"""모바일 폭(390px)에서 페이지마다 가로 넘침이 없는지 측정한다.

    python3 test/web/mobile_overflow.py http://localhost:8799
"""
import sys

from playwright.sync_api import sync_playwright

base = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://localhost:8799"
paths = ["/", "/start/", "/how/", "/showcase/", "/developers/", "/changelog/"]
WIDTH = 390

bad = []
with sync_playwright() as p:
    browser = p.chromium.launch()
    for path in paths:
        page = browser.new_page(viewport={"width": WIDTH, "height": 844})
        page.goto(base + path, wait_until="load")
        page.wait_for_timeout(500)
        sw = page.evaluate("document.documentElement.scrollWidth")
        offenders = page.evaluate(
            """(w) => [...document.querySelectorAll('body *')]
                 .filter(e => e.getBoundingClientRect().right > w + 1 && !e.closest('.nav-links'))
                 .slice(0, 5)
                 .map(e => e.tagName.toLowerCase() + (e.className ? '.' + String(e.className).split(' ')[0] : ''))""",
            WIDTH,
        )
        print(f"{path:14} scrollWidth={sw}")
        if sw > WIDTH:
            bad.append((path, sw, offenders))
        page.close()
    browser.close()

for path, sw, off in bad:
    print(f"OVERFLOW {path}: {sw}px > {WIDTH}px  ({', '.join(off)})")
sys.exit(1 if bad else 0)
