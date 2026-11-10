"""Builds the release zip: compiles Translator.ahk and packs it with the files it needs at run time.

    python tools/build_release.py [version]        (default version: 0.1.0)

Needs build/ahk2exe/Ahk2Exe.exe (https://github.com/AutoHotkey/Ahk2Exe/releases) and an installed
AutoHotkey v2. Files are taken from an explicit list, so personal files (config.ini, secret*.txt,
bookmarks.json) and the engines and models can never end up in the zip.
"""
import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
AHK2EXE = ROOT / 'build' / 'ahk2exe' / 'Ahk2Exe.exe'
BASE = pathlib.Path(os.environ.get('LOCALAPPDATA', '')) / 'Programs' / 'AutoHotkey' / 'v2' / 'AutoHotkey64.exe'
DIST = ROOT / 'dist'
NAME = 'SelectionTranslator'
EXE = 'Translator.exe'

FILES = [
    'LICENSE',
    'THIRD_PARTY_NOTICES.txt',
    'README.md',
    'README.zh-CN.md',
    'manifest.json',
    'config.example.ini',
    'lang/zh.ini',
    'lang/en.ini',
    'dict/ecdict.dat',
    'dict/ecdict.idx',
    'LICENSES/ECDICT-MIT.txt',
    'LICENSES/Hy-MT2-Apache-2.0.txt',
    'LICENSES/LLVM-OpenMP.txt',
    'LICENSES/llama.cpp-MIT.txt',
]
FILES += [f'docs/img/{n}_{lang}.{ext}' for lang in ('zh', 'en') for n, ext in (
    ('demo', 'gif'), ('word', 'png'), ('sentence', 'png'), ('input', 'png'), ('models', 'png'))]


def fail(msg):
    sys.exit('build failed: ' + msg)


def main():
    version = sys.argv[1] if len(sys.argv) > 1 else '0.1.0'
    if not AHK2EXE.exists():
        fail(f'{AHK2EXE} not found; download Ahk2Exe into build/ahk2exe first')
    if not BASE.exists():
        fail(f'{BASE} not found; install AutoHotkey v2')
    missing = [f for f in FILES if not (ROOT / f).is_file()]
    if missing:
        fail('missing files: ' + ', '.join(missing))
    subprocess.run([sys.executable, str(ROOT / 'tools' / 'check_i18n.py')], check=True)

    folder = DIST / NAME
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    exe = folder / EXE
    # Ahk2Exe reports through its exit code and a console message when /silent is given
    r = subprocess.run([str(AHK2EXE), '/in', str(ROOT / 'Translator.ahk'), '/out', str(exe), '/base', str(BASE), '/silent', 'verbose'],
                       capture_output=True, text=True, errors='replace')
    print((r.stdout + r.stderr).strip())
    if r.returncode != 0 or not exe.is_file():
        fail('Ahk2Exe could not compile Translator.ahk')

    for f in FILES:
        dst = folder / f
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / f, dst)

    zip_path = DIST / f'{NAME}-v{version}-win64.zip'
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p in sorted(folder.rglob('*')):
            if p.is_file():
                z.write(p, pathlib.Path(NAME) / p.relative_to(folder))

    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
    for f in ['LICENSE', 'THIRD_PARTY_NOTICES.txt', 'LICENSES/Hy-MT2-Apache-2.0.txt', EXE]:
        if f'{NAME}/{f}' not in names:
            fail(f'{f} is not in the zip')
    bad = [n for n in names if any(x in n.lower() for x in ('secret', 'bookmarks.json', 'config.ini', '.gguf', 'llama-server'))
           and not n.endswith('config.example.ini')]
    if bad:
        fail('personal or third-party files in the zip: ' + ', '.join(bad))

    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    print(f'{zip_path}\n{zip_path.stat().st_size / 1048576:.1f} MB, {len(names)} files\nSHA-256 {digest}')


if __name__ == '__main__':
    main()
