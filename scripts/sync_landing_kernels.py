#!/usr/bin/env python3
"""Deterministic extractor that pulls verbatim DOM/CDP JavaScript kernels from
`daemon/src/dom.rs` and verbatim MCP JSON-RPC schemas from `daemon/src/mcp.rs`
into `landing/station-kernels.js`.

Usage:
  python3 scripts/sync_landing_kernels.py          # regenerate landing/station-kernels.js
  python3 scripts/sync_landing_kernels.py --check  # exit 1 if landing/station-kernels.js is stale
"""
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOM_RS_PATH = os.path.join(ROOT, "daemon", "src", "dom.rs")
MCP_RS_PATH = os.path.join(ROOT, "daemon", "src", "mcp.rs")
CARGO_TOML_PATH = os.path.join(ROOT, "daemon", "Cargo.toml")
OUT_JS_PATH = os.path.join(ROOT, "landing", "station-kernels.js")


def extract_rust_raw_format_template(rs_source: str, fn_name: str) -> str:
    """Extracts the verbatim `r#\"...\"#` format template inside `pub fn <fn_name>`."""
    fn_pat = re.compile(rf"pub\s+fn\s+{re.escape(fn_name)}\b.*?\{{", re.S)
    m = fn_pat.search(rs_source)
    if not m:
        raise RuntimeError(f"Could not find `pub fn {fn_name}` in {DOM_RS_PATH}")
    tail = rs_source[m.end():]
    raw_pat = re.compile(r'r#"(.*?)"#', re.S)
    rm = raw_pat.search(tail)
    if not rm:
        raise RuntimeError(f"Could not find raw string r#\"...\"# in `pub fn {fn_name}`")
    return rm.group(1)


def extract_mcp_json_array(mcp_source: str, fn_name: str):
    """Extracts and JSON-validates `fn <fn_name>() -> Value { json!([ ... ]) }`."""
    # Use balanced bracket scan for robustness against nested arrays in inputSchema
    start_m = re.search(rf"fn\s+{re.escape(fn_name)}\s*\(\)\s*->\s*Value\s*\{{", mcp_source)
    if not start_m:
        raise RuntimeError(f"Could not find `fn {fn_name}` in {MCP_RS_PATH}")
    idx = mcp_source.find("json!(", start_m.end())
    if idx == -1:
        raise RuntimeError(f"Could not find `json!(` in `fn {fn_name}`")
    arr_start = mcp_source.find("[", idx)
    if arr_start == -1:
        raise RuntimeError(f"Could not find `[` inside `fn {fn_name}`")

    depth = 0
    in_str = False
    escape = False
    arr_end = -1
    for i in range(arr_start, len(mcp_source)):
        ch = mcp_source[i]
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
                if depth == 0:
                    arr_end = i + 1
                    break
    if arr_end == -1:
        raise RuntimeError(f"Unbalanced brackets in `fn {fn_name}`")

    raw_json = mcp_source[arr_start:arr_end]
    return json.loads(raw_json)


def build_bundle() -> str:
    with open(DOM_RS_PATH, "r", encoding="utf-8") as f:
        dom_rs = f.read()
    with open(MCP_RS_PATH, "r", encoding="utf-8") as f:
        mcp_rs = f.read()
    with open(CARGO_TOML_PATH, "r", encoding="utf-8") as f:
        cargo_toml = f.read()

    ver_m = re.search(r'^version\s*=\s*"([^"]+)"', cargo_toml, re.M)
    version = ver_m.group(1) if ver_m else "0.4.0"

    proto_m = re.search(r'const\s+MCP_PROTOCOL_VERSION:\s*&str\s*=\s*"([^"]+)"', mcp_rs)
    mcp_proto = proto_m.group(1) if proto_m else "2024-11-05"

    instr_m = re.search(r'"instructions":\s*"((?:[^"\\]|\\.)*)"', mcp_rs)
    mcp_instructions = json.loads(f'"{instr_m.group(1)}"') if instr_m else ""

    snap_tpl = extract_rust_raw_format_template(dom_rs, "build_snapshot_js")
    act_tpl = extract_rust_raw_format_template(dom_rs, "build_act_js")
    read_tpl = extract_rust_raw_format_template(dom_rs, "build_read_js")
    upload_tpl = extract_rust_raw_format_template(dom_rs, "build_upload_attach_js")

    tools = extract_mcp_json_array(mcp_rs, "tool_definitions")
    resources = extract_mcp_json_array(mcp_rs, "resource_definitions")
    prompts = extract_mcp_json_array(mcp_rs, "prompt_definitions")

    dom_sha = hashlib.sha256(dom_rs.encode("utf-8")).hexdigest()[:16]
    mcp_sha = hashlib.sha256(mcp_rs.encode("utf-8")).hexdigest()[:16]

    payload = {
        "meta": {
            "version": version,
            "mcp_protocol_version": mcp_proto,
            "dom_rs_sha256_prefix": dom_sha,
            "mcp_rs_sha256_prefix": mcp_sha,
            "tool_count": len(tools),
            "resource_count": len(resources),
            "prompt_count": len(prompts),
        },
        "templates": {
            "snapshot": snap_tpl,
            "act": act_tpl,
            "read": read_tpl,
            "upload_attach": upload_tpl,
        },
        "mcp": {
            "instructions": mcp_instructions,
            "tools": tools,
            "resources": resources,
            "prompts": prompts,
        },
    }

    payload_json = json.dumps(payload, indent=2, ensure_ascii=False)

    return f"""/* AUTO-GENERATED BY scripts/sync_landing_kernels.py — DO NOT EDIT BY HAND.
 * Ground-truth sources:
 *   - daemon/src/dom.rs (sha256:{dom_sha})
 *   - daemon/src/mcp.rs (sha256:{mcp_sha})
 * Run `python3 scripts/sync_landing_kernels.py --check` in CI to enforce zero drift.
 */
(function (root) {{
  "use strict";

  const BUNDLE = {payload_json};

  /**
   * Reproduces Rust `format!` on a raw-string template (`r#\"...\"#`):
   * substitutes named `{{key}}` placeholders and unescapes `{{{{` -> `{{` and `}}}}` -> `}}`
   * in a single deterministic pass so substituted JSON values are never mutated.
   */
  function rustFormat(template, vars) {{
    return template.replace(/\\{{\\{{|\\}}\\}}|\\{{([a-zA-Z0-9_]+)\\}}/g, function (match, name) {{
      if (match === "{{{{") return "{{";
      if (match === "}}}}") return "}}";
      return Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : match;
    }});
  }}

  function clampInt(val, lo, hi, fallback) {{
    const n = Number.isFinite(Number(val)) ? Math.trunc(Number(val)) : fallback;
    return Math.max(lo, Math.min(hi, n));
  }}

  const StationKernels = {{
    META: BUNDLE.meta,
    MCP: BUNDLE.mcp,

    buildSnapshotJs: function (viewportOnly, maxElements) {{
      const vp = viewportOnly ? "true" : "false";
      const maxEl = clampInt(maxElements, 10, 500, 120);
      return rustFormat(BUNDLE.templates.snapshot, {{
        vp_only: vp,
        max_el: maxEl
      }});
    }},

    buildActJs: function (params) {{
      const p = params || {{}};
      const actionJson = JSON.stringify(String(p.action || "click").toLowerCase());
      const targetJson = JSON.stringify(p.target != null ? String(p.target) : "");
      const valueJson = JSON.stringify(p.value != null ? String(p.value) : "");
      return rustFormat(BUNDLE.templates.act, {{
        action_json: actionJson,
        target_json: targetJson,
        value_json: valueJson
      }});
    }},

    buildReadJs: function (maxChars) {{
      const cap = clampInt(maxChars, 1000, 250000, 40000);
      return rustFormat(BUNDLE.templates.read, {{
        cap: cap
      }});
    }},

    buildUploadAttachJs: function (selectorOrRef) {{
      const selJson = JSON.stringify(selectorOrRef != null ? String(selectorOrRef) : "");
      return rustFormat(BUNDLE.templates.upload_attach, {{
        sel_json: selJson
      }});
    }},

    /** Formats an MCP JSON-RPC 2.0 response envelope identically to `daemon/src/mcp.rs`. */
    formatMcpToolReply: function (id, text, isError) {{
      return {{
        jsonrpc: "2.0",
        id: id,
        result: {{
          content: [{{ type: "text", text: String(text) }}],
          isError: Boolean(isError)
        }}
      }};
    }}
  }};

  if (typeof module !== "undefined" && module.exports) {{
    module.exports = StationKernels;
  }}
  root.StationKernels = StationKernels;
}})(typeof globalThis !== "undefined" ? globalThis : window);
"""


def main() -> int:
    expected = build_bundle()
    if "--check" in sys.argv:
        if not os.path.exists(OUT_JS_PATH):
            print(f"FAIL: {OUT_JS_PATH} is missing. Run `python3 scripts/sync_landing_kernels.py`.", file=sys.stderr)
            return 1
        with open(OUT_JS_PATH, "r", encoding="utf-8") as f:
            actual = f.read()
        if actual != expected:
            print(
                "FAIL: landing/station-kernels.js is out of sync with daemon/src/{dom,mcp}.rs!\n"
                "Run `python3 scripts/sync_landing_kernels.py` to sync.",
                file=sys.stderr,
            )
            return 1
        print("OK: landing/station-kernels.js matches daemon/src/dom.rs and daemon/src/mcp.rs byte-for-byte.")
        return 0

    with open(OUT_JS_PATH, "w", encoding="utf-8") as f:
        f.write(expected)
    print(f"Generated {OUT_JS_PATH} ({len(expected):,} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
