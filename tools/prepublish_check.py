"""Checks the repository before it is published. Prints FAIL / WARN lines; exit code 1 if anything failed.

    python tools/prepublish_check.py
"""
import json
import pathlib
import re
import subprocess
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
FORBIDDEN = re.compile(r'(^|/)(config\.ini|secret[^/]*\.txt|bookmarks\.json[^/]*|TODO\.md|e2e\.ahk|SelfCheck[^/]*|[^/]*\.log|[^/]*\.gguf|[^/]*\.exe)$|^(llama|models|downloads|build|dist)/')
PERSONAL = [r'C:\\Users\\', r'Documents_1']
REQUIRED = ['LICENSE', 'THIRD_PARTY_NOTICES.txt', 'README.md', 'README.zh-CN.md', 'manifest.json', 'config.example.ini',
            'LICENSES/ECDICT-MIT.txt', 'LICENSES/Hy-MT2-Apache-2.0.txt', 'LICENSES/LLVM-OpenMP.txt', 'LICENSES/llama.cpp-MIT.txt']
fails, warns = [], []


def git(*args):
    return subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True, encoding='utf-8', errors='replace').stdout


def tracked():
    return [f for f in git('ls-files', '--cached', '--others', '--exclude-standard').splitlines() if (ROOT / f).is_file()]


def read(f):
    try:
        return (ROOT / f).read_text(encoding='utf-8')
    except UnicodeDecodeError:
        return None


def main():
    files = tracked()
    for f in REQUIRED:
        if f not in files:
            fails.append(f'required file not tracked: {f}')
    for f in files:
        if FORBIDDEN.search(f):
            fails.append(f'must not be published: {f}')

    secrets = []
    for name in ('secret.txt', 'secret_microsoft.txt'):
        p = ROOT / name
        if p.is_file():
            v = p.read_text(encoding='utf-8', errors='replace').strip()
            if len(v) >= 10:
                secrets.append(v)
    email = git('config', 'user.email').strip()
    for f in files:
        text = read(f)
        if text is None:
            continue
        if any(s in text for s in secrets):
            fails.append(f'an API key appears in {f}')
        for pat in PERSONAL:
            if f != 'tools/prepublish_check.py' and re.search(pat, text):
                fails.append(f'personal path in {f}')
                break
        if email and f != 'LICENSE' and email in text:
            warns.append(f'your git e-mail appears in {f}')

    # Local links and images in the READMEs
    for f in ('README.md', 'README.zh-CN.md'):
        for link in re.findall(r'\]\(([^)\s#]+)', read(f)):
            if not re.match(r'[a-z]+:', link) and not (ROOT / link).exists():
                fails.append(f'{f}: broken link {link}')

    # Every download in the manifest is pinned and comes over HTTPS
    def walk(x):
        if isinstance(x, dict):
            url = x.get('url')
            if isinstance(url, str) and 'size' in x:      # a download, not a link to a license page
                if not url.startswith('https://'):
                    fails.append(f'manifest: not HTTPS: {url}')
                if not re.fullmatch(r'[0-9a-fA-F]{64}', str(x.get('sha256', ''))):
                    fails.append(f'manifest: no SHA-256 for {url}')
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk(json.loads(read('manifest.json')))

    r = subprocess.run([sys.executable, str(ROOT / 'tools' / 'check_i18n.py')], capture_output=True, text=True, encoding='utf-8', errors='replace')
    if r.returncode != 0:
        fails.append('check_i18n.py failed: ' + r.stdout.strip()[-200:])

    if git('status', '--porcelain').strip():
        warns.append('working tree has uncommitted changes')
    name = git('config', 'user.name').strip()
    if name.lower() in ('', 'user'):
        warns.append(f'git user.name is "{name}"; set the name to publish under before the first public commit')

    zips = sorted((ROOT / 'dist').glob('*.zip'))
    if not zips:
        warns.append('no release zip in dist/; run tools/build_release.py')
    else:
        with zipfile.ZipFile(zips[-1]) as z:
            names = z.namelist()
        for n in names:
            inner = n.split('/', 1)[-1]
            if FORBIDDEN.search(inner) and inner != 'Translator.exe':
                fails.append(f'{zips[-1].name} contains {inner}')
        newest = max((ROOT / f).stat().st_mtime for f in files if f.endswith(('.ahk', '.ini', '.json')))
        if zips[-1].stat().st_mtime < newest:
            warns.append('the release zip is older than the source; rebuild it')

    for w in dict.fromkeys(warns):
        print('WARN ', w)
    for f in dict.fromkeys(fails):
        print('FAIL ', f)
    print(f'{len(files)} files checked: {len(set(fails))} failed, {len(set(warns))} warnings')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
