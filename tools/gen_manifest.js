#!/usr/bin/env node
/**
 * Generates manifest.lua -- the release description easyhover_suite.lua fetches over HTTPS.
 *
 *   node tools/gen_manifest.js
 *
 * Run this after ANY change to a role's files, or the Suite will keep telling computers they
 * are current when they are not. tests/run_suite.sh asserts the manifest is in sync, so the
 * test suite catches a forgotten run.
 *
 * The manifest is DATA: a plain Lua table constructor, parsed on the computer with
 * textutils.unserialise in an empty environment. It cannot execute anything.
 */

"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const REPO = "https://raw.githubusercontent.com/maar-10/EasyHover/main";
const SCHEMA = 1; // bump ONLY when persisted config layout changes incompatibly

/**
 * The roles. `status: "released"` means it has files and can be installed; `"prepared"` means
 * the role exists in the design and is reserved, but nothing ships for it yet -- the Suite
 * offers it, says so plainly, and refuses to pretend it installed something.
 *
 * `dirs`     directories owned by the role. The Suite may DELETE inside these when repairing a
 *            corrupt install, so nothing the operator owns may ever live in one.
 * `configs`  persisted settings. Never deleted, always backed up, extended in place.
 * `luaPath`  prefix added to package.path so the Suite can require the role's own config module
 *            to extend a saved config with newly added defaults.
 */
const ROLES = {
  flight: {
    title: "Flight computer",
    blurb: "Thrusters, sensors, pilot inputs, PID loops. One per craft. No UI.",
    status: "released",
    dirs: ["flight"],
    // The flight role keeps its own lib/, so it does not ship shared/ wholesale -- but the build
    // stamp has to be readable HERE too, or the flight computer cannot say which build it is
    // running. Named explicitly rather than pulling in the whole directory.
    extraFiles: [{ src: "shared/install.lua", dst: "shared/install.lua" }],
    launcher: { src: "launchers/flight.lua", dst: "startup.lua" },
    entry: "flight/startup.lua",
    luaPath: "/flight",
    configs: ["/eh_flight_config.tbl"],
  },
  ui_main: {
    title: "Main display",
    blurb: "Overhead engine + fuel panel and the configuration screens. Drives every assigned monitor.",
    status: "released",
    dirs: ["ui_main", "shared"],
    // The vendored Basalt full build installs at /basalt.lua so `require("basalt")` resolves.
    // Pinned commit f6cde73 -- the same build EasyKey and DriveByWire use.
    extraFiles: [{ src: "vendor/basalt-full.lua", dst: "basalt.lua" }],
    launcher: { src: "launchers/ui_main.lua", dst: "startup.lua" },
    entry: "ui_main/startup.lua",
    luaPath: "/ui_main",
    configs: ["/eh_ui_main_config.tbl"],
  },
  gps_beacon: {
    title: "GPS beacon",
    blurb: "One of four world-anchored hosts that let the craft locate itself. Answers CC's own"
      + " gps.locate() pings and reports link status and constellation quality.",
    status: "released",
    dirs: ["gps_beacon", "shared"],
    // NO BASALT. A beacon runs on a BASIC computer, which has no mouse -- mouse_click is only
    // generated on advanced ones, so a panel of buttons there is entirely inert. The screen is
    // plain `term`, keyboard-driven, and 300KB lighter on each of four computers.
    launcher: { src: "launchers/gps_beacon.lua", dst: "startup.lua" },
    entry: "gps_beacon/startup.lua",
    luaPath: "/gps_beacon",
    configs: ["/eh_gps_beacon_config.tbl"],
  },
  nav: {
    title: "Navigation computer",
    blurb: "Position fixing over GPS, waypoints, and the fix relay onto the craft's cable."
      + " Needs an ender modem AND a wired one.",
    status: "released",
    dirs: ["nav", "shared"],
    // NO Basalt: the screen has to TYPE things -- a waypoint name and three coordinates -- and a
    // mouse helps with neither. Plain `term`, keyboard-driven, same as the beacon.
    launcher: { src: "launchers/nav.lua", dst: "startup.lua" },
    entry: "nav/startup.lua",
    luaPath: "/nav",
    configs: ["/eh_nav_config.tbl", "/eh_waypoints.tbl", "/eh_routes.tbl"],
  },
  ui_pfd: {
    title: "Primary flight display",
    blurb: "Attitude and flight-path indicator. Its own computer so the refresh rate is free.",
    status: "prepared",
    dirs: ["ui_pfd"],
    configs: ["/eh_ui_pfd_config.tbl"],
    luaPath: "/ui_pfd",
  },
  ui_prox: {
    title: "Proximity display",
    blurb: "Laser proximity warnings per vehicle surface.",
    status: "prepared",
    dirs: ["ui_prox"],
    configs: ["/eh_ui_prox_config.tbl"],
    luaPath: "/ui_prox",
  },
  ui_aux: {
    title: "Aux control",
    blurb: "Lights, doors, landing gear via redstone relays.",
    status: "prepared",
    dirs: ["ui_aux"],
    configs: ["/eh_ui_aux_config.tbl"],
    luaPath: "/ui_aux",
  },
  music: {
    title: "Entertainment",
    blurb: "Search, playlists and DFPWM streaming. Needs an external transcode service.",
    status: "prepared",
    dirs: ["music"],
    configs: ["/eh_music_config.tbl"],
    luaPath: "/music",
  },
  ground: {
    title: "Ground station",
    blurb: "Ender-modem telemetry receiver. Advisory only -- it can never command the craft.",
    status: "prepared",
    dirs: ["ground"],
    configs: ["/eh_ground_config.tbl"],
    luaPath: "/ground",
  },
};

/** Files never shipped to a computer even though they live in a role directory. */
const EXCLUDE = [/\.craftos\//, /(^|\/)backup\//, /\.md$/i];

/**
 * FNV-1a, 32-bit, lower-case hex. Must match checksum() in easyhover_suite.lua byte for byte;
 * tests/run_suite.sh asserts they agree.
 *
 * Not a cryptographic hash and not pretending to be one. The trust root is HTTPS to a pinned
 * raw.githubusercontent.com URL; this answers "did this file change" and "did the download
 * arrive intact", paired with the byte size.
 */
function fnv1a(text) {
  const buf = Buffer.from(text, "utf8");
  let h = 2166136261;
  for (const b of buf) {
    h = (h ^ b) >>> 0; // force unsigned: JS ^ yields int32 and the halves below assume unsigned
    // 32-bit multiply by 16777619 in 16-bit halves. The naive product reaches ~7.2e16, past the
    // 2^53 exact-integer limit of Lua's doubles, so both sides must split it identically.
    const lo = h % 65536;
    const hi = (h - lo) / 65536;
    h = (((hi * 16777619) % 65536) * 65536 + lo * 16777619) % 4294967296;
  }
  return h.toString(16).padStart(8, "0");
}

function readNormalised(absolute) {
  return fs.readFileSync(absolute, "utf8").replace(/\r\n/g, "\n");
}

function walk(relativeDir, out) {
  const absolute = path.join(ROOT, relativeDir);
  if (!fs.existsSync(absolute)) return out;
  for (const entry of fs.readdirSync(absolute, { withFileTypes: true }).sort((a, b) =>
    a.name.localeCompare(b.name))) {
    const rel = `${relativeDir}/${entry.name}`;
    if (EXCLUDE.some((re) => re.test(rel))) continue;
    if (entry.isDirectory()) {
      walk(rel, out);
    } else if (entry.name.endsWith(".lua")) {
      out.push(rel);
    }
  }
  return out;
}

function luaStr(s) {
  return `"${String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

/** A Lua table-constructor literal, deterministic so the manifest only changes when bytes do. */
function luaValue(v, indent) {
  const pad = "  ".repeat(indent);
  const padIn = "  ".repeat(indent + 1);
  if (typeof v === "string") return luaStr(v);
  if (typeof v === "number") return String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  if (Array.isArray(v)) {
    if (v.length === 0) return "{}";
    const items = v.map((item) => `${padIn}${luaValue(item, indent + 1)},`);
    return `{\n${items.join("\n")}\n${pad}}`;
  }
  const keys = Object.keys(v).sort();
  if (keys.length === 0) return "{}";
  const items = keys.map((k) => `${padIn}[${luaStr(k)}] = ${luaValue(v[k], indent + 1)},`);
  return `{\n${items.join("\n")}\n${pad}}`;
}

// ---------------------------------------------------------------- build

const digestParts = [];
const roleTable = {};

for (const roleName of Object.keys(ROLES).sort()) {
  const spec = ROLES[roleName];
  const files = [];

  if (spec.status === "released") {
    const sources = [];
    for (const dir of spec.dirs) walk(dir, sources);
    if (spec.launcher) sources.push(spec.launcher.src);
    for (const extra of spec.extraFiles || []) sources.push(extra.src);

    for (const src of sources) {
      const absolute = path.join(ROOT, src);
      if (!fs.existsSync(absolute)) {
        console.error(`  ! missing file for role ${roleName}: ${src}`);
        process.exitCode = 1;
        continue;
      }
      const body = readNormalised(absolute);
      let dst = src;
      if (spec.launcher && src === spec.launcher.src) {
        dst = spec.launcher.dst;
      } else {
        for (const extra of spec.extraFiles || []) {
          if (extra.src === src) dst = extra.dst;
        }
      }
      const entry = { src, dst, size: Buffer.byteLength(body, "utf8"), sum: fnv1a(body) };
      files.push(entry);
      digestParts.push(`${roleName}:${dst}:${entry.sum}:${entry.size}`);
    }
    files.sort((a, b) => a.dst.localeCompare(b.dst));
  }

  roleTable[roleName] = {
    title: spec.title,
    blurb: spec.blurb,
    status: spec.status,
    dirs: spec.dirs,
    configs: spec.configs || [],
    luaPath: spec.luaPath || "",
    entry: spec.entry || "",
    files,
  };
}

const updaterBody = readNormalised(path.join(ROOT, "easyhover_suite.lua"));
const manifest = {
  version: fnv1a(digestParts.sort().join("|")).slice(0, 12),
  schema: SCHEMA,
  base: REPO,
  updater: { size: Buffer.byteLength(updaterBody, "utf8"), sum: fnv1a(updaterBody) },
  roles: roleTable,
};

const header = `-- EasyHover release manifest. GENERATED by tools/gen_manifest.js -- do not edit by hand.
--
-- Read by easyhover_suite.lua over HTTPS and parsed with textutils.unserialise, so this is a
-- plain data table: no function calls, no \`return\`, nothing executable.
--
-- \`sum\` is FNV-1a 32-bit over the file's LF-normalised bytes, paired with \`size\`. Together they
-- answer "did this change" and "did the download arrive intact". The trust root is HTTPS to the
-- pinned raw.githubusercontent.com URL, not this checksum.
--
-- \`version\` is a digest of every shipped file's sum+size, so it moves only when shipped bytes
-- move. \`schema\` is the persisted-config generation: a bump means saved configs get backed up.
--
-- \`status = "prepared"\` roles are reserved in the design but ship no files yet. The Suite
-- offers them and says so rather than pretending an empty install succeeded.
`;

const out = `${header}${luaValue(manifest, 0)}\n`;
const target = path.join(ROOT, "manifest.lua");

// --selftest: print the reference checksums. tests/run_suite.sh compares these against the
// values test_suite.lua asserts on the Lua side, so a divergence between the two
// implementations is caught rather than silently invalidating every computer's install.
if (process.argv.includes("--selftest")) {
  console.log(`empty=${fnv1a("")}`);
  console.log(`a=${fnv1a("a")}`);
  console.log(`hello=${fnv1a("hello")}`);
  process.exit(0);
}

// --check: is the committed manifest in sync with the working tree? Forgetting to regenerate
// would make the Suite tell every computer it is current when it is not.
if (process.argv.includes("--check")) {
  const existing = fs.existsSync(target) ? fs.readFileSync(target, "utf8") : "";
  if (existing.replace(/\r\n/g, "\n") === out) {
    console.log(`manifest.lua is in sync (version ${manifest.version})`);
    process.exit(0);
  }
  console.error("manifest.lua is OUT OF SYNC with the working tree.");
  console.error("  run: node tools/gen_manifest.js");
  process.exit(1);
}

fs.writeFileSync(target, out, "utf8");

let released = 0;
let prepared = 0;
for (const name of Object.keys(roleTable)) {
  if (roleTable[name].status === "released") released++;
  else prepared++;
}
console.log(`manifest.lua written: version ${manifest.version}, schema ${manifest.schema}`);
console.log(`  ${released} released role(s), ${prepared} prepared`);
for (const name of Object.keys(roleTable).sort()) {
  const r = roleTable[name];
  console.log(`  ${r.status === "released" ? "*" : "-"} ${name.padEnd(9)} ${r.files.length} file(s)`);
}
