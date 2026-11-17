#!/usr/bin/env python3
"""fast_opencli.py — Direct HTTP RPC Client for OpenCLI Daemon.

Bypasses CLI subprocess overhead (~310ms -> ~11ms).
Runs directly against gemini-station: http://127.0.0.1:19826/command with header
X-Station-Token (from ~/.flossi/station.token). 19825 is OpenCLI's own daemon.
"""

from __future__ import annotations
import argparse
import asyncio
import json
import re
import sys
import time
from typing import Any, NamedTuple
import urllib.request
import urllib.error


def _station_token() -> str:
    try:
        with open(__import__("os").path.expanduser("~/.flossi/station.token")) as f:
            return f.read().strip()
    except OSError:
        return ""


class EvalResult(NamedTuple):
    ok: bool
    data: Any = None
    error: str | None = None
    latency_ms: float = 0.0


class FastOpenCLIClient:
    def __init__(self, profile_id: str | None = None, session: str = "gemini", daemon_port: int = 19826):
        import os
        self.profile_id = profile_id or os.environ.get("OPENCLI_PROFILE", "3u8czsjm")
        self.session = session
        self.daemon_port = daemon_port
        self.daemon_url = f"http://127.0.0.1:{daemon_port}/command"

    def eval_js_sync(self, javascript_code: str, timeout: int = 30000) -> EvalResult:
        """Synchronous HTTP evaluation using standard library urllib."""
        start = time.perf_counter()
        payload = json.dumps({
            "id": f"cmd_{int(time.time()*1000)}",
            "action": "exec",
            "code": javascript_code,
            "session": self.session,
            "contextId": self.profile_id,
            "timeout": timeout,
        }).encode("utf-8")
        req = urllib.request.Request(
            self.daemon_url,
            data=payload,
            headers={"Content-Type": "application/json", "X-Station-Token": _station_token()},
            method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=30.0) as resp:
                elapsed = (time.perf_counter() - start) * 1000
                res_data = json.loads(resp.read().decode("utf-8"))
                return EvalResult(
                    ok=res_data.get("ok", False),
                    data=res_data.get("data"),
                    error=res_data.get("error"),
                    latency_ms=round(elapsed, 2)
                )
        except Exception as e:
            elapsed = (time.perf_counter() - start) * 1000
            return EvalResult(ok=False, error=str(e), latency_ms=round(elapsed, 2))

    async def eval_js(self, javascript_code: str) -> EvalResult:
        """Asynchronous non-blocking evaluation."""
        return await asyncio.to_thread(self.eval_js_sync, javascript_code)

    async def inject_prompt(self, prompt_text: str, auto_send: bool = True) -> dict[str, Any]:
        """CSP-Safe DOM Paragraph Synthesizer bypassing TrustedHTML."""
        escaped_prompt = json.dumps(prompt_text)
        injection_code = f"""(() => {{
          const el = document.querySelector('rich-textarea div[contenteditable="true"]');
          if (!el) return {{ error: 'No contenteditable input found' }};
          el.focus();
          const lines = {escaped_prompt}.split('\\n');
          const ps = lines.map(line => {{
            const p = document.createElement('p');
            p.textContent = line || ' ';
            return p;
          }});
          el.replaceChildren(...ps);
          const sel = window.getSelection();
          const range = document.createRange();
          range.selectNodeContents(el);
          range.collapse(false);
          sel.removeAllRanges();
          sel.addRange(range);
          document.execCommand('insertText', false, ' ');
          el.dispatchEvent(new InputEvent('input', {{ bubbles: true, cancelable: true, inputType: 'insertText', data: ' ' }}));
          el.dispatchEvent(new Event('change', {{ bubbles: true }}));
          return {{ injected: true, chars: el.innerText.length }};
        }})()"""
        res = await self.eval_js(injection_code)
        if not res.ok:
            raise RuntimeError(f"Prompt injection failed: {res.error}")

        if auto_send:
            # Allow Angular change-detection microtask to awaken Send button
            await asyncio.sleep(0.2)
            click_code = """(() => {
              const btn = document.querySelector('button[aria-label*="Send" i], button[aria-label*="Envoyer" i], button.send-button');
              if (btn && !btn.disabled) {
                btn.click();
                return { sent: true };
              }
              return { sent: false, hasBtn: !!btn, disabled: btn ? btn.disabled : true };
            })()"""
            click_res = await self.eval_js(click_code)
            return {"injected": res.data, "send": click_res.data}
        return res.data

    async def wait_for_completion(self, max_timeout_s: float = 120.0, poll_interval_s: float = 1.0) -> str:
        """Monitors generation completion using DOM stability without CPU-spinning."""
        start = time.time()
        last_chars = -1
        stable_cycles = 0

        check_code = """(() => {
          const stopBtn = document.querySelector('button[aria-label*="Stop" i], button[aria-label*="Interrompre" i], button[aria-label*="Arrêter" i]');
          const mcs = document.querySelectorAll('message-content, .model-response-text');
          const lastMc = mcs && mcs.length > 0 ? mcs[mcs.length - 1] : null;
          let chars = 0;
          if (lastMc) {
            chars = (lastMc.innerText || lastMc.textContent || '').trim().length;
          }
          return { isThinking: !!stopBtn, chars };
        })()"""

        has_started = False
        while (time.time() - start) < max_timeout_s:
            res = await self.eval_js(check_code)
            if res.ok and isinstance(res.data, dict):
                is_thinking = res.data.get("isThinking", False)
                chars = res.data.get("chars", 0)
                if is_thinking or chars > 50:
                    has_started = True

                if chars > 50 and chars == last_chars:
                    stable_cycles += 1
                else:
                    stable_cycles = 0
                last_chars = chars

                if has_started and not is_thinking and stable_cycles >= 2:
                    break
            await asyncio.sleep(poll_interval_s)

        extract_code = """(() => {
          const rcs = document.querySelectorAll('response-container');
          if (rcs && rcs.length > 0) {
            const lastRc = rcs[rcs.length - 1];
            const md = lastRc.querySelector('.markdown, message-content, div[class*="markdown"]');
            if (md && md.textContent && md.textContent.trim().length > 0) return md.textContent;
            if (lastRc.textContent && lastRc.textContent.trim().length > 0) return lastRc.textContent;
          }
          const mcs = document.querySelectorAll('message-content');
          if (mcs && mcs.length > 0) return mcs[mcs.length - 1].textContent || mcs[mcs.length - 1].innerText;
          const turns = document.querySelectorAll('model-response');
          const last = turns[turns.length - 1];
          return last ? (last.querySelector('.markdown')?.textContent || last.textContent || last.innerText) : '';
        })()"""
        final_res = await self.eval_js(extract_code)
        return final_res.data if final_res.ok else ""

    def extract_json_payload(self, text: str) -> dict[str, Any] | None:
        """Strips model thinking blocks and parses structured JSON verdict."""
        cleaned = re.sub(r'<thought>.*?</thought>', '', text, flags=re.DOTALL)
        match = re.search(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```', cleaned, re.DOTALL)
        if match:
            try:
                return json.loads(match.group(1))
            except Exception:
                pass
        match_json_prefix = re.search(r'JSON\s*(\{[\s\S]*?\})', cleaned)
        if match_json_prefix:
            try:
                return json.loads(match_json_prefix.group(1))
            except Exception:
                pass
        match2 = re.search(r'(\{[\s\S]*"verdict"[\s\S]*\})', cleaned)
        if match2:
            try:
                return json.loads(match2.group(1))
            except Exception:
                pass
        match2 = re.search(r'(\{[\s\S]*"uncertain_words"[\s\S]*\})', cleaned)
        if match2:
            try:
                return json.loads(match2.group(1))
            except Exception:
                pass
        match3 = re.search(r'(\{[\s\S]*"clips"[\s\S]*\})', cleaned)
        if match3:
            try:
                return json.loads(match3.group(1))
            except Exception:
                pass
        return None


def main():
    parser = argparse.ArgumentParser(description="Fast OpenCLI Direct RPC Tool")
    parser.add_argument("--status", action="store_true", help="Check daemon connection & Chrome tab status")
    parser.add_argument("--eval", type=str, help="Evaluate raw JavaScript in Chrome tab")
    args = parser.parse_args()

    client = FastOpenCLIClient()
    if args.status:
        res = client.eval_js_sync("document.title")
        if res.ok:
            print(f"[FastOpenCLI] Daemon Port 19826 ONLINE. Latency: {res.latency_ms}ms")
            print(f"[FastOpenCLI] Active Tab Title: {res.data}")
        else:
            print(f"[FastOpenCLI] ERROR: {res.error}")
            sys.exit(1)
    elif args.eval:
        res = client.eval_js_sync(args.eval)
        print(f"Result (in {res.latency_ms}ms):", res.data if res.ok else f"ERROR: {res.error}")


if __name__ == "__main__":
    main()
