"""Descarga el paquete de idioma + paquetes OnDemand de un idioma para la build 19041 (x64).

- Los NOMBRES de archivo salen de las listas de W10MUI (tools/W10MUI/Langs y OnDemand, sección x64).
- Las URLs y SHA-1 salen de UNA llamada a la API de uupdump (api.uupdump.net/get.php),
  que devuelve enlaces directos al CDN de Microsoft. Cada archivo se verifica con su SHA-1.

Uso:  python tools/get-langpack.py es-MX <carpeta_destino>
Crea <destino>/Langs/*.esd y <destino>/OnDemand/x64/*.cab (estructura que espera W10MUI).
"""
import hashlib
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

BUILD = "19041"
UPDATE_ID = "700d530c-2c64-4f15-a27f-ba5bb0677911"   # 19041.572 amd64 (mismo ID que usan las listas de W10MUI)
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
HERE = Path(__file__).resolve().parent / "W10MUI"


def names_for(lang, listfile):
    """Nombres de archivo del bloque x64 de la lista de W10MUI para ese idioma."""
    text = listfile.read_text(encoding="utf-8", errors="replace")
    x64 = text.split("x86 (32 Bit)")[0]
    out, inside = [], False
    for line in x64.splitlines():
        s = line.strip()
        if re.fullmatch(r"[a-z]{2,3}(-[A-Za-z]{2,4})?(-[A-Z]{2})?", s):
            inside = s.lower() == lang.lower()
            continue
        if inside and "file=" in s:
            out.append(s.split("file=")[1].lower())
    return out


def api_files(cache):
    if cache.exists() and time.time() - cache.stat().st_mtime < 6 * 3600:   # los enlaces caducan
        return json.loads(cache.read_text())
    for i in range(5):
        req = urllib.request.Request(f"https://api.uupdump.net/get.php?id={UPDATE_ID}", headers=UA)
        r = json.loads(urllib.request.urlopen(req, timeout=120).read())["response"]
        if "files" in r:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps(r["files"]))
            return r["files"]
        print(f"  API: {r.get('error')} -> reintento en {30 * (i + 1)}s", flush=True)
        time.sleep(30 * (i + 1))
    raise SystemExit("La API de uupdump no respondió con la lista de archivos.")


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, dest, expected):
    part = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=300) as r, open(part, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        done, last = 0, -25
        while chunk := r.read(1 << 20):
            f.write(chunk)
            done += len(chunk)
            if total > 5 * 2**20 and done * 100 // total >= last + 25:
                last = done * 100 // total
                print(f"     [{last:3d}%] {done / 2**20:.1f}/{total / 2**20:.1f} MiB", flush=True)
    if sha1(part) != expected.lower():
        part.unlink()
        raise SystemExit(f"SHA-1 no coincide: {dest.name}")
    part.replace(dest)


def main():
    lang, dest = sys.argv[1], Path(sys.argv[2])
    lp = names_for(lang, HERE / "Langs" / f"{BUILD}-LPs.txt")
    od = names_for(lang, HERE / "OnDemand" / f"{BUILD}-OnDemand.txt")
    if not lp:
        raise SystemExit(f"No encontré el paquete de idioma {lang} para {BUILD}")
    files = {k.lower(): v for k, v in api_files(dest / "uupdump-files.json").items()}
    jobs = [(n, dest / "Langs") for n in lp] + [(n, dest / "OnDemand" / "x64") for n in od]
    for k, (name, folder) in enumerate(jobs, 1):
        print(f"[{(k - 1) * 100 // len(jobs):3d}%] {k}/{len(jobs)} {name}", flush=True)
        if name not in files:
            raise SystemExit(f"  no está en la API: {name}")
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / name
        if target.exists() and sha1(target) == files[name]["sha1"].lower():
            print("     ya existe (SHA-1 ok)")
            continue
        fetch(files[name]["url"], target, files[name]["sha1"])
    print(f"[100%] {len(jobs)} archivos verificados (SHA-1) en {dest}")


if __name__ == "__main__":
    main()
