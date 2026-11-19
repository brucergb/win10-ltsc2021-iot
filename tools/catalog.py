"""Consulta mínima del Microsoft Update Catalog (sin dependencias).

Uso:
  python tools/catalog.py search "texto"          -> id | título | clasificación | tamaño
  python tools/catalog.py links <id> [<id> ...]    -> URLs de descarga directa
  python tools/catalog.py get <id> <carpeta>       -> descarga los archivos de esa update
"""
import html
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "https://www.catalog.update.microsoft.com"
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}


def _fetch(url, data=None):
    req = urllib.request.Request(url, data=data, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8", "replace")


def search(query):
    page = _fetch(f"{BASE}/Search.aspx?q={urllib.parse.quote(query)}")
    rows = re.findall(r'<tr id="([0-9a-f-]{36})_R\d+".*?</tr>', page, re.S)
    out = []
    for uid in dict.fromkeys(rows):
        block = re.search(rf'<tr id="{uid}_R\d+".*?</tr>', page, re.S).group(0)
        cells = [html.unescape(re.sub(r"<[^>]+>", " ", c)).split() for c in
                 re.findall(r"<td[^>]*>(.*?)</td>", block, re.S)]
        cells = [" ".join(c) for c in cells]
        # columnas: [vacía, título, productos, clasificación, fecha, versión, tamaño, botón]
        out.append({"id": uid, "title": cells[1], "products": cells[2],
                    "class": cells[3], "date": cells[4], "size": cells[6]})
    return out


def links(uid):
    payload = json.dumps([{"size": 0, "languages": "", "uidInfo": uid, "updateID": uid}])
    data = urllib.parse.urlencode({"updateIDs": payload}).encode()
    page = _fetch(f"{BASE}/DownloadDialog.aspx", data)
    return re.findall(r"\.url\s*=\s*'([^']+)'", page)


def main():
    cmd, *args = sys.argv[1:]
    if cmd == "search":
        for r in search(" ".join(args)):
            print(f"{r['id']} | {r['title']} | {r['class']} | {r['date']} | {r['size']}")
    elif cmd == "links":
        for uid in args:
            for u in links(uid):
                print(u)
    elif cmd == "get":
        uid, dest = args
        Path(dest).mkdir(parents=True, exist_ok=True)
        for u in links(uid):
            name = Path(urllib.parse.urlparse(u).path).name
            target = Path(dest) / name
            if target.exists():
                print(f"ya existe: {target}")
                continue
            print(f"descargando {name} ...", flush=True)
            last = [-5]

            def hook(blocks, bsize, total):
                if total <= 0:
                    return
                pct = min(100, blocks * bsize * 100 // total)
                if pct >= last[0] + 5:  # un print cada 5 %
                    last[0] = pct
                    print(f"  [{pct:3d}%] {blocks * bsize / 2**20:.0f}/{total / 2**20:.0f} MiB", flush=True)

            tmp = target.with_suffix(target.suffix + ".part")
            urllib.request.urlretrieve(u, tmp, hook)
            tmp.replace(target)
            print(f"  ok ({target.stat().st_size / 2**20:.1f} MiB)")


if __name__ == "__main__":
    main()
