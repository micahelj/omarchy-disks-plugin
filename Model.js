.pragma library

// Binary units with Windows-style labels, so a "2 TB" drive reads 1.8 TB here
// just like it does in Explorer.
function formatBytes(bytes) {
  var n = Number(bytes) || 0
  var units = ["B", "KB", "MB", "GB", "TB", "PB"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024
    i++
  }
  var digits = i === 0 || n >= 100 ? 0 : 1
  return n.toFixed(digits) + " " + units[i]
}

function usedFraction(drive) {
  if (!drive || !(drive.size > 0)) return 0
  return Math.max(0, Math.min(1, drive.used / drive.size))
}

function percent(drive) {
  return Math.round(usedFraction(drive) * 100)
}

function driveGlyph(drive) {
  if (!drive) return "󰋊"
  if (drive.removable || drive.transport === "usb") return "󰕓"
  return "󰋊"
}

function driveSubtitle(drive) {
  if (!drive) return ""
  return drive.model || drive.device || ""
}

function displayName(entry) {
  var name = String(entry && entry.name || "")
  if (/^\.Trash-\d+$/.test(name)) return "Trash"
  return name
}

// Breadcrumb from the drive root down to `path`.
function crumbs(drive, path) {
  if (!drive) return []
  var mount = drive.mount
  var list = [{ name: drive.label, path: mount }]
  if (!path || path === mount) return list
  var rest = path.slice(mount === "/" ? 1 : mount.length + 1)
  var acc = mount === "/" ? "" : mount
  var parts = rest.split("/")
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === "") continue
    acc += "/" + parts[i]
    list.push({ name: parts[i], path: acc })
  }
  return list
}

// Largest `limit` non-empty entries; everything else folds into one row.
function visibleEntries(scan, limit) {
  if (!scan || !scan.entries) return { rows: [], restCount: 0, restSize: 0 }
  var rows = []
  var restCount = 0
  var restSize = 0
  for (var i = 0; i < scan.entries.length; i++) {
    var e = scan.entries[i]
    if (rows.length < limit && e.size > 0) rows.push(e)
    else {
      restCount++
      restSize += e.size
    }
  }
  return { rows: rows, restCount: restCount, restSize: restSize }
}
