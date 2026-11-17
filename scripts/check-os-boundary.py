#!/usr/bin/env python3
"""Mechanical checks for the OS boundary (native layer) of ziggurats.

This is the regression net for the audit in `docs/architecture/os-boundary-audit.md`.
It is deliberately a *static* checker: every rule below caught a real defect that the
existing test graph could not see because `zig build test` compiles each module in its
own target.

Rules
-----
1. module-ownership   — a file reachable from two public `b.addModule(...)` roots. Zig
                        rejects this at compile time ("file exists in modules ...") the
                        moment a consumer imports both modules, so the library must not
                        ship such a pair.
2. unused-declared-import — a module declares an import it never `@import`s. A stale
                        import table hides the real dependency graph.
3. native-wiring      — `DesktopRuntime` must install the native menu/tray/dialog/
                        clipboard backends (or the audit must list the gap as debt).
4. silent-noop        — every `WindowExtrasSnapshot` field must be read by each native
                        backend's `applyWindowExtras` (Mock is exempt: it records the
                        whole snapshot).
5. dead-public-fn     — `pub fn` in a native backend that no other code references.
                        `setDarkMode()` was implemented, tested by nothing and called by
                        nothing for months; this rule makes that visible.

Known debt is recorded in `tests/ci/os-boundary-baseline.txt` as `rule|path|detail`
lines. The checker fails only on findings that are *not* in the baseline, so existing
debt is visible without blocking every unrelated PR. Delete a baseline line when the
debt is fixed; adding one requires a matching entry in the audit document.

Usage:
    python3 scripts/check-os-boundary.py
    python3 scripts/check-os-boundary.py --self-test
    python3 scripts/check-os-boundary.py --strict   # stale baseline lines fail too
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join("tests", "native", "baseline.txt")

# Directories that are build-time-only or standalone executables, not public modules.
ORPHAN_EXEMPT_PREFIXES = (
    "src/build_tools/",
    "src/docsite/",
    "src/cli/",
    "src/bundler/",
)

# `@import("...")` where the path ends in `.zig` is a file edge. Module names are not.
IMPORT_SUFFIX = ".zig"

MODULE_RE = re.compile(r'b\.addModule\(\s*"([^"]+)"\s*,')
ROOT_RE = re.compile(r'\.root_source_file\s*=\s*b\.path\(\s*"([^"]+)"\s*\)')
IMPORT_NAME_RE = re.compile(r'\.name\s*=\s*"([^"]+)"\s*,\s*\.module\s*=')
PUB_FN_RE = re.compile(r'^\s*pub fn ([A-Za-z_][A-Za-z0-9_]*)\s*\(', re.M)


# ---------------------------------------------------------------------------
# Zig lexer helpers
# ---------------------------------------------------------------------------

def extract_imports(text: str) -> list[str]:
    """Return only the strings passed to `@import(...)` in *code*.

    Comments, single-line strings and Zig multiline strings (`\\\\`) are skipped, so the
    code fences embedded in `src/docsite/apidoc.zig` cannot create phantom edges.
    """
    out: list[str] = []
    i = 0
    n = len(text)
    at_line_start = True
    while i < n:
        c = text[i]
        if c == "\n":
            at_line_start = True
            i += 1
            continue
        if at_line_start and c in " \t\r":
            i += 1
            continue
        if at_line_start and c == "\\" and i + 1 < n and text[i + 1] == "\\":
            # Zig multiline string content: the rest of the line is data.
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue
        at_line_start = False

        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue
        if c in ('"', "'"):
            quote = c
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if text.startswith("@import", i):
            j = i + len("@import")
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] == "(":
                j += 1
                while j < n and text[j] in " \t\r\n":
                    j += 1
                if j < n and text[j] == '"':
                    j += 1
                    buf: list[str] = []
                    while j < n:
                        ch = text[j]
                        if ch == "\\" and j + 1 < n:
                            buf.append(text[j + 1])
                            j += 2
                            continue
                        if ch == '"':
                            j += 1
                            break
                        buf.append(ch)
                        j += 1
                    out.append("".join(buf))
                    i = j
                    continue
        i += 1
    return out


def sanitize(text: str) -> str:
    """Blank comments/strings while preserving offsets (used for brace matching)."""
    chars = list(text)
    i = 0
    n = len(text)
    at_line_start = True
    while i < n:
        c = text[i]
        if c == "\n":
            at_line_start = True
            i += 1
            continue
        if at_line_start and c in " \t\r":
            i += 1
            continue
        if at_line_start and c == "\\" and i + 1 < n and text[i + 1] == "\\":
            j = text.find("\n", i)
            end = n if j == -1 else j
            for k in range(i, end):
                if chars[k] != "\n":
                    chars[k] = " "
            i = end
            continue
        at_line_start = False
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            end = n if j == -1 else j
            for k in range(i, end):
                chars[k] = " "
            i = end
            continue
        if c in ('"', "'"):
            quote = c
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == quote:
                    j += 1
                    break
                j += 1
            for k in range(i, min(j, n)):
                if chars[k] != "\n":
                    chars[k] = " "
            i = j
            continue
        i += 1
    return "".join(chars)


def brace_block(text: str, open_index: int) -> tuple[int, int] | None:
    """Return (start, end) of the `{...}` block at/after `open_index`."""
    clean = sanitize(text)
    start = clean.find("{", open_index)
    if start < 0:
        return None
    depth = 0
    for i in range(start, len(clean)):
        if clean[i] == "{":
            depth += 1
        elif clean[i] == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1
    return None


def read_text(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


# ---------------------------------------------------------------------------
# build.zig parsing
# ---------------------------------------------------------------------------

def public_modules(build_text: str) -> dict[str, str]:
    """name -> repo-relative root source file for every `b.addModule(...)`."""
    modules: dict[str, str] = {}
    for match in MODULE_RE.finditer(build_text):
        name = match.group(1)
        block = brace_block(build_text, match.end())
        if block is None:
            continue
        body = build_text[block[0]:block[1]]
        root_match = ROOT_RE.search(body)
        if root_match:
            modules[name] = os.path.normpath(root_match.group(1))
    return modules


def declared_imports(build_text: str) -> dict[str, set[str]]:
    """name -> import names listed in the module's `.imports = &.{...}` table."""
    out: dict[str, set[str]] = {}
    for match in MODULE_RE.finditer(build_text):
        name = match.group(1)
        block = brace_block(build_text, match.end())
        if block is None:
            continue
        body = build_text[block[0]:block[1]]
        imports_match = re.search(r'\.imports\s*=\s*&\.\{', body)
        if not imports_match:
            continue
        imports_block = brace_block(body, imports_match.start())
        if imports_block is None:
            continue
        out[name] = set(IMPORT_NAME_RE.findall(body[imports_block[0]:imports_block[1]]))
    return out


# ---------------------------------------------------------------------------
# Ownership graph
# ---------------------------------------------------------------------------

def resolve_file_import(importer: str, imported: str) -> str | None:
    if not imported.endswith(IMPORT_SUFFIX):
        return None
    candidate = os.path.normpath(os.path.join(os.path.dirname(importer), imported))
    if candidate.startswith(".."):
        return None
    return candidate


def owned_files(root: str) -> set[str]:
    seen: set[str] = set()
    stack = [os.path.normpath(root)]
    while stack:
        path = stack.pop()
        if path in seen:
            continue
        full = os.path.join(REPO_ROOT, path)
        if not os.path.isfile(full):
            continue
        seen.add(path)
        for imported in extract_imports(read_text(full)):
            edge = resolve_file_import(path, imported)
            if edge is not None:
                stack.append(edge)
    return seen


def module_ownership_findings() -> list[tuple[str, str, str]]:
    build_text = read_text(os.path.join(REPO_ROOT, "build.zig"))
    modules = public_modules(build_text)
    findings: list[tuple[str, str, str]] = []

    owners: dict[str, set[str]] = {}
    for name, root in modules.items():
        if not os.path.isfile(os.path.join(REPO_ROOT, root)):
            findings.append(("module-root-missing", root, name))
            continue
        for path in owned_files(root):
            owners.setdefault(path, set()).add(name)

    for path, names in sorted(owners.items()):
        if len(names) > 1:
            findings.append(("module-ownership", path, "modules " + ", ".join(sorted(names))))

    # Every src/**/*.zig that is not build-time-only must belong to one public module.
    for dirpath, _dirnames, filenames in os.walk(os.path.join(REPO_ROOT, "src")):
        for filename in filenames:
            if not filename.endswith(".zig"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, filename), REPO_ROOT).replace(os.sep, "/")
            if rel.startswith(ORPHAN_EXEMPT_PREFIXES):
                continue
            if rel not in owners:
                findings.append(("module-orphan", rel, "not reachable from any public module"))
    return findings


def declared_import_findings() -> list[tuple[str, str, str]]:
    build_text = read_text(os.path.join(REPO_ROOT, "build.zig"))
    modules = public_modules(build_text)
    declared = declared_imports(build_text)
    findings: list[tuple[str, str, str]] = []
    for name, imports in sorted(declared.items()):
        root = modules.get(name)
        if root is None:
            continue
        used: set[str] = set()
        for path in owned_files(root):
            used.update(extract_imports(read_text(os.path.join(REPO_ROOT, path))))
        for import_name in sorted(imports):
            if import_name not in used:
                findings.append((
                    "unused-declared-import",
                    root,
                    f"module '{name}' declares '{import_name}' but never imports it",
                ))
    return findings


# ---------------------------------------------------------------------------
# Runtime wiring / no-op / dead code
# ---------------------------------------------------------------------------

def token_findings() -> list[tuple[str, str, str]]:
    findings: list[tuple[str, str, str]] = []

    # The wiring lives in the optional `zts_runtime_native` package, not in `z_ts`. If someone
    # deletes a step from the bridge, every native plugin silently falls back to its stub.
    wrapper_path = "src/runtime_native/mod.zig"
    if not os.path.isfile(os.path.join(REPO_ROOT, wrapper_path)):
        findings.append(("native-wiring", wrapper_path, "optional native runtime bridge is missing"))
    else:
        wrapper = read_text(os.path.join(REPO_ROOT, wrapper_path))
        required = {
            "withMenuBackend": "native menu backend is never installed",
            "withTrayBackend": "native tray backend is never installed",
            "dialogBackend": "native dialog backend is never installed",
            "clipboardBackend": "native clipboard backend is never installed",
            "setWindowObserver": "window lifecycle is not observed",
            "registerMenuWindow": "windows are never registered with the menu backend",
            "unregisterMenuWindow": "menu registrations are never released",
        }
        for token, detail in required.items():
            if token not in wrapper:
                findings.append(("native-wiring", wrapper_path, detail))

    # `z_ts` must stay native-free: the bridge is a separate package.
    for path in ("src/app_runtime.zig", "src/root.zig"):
        body = read_text(os.path.join(REPO_ROOT, path))
        if "zts_tauri_native" in body or '@import("zts_runtime_native")' in body:
            findings.append(("umbrella-purity", path, "z_ts must not import the native bridge"))

    # The bridge is only usable if the runtime exposes the observer seam.
    runtime = read_text(os.path.join(REPO_ROOT, "src", "app_runtime.zig"))
    for token in ("WindowObserver", "setWindowObserver", "window_observer.onOpen", "window_observer.onClose"):
        if token not in runtime:
            findings.append(("native-wiring", "src/app_runtime.zig", f"missing {token}"))
    return findings


def extra_fields() -> list[str]:
    path = os.path.join(REPO_ROOT, "src", "core", "window_extras.zig")
    text = read_text(path)
    match = re.search(r"pub const WindowExtrasSnapshot\s*=\s*(?:extern\s+)?struct\s*\{", text)
    if not match:
        return []
    block = brace_block(text, match.start())
    if block is None:
        return []
    body = text[block[0]:block[1]]
    fields = re.findall(r"^\s{4}([a-z_][a-z0-9_]*)\s*:", body, re.M)
    return fields


def apply_extras_body(path: str) -> str:
    text = read_text(os.path.join(REPO_ROOT, path))
    match = re.search(r"pub fn applyWindowExtras\s*\(", text)
    if not match:
        return ""
    brace = text.find("{", match.end())
    if brace < 0:
        return ""
    block = brace_block(text, brace)
    return "" if block is None else text[block[0]:block[1]]


# Fields that are bookkeeping, not OS requests: `centered` / `devtools_open` record what the
# command layer did and have no backend setter of their own.
NOOP_EXEMPT = {"centered", "devtools_open"}


def noop_findings() -> list[tuple[str, str, str]]:
    fields = [f for f in extra_fields() if f not in NOOP_EXEMPT]
    findings: list[tuple[str, str, str]] = []
    for backend in ("src/webview/linux.zig", "src/webview/macos.zig", "src/webview/windows.zig"):
        body = apply_extras_body(backend)
        if not body:
            findings.append(("silent-noop", backend, "no applyWindowExtras implementation"))
            continue
        for field in fields:
            if not re.search(r"\b" + re.escape(field) + r"\b", body):
                findings.append(("silent-noop", backend, f"field '{field}' is never read"))
    return findings


PUB_FN_SCAN = (
    "src/webview/linux.zig",
    "src/webview/macos.zig",
    "src/webview/windows.zig",
    "src/tauri/dialog/native_gtk.zig",
    "src/tauri/dialog/native_macos.zig",
    "src/tauri/dialog/native_windows.zig",
    "src/tauri/clipboard/native_gtk.zig",
    "src/tauri/clipboard/native_macos.zig",
    "src/tauri/clipboard/native_windows.zig",
    "src/tauri/menu/native_gtk.zig",
    "src/tauri/menu/native_macos.zig",
    "src/tauri/menu/native_windows.zig",
    "src/tauri/tray/native_gtk.zig",
    "src/tauri/tray/native_macos.zig",
    "src/tauri/tray/native_windows.zig",
)


def all_sources() -> dict[str, str]:
    out: dict[str, str] = {}
    for top in ("src", "tests", "examples"):
        for dirpath, _dirnames, filenames in os.walk(os.path.join(REPO_ROOT, top)):
            for filename in filenames:
                if not filename.endswith(".zig"):
                    continue
                full = os.path.join(dirpath, filename)
                rel = os.path.relpath(full, REPO_ROOT).replace(os.sep, "/")
                out[rel] = read_text(full)
    return out


def dead_public_fn_findings(sources: dict[str, str]) -> list[tuple[str, str, str]]:
    findings: list[tuple[str, str, str]] = []
    for rel in PUB_FN_SCAN:
        if rel not in sources:
            continue
        for name in PUB_FN_RE.findall(sources[rel]):
            occurrences = 0
            pattern = re.compile(r"\b" + re.escape(name) + r"\b")
            for text in sources.values():
                occurrences += len(pattern.findall(text))
            if occurrences <= 1:
                findings.append(("dead-public-fn", rel, f"pub fn {name}() is never referenced"))
    return findings


# ---------------------------------------------------------------------------
# Baseline / reporting
# ---------------------------------------------------------------------------

def load_baseline() -> set[str]:
    path = os.path.join(REPO_ROOT, BASELINE)
    if not os.path.isfile(path):
        return set()
    out: set[str] = set()
    for line in read_text(path).splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.add(line)
    return out


def key(rule: str, path: str, detail: str) -> str:
    return f"{rule}|{path}|{detail}"


def report(findings: list[tuple[str, str, str]], strict: bool) -> int:
    baseline = load_baseline()
    new_errors: list[str] = []
    seen_keys: set[str] = set()
    for rule, path, detail in sorted(set(findings)):
        k = key(rule, path, detail)
        seen_keys.add(k)
        if k in baseline:
            print(f"KNOWN {k}")
        else:
            new_errors.append(k)
            print(f"ERR   {k}")
    stale = sorted(baseline - seen_keys)
    for k in stale:
        print(f"WARN  stale-baseline {k}")
    if new_errors:
        print(f"ERR os-boundary new={len(new_errors)} known={len(baseline)}")
        return 1
    if strict and stale:
        print(f"ERR os-boundary stale-baseline={len(stale)} (run with --strict to fail)")
        return 1
    print(f"OK os-boundary findings={len(findings)} known={len(baseline)}")
    return 0


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

SELF_TEST_BUILD = """
const std = @import("std");
pub fn build(b: *std.Build) void {
    const a = b.addModule("zts_a", .{
        .root_source_file = b.path("mods/a/root.zig"),
    });
    const bmod = b.addModule("zts_b", .{
        .root_source_file = b.path("mods/b/root.zig"),
    });
    _ = a;
    _ = bmod;
}
"""

SELF_TEST_FILES = {
    "mods/a/root.zig": 'const shared = @import("../shared.zig");\n// @import("commented.zig")\nconst s = "@import(\\"string.zig\\")";\n',
    "mods/b/root.zig": 'const shared = @import("../shared.zig");\n',
    "mods/shared.zig": "pub const x = 1;\n",
    "mods/commented.zig": "",
    "mods/string.zig": "",
}


def self_test() -> int:
    # Lexer: comments and strings must not become edges.
    sample = SELF_TEST_FILES["mods/a/root.zig"]
    imports = extract_imports(sample)
    if imports != ["../shared.zig"]:
        print(f"ERR self-test extract_imports = {imports!r}")
        return 1

    # Ownership: two roots reaching the same file is an error.
    tmp = tempfile.mkdtemp(prefix="zts-os-boundary-")
    try:
        for rel, body in SELF_TEST_FILES.items():
            full = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as fh:
                fh.write(body)
        with open(os.path.join(tmp, "build.zig"), "w", encoding="utf-8") as fh:
            fh.write(SELF_TEST_BUILD)

        global REPO_ROOT
        old_root = REPO_ROOT
        REPO_ROOT = tmp
        try:
            findings = module_ownership_findings()
        finally:
            REPO_ROOT = old_root
        keys = {key(*f) for f in findings}
        if not any("module-ownership|mods/shared.zig" in k for k in keys):
            print(f"ERR self-test ownership findings = {sorted(keys)!r}")
            return 1
        if any("commented.zig" in k or "string.zig" in k for k in keys):
            print(f"ERR self-test phantom import in comments/strings: {sorted(keys)!r}")
            return 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("OK os-boundary self-test cases=2")
    return 0


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--strict", action="store_true", help="fail on stale baseline entries")
    parser.add_argument(
        "--write-baseline",
        action="store_true",
        help="record every current finding as known debt (review the diff before committing)",
    )
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    findings: list[tuple[str, str, str]] = []
    findings += module_ownership_findings()
    findings += declared_import_findings()
    findings += token_findings()
    findings += noop_findings()
    findings += dead_public_fn_findings(all_sources())

    if args.write_baseline:
        path = os.path.join(REPO_ROOT, BASELINE)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        lines = [
            "# Known OS-boundary debt. One finding per line: rule|path|detail.",
            "# Delete a line when the debt is fixed; adding one requires an entry in",
            "# docs/architecture/os-boundary-audit.md.",
        ]
        lines += [key(*f) for f in sorted(set(findings))]
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        print(f"OK os-boundary baseline written findings={len(set(findings))} -> {BASELINE}")
        return 0

    return report(findings, args.strict)


if __name__ == "__main__":
    sys.exit(main())
