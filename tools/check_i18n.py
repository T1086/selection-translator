"""Check the UI language files against the source code.

Usage:  python tools/check_i18n.py

Reports (exit code 1 if anything is wrong):
  - keys used in the code (T("key") / "key" lists) that are missing from a language file
  - keys that exist in one language file but not in the other
  - keys defined but never used
  - placeholders ({1}, {2}, ...) that differ between languages
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANG_DIR = ROOT / "lang"
LANGS = ["zh", "en"]
KEY_RE = r"[a-z][a-z0-9_]*(?:\.[A-Za-z0-9_]+)+"


def load(path):
    out = {}
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        ln = raw.lstrip()
        if not ln or ln[0] in ";[" or "=" not in ln:
            continue
        k, v = ln.split("=", 1)
        k = k.strip()
        if k in out:
            print(f"duplicate key in {path.name}: {k}")
            sys.exit(1)
        out[k] = v
    return out


def dynamic_prefixes():
    """Prefixes of keys built at run time, e.g. Tr("model.rt." . id)."""
    out = set()
    for p in ROOT.glob("*.ahk"):
        if p.name.startswith("SelfCheck"):
            continue
        out.update(re.findall(r'\bTr\("(' + KEY_RE + r'\.)"\s*\.', p.read_text(encoding="utf-8-sig")))
    return out


def used_keys():
    keys = set()
    for p in ROOT.glob("*.ahk"):
        if p.name.startswith("SelfCheck"):
            continue
        text = p.read_text(encoding="utf-8-sig")
        keys.update(re.findall(r'\bTr\("(' + KEY_RE + r')"', text))
        # keys kept in tables / conditionals: "lang.zh", T(cond ? "a.b" : "c.d")
        keys.update(re.findall(r'"(' + KEY_RE + r')"', text))
    return keys


def main():
    data = {lang: load(LANG_DIR / f"{lang}.ini") for lang in LANGS}
    code = used_keys()
    problems = 0
    for lang, d in data.items():
        # only treat quoted dotted strings that look like our keys (known prefix) as keys
        prefixes = {k.split(".")[0] for k in d}
        need = {k for k in code if k.split(".")[0] in prefixes}
        for k in sorted(need - set(d)):
            print(f"[{lang}] missing: {k}")
            problems += 1
    base = set(data[LANGS[0]])
    for lang in LANGS[1:]:
        other = set(data[lang])
        for k in sorted(base - other):
            print(f"[{lang}] missing (present in {LANGS[0]}): {k}")
            problems += 1
        for k in sorted(other - base):
            print(f"[{LANGS[0]}] missing (present in {lang}): {k}")
            problems += 1
    prefixes = {k.split(".")[0] for k in base}
    dyn = dynamic_prefixes()
    for k in sorted(base):
        if k not in code and not any(k.startswith(d) for d in dyn):
            print(f"unused: {k}")
    ph = lambda s: sorted(set(re.findall(r"\{\d+\}", s)))
    for k in sorted(base & set(data[LANGS[1]])):
        if ph(data["zh"][k]) != ph(data["en"][k]):
            print(f"placeholder mismatch: {k}  zh={ph(data['zh'][k])} en={ph(data['en'][k])}")
            problems += 1
    print("OK" if not problems else f"{problems} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
