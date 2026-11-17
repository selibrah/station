//! Gemini web app support. This is the only site-specific code in the daemon:
//! the `--gemini` preset, the extra `/status` fields, and the prompt injector behind `/inject`.

use std::time::Duration;
use serde_json::{json, Value};

use crate::server::{eval_session, AppState};

pub const HOST: &str = "gemini.google.com";
pub const URL: &str = "https://gemini.google.com";
/// Folder under ~/.flossi from when the daemon was Gemini-only; `--gemini` keeps using it so the login survives.
pub const LEGACY_PROFILE: &str = "gemini_profile";

/// `/status` payload on a Gemini tab: the generic url/title plus generation and login state.
pub const STATUS_JS: &str = r#"(() => {
    const stopBtn = document.querySelector('button[aria-label*="Stop"]') || document.querySelector('button[aria-label*="Arrêter"]');
    const mcs = document.querySelectorAll('message-content, model-response');
    const lastMc = mcs && mcs.length > 0 ? mcs[mcs.length - 1] : null;
    let chars = 0;
    if (lastMc) {
        chars = lastMc.innerText.length;
    } else {
        const turns = document.querySelectorAll('model-response');
        const last = turns[turns.length - 1];
        chars = last ? (last.querySelector('.markdown')?.innerText.length || last.innerText.length) : 0;
    }
    return {
        isGenerating: !!stopBtn,
        chars: chars,
        url: window.location.href,
        title: document.title,
        // Logged-in Gemini shows the account avatar (it links to accounts.google.com/SignOutOptions).
        isLoggedIn: !!document.querySelector('a[href*="SignOutOptions"], a[aria-label*="Google Account"], a[aria-label*="Compte Google"]')
            && !window.location.href.includes('accounts.google.com'),
    };
})()"#;

/// Types a prompt into the chat editor of the `session` tab (main tab when None) and optionally sends it.
/// Written for Gemini's editor; the fallback selectors also cover ProseMirror editors and plain inputs.
pub async fn inject_prompt(
    state: &AppState,
    session: Option<&str>,
    prompt_text: &str,
    auto_send: bool,
) -> Result<Value, String> {
    let escaped_prompt = serde_json::to_string(prompt_text).unwrap_or_else(|_| "\"\"".to_string());
    let js = format!(r#"(() => {{
        let el = document.querySelector('rich-textarea div[contenteditable="true"]');
        if (!el) el = document.querySelector('div[contenteditable="true"].ProseMirror');
        if (!el) el = document.querySelector('div[contenteditable="true"]');
        if (!el) el = document.querySelector('textarea, input[type="text"]');
        if (!el) return {{ error: 'No input element found on active page' }};

        el.focus();
        if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {{
            el.value = {escaped_prompt};
            el.dispatchEvent(new Event('input', {{ bubbles: true }}));
            el.dispatchEvent(new Event('change', {{ bubbles: true }}));
            return {{ injected: true, chars: el.value.length }};
        }}

        const lines = {escaped_prompt}.split('\n');
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
    }})()"#);

    let res = eval_session(state, session, &js, 10000).await?;

    if auto_send {
        tokio::time::sleep(Duration::from_millis(220)).await;
        let click_js = r#"(() => {
            const editor = document.querySelector('.ql-editor, [contenteditable="true"]');
            if (editor) {
                const enterDown = new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true });
                const enterUp = new KeyboardEvent("keyup", { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true });
                editor.dispatchEvent(enterDown);
                editor.dispatchEvent(enterUp);
                return { sent: true, method: "enter_key" };
            }
            const btn = document.querySelector('button[aria-label*="Envoyer"]')
                || document.querySelector('button[aria-label*="Send"]')
                || document.querySelector('button[data-testid="send-button"]')
                || document.querySelector('button.send-button')
                || document.querySelector('button[type="submit"]');
            if (btn && !btn.disabled) {
                btn.click();
                return { sent: true, method: "button_click" };
            }
            return { sent: false, hasBtn: !!btn, disabled: btn ? btn.disabled : true };
        })()"#;
        let send_res = eval_session(state, session, click_js, 5000).await?;
        return Ok(json!({
            "injected": res,
            "send": send_res,
        }));
    }

    Ok(res)
}
