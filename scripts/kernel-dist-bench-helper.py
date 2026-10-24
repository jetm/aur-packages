#!/usr/bin/env python3
"""Helper for kernel-dist-bench.sh: Kbuild cmd parsing, stats parsing, timeline.

Subcommands:
  timeline <tree>                       phase table from file mtimes
  build-cmd <tree> <tu> <outdir> <tag>  NUL-separated argv for one TU
  stats                                 parse `sccache --show-stats` on stdin
  safe-subdir|strip-ccache-path|dist-cpus|verdict|load-check
                                        small probe/run predicates (see kernel-dist-bench.sh)
  run-row <label> <date> <tree> <start> <end> <log> <rev> [VAR=val ...]
                                        one runs.tsv row
  report <runs.tsv> <probe.verdict>     bar / stretch / follow-on summary
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
    print("phase\tstart\tend\tseconds\tobjects")
    for line in format_rows(collect(tree)):
        print(line)


def collect(tree):
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
    return phases(objs, vmlinux_a, vmlinux_o, mod_o, ko)


# ---- probe / run / report ------------------------------------------------

BAR_RATIO_NUM, BAR_RATIO_DEN = 4, 5  # dist wall must be <= 0.8 of baseline
STRETCH_SECONDS = 600
COLUMNS = ["label", "date", "overrides", "wall", "prepare", "compile",
           "vmlinux_lto", "modpost", "module_stubs", "module_link",
           "packaging", "distributed", "failed_distributed", "revision"]
SERIAL_PHASES = [("vmlinux_lto", "vmlinux LTO"), ("modpost", "modpost"),
                 ("module_link", "module link"), ("packaging", "packaging")]
TS_RE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d ", re.M)
LOAD_LIMIT = 4.0


def safe_subdir(sub):
    """True when sub names a directory strictly inside the tree."""
    if not sub or os.path.isabs(sub):
        return False
    parts = [p for p in sub.split("/") if p not in ("", ".")]
    return bool(parts) and ".." not in parts


def strip_ccache_path(path):
    """PATH with every entry that has a ccache path component removed."""
    keep = [p for p in path.split(":") if "ccache" not in p.split("/")]
    return ":".join(keep)


def dist_cpus(text):
    m = re.search(r'"num_cpus"\s*:\s*(\d+)', text)
    return int(m.group(1)) if m else 0


def verdict_line(local_rate, dist_rate):
    return "verdict: dist-wins" if dist_rate > local_rate else "verdict: local-wins"


def load_refused(loadavg_text, limit=LOAD_LIMIT):
    return float(loadavg_text.split()[0]) > limit


def bar_met(base_wall, dist_wall):
    # integer-ratio form so exactly 0.8 compares exactly
    return dist_wall * BAR_RATIO_DEN <= base_wall * BAR_RATIO_NUM


def log_stats(text, overrides):
    """(distributed, failed) from a timestamp-prefixed log; 0/0 off sccache."""
    for ov in overrides:
        if ov.startswith("_cc_launcher=") and ov.split("=", 1)[1] != "sccache":
            return 0, 0
    s = parse_stats(TS_RE.sub("", text))
    return s["ok"], s["failed"]


def phase_seconds(rows, start, end):
    """Seven phase seconds: prepare, compile, vmlinux, modpost, stubs, link, packaging."""
    secs = [round(e - s) for _n, s, e, _c in rows]
    prepare = max(0, round(rows[0][1] - start))
    packaging = max(0, round(end - rows[4][2]))
    return [prepare, secs[0], secs[1], secs[2], secs[3], secs[4], packaging]


def make_row(label, date, overrides, wall, secs, dist, failed, rev):
    fields = [label, date, ",".join(overrides) or "-", str(wall)]
    fields += [str(x) for x in secs] + [str(dist), str(failed), rev]
    return "\t".join(fields)


def parse_rows(text):
    rows = []
    for line in text.splitlines():
        f = line.split("\t")
        if len(f) != len(COLUMNS):
            continue
        r = dict(zip(COLUMNS, f))
        for k in COLUMNS[3:13]:
            r[k] = int(r[k])
        rows.append(r)
    return rows


def build_report(runs_text, probe_text):
    """(lines, ok) for the report subcommand."""
    rows = parse_rows(runs_text)
    out = ["\t".join(r[c] if isinstance(r[c], str) else str(r[c]) for c in COLUMNS) for r in rows]
    base = [r for r in rows if r["label"] == "baseline"]
    dist = [r for r in rows if r["label"].startswith("dist")]
    if not base or not dist:
        return out + ["report: need a baseline row and a dist row"], False
    b = base[-1]
    d = min(dist, key=lambda r: r["wall"])
    out.append(f"{d['label']}\t{d['wall']}s vs baseline {b['wall']}s\tratio {d['wall'] / b['wall']:.3f}")
    met = bar_met(b["wall"], d["wall"])
    out.append("bar: met" if met else "bar: missed")
    out.append("stretch: met" if d["wall"] < STRETCH_SECONDS else "stretch: missed")
    if met:
        out.append("follow-on: justified")
    else:
        out.append("follow-on: not justified")
        lines = [ln for ln in probe_text.splitlines() if ln.startswith("verdict:")]
        out.append(lines[-1] if lines else "verdict: no probe recorded")
        key, name = max(SERIAL_PHASES, key=lambda p: d[p[0]])
        out.append(f"longest serial phase: {name} ({d[key]} s)")
    return out, True


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

    check("0.75 of baseline meets the bar", bar_met(1000, 750))
    check("0.85 of baseline misses the bar", not bar_met(1000, 850))
    check("exactly 0.8 of baseline meets the bar", bar_met(1000, 800) and not bar_met(1000, 801))

    secs = phase_seconds(rows, 90, 215)
    check("prepare is makepkg start to first object, packaging last .ko to exit",
          secs == [0, 89, 30, 10, 20, 40, 15])
    row = make_row("dist-1", "2026-10-24", ["_cc_launcher=sccache"], 700, secs, 5, 1, "abc1234")
    f = row.split("\t")
    check("runs.tsv row has label first and 14 fields in column order",
          f[0] == "dist-1" and len(f) == len(COLUMNS) and f[3] == "700" and f[10] == "15"
          and f[11:] == ["5", "1", "abc1234"])
    check("empty overrides are recorded as a dash",
          make_row("x", "d", [], 1, secs, 0, 0, "r").split("\t")[2] == "-")

    def rep(base_wall, dist_wall, probe=""):
        tsv = "\n".join([
            make_row("baseline", "d", [], base_wall, [1, 2, 3, 4, 5, 6, 7], 0, 0, "r"),
            make_row("dist-slow", "d", [], 2000, [1, 2, 3, 4, 5, 6, 7], 0, 0, "r"),
            make_row("dist-a", "d", [], dist_wall, [10, 400, 90, 30, 20, 60, 15], 9, 0, "r"),
        ])
        return build_report(tsv, probe)[0]

    lines = rep(1000, 850, "verdict: dist-wins\nverdict: local-wins\n")
    check("every run line starts with its label",
          [ln.split("\t")[0] for ln in lines[:3]] == ["baseline", "dist-slow", "dist-a"])
    check("0.85 report says bar missed, not met", "bar: missed" in lines and "bar: met" not in lines)
    check("0.75 report says bar met and follow-on justified",
          "bar: met" in rep(1000, 750) and "follow-on: justified" in rep(1000, 750))
    check("stretch needs strictly under 600 s",
          "stretch: met" in rep(1000, 599) and "stretch: missed" in rep(1000, 600))
    check("follow-on not justified carries last probe verdict and longest serial phase",
          lines[-3:] == ["follow-on: not justified", "verdict: local-wins",
                         "longest serial phase: vmlinux LTO (90 s)"])
    check("report without a baseline row fails",
          build_report(make_row("dist-a", "d", [], 5, [1] * 7, 0, 0, "r"), "")[1] is False)

    check("load average above 4 is refused, at or below is not",
          load_refused("4.01 1.00 1.00 1/200 99\n") and not load_refused("4.00 9.00 9.00 1/200 99\n"))
    check("subdir outside the tree is unsafe",
          safe_subdir("drivers/net/") and not safe_subdir("../x") and not safe_subdir("/etc")
          and not safe_subdir("a/../../b") and not safe_subdir("") and not safe_subdir("."))
    check("ccache dir dropped from PATH",
          strip_ccache_path("/usr/lib/ccache/bin:/usr/bin:/opt/ccache:/bin") == "/usr/bin:/bin")
    check("first num_cpus parsed from dist-status",
          dist_cpus('{"SchedulerStatus":["x",{"num_servers":1,"num_cpus":96},{"num_cpus":4}]}') == 96
          and dist_cpus("not running") == 0)
    check("verdict line follows the rates",
          verdict_line(10.0, 12.0) == "verdict: dist-wins" and verdict_line(10.0, 10.0) == "verdict: local-wins")
    log = ("2026-10-24T10:00:00 Successful distributed compiles  7\n"
           "2026-10-24T10:00:00 Failed distributed compiles  2\n")
    check("log stats parse behind timestamps and are zero off sccache",
          log_stats(log, []) == (7, 2) and log_stats(log, ["_cc_launcher=ccache"]) == (0, 0))

    ok = sum(1 for _, c in checks if c)
    for name, c in checks:
        if not c:
            print(f"FAIL: {name}", file=sys.stderr)
    print(f"checks: {ok}/{len(checks)} run")
    # a shortfall means a check never ran or failed; either way non-zero
    sys.exit(0 if ok == len(checks) and len(checks) == EXPECTED_CHECKS else 1)


EXPECTED_CHECKS = 29


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
    elif cmd == "safe-subdir" and len(sys.argv) == 3:
        sys.exit(0 if safe_subdir(sys.argv[2]) else 2)
    elif cmd == "strip-ccache-path" and len(sys.argv) == 3:
        print(strip_ccache_path(sys.argv[2]))
    elif cmd == "dist-cpus":
        print(dist_cpus(sys.stdin.read()))
    elif cmd == "verdict" and len(sys.argv) == 4:
        print(verdict_line(float(sys.argv[2]), float(sys.argv[3])))
    elif cmd == "load-check" and len(sys.argv) == 3:
        with open(sys.argv[2], encoding="utf-8") as fh:
            if load_refused(fh.read()):
                sys.exit(4)
    elif cmd == "run-row" and len(sys.argv) >= 9:
        label, date, tree, start, end, logfile, rev = sys.argv[2:9]
        overrides = sys.argv[9:]
        secs = phase_seconds(collect(tree), float(start), float(end))
        with open(logfile, encoding="utf-8", errors="replace") as fh:
            dist, failed = log_stats(fh.read(), overrides)
        print(make_row(label, date, overrides, round(float(end) - float(start)), secs, dist, failed, rev))
    elif cmd == "report" and len(sys.argv) == 4:
        def slurp(p):
            try:
                with open(p, encoding="utf-8") as fh:
                    return fh.read()
            except FileNotFoundError:
                return ""
        lines, ok = build_report(slurp(sys.argv[2]), slurp(sys.argv[3]))
        print("\n".join(lines))
        sys.exit(0 if ok else 1)
    elif cmd == "self-test":
        self_test()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
