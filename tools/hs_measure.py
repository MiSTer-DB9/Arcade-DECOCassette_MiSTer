#!/usr/bin/env python3
"""Measure each DECO set's hiscore table init RELATIVE TO GAME ENTRY in MAME (headless, scratch cfg/nvram).
   hs_measure.py set...   -> per set: game entry frame (first PC below $F000 = BIOS hands over after the cassette
                             load + rewind), then the hiscore.dat write clusters as frames after entry.
   The core holds hiscore.v in reset until its own first opcode fetch below $F000 (HISCORE-2026-10-25), so
   START_WAIT counts from entry: START_WAIT = (last init write after entry + 2) frames."""
import subprocess, sys, tempfile
from pathlib import Path

MAME = "/CybertronMD/Mame/mame"
ROMS = Path(__file__).resolve().parent.parent / "games/mame"
HISCORE_DAT = Path("/CybertronMD/Mame/plugins/hiscore/hiscore.dat")
AFTER, GAP = 1800, 30                                 # frames logged after entry; cluster gap

LUA = """local scr = manager.machine.screens[":screen"]
local cpu = manager.machine.devices[":maincpu"]
local sp = cpu.spaces["program"]
local entry = nil
local samples = 0
taps = {}
for _, r in ipairs({%s}) do
  taps[#taps + 1] = sp:install_write_tap(r[1], r[1] + r[2] - 1, "hs" .. r[1], function(o, d, m)
    print(string.format("W %%d %%04X %%02X", scr:frame_number(), o, d))
  end)
end
local function tick()
  samples = samples + 1
  local f = scr:frame_number()
  if entry == nil and cpu.state["PC"].value < 0xF000 then
    entry = f
    print(string.format("E %%d %%.4f", f, manager.machine.time:as_double()))
  end
  if (entry ~= nil and f >= entry + %d) or f >= 60000 then
    print(string.format("S %%d", samples))
    manager.machine:exit()
  end
end
if emu.add_machine_periodic_notifier then sub = emu.add_machine_periodic_notifier(tick) else emu.register_periodic(tick) end
"""


def parse_hiscores():
    """decocass section of hiscore.dat: {set: ["@:maincpu,program,addr,len,start,end", ...]}"""
    out, names, lines, insec = {}, [], [], False
    for ln in HISCORE_DAT.read_text(errors="replace").splitlines():
        ln = ln.strip()
        if ln.startswith(";@s:"):
            insec = ln.endswith("dataeast/decocass.cpp")
            continue
        if not insec or not ln or ln.startswith(";"):
            continue
        if ln.endswith(":") and not ln.startswith("@"):
            if lines:
                for n in names:
                    out[n] = lines
                names, lines = [], []
            names.append(ln[:-1])
        elif ln.startswith("@"):
            lines.append(ln)
    for n in names:
        out[n] = lines
    return out


def measure(name, lines, tmp):
    ranges = [(int(l.split(",")[2], 16), int(l.split(",")[3], 16)) for l in lines]
    lua = Path(tmp) / f"{name}.lua"
    lua.write_text(LUA % (", ".join(f"{{{a}, {n}}}" for a, n in ranges), AFTER))
    r = subprocess.run([MAME, name, "-rompath", str(ROMS), "-video", "none", "-sound", "none", "-nothrottle",
                        "-noplugins", "-cfg_directory", f"{tmp}/cfg", "-nvram_directory", f"{tmp}/nv",
                        "-snapshot_directory", f"{tmp}/snap", "-autoboot_script", str(lua)],
                       capture_output=True, text=True, timeout=900)
    entry, samples, writes = None, None, []
    for ln in r.stdout.splitlines():
        p = ln.split()
        if p and p[0] == "E":
            entry = int(p[1])
        elif p and p[0] == "S":
            samples = int(p[1])
        elif p and p[0] == "W":
            writes.append((int(p[1]), p[2], p[3]))
    if entry is None:
        err = r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "no output"
        return f"{name:12s} NO ENTRY ({err})"
    pre = sorted({f for f, a, v in writes if f < entry})
    post = sorted({f - entry for f, a, v in writes if f >= entry})
    clusters, start = [], None
    for i, f in enumerate(post):
        if start is None:
            start = f
        if i + 1 == len(post) or post[i + 1] - f > GAP:
            clusters.append(f"{start}-{f}" if f != start else f"{f}")
            start = None
    return (f"{name:12s} entry f{entry} (samples {samples})  writes before entry: {len(pre)} frames"
            f" (last f{pre[-1] if pre else '-'})  after entry (+frames): {' '.join(clusters) or 'none'}")


if __name__ == "__main__":
    hs = parse_hiscores()
    with tempfile.TemporaryDirectory() as tmp:
        for name in sys.argv[1:]:
            print(measure(name, hs[name], tmp) if name in hs else f"{name:12s} no hiscore.dat entry", flush=True)
