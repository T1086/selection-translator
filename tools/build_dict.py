"""
Converts ECDICT's ecdict.csv into an offline dictionary that Translator.ahk can binary-search directly.

Usage:
    python tools/build_dict.py <path to ecdict.csv>

Data source: https://github.com/skywind3000/ECDICT (ecdict.csv, MIT license)
Output (written to the project's dict/ directory):
    ecdict.dat  one entry per line: key \t word \t phonetic \t translation \t exchange
                key = lowercase headword; the file is sorted by key's code points; multiple lines within translation are separated by a literal \n
    ecdict.idx  one little-endian uint32 (4 bytes) per entry, recording the byte offset of each line in ecdict.dat, in order
The AHK side binary-searches via idx and reads only ~20 lines per query, so the dictionary never needs to be loaded into memory.
"""
import csv
import os
import re
import struct
import sys

# Normalizes ECDICT part-of-speech abbreviations to common English forms (a. is an old style, mapped to adj.)
POS_MAP = {
    "a": "adj", "adj": "adj", "ad": "adv", "adv": "adv",
    "n": "n", "v": "v", "vt": "vt", "vi": "vi",
    "prep": "prep", "conj": "conj", "pron": "pron",
    "int": "int", "interj": "int", "num": "num", "art": "art",
    "abbr": "abbr", "aux": "aux", "pl": "pl", "pref": "pref", "suf": "suf",
    "det": "det", "un": "un", "na": "na",
}
POS_RE = re.compile(r"^\s*([A-Za-z]+)\.\s*")
MAX_TRANSLATION = 4000   # AHK File.ReadLine has a per-line limit; longer translations are truncated


def norm_line(line):
    line = line.strip()
    m = POS_RE.match(line)
    if m and m.group(1).lower() in POS_MAP:
        return POS_MAP[m.group(1).lower()] + ". " + line[m.end():].strip()
    return line


def norm_phonetic(p):
    # ECDICT marks primary stress with ' and secondary stress with ,; convert these to IPA stress marks
    return p.replace("'", "ˈ").replace(",", "ˌ").strip()


def clean(s):
    return s.replace("\t", " ").replace("\r", "").replace("\n", " ").strip()


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dict")
    os.makedirs(out_dir, exist_ok=True)

    entries = []
    with open(src, encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            word = clean(r["word"])
            trans = r["translation"]
            if not word or not trans:
                continue
            # Non-BMP characters sort differently in UTF-16 (AHK) than by code point, so they are skipped (very few)
            if any(ord(ch) > 0xFFFF for ch in word):
                continue
            lines = [norm_line(clean(x)) for x in trans.split("\\n")]
            trans = "\\n".join(x for x in lines if x)[:MAX_TRANSLATION]
            if not trans:
                continue
            key = word.lower()
            entries.append((key, word, norm_phonetic(clean(r["phonetic"])), trans, clean(r["exchange"])))

    entries.sort(key=lambda e: (e[0], e[1]))

    dat_path = os.path.join(out_dir, "ecdict.dat")
    idx_path = os.path.join(out_dir, "ecdict.idx")
    with open(dat_path, "wb") as dat, open(idx_path, "wb") as idx:
        for e in entries:
            idx.write(struct.pack("<I", dat.tell()))
            dat.write(("\t".join(e) + "\n").encode("utf-8"))
    print(f"{len(entries)} entries -> {dat_path}, {idx_path}")


if __name__ == "__main__":
    main()
