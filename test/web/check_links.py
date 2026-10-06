"""홈페이지(web/) 링크 검사 — 내부 링크·앵커·이미지, 그리고 다운로드 버튼이 가리키는 릴리스 파일.

    python3 test/web/check_links.py [web_dir] [--no-network]
"""
import glob
import os
import re
import sys
import urllib.request

web = next((a for a in sys.argv[1:] if not a.startswith("--")), "web")
network = "--no-network" not in sys.argv

pages = sorted(glob.glob(f"{web}/index.html") + glob.glob(f"{web}/*/index.html"))
ids = {p: set(re.findall(r'id="([^"]+)"', open(p, encoding="utf-8").read())) for p in pages}


def page_for(path):
    return f"{web}/index.html" if path == "/" else f"{web}{path}index.html"


def exists(href):
    p = href.split("#")[0].split("?")[0]
    return any(os.path.exists(f"{web}{c}") for c in (p, p + "index.html", p.rstrip("/")))


broken, downloads = [], set()
for p in pages:
    s = open(p, encoding="utf-8").read()
    for href in re.findall(r'href="([^"]+)"', s):
        if href.startswith("#") and len(href) > 1 and href[1:] not in ids[p]:
            broken.append((p, href, "missing anchor"))
        m = re.match(r"^(/[a-z0-9-]*/?)#(.+)$", href)
        if m:
            target = page_for(m.group(1) if m.group(1).endswith("/") else m.group(1) + "/")
            if target in ids and m.group(2) not in ids[target]:
                broken.append((p, href, "missing anchor on target page"))
        if href.startswith("/") and not href.startswith("//") and not exists(href):
            broken.append((p, href, "missing page/file"))
        if "/releases/latest/download/" in href:
            downloads.add(href)
    for src in re.findall(r'src="(/[^"]+)"', s):
        if not exists(src):
            broken.append((p, src, "missing image/script"))

if network:
    for url in sorted(downloads):
        try:
            req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "dureclaw-ci"})
            code = urllib.request.urlopen(req, timeout=20).status
        except Exception as e:  # noqa: BLE001
            code = getattr(e, "code", str(e))
        print(f"download {code}  {url}")
        if code != 200:
            broken.append(("<release>", url, f"download returned {code}"))

print(f"checked {len(pages)} pages, {len(downloads)} download links")
for b in broken:
    print("BROKEN:", *b)
sys.exit(1 if broken else 0)
