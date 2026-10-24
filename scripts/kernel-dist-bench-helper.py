#!/usr/bin/env python3
"""Helper for kernel-dist-bench.sh: Kbuild cmd parsing, stats parsing, timeline.

Subcommands:
  timeline <tree>                       phase table from file mtimes
  build-cmd <tree> <tu> <outdir> <tag>  NUL-separated argv for one TU
  stats                                 parse `sccache --show-stats` on stdin
  self-test                             offline checks, prints "checks: N/N run"
"""
import os
import re
import shlex
import sys
import time

PIN_FROM = "-march=native"
PIN_TO = "-march=znver4"


def pin_march(argv):
    """Replace -march=native with -march=znver4; return (argv, count)."""
    out, n = [], 0
    for a in argv:
        if PIN_FROM in a:
            n += a.count(PIN_FROM)
            a = a.replace(PIN_FROM, PIN_TO)
        out.append(a)
    return out, n


def savedcmd_argv(cmd_text, d, b):
    """argv of the savedcmd line for <d>/<b>.o in a .cmd file's text."""
    prefix = f"savedcmd_{d}/{b}.o := "
    for line in cmd_text.splitlines():
        if line.startswith(prefix):
            return shlex.split(line[len(prefix):])
    raise ValueError(f"no line starting {prefix!r}")


def rewrite_outputs(argv, obj, dep):
    """Point -o and -Wp,-MMD,<path> at obj and dep."""
    out = list(argv)
    if "-o" not in out:
        raise ValueError("no -o argument")
    out[out.index("-o") + 1] = obj
    hit = False
    for i, a in enumerate(out):
        if a.startswith("-Wp,-MMD,"):
            out[i] = "-Wp,-MMD," + dep
            hit = True
    if not hit:
        raise ValueError("no -Wp,-MMD argument")
    return out


def build_cmd(tree, tu, outdir, tag):
    d, f = os.path.split(tu)
    b = f[:-2] if f.endswith(".c") else os.path.splitext(f)[0]
    cmdfile = os.path.join(tree, d, f".{b}.o.cmd")
    with open(cmdfile, encoding="utf-8", errors="replace") as fh:
        argv = savedcmd_argv(fh.read(), d, b)
    argv, n = pin_march(argv)
    print(f"{PIN_FROM} -> {PIN_TO}: {n} replacement(s) in {tu}", file=sys.stderr)
    argv[0] = "/usr/bin/clang"
    return rewrite_outputs(argv, os.path.join(outdir, f"{b}.{tag}.o"),
                           os.path.join(outdir, f"{b}.{tag}.d"))


STAT_RE = re.compile(r"^(Successful|Failed) distributed compiles\s+(\d+)\s*$", re.M)
EXEC_RE = re.compile(r"^Compile requests executed\s+(\d+)\s*$", re.M)


def parse_stats(text):
    """Return dict ok/failed distributed compiles and executed requests (0 if absent)."""
    r = {"ok": 0, "failed": 0, "executed": 0}
    for kind, val in STAT_RE.findall(text):
        r["ok" if kind == "Successful" else "failed"] = int(val)
    m = EXEC_RE.search(text)
    if m:
        r["executed"] = int(m.group(1))
    return r


def phases(objs, vmlinux_a, vmlinux_o, mod_o, ko):
    """Phase rows (name, start, end, count) from {path-less} mtime lists."""
    comp = sorted(t for t in objs if t <= vmlinux_a)
    mod_o = sorted(mod_o)
    ko = sorted(ko)
    return [
        ("compile", comp[0], comp[-1], len(comp)),
        ("vmlinux_lto", vmlinux_a, vmlinux_o, 1),
        ("modpost_kallsyms_btf", vmlinux_o, mod_o[0], 1),
        ("module_stubs", mod_o[0], mod_o[-1], len(mod_o)),
        ("module_link", mod_o[-1], ko[-1], len(ko)),
    ]


def fmt_time(t):
    return time.strftime("%H:%M:%S", time.localtime(t))


def format_rows(rows):
    return [f"{n}\t{fmt_time(s)}\t{fmt_time(e)}\t{round(e - s)}\t{c}" for n, s, e, c in rows]


def timeline(tree):
    objs, mod_o, ko = [], [], []
    vmlinux_a = vmlinux_o = None
    for root, _dirs, files in os.walk(tree, followlinks=True):
        for f in files:
            if not f.endswith((".o", ".ko", ".a")):
                continue
            p = os.path.join(root, f)
            try:
                t = os.stat(p).st_mtime
            except OSError:
                continue
            if root == tree and f == "vmlinux.a":
                vmlinux_a = t
            elif root == tree and f == "vmlinux.o":
                vmlinux_o = t
            elif f.endswith(".mod.o"):
                mod_o.append(t)
            elif f.endswith(".ko"):
                ko.append(t)
            elif f.endswith(".o") and not f.endswith(".lto.o"):
                objs.append(t)
    for name, v in (("vmlinux.a", vmlinux_a), ("vmlinux.o", vmlinux_o),
                    ("*.mod.o", mod_o), ("*.ko", ko), ("objects", objs)):
        if not v:
            sys.exit(f"timeline: {name} not found under {tree}")
    print("phase\tstart\tend\tseconds\tobjects")
    for line in format_rows(phases(objs, vmlinux_a, vmlinux_o, mod_o, ko)):
        print(line)


def self_test():
    checks = []

    def check(name, cond):
        checks.append((name, bool(cond)))

    argv, n = pin_march(["clang", "-march=native", "-O2", "-Wa,-march=native"])
    check("march replaced in bare and nested args", n == 2 and argv[1] == PIN_TO and argv[3] == "-Wa," + PIN_TO)
    argv, n = pin_march(["clang", "-O2"])
    check("march absent is a zero-count no-op", n == 0 and argv == ["clang", "-O2"])

    text = ("savedcmd_kernel/fork.o := clang -Wp,-MMD,kernel/.fork.o.d -march=native "
            "-DKBUILD_MODFILE='\"kernel/fork\"' -c -o kernel/fork.o kernel/fork.c\n")
    a = savedcmd_argv(text, "kernel", "fork")
    check("shlex keeps quoted define as one arg", '-DKBUILD_MODFILE="kernel/fork"' in a)
    a = rewrite_outputs(a, "/t/fork.x.o", "/t/fork.x.d")
    check("-o rewritten", a[a.index("-o") + 1] == "/t/fork.x.o")
    check("-Wp,-MMD rewritten", "-Wp,-MMD,/t/fork.x.d" in a)
    try:
        savedcmd_argv(text, "kernel", "other")
        missing = False
    except ValueError:
        missing = True
    check("missing savedcmd line raises", missing)

    s = parse_stats("Compile requests executed       12\nSuccessful distributed compiles  3\n"
                    "Failed distributed compiles  1\n")
    check("stats parsed", s == {"ok": 3, "failed": 1, "executed": 12})
    check("absent dist lines count as zero", parse_stats("Cache hits 4\n") == {"ok": 0, "failed": 0, "executed": 0})

    rows = phases([10, 20, 30, 99, 150], 100, 130, [140, 160], [170, 180, 200])
    check("compile excludes objects after vmlinux.a", rows[0] == ("compile", 10, 99, 4))
    check("phase boundaries chain",
          rows[1][1:3] == (100, 130) and rows[2][1:3] == (130, 140)
          and rows[3] == ("module_stubs", 140, 160, 2) and rows[4] == ("module_link", 160, 200, 3))
    check("rows formatted tab-separated with seconds",
          format_rows(rows)[0].split("\t")[3] == "89" and len(format_rows(rows)[0].split("\t")) == 5)

    ok = sum(1 for _, c in checks if c)
    for name, c in checks:
        if not c:
            print(f"FAIL: {name}", file=sys.stderr)
    print(f"checks: {ok}/{len(checks)} run")
    # a shortfall means a check never ran or failed; either way non-zero
    sys.exit(0 if ok == len(checks) and len(checks) == EXPECTED_CHECKS else 1)


EXPECTED_CHECKS = 11


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "timeline" and len(sys.argv) == 3:
        timeline(sys.argv[2])
    elif cmd == "build-cmd" and len(sys.argv) == 6:
        sys.stdout.buffer.write(b"\0".join(x.encode() for x in build_cmd(*sys.argv[2:])) + b"\0")
    elif cmd == "stats":
        r = parse_stats(sys.stdin.read())
        print(r["ok"], r["failed"], r["executed"])
    elif cmd == "self-test":
        self_test()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
