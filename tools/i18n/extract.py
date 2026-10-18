#!/usr/bin/env python3
"""Collects every user-facing Korean string the app looks up, for the English Localizable.strings.

The Swift compiler does the finding: built with -emit-localized-strings it writes, per source file, each
literal that becomes a LocalizedStringKey (Text, Button, Label, Toggle, .help, ...) or a
String.LocalizationValue (our L("...") helper), with the exact key it looks up at run time
(`\\(n)개` -> `%lld개`, a String -> `%@`, a Double -> `%lf`, a literal % -> `%%`).
Both the plain build and the Mac App Store build (-D MAS) are read, since #if MAS hides some strings.

Usage (from the repo root):
  python3 tools/i18n/extract.py           # build twice (incremental, a few seconds), write strings.json + chunk-1..3.json
  python3 tools/i18n/extract.py --todo    # also list Korean literals the compiler did not see as localizable
Outputs in tools/i18n/: strings.json [{key, file, line}] (one entry per key, its first place in the source)
and chunk-1.json .. chunk-3.json, the same list cut in three for translators (who return chunk-N.en.json).
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "tools" / "i18n"
HANGUL = re.compile(r"[가-힣]")
CHUNKS = 3
BUILDS = [("i18n", []), ("i18n-mas", ["-Xswiftc", "-DMAS"])]
# --todo ignores these: terminal tools and QA renders for development, and the facts and prompts we send
# to the AI (the offline chat matches those Korean words too) stay Korean. So do terminal print lines.
TODO_SKIP = {"main.swift", "MetricsCLI.swift", "AssistantCLI.swift", "AssistantPrompt.swift", "PetQA.swift",
             "AssistantQA.swift", "SpritePreview.swift", "RealSpritePreview.swift", "DashboardSnapshot.swift",
             "SystemSnapshotText.swift"}
CLI_LINE = re.compile(r"\b(print|fputs)\(")


def build(name, extra):
    # The compiler writes the lists only for files it compiles, so each run builds from a fresh scratch folder
    # (about ten seconds in debug, no package dependencies), apart from the app's own .build.
    strings = ROOT / ".build" / f"{name}-strings"
    for old in (strings, ROOT / ".build" / name):
        shutil.rmtree(old, ignore_errors=True)
    strings.mkdir(parents=True)
    cmd = ["swift", "build", "--target", "DogMonitor", "--package-path", str(ROOT),
           "--scratch-path", str(ROOT / ".build" / name), *extra,
           "-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", str(strings)]
    print(f"==> swift build ({name})", file=sys.stderr)
    done = subprocess.run(cmd, capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(done.stdout[-3000:] + done.stderr[-3000:])
    return strings


def read_stringsdata(folder):
    """[(key, file, line, column)] for every Localizable entry the compiler wrote."""
    out = []
    for path in sorted(folder.glob("*.stringsdata")):
        data = json.loads(path.read_text())
        src = Path(data["source"])
        if not src.exists():  # a source file deleted since its last build
            continue
        rel = src.resolve().relative_to(ROOT).as_posix()
        for table, entries in data["tables"].items():
            if table != "Localizable":
                continue
            for e in entries:
                loc = e.get("location", {})
                out.append((e["key"], rel, loc.get("startingLine", 0), loc.get("startingColumn", 0)))
    return out


def literals(text):
    """Every string literal in Swift source: (line, utf8 column of the opening quote, literal text with each
    interpolation as \\x00, start index, end index). Skips comments, follows \\( ... ) into nested literals,
    handles \"\"\" and #"..."#."""
    found = []
    i, n, line, line_start = 0, len(text), 1, 0

    def col(pos):
        return len(text[line_start:pos].encode("utf-8")) + 1

    def newline(pos):
        nonlocal line, line_start
        line += 1
        line_start = pos + 1

    def code(i, depth_stop):
        """Scans code from i; with depth_stop returns at the ) that closes an interpolation."""
        depth = 0
        while i < n:
            c = text[i]
            if c == "\n":
                newline(i)
                i += 1
            elif text.startswith("//", i):
                while i < n and text[i] != "\n":
                    i += 1
            elif text.startswith("/*", i):
                nest = 0
                while i < n:
                    if text.startswith("/*", i):
                        nest += 1
                        i += 2
                    elif text.startswith("*/", i):
                        nest -= 1
                        i += 2
                        if nest == 0:
                            break
                    else:
                        if text[i] == "\n":
                            newline(i)
                        i += 1
            elif c == '"' or (c == "#" and re.match(r'#+"', text[i:i + 8])):
                i = string(i)
            elif c == "(":
                depth += 1
                i += 1
            elif c == ")":
                if depth_stop and depth == 0:
                    return i + 1
                depth -= 1
                i += 1
            else:
                i += 1
        return i

    def string(i):
        start, start_line, start_col = i, line, col(i)
        hashes = 0
        while text[i] == "#":
            hashes += 1
            i += 1
        multi = text.startswith('"""', i)
        i += 3 if multi else 1
        close = ('"""' if multi else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        parts = []
        while i < n:
            if text.startswith(close, i):
                i += len(close)
                break
            if text.startswith(escape, i):
                j = i + len(escape)
                if j < n and text[j] == "(":
                    parts.append("\x00")  # an interpolation
                    i = code(j + 1, True)
                    continue
                parts.append(text[i:j + 1])
                i = j + 1
                continue
            if text[i] == "\n":
                newline(i)
            parts.append(text[i])
            i += 1
        found.append((start_line, start_col, "".join(parts), start, i))
        return i

    code(0, False)
    return found


def todo(seen):
    """Korean literals the compiler did not report: candidates for L("...") (or deliberate plain strings)."""
    total = 0
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        if path.name in TODO_SKIP:
            continue
        rel = path.relative_to(ROOT).as_posix()
        lines = path.read_text().split("\n")
        rows = [(ln, c, s) for ln, c, s, _, _ in literals(path.read_text())
                if HANGUL.search(s) and (rel, ln, c) not in seen and not CLI_LINE.search(lines[ln - 1])]
        for ln, c, s in rows:
            print(f"{rel}:{ln}:{c}: {s[:90]!r}")
        total += len(rows)
    print(f"plain Korean literals: {total}", file=sys.stderr)


def main():
    entries = []
    for name, extra in BUILDS:
        entries += read_stringsdata(build(name, extra))
    seen = {(f, ln, c) for _, f, ln, c in entries}
    first = {}
    for key, f, ln, _ in sorted(entries, key=lambda e: (e[1], e[2], e[3])):
        if HANGUL.search(key) and key not in first:
            first[key] = {"key": key, "file": f, "line": ln}
    rows = sorted(first.values(), key=lambda r: (r["file"], r["line"], r["key"]))
    (OUT / "strings.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1) + "\n")
    size = -(-len(rows) // CHUNKS)
    for k in range(CHUNKS):
        part = rows[k * size:(k + 1) * size]
        (OUT / f"chunk-{k + 1}.json").write_text(json.dumps(part, ensure_ascii=False, indent=1) + "\n")
        print(f"chunk-{k + 1}.json: {len(part)}")
    print(f"strings.json: {len(rows)} keys")
    if "--todo" in sys.argv:
        todo(seen)


if __name__ == "__main__":
    main()
