#!/usr/bin/env python3
"""status.py — Health and latency check across all Ultimate Toolbox subsystems."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path
import urllib.request
import urllib.error

TOOLBOX_ROOT = Path(__file__).resolve().parent.parent

def check_gemini_station() -> dict:
    token_file = Path.home() / ".flossi" / "station.token"
    token = token_file.read_text().strip() if token_file.exists() else ""
    url = "http://127.0.0.1:19826/command"
    payload = json.dumps({
        "id": f"health_{int(time.time()*1000)}",
        "action": "exec",
        "code": "({ title: document.title, url: window.location.href })",
        "session": "gemini",
        "contextId": "4u89suza"
    }).encode("utf-8")

    t0 = time.time()
    try:
        req = urllib.request.Request(url, data=payload, headers={
            "Content-Type": "application/json",
            "X-Station-Token": token
        })
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            data = json.loads(resp.read().decode())
            rtt = (time.time() - t0) * 1000.0
            val = data.get("result", {}).get("value", {})
            return {
                "name": "Gemini Station (Rust CDP)",
                "status": "ONLINE 🟢",
                "port": 19826,
                "latency_ms": round(rtt, 2),
                "title": val.get("title", "N/A"),
                "url": val.get("url", "N/A")
            }
    except Exception as e:
        return {
            "name": "Gemini Station (Rust CDP)",
            "status": "OFFLINE 🔴",
            "port": 19826,
            "error": str(e)
        }

def check_opencli() -> dict:
    t0 = time.time()
    try:
        req = urllib.request.Request("http://127.0.0.1:19825/command", data=b'{"id":"ping","action":"ping"}', headers={
            "Content-Type": "application/json",
            "X-OpenCLI": "1"
        })
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            rtt = (time.time() - t0) * 1000.0
            return {"name": "OpenCLI Daemon", "status": "ONLINE 🟢", "port": 19825, "latency_ms": round(rtt, 2)}
    except Exception:
        return {"name": "OpenCLI Daemon", "status": "STANDBY / OFFLINE ⚪", "port": 19825}

def check_omniflow() -> dict:
    try:
        sys.path.insert(0, str(TOOLBOX_ROOT))
        import omniflow
        from omniflow import Pipe, AsyncPipe, Result
        return {"name": "Omniflow Functional Media Toolkit", "status": "READY 🟢", "version": "1.1"}
    except Exception as e:
        return {"name": "Omniflow Functional Media Toolkit", "status": "ERROR 🔴", "error": str(e)}

def check_security_vault() -> dict:
    try:
        sys.path.insert(0, str(TOOLBOX_ROOT / "security-vault"))
        import vault
        items = vault.list_()
        return {"name": "macOS Keychain Security Vault", "status": f"ACTIVE 🟢 ({len(items)} accounts managed)"}
    except Exception as e:
        return {"name": "macOS Keychain Security Vault", "status": "ERROR 🔴", "error": str(e)}

def main():
    print("=" * 68)
    print(" ⚡ ULTIMATE TOOLBOX SUBSYSTEM TELEMETRY")
    print("=" * 68)

    checks = [
        check_gemini_station(),
        check_opencli(),
        check_omniflow(),
        check_security_vault()
    ]

    for c in checks:
        print(f"• {c['name']:<35} : {c['status']}")
        if "latency_ms" in c:
            print(f"  └─ Latency: {c['latency_ms']} ms | Port: {c.get('port')}")
        if "title" in c and c['title'] != 'N/A':
            print(f"  └─ Active Target: {c['title'][:55]}")
        if "error" in c and "ONLINE" not in c['status'] and "READY" not in c['status'] and "ACTIVE" not in c['status']:
            print(f"  └─ Notice: {c['error'][:60]}")

    print("=" * 68)

if __name__ == "__main__":
    main()
