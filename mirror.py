#!/usr/bin/env python3
"""
Python mirror of the SystemVerilog project (NOT a replacement for running it).

Why it exists: no HDL simulator was available where this project was written, so
this re-implements, line for line in intent:
  * the RTL (golden + every BUG_ switch),
  * the scoreboard's check()/update_model() rules,
  * the SVA assertion set (same antecedents/consequents, same disable gating),
  * the covergroup bins (cg_ops, cg_data, cg_flags, cg_rst),
  * the test phases (smoke/random/.../closure).
It answers three questions before you ever open a simulator:
  1. Is the reference model self-consistent with the golden RTL?  (0 errors)
  2. Can the constrained-random closure loop reach 100% coverage?
  3. Is every injected bug detectable by the scoreboard and/or an assertion?

usage: python3 mirror.py [--depth 16] [--width 8] [--seeds 20]
"""
import argparse, random, sys

ALL_BUGS = ["OVERFLOW_WRITE", "UNDERFLOW_READ", "FULL_OFF_BY_ONE", "WPTR_WRAP",
            "SIMUL_COUNT", "DATA_ALLONES", "LAST_ENTRY_DROP", "NO_OVERFLOW_FLAG",
            "UNDERFLOW_FLAG_CORNER", "RESET_RPTR"]


# --------------------------------------------------------------------------- RTL
class Dut:
    def __init__(s, depth, width, bug=None):
        s.D, s.W, s.bug = depth, width, bug
        s.AW = depth.bit_length() - 1
        s.mask = (1 << width) - 1
        s.mem = [None] * depth
        s.wptr = s.rptr = s.cnt = None          # X before first reset
        s.rdata = s.rv = s.ovf = s.unf = None

    def outputs(s):
        if s.cnt is None:
            return dict(full=None, empty=None, count=None, rdata=s.rdata,
                        rv=s.rv, ovf=s.ovf, unf=s.unf)
        thr = s.D - 1 if s.bug == "FULL_OFF_BY_ONE" else s.D
        return dict(full=int(s.cnt == thr), empty=int(s.cnt == 0), count=s.cnt,
                    rdata=s.rdata, rv=s.rv, ovf=s.ovf, unf=s.unf)

    def edge(s, rst_n, wr, rd, wd):
        o = s.outputs()
        b, D = s.bug, s.D
        if not rst_n:
            s.wptr = 0
            if b == "RESET_RPTR":
                if s.rptr is None:
                    s.rptr = 0                   # only power-up init
            else:
                s.rptr = 0
            s.cnt, s.rdata, s.rv, s.ovf, s.unf = 0, 0, 0, 0, 0
            return
        full, empty = o["full"], o["empty"]
        do_wr = wr if b == "OVERFLOW_WRITE" else (wr and not full)
        do_rd = rd if b == "UNDERFLOW_READ" else (rd and not empty)
        wd_eff = wd ^ 1 if (b == "DATA_ALLONES" and wd == s.mask) else wd
        mem_wr = do_wr and not (b == "LAST_ENTRY_DROP" and s.cnt == D - 1 and do_rd)
        # next-state values computed from OLD state (nonblocking semantics)
        n_ovf = 0 if b == "NO_OVERFLOW_FLAG" else int(bool(wr and full))
        n_unf = int(bool(rd and empty and not wr)) if b == "UNDERFLOW_FLAG_CORNER" \
            else int(bool(rd and empty))
        # read samples OLD memory (nonblocking semantics) -> do it before the write
        n_rdata, n_rptr = s.rdata, s.rptr
        if do_rd:
            n_rdata = s.mem[s.rptr]
            n_rptr = (s.rptr + 1) % D
        n_wptr = s.wptr
        if mem_wr:
            s.mem[s.wptr] = wd_eff
            if b == "WPTR_WRAP":
                n_wptr = 1 if s.wptr == D - 1 else (s.wptr + 1) % D
            else:
                n_wptr = (s.wptr + 1) % D
        m = 2 * D
        k = (int(bool(do_wr)), int(bool(do_rd)))
        if k == (1, 0):   n_cnt = (s.cnt + 1) % m
        elif k == (0, 1): n_cnt = (s.cnt - 1) % m
        elif k == (1, 1): n_cnt = (s.cnt + 1) % m if b == "SIMUL_COUNT" else s.cnt
        else:             n_cnt = s.cnt
        s.ovf, s.unf, s.rv = n_ovf, n_unf, int(bool(do_rd))
        s.wptr, s.rptr, s.rdata, s.cnt = n_wptr, n_rptr, n_rdata, n_cnt


# ---------------------------------------------------------------------- scoreboard
class Scoreboard:
    def __init__(s, depth):
        s.D = depth
        s.q = []
        s.exp_rv = s.exp_ovf = s.exp_unf = 0
        s.exp_rdata = 0
        s.seen_reset = False
        s.errors = 0
        s.first_err = None
        s.cycles = 0
        s.msgs = []

    def err(s, what):
        s.errors += 1
        if s.first_err is None:
            s.first_err = s.cycles
        if len(s.msgs) < 3:
            s.msgs.append(f"cycle {s.cycles}: {what}")

    def step(s, o):
        s.cycles += 1
        # (1) check
        if s.seen_reset:
            n = len(s.q)
            if o["full"] != int(n == s.D):   s.err("FULL")
            if o["empty"] != int(n == 0):    s.err("EMPTY")
            if o["count"] != n:              s.err("COUNT")
            if o["rv"] != s.exp_rv:          s.err("RDATA_VALID")
            elif s.exp_rv and o["rdata"] != s.exp_rdata:
                s.err("DATA")
            if o["ovf"] != s.exp_ovf:        s.err("OVERFLOW")
            if o["unf"] != s.exp_unf:        s.err("UNDERFLOW")
        # (2) update
        if not o["rst_n"]:
            s.q.clear()
            s.exp_rv = s.exp_ovf = s.exp_unf = 0
            s.exp_rdata = 0
            s.seen_reset = True
            return
        if not s.seen_reset:
            return
        full, empty = len(s.q) == s.D, len(s.q) == 0
        do_wr, do_rd = o["wr"] and not full, o["rd"] and not empty
        s.exp_ovf, s.exp_unf = int(bool(o["wr"] and full)), int(bool(o["rd"] and empty))
        s.exp_rv = int(bool(do_rd))
        if do_rd: s.exp_rdata = s.q.pop(0)
        if do_wr: s.q.append(o["wd"])


# --------------------------------------------------------------------------- SVA
class Sva:
    """Same properties as sva/fifo_sva.sv. prev/cur are consecutive samples."""
    def __init__(s, depth):
        s.D = depth
        s.prev = None
        s.fails = {}

    def f(s, name):
        s.fails[name] = s.fails.get(name, 0) + 1

    def step(s, c):
        D, p = s.D, s.prev
        xs = [c[k] for k in ("full", "empty", "count", "ovf", "unf", "rv")]
        if c["rst_n"]:                                    # default disable iff (!rst_n)
            if any(v is None for v in xs):
                s.f("a_no_x")
            else:
                if c["rv"] and c["rdata"] is None:        s.f("a_rdata_no_x")
                if c["full"] and c["empty"]:              s.f("a_flags_exclusive")
                if c["count"] > D:                        s.f("a_count_range")
                if c["full"] != int(c["count"] == D):     s.f("a_full_def")
                if c["empty"] != int(c["count"] == 0):    s.f("a_empty_def")
                if c["ovf"] and not (p and p["wr"] and p["full"]):
                    s.f("a_overflow_no_spurious")
                if c["unf"] and not (p and p["rd"] and p["empty"]):
                    s.f("a_underflow_no_spurious")
            # consequents of attempts launched on prev (need prev.rst_n and cur.rst_n)
            if p and p["rst_n"] and not any(v is None for v in xs) and \
               not any(p[k] is None for k in ("full", "empty", "count")):
                p_dw, p_dr = p["wr"] and not p["full"], p["rd"] and not p["empty"]
                if c["count"] != p["count"] + int(bool(p_dw)) - int(bool(p_dr)):
                    s.f("a_count_update")
                if p["wr"] and p["full"] and not c["ovf"]:
                    s.f("a_overflow_flag")
                if p["wr"] and p["full"] and not p["rd"] and c["count"] != p["count"]:
                    s.f("a_overflow_no_corrupt")
                if p["rd"] and p["empty"] and not c["unf"]:
                    s.f("a_underflow_flag")
                if p["rd"] and p["empty"] and not p["wr"] and \
                   (c["count"] != p["count"] or c["rv"]):
                    s.f("a_underflow_no_corrupt")
                if p_dr and not c["rv"]:                  s.f("a_rvalid_follows_read")
                if (not p_dr) and c["rv"]:                s.f("a_rvalid_only_after_read")
                if (not p_dr) and c["rdata"] != p["rdata"]:
                    s.f("a_rdata_hold")
        # reset check (not gated by disable)
        if p and not p["rst_n"]:
            if not (c["count"] == 0 and c["empty"] == 1 and c["full"] == 0 and
                    c["ovf"] == 0 and c["unf"] == 0 and c["rv"] == 0):
                s.f("a_reset_state")
        s.prev = c


# ----------------------------------------------------------------------- coverage
def lvl_of(c, D):
    if c == 0: return "EMPTY"
    if c == D: return "FULL"
    if c == 1: return "ONE"
    if c == D - 1: return "AF"
    return "MID"


class Coverage:
    LV = ["EMPTY", "ONE", "MID", "AF", "FULL"]
    OPS = ["idle", "wr", "rd", "wrrd"]

    def __init__(s, D, W):
        s.D, s.W = D, W
        s.cross, s.lvl_hit, s.trans = set(), set(), set()
        s.data, s.flags, s.rst = set(), set(), set()
        s.ops_hist = []                     # level history for transition bins
        s.flag_prev = {"ovf": 0, "unf": 0}
        s.prev_rst = None

    def sample(s, o):
        if o["count"] is None:
            s.prev_rst = o["rst_n"]; return
        L = lvl_of(o["count"], s.D)
        if o["rst_n"]:
            op = s.OPS[(2 if o["wr"] else 0) + (1 if o["rd"] else 0)]
            s.lvl_hit.add(L); s.cross.add((L, op))
            h = s.ops_hist; h.append(L)
            if len(h) >= 2:
                pair = (h[-2], h[-1])
                for nm, pr in (("e2o", ("EMPTY", "ONE")), ("o2e", ("ONE", "EMPTY")),
                               ("af2f", ("AF", "FULL")), ("f2af", ("FULL", "AF"))):
                    if pair == pr: s.trans.add(nm)
            if len(h) >= 3:
                if h[-3:] == ["FULL"] * 3:  s.trans.add("full3")
                if h[-3:] == ["EMPTY"] * 3: s.trans.add("empty3")
            if len(h) > 3: del h[0]
            if o["wr"]:
                s.data.add("zero" if o["wd"] == 0 else "ones" if o["wd"] == (1 << s.W) - 1 else "mid")
            for k in ("ovf", "unf"):
                if o[k]:
                    s.flags.add(k + "_pulse")
                    if s.flag_prev[k]: s.flags.add(k + "_b2b")
                s.flag_prev[k] = o[k]
        elif s.prev_rst == 1:
            s.rst.add("empty" if L == "EMPTY" else "full" if L == "FULL" else "mid")
        s.prev_rst = o["rst_n"]

    def pct(s):
        ops = (len(s.cross) + len(s.lvl_hit) + len(s.trans)) / (20 + 5 + 6)
        return dict(cg_ops=ops * 100, cg_data=len(s.data) / 3 * 100,
                    cg_flags=len(s.flags) / 4 * 100, cg_rst=len(s.rst) / 3 * 100)

    def closed(s):
        return all(v >= 99.999 for v in s.pct().values())

    def holes(s):
        miss = []
        for L in s.LV:
            for op in s.OPS:
                if (L, op) not in s.cross: miss.append(f"cross({L},{op})")
        for nm in ("e2o", "o2e", "af2f", "f2af", "full3", "empty3"):
            if nm not in s.trans: miss.append("trans:" + nm)
        for d in ("zero", "ones", "mid"):
            if d not in s.data: miss.append("data:" + d)
        for f in ("ovf_pulse", "ovf_b2b", "unf_pulse", "unf_b2b"):
            if f not in s.flags: miss.append("flag:" + f)
        for r in ("empty", "mid", "full"):
            if r not in s.rst: miss.append("rst:" + r)
        return miss


# ------------------------------------------------------------------ TB harness
class Tb:
    def __init__(s, depth, width, bug, rng):
        s.D, s.W, s.rng = depth, width, rng
        s.dut = Dut(depth, width, bug)
        s.sb, s.sva, s.cov = Scoreboard(depth), Sva(depth), Coverage(depth, width)
        s.rst_n_pin, s.cycles_run = 0, 0

    def cycle(s, rst_n, wr, rd, wd):
        o = s.dut.outputs()
        o.update(rst_n=rst_n, wr=wr, rd=rd, wd=wd)
        s.sb.step(o); s.sva.step(dict(o)); s.cov.sample(o)
        s.dut.edge(rst_n, wr, rd, wd)
        s.cycles_run += 1

    def wdata(s):
        r = s.rng.random() * 100
        if r < 5:  return 0
        if r < 10: return (1 << s.W) - 1
        return s.rng.randint(1, (1 << s.W) - 2)

    def phase(s, n, wr_w, rd_w):
        for _ in range(n):
            s.cycle(1, int(s.rng.random() * 100 < wr_w), int(s.rng.random() * 100 < rd_w), s.wdata())

    def reset(s, n):
        for _ in range(n):
            s.cycle(0, s.rng.randint(0, 1), s.rng.randint(0, 1), s.wdata())

    # tests --------------------------------------------------------------
    def smoke(s):
        D = s.D
        s.phase(D + 4, 100, 0); s.phase(D + 4, 0, 100); s.phase(D, 100, 100)

    def rnd(s):        s.phase(5000, 50, 50)
    def wr_heavy(s):   s.phase(5000, 80, 20)
    def rd_heavy(s):   s.phase(5000, 20, 80)

    def bursty(s):
        D, r = s.D, s.rng
        for _ in range(20):
            s.phase(r.randint(2 * D, 3 * D), 90, 10)
            s.phase(r.randint(2 * D, 3 * D), 10, 90)

    def reset_test(s):
        D, r = s.D, s.rng
        for _ in range(6):
            s.phase(r.randint(D, 3 * D), r.randint(10, 90), r.randint(10, 90))
            s.reset(r.randint(1, 3))
        s.phase(2 * D, 100, 0); s.reset(2)
        s.reset(1)
        s.phase(D // 2, 100, 0); s.reset(1)
        s.phase(2 * D, 100, 0); s.phase(2 * D, 0, 100); s.reset(2)
        s.phase(D, 60, 40)

    def closure(s, max_rounds=1000):
        D, r, n = s.D, s.rng, 0
        while not s.cov.closed() and s.sb.errors == 0 and n < max_rounds:
            s.phase(r.randint(D, 8 * D), r.randint(5, 95), r.randint(5, 95))
            if r.randint(0, 2) == 0: s.reset(r.randint(1, 3))
            n += 1
        return n

    def run(s, test="regress"):
        s.reset(3)
        rounds = 0
        if test == "regress":
            s.smoke(); s.rnd(); s.wr_heavy(); s.rd_heavy(); s.bursty(); s.reset_test()
            rounds = s.closure()
        else:
            getattr(s, test)()
        sva_fails = sum(s.sva.fails.values())
        return dict(sb=s.sb.errors, sva=sva_fails, first=s.sb.first_err,
                    cov_ok=s.cov.closed(), rounds=rounds, cov=s.cov.pct(),
                    sva_names=sorted(s.sva.fails), holes=s.cov.holes(), msgs=s.sb.msgs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--depth", type=int, default=16)
    ap.add_argument("--width", type=int, default=8)
    ap.add_argument("--seeds", type=int, default=20)
    a = ap.parse_args()
    rc = 0

    print(f"== mirror of sync_fifo  DEPTH={a.depth} DATA_W={a.width}  seeds=1..{a.seeds} ==\n")

    # 1+2: golden must be clean and coverage must close
    rounds, bad = [], 0
    for seed in range(1, a.seeds + 1):
        r = Tb(a.depth, a.width, None, random.Random(seed)).run("regress")
        ok = r["sb"] == 0 and r["sva"] == 0 and r["cov_ok"]
        bad += (not ok)
        rounds.append(r["rounds"])
        if not ok:
            print(f"  seed {seed}: GOLDEN NOT CLEAN sb={r['sb']} sva={r['sva']} {r['sva_names']} "
                  f"cov_ok={r['cov_ok']} holes={r['holes']} {r['msgs']}")
    print(f"golden RTL      : {a.seeds - bad}/{a.seeds} seeds clean + coverage closed; "
          f"closure rounds after directed tests: min={min(rounds)} max={max(rounds)} "
          f"avg={sum(rounds)/len(rounds):.1f}")
    rc |= bad != 0

    # coverage achieved by the directed tests alone (what closure had to add)
    pre = Tb(a.depth, a.width, None, random.Random(1))
    pre.reset(3); pre.smoke(); pre.rnd(); pre.wr_heavy(); pre.rd_heavy(); pre.bursty(); pre.reset_test()
    print("directed tests alone leave these holes:", pre.cov.holes() or "none")
    print()

    # 3: mutation campaign
    print(f"{'bug':26s} {'verdict':8s} {'sb_err':>7s} {'sva_fail':>8s} {'1st-err':>8s}  assertions that fired")
    esc = 0
    for bug in ALL_BUGS:
        caught_by_sb = caught_by_sva = 0
        worst = None
        for seed in range(1, a.seeds + 1):
            r = Tb(a.depth, a.width, bug, random.Random(seed)).run("regress")
            caught_by_sb += r["sb"] > 0
            caught_by_sva += r["sva"] > 0
            if seed == 1: worst = r
            if r["sb"] == 0 and r["sva"] == 0:
                print(f"  !! seed {seed}: {bug} produced NO failure")
        detected = (worst["sb"] > 0 or worst["sva"] > 0)
        esc += not detected
        print(f"{bug:26s} {'CAUGHT' if detected else 'ESCAPED':8s} {worst['sb']:7d} {worst['sva']:8d} "
              f"{str(worst['first']):>8s}  {','.join(worst['sva_names']) or '-'}"
              f"   [sb on {caught_by_sb}/{a.seeds} seeds, sva on {caught_by_sva}/{a.seeds}]")
    print(f"\nbugs escaped: {esc}")
    rc |= esc != 0
    return rc


if __name__ == "__main__":
    sys.exit(main())
