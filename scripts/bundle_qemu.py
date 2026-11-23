#!/usr/bin/env python3
"""Copies QEMU, qemu-img and swtpm (with every non-system library they load) from Homebrew into
VAMP.app/Contents/Resources/qemu, so VAMP needs nothing installed. Layout mirrors Homebrew's:

    qemu/bin/{qemu-system-aarch64,qemu-img,swtpm}
    qemu/lib/*.dylib                 (install names rewritten to @loader_path)
    qemu/share/qemu/...              (ARM firmware + ROMs; QEMU finds ../share/qemu next to its binary)
    qemu/licenses/<package>/...      (each package's license files, plus SOURCES.txt)

Usage: bundle_qemu.py <VAMP.app> [homebrew prefix]
"""
import os, re, shutil, subprocess, sys

app = sys.argv[1]
brew = sys.argv[2] if len(sys.argv) > 2 else "/opt/homebrew"
root = os.path.join(app, "Contents", "Resources", "qemu")
here = os.path.dirname(os.path.abspath(__file__))
BINARIES = ["qemu-system-aarch64", "qemu-img", "swtpm"]
SHARE = ["edk2-aarch64-code.fd", "edk2-arm-vars.fd", "edk2-licenses.txt", "efi-virtio.rom",
         "vgabios-ramfb.bin", "vgabios-virtio.bin", "keymaps", "firmware"]


def run(*a):
    return subprocess.run(a, check=True, capture_output=True, text=True).stdout


def deps(path):
    """Non-system libraries a Mach-O references, resolved to real files."""
    out = run("otool", "-L", path).splitlines()[1:]
    rpaths = re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+)", run("otool", "-l", path))
    found = []
    for line in out:
        ref = line.strip().split(" (")[0]
        if ref.startswith(("/usr/lib/", "/System/")):
            continue
        base = os.path.dirname(os.path.realpath(path))
        if ref.startswith("@loader_path/") or ref.startswith("@executable_path/"):
            cand = [os.path.join(base, ref.split("/", 1)[1])]
        elif ref.startswith("@rpath/"):
            cand = [os.path.join(r.replace("@loader_path", base).replace("@executable_path", base), ref[7:]) for r in rpaths]
        else:
            cand = [ref]
        real = next((os.path.realpath(c) for c in cand if os.path.exists(c)), None)
        if real is None:
            sys.exit(f"bundle_qemu: can't resolve {ref} (needed by {path})")
        if os.path.realpath(real) != os.path.realpath(path):  # skip a dylib's own install name
            found.append((ref, real))
    return found


def package_of(real):
    m = re.match(re.escape(brew) + r"/Cellar/([^/]+)/([^/]+)/", real)
    return (m.group(1), m.group(2)) if m else None


shutil.rmtree(root, ignore_errors=True)
for d in ("bin", "lib", "share/qemu", "licenses"):
    os.makedirs(os.path.join(root, d))

# Walk the dependency graph from the three tools.
queue = [os.path.realpath(os.path.join(brew, "bin", b)) for b in BINARIES]
libs, refs, packages = {}, {}, set()
seen = set()
while queue:
    f = queue.pop()
    if f in seen:
        continue
    seen.add(f)
    if p := package_of(f):
        packages.add(p)
    refs[f] = deps(f)
    for _, real in refs[f]:
        name = os.path.basename(real)
        if name in libs and libs[name] != real:
            sys.exit(f"bundle_qemu: two different libraries named {name}")
        libs[name] = real
        queue.append(real)

placed = {}
for b in BINARIES:
    src = os.path.realpath(os.path.join(brew, "bin", b))
    dst = os.path.join(root, "bin", b)
    shutil.copy2(src, dst)
    placed[src] = (dst, "@loader_path/../lib/")
for name, src in libs.items():
    dst = os.path.join(root, "lib", name)
    shutil.copy2(src, dst)
    placed[src] = (dst, "@loader_path/")

# Point every reference at the bundled copy, then re-sign (rewriting breaks the old signature).
for src, (dst, prefix) in placed.items():
    os.chmod(dst, 0o755)
    args = []
    if dst.endswith(".dylib"):
        args += ["-id", "@loader_path/" + os.path.basename(dst)]
    for ref, real in refs[src]:
        args += ["-change", ref, prefix + os.path.basename(real)]
    for r in re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+)", run("otool", "-l", dst)):
        args += ["-delete_rpath", r]
    if args:
        run("install_name_tool", *args, dst)
for src, (dst, _) in placed.items():
    ent = ["--entitlements", os.path.join(here, "qemu.entitlements")] if dst.endswith("qemu-system-aarch64") else []
    run("codesign", "--force", "--sign", "-", *ent, dst)

# Firmware and data QEMU loads for an ARM virt machine.
share = os.path.join(brew, "share", "qemu")
for item in SHARE:
    s, d = os.path.join(share, item), os.path.join(root, "share", "qemu", item)
    if os.path.isdir(s):
        shutil.copytree(s, d, symlinks=False)
    else:
        shutil.copy2(s, d)

# Licenses (QEMU, swtpm and their libraries are GPL/LGPL/BSD/MIT): ship each package's license
# files and say exactly which upstream versions these are, with where to get the source.
lic = re.compile(r"^(COPYING|LICENSE|LICENCE|COPYRIGHT|NOTICE)", re.I)
lines = ["VAMP bundles these unmodified Homebrew builds. Source for each is available from the",
         "project's homepage, or from Homebrew (https://github.com/Homebrew/homebrew-core, Formula/<name>.rb).", ""]
try:  # one query for every package's homepage
    info = run(os.path.join(brew, "bin", "brew"), "info", "--json=v2", *sorted(n for n, _ in packages))
    homes = dict(re.findall(r'"name":\s*"([^"]+)".*?"homepage":\s*"([^"]+)"', info, re.S))
except Exception:
    homes = {}
for name, ver in sorted(packages):
    cellar = os.path.join(brew, "Cellar", name, ver)
    dest = os.path.join(root, "licenses", name)
    os.makedirs(dest, exist_ok=True)
    for f in os.listdir(cellar):
        if lic.match(f) and os.path.isfile(os.path.join(cellar, f)):
            shutil.copy2(os.path.join(cellar, f), dest)
    lines.append(f"{name} {ver}  {homes.get(name, '')}")
open(os.path.join(root, "licenses", "SOURCES.txt"), "w").write("\n".join(lines) + "\n")

# Homebrew ships some of these read-only; keep everything owner-writable so the app can clear the
# quarantine flag a download leaves on them.
subprocess.run(["chmod", "-R", "u+w", root], check=True)

print(f"bundled {len(BINARIES)} tools, {len(libs)} libraries, {len(packages)} packages into {root}")
