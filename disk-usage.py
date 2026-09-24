#!/usr/bin/env python3
"""Read-only disk usage helper for the athesias.disks bar widget.

  disk-usage.py drives        -> JSON list of mounted drives with totals
  disk-usage.py scan <path>   -> JSON breakdown of <path>'s immediate children

Nothing here writes to disk: it only runs findmnt, lsblk and du.
"""

import json
import os
import re
import subprocess
import sys

# Pseudo and system filesystems that are not "drives" to the user.
SKIP_FSTYPES = {
    "autofs", "binfmt_misc", "bpf", "cgroup", "cgroup2", "configfs", "debugfs",
    "devpts", "devtmpfs", "efivarfs", "fusectl", "hugetlbfs", "mqueue", "nsfs",
    "overlay", "proc", "pstore", "ramfs", "securityfs", "squashfs", "sysfs",
    "tmpfs", "tracefs", "zram",
}
# Small firmware/boot partitions that live on the system drive.
SKIP_TARGETS = {"/boot", "/efi", "/boot/efi"}


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def base_source(source):
    # btrfs subvolume mounts report "/dev/mapper/root[/@home]".
    return re.sub(r"\[.*\]$", "", source or "")


def real_mounts():
    out = run(["findmnt", "-D", "-b", "-J", "-o", "SOURCE,FSTYPE,SIZE,USED,AVAIL,TARGET"])
    try:
        filesystems = json.loads(out.stdout).get("filesystems", [])
    except ValueError:
        return []
    mounts = []
    for fs in filesystems:
        source = fs.get("source") or ""
        if not source.startswith("/dev/") or fs.get("fstype") in SKIP_FSTYPES:
            continue
        mounts.append({
            "device": base_source(source),
            "fstype": fs.get("fstype") or "",
            "size": int(fs.get("size") or 0),
            "used": int(fs.get("used") or 0),
            "avail": int(fs.get("avail") or 0),
            "target": fs.get("target") or "",
        })
    return mounts


def device_info(device):
    """Filesystem label plus the physical disk's model and transport."""
    out = run(["lsblk", "-J", "-s", "-o", "LABEL,MODEL,TRAN,ROTA,RM,TYPE", device])
    try:
        nodes = json.loads(out.stdout).get("blockdevices", [])
    except ValueError:
        return {}
    info = {}
    stack = list(nodes)
    while stack:
        node = stack.pop()
        if node.get("label") and "label" not in info:
            info["label"] = node["label"]
        if node.get("type") == "disk":
            info["model"] = (node.get("model") or "").strip()
            info["transport"] = node.get("tran") or ""
            info["rotational"] = bool(node.get("rota"))
            info["removable"] = bool(node.get("rm"))
        stack.extend(node.get("children") or [])
    return info


def drives():
    by_device = {}
    for m in real_mounts():
        if m["target"] in SKIP_TARGETS:
            continue
        by_device.setdefault(m["device"], []).append(m)

    result = []
    for device, mounts in by_device.items():
        mounts.sort(key=lambda m: (len(m["target"]), m["target"]))
        primary = mounts[0]
        info = device_info(device)
        is_system = primary["target"] == "/"
        label = info.get("label") or ("System" if is_system else os.path.basename(primary["target"]) or device)
        result.append({
            "device": device,
            "label": label,
            "system": is_system,
            "model": info.get("model", ""),
            "transport": info.get("transport", ""),
            "rotational": info.get("rotational", False),
            "removable": info.get("removable", False),
            "fstype": primary["fstype"],
            "mount": primary["target"],
            "mounts": [m["target"] for m in mounts],
            "size": primary["size"],
            "used": primary["used"],
            "avail": primary["avail"],
        })
    # System drive first, then by label.
    result.sort(key=lambda d: (not d["system"], d["label"].lower()))
    return result


def du(args):
    out = run(["du", "-x", "-B1"] + args)
    sizes = {}
    for line in out.stdout.splitlines():
        size, _, path = line.partition("\t")
        if path:
            sizes[path] = int(size)
    denied = sum(1 for line in out.stderr.splitlines() if "ermission denied" in line)
    return sizes, denied


def scan(path):
    path = os.path.realpath(path)
    if not os.path.isdir(path):
        return {"path": path, "error": "Not a folder", "entries": [], "total": 0, "denied": 0}

    sizes, denied = du(["-a", "-d1", "--", path])
    total = sizes.pop(path, 0)
    entries = {p: s for p, s in sizes.items() if os.path.dirname(p) == path}

    # Other mounts of the same device nested below this path (btrfs subvolumes
    # like /home and /var/log under /) are skipped by du -x, so measure them
    # separately and credit them to the child folder they live under.
    device = None
    mounts = real_mounts()
    for m in sorted(mounts, key=lambda m: len(m["target"]), reverse=True):
        if path == m["target"] or path.startswith(m["target"].rstrip("/") + "/"):
            device = m["device"]
            break
    prefix = path.rstrip("/") + "/"
    for m in mounts:
        target = m["target"]
        if m["device"] != device or not target.startswith(prefix) or target == path:
            continue
        nested, nested_denied = du(["-s", "--", target])
        size = nested.get(target, 0)
        denied += nested_denied
        child = prefix + target[len(prefix):].split("/", 1)[0]
        entries[child] = entries.get(child, 0) + size
        total += size

    items = []
    for p, size in entries.items():
        items.append({
            "name": os.path.basename(p),
            "path": p,
            "size": size,
            "dir": os.path.isdir(p) and not os.path.islink(p),
        })
    items.sort(key=lambda e: e["size"], reverse=True)
    return {"path": path, "total": total, "entries": items, "denied": denied}


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "drives":
        print(json.dumps(drives()))
    elif len(sys.argv) >= 3 and sys.argv[1] == "scan":
        print(json.dumps(scan(sys.argv[2])))
    else:
        print("usage: disk-usage.py drives | scan <path>", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
