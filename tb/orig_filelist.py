#!/usr/bin/env python3
"""Rewrite apmu_sim.f so that every entry points at the ORIGINAL he-soc source instead of the bundle copy.

Used to prove that a behaviour seen with the bundle is identical with he-soc/hardware/ip_list sources.
Mapping is taken from .provenance.json ([he-soc path relative to hardware/, bundle path]).
Also byte-compares every mapped pair and reports differences.

usage: orig_filelist.py <bundle_root> <hesoc_hardware_root> <in.f> <out.f>
"""
import filecmp, json, os, sys

root, hw, fin, fout = sys.argv[1:5]
prov = {b: s for s, b in json.load(open(os.path.join(root, ".provenance.json")))}
out, diffs, n_files = [], [], 0
for raw in open(fin):
    line = raw.strip()
    if not line or line.startswith("//"):
        continue
    if line.startswith("+incdir+"):
        rel = line[len("+incdir+"):]
        assert rel.startswith("rtl/"), line
        src = os.path.join(hw, "ip_list", rel[len("rtl/"):])
        assert os.path.isdir(src), "missing he-soc include dir: " + src
        out.append("+incdir+" + src)
        continue
    if line not in prov:
        # bundle-authored files (e.g. rtl/hesoc_cfg/apmu_hesoc_top.sv) have no he-soc original
        if line.startswith("rtl/hesoc_cfg/"):
            print("orig_filelist: %s is bundle-authored (no he-soc original), kept from bundle" % line)
            out.append(os.path.join(root, line))
            continue
        sys.exit("ERROR: %s is not in .provenance.json" % line)
    src = os.path.join(hw, prov[line])
    assert os.path.isfile(src), "missing he-soc source: " + src
    n_files += 1
    if not filecmp.cmp(src, os.path.join(root, line), shallow=False):
        diffs.append(line)
    out.append(src)
# headers are reached through +incdir; compare them too
for b, s in prov.items():
    if b.endswith((".svh", ".vh")) and not filecmp.cmp(os.path.join(hw, s), os.path.join(root, b), shallow=False):
        diffs.append(b)
open(fout, "w").write("\n".join(out) + "\n")
print("orig_filelist: %d source files mapped to he-soc; byte-identical to bundle: %s%s"
      % (n_files, "yes" if not diffs else "NO", "" if not diffs else " -> " + ", ".join(diffs)))
