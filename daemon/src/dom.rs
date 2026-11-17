//! Agent-native DOM primitives: interactive Snapshot (`@e1` refs), deterministic Act
//! (React/Angular-compatible click/fill/press/select/scroll), Clean Markdown Reader,
//! and gesture-free File Upload via chunked DataTransfer.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Builds the JS payload for `/snapshot` — assigns `data-station-ref="e1..eN"` to visible
/// interactive elements and returns both structured elements and a compact LLM text map.
pub fn build_snapshot_js(viewport_only: bool, max_elements: usize) -> String {
    let vp_only = if viewport_only { "true" } else { "false" };
    let max_el = max_elements.clamp(10, 500);
    format!(
        r#"(() => {{
    const VIEWPORT_ONLY = {vp_only};
    const MAX_ELEMENTS = {max_el};
    const vw = window.innerWidth || document.documentElement.clientWidth || 1280;
    const vh = window.innerHeight || document.documentElement.clientHeight || 900;

    // Clear stale refs so numbers stay fresh and unambiguous
    document.querySelectorAll('[data-station-ref]').forEach(el => el.removeAttribute('data-station-ref'));

    const isVisible = (el) => {{
        if (!el || !(el instanceof Element)) return false;
        if (el.closest('[aria-hidden="true"], [hidden], template, script, style, noscript')) return false;
        const st = window.getComputedStyle(el);
        if (st.display === 'none' || st.visibility === 'hidden' || parseFloat(st.opacity) === 0) return false;
        const r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) return false;
        if (VIEWPORT_ONLY && (r.bottom < 0 || r.top > vh || r.right < 0 || r.left > vw)) return false;
        return true;
    }};

    const clean = (s, max = 110) => (s || '').replace(/\s+/g, ' ').trim().slice(0, max);

    const getLabel = (el) => {{
        const aria = el.getAttribute('aria-label');
        if (aria) return clean(aria);
        const labelledBy = el.getAttribute('aria-labelledby');
        if (labelledBy) {{
            const txt = labelledBy.split(/\s+/).map(id => document.getElementById(id)?.innerText || '').join(' ');
            if (txt.trim()) return clean(txt);
        }}
        if (el.id) {{
            const lbl = document.querySelector(`label[for="${{CSS.escape(el.id)}}"]`);
            if (lbl && lbl.innerText) return clean(lbl.innerText);
        }}
        const parentLabel = el.closest('label');
        if (parentLabel && parentLabel.innerText) return clean(parentLabel.innerText);
        const ph = el.getAttribute('placeholder');
        if (ph) return clean(ph);
        const title = el.getAttribute('title');
        const txt = clean(el.innerText || el.textContent || el.value || '');
        return txt || clean(title || el.getAttribute('name') || '');
    }};

    const headings = [...document.querySelectorAll('h1, h2, h3')]
        .filter(isVisible)
        .slice(0, 20)
        .map(h => ({{ level: h.tagName.toLowerCase(), text: clean(h.innerText, 120) }}))
        .filter(h => h.text.length > 0);

    const selector = [
        'a[href]',
        'button',
        'input:not([type="hidden"])',
        'textarea',
        'select',
        'summary',
        '[contenteditable="true"]',
        '[role="button"]',
        '[role="link"]',
        '[role="tab"]',
        '[role="menuitem"]',
        '[role="checkbox"]',
        '[role="switch"]',
        '[role="combobox"]',
        '[role="searchbox"]',
        '[role="option"]'
    ].join(',');

    const candidates = [...document.querySelectorAll(selector)].filter(isVisible);
    const elements = [];
    const lines = [];
    let idx = 0;

    for (const el of candidates) {{
        if (elements.length >= MAX_ELEMENTS) break;
        // Skip nested interactive child when parent button/link already wraps it cleanly
        const parentInteractive = el.parentElement?.closest('button, a[href], [role="button"], [role="link"]');
        if (parentInteractive && candidates.includes(parentInteractive)) continue;

        const label = getLabel(el);
        const tag = el.tagName.toLowerCase();
        const type = (el.getAttribute('type') || '').toLowerCase();
        const role = (el.getAttribute('role') || (
            tag === 'a' ? 'link' :
            tag === 'button' ? 'button' :
            tag === 'select' ? 'select' :
            tag === 'textarea' ? 'textbox' :
            tag === 'input' ? (type || 'input') : 'interactive'
        )).toLowerCase();

        // Skip completely unlabeled decorative links/divs unless it is an input/file
        if (!label && tag !== 'input' && tag !== 'textarea' && tag !== 'select' && !el.isContentEditable) continue;

        idx += 1;
        const refId = `e${{idx}}`;
        el.setAttribute('data-station-ref', refId);

        const r = el.getBoundingClientRect();
        const href = tag === 'a' ? (el.href || '') : undefined;
        const val = ('value' in el && type !== 'password') ? clean(String(el.value || ''), 60) : undefined;
        const disabled = !!el.disabled || el.getAttribute('aria-disabled') === 'true';
        const inViewport = r.bottom >= 0 && r.top <= vh;

        elements.push({{
            ref: refId,
            tag,
            role,
            label,
            ...(type ? {{ type }} : {{}}),
            ...(val ? {{ value: val }} : {{}}),
            ...(href ? {{ href: href.slice(0, 180) }} : {{}}),
            ...(disabled ? {{ disabled: true }} : {{}}),
            in_viewport: inViewport,
            rect: {{ x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) }}
        }});

        let line = `[@${{refId}}] ${{role}}`;
        if (label) line += ` "${{label}}"`;
        if (val) line += ` value="${{val}}"`;
        if (disabled) line += ` (disabled)`;
        if (href && !href.startsWith('javascript:')) line += ` -> ${{href.slice(0, 100)}}`;
        lines.push(line);
    }}

    const maxScrollY = Math.max(0, document.documentElement.scrollHeight - vh);
    const header = [
        `Page: ${{clean(document.title, 140)}}`,
        `URL: ${{location.href}}`,
        `Scroll: ${{Math.round(window.scrollY)}} / ${{Math.round(maxScrollY)}} px (${{elements.length}} interactive refs)`
    ];
    if (headings.length) {{
        header.push('Headings: ' + headings.map(h => `[${{h.level}}] ${{h.text}}`).join(' | '));
    }}

    return {{
        title: document.title,
        url: location.href,
        scroll_y: Math.round(window.scrollY),
        max_scroll_y: Math.round(maxScrollY),
        element_count: elements.length,
        headings,
        elements,
        snapshot_text: header.join('\n') + '\n---\n' + lines.join('\n')
    }};
}})()"#
    )
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ActParams {
    /// "click" | "fill" | "press" | "select" | "hover" | "scroll" | "focus"
    pub action: String,
    /// Snapshot ref ("@e4" or "e4") or CSS selector ("button[type=submit]")
    pub target: Option<String>,
    /// Value for "fill"/"select", key name for "press" ("Enter"), or direction for "scroll" ("down"/"up"/"bottom"/"top")
    pub value: Option<String>,
    pub session: Option<String>,
    pub target_id: Option<String>,
}

/// Builds React/Vue/Angular-safe DOM interaction JS for `/act`.
pub fn build_act_js(params: &ActParams) -> String {
    let action_json = serde_json::to_string(&params.action.to_lowercase()).unwrap_or_else(|_| "\"click\"".into());
    let target_json = serde_json::to_string(params.target.as_deref().unwrap_or("")).unwrap_or_else(|_| "\"\"".into());
    let value_json = serde_json::to_string(params.value.as_deref().unwrap_or("")).unwrap_or_else(|_| "\"\"".into());

    format!(
        r#"(async () => {{
    const action = {action_json};
    const rawTarget = {target_json}.trim();
    const val = {value_json};

    if (action === 'scroll' && !rawTarget) {{
        const dir = (val || 'down').toLowerCase();
        const step = Math.round((window.innerHeight || 800) * 0.8);
        if (dir === 'top') window.scrollTo({{ top: 0, behavior: 'instant' }});
        else if (dir === 'bottom') window.scrollTo({{ top: document.documentElement.scrollHeight, behavior: 'instant' }});
        else if (dir === 'up') window.scrollBy({{ top: -step, behavior: 'instant' }});
        else if (!isNaN(Number(dir)) && dir !== '') window.scrollBy({{ top: Number(dir), behavior: 'instant' }});
        else window.scrollBy({{ top: step, behavior: 'instant' }});
        await new Promise(r => setTimeout(r, 80));
        return {{ ok: true, action: 'scroll', scroll_y: Math.round(window.scrollY) }};
    }}

    const resolveTarget = (t) => {{
        if (!t) return document.activeElement || document.body;
        const refMatch = t.match(/^@?(e\d+)$/i);
        if (refMatch) {{
            const byRef = document.querySelector(`[data-station-ref="${{refMatch[1].toLowerCase()}}"]`);
            if (byRef) return byRef;
        }}
        try {{
            return document.querySelector(t);
        }} catch (_) {{
            return null;
        }}
    }};

    const el = resolveTarget(rawTarget);
    if (!el) {{
        return {{ ok: false, error: `Target not found: '${{rawTarget}}'. Run snapshot first to refresh @eN refs.` }};
    }}

    if (el.scrollIntoView) {{
        el.scrollIntoView({{ block: 'center', inline: 'center', behavior: 'instant' }});
        await new Promise(r => setTimeout(r, 40));
    }}

    const rect = el.getBoundingClientRect();
    const cx = rect.left + rect.width / 2;
    const cy = rect.top + rect.height / 2;
    const mouseOpts = {{ bubbles: true, cancelable: true, clientX: cx, clientY: cy, view: window }};

    if (action === 'hover') {{
        el.dispatchEvent(new PointerEvent('pointerover', mouseOpts));
        el.dispatchEvent(new MouseEvent('mouseover', mouseOpts));
        el.dispatchEvent(new MouseEvent('mousemove', mouseOpts));
        return {{ ok: true, action: 'hover', tag: el.tagName.toLowerCase() }};
    }}

    if (action === 'focus') {{
        el.focus();
        return {{ ok: true, action: 'focus', tag: el.tagName.toLowerCase() }};
    }}

    if (action === 'click') {{
        el.dispatchEvent(new PointerEvent('pointerdown', mouseOpts));
        el.dispatchEvent(new MouseEvent('mousedown', mouseOpts));
        if (el.focus) el.focus();
        el.dispatchEvent(new PointerEvent('pointerup', mouseOpts));
        el.dispatchEvent(new MouseEvent('mouseup', mouseOpts));
        el.click();
        return {{
            ok: true,
            action: 'click',
            tag: el.tagName.toLowerCase(),
            text: (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 80),
            url: location.href
        }};
    }}

    if (action === 'fill' || action === 'type') {{
        el.focus();
        if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {{
            const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
            if (setter) setter.call(el, val);
            else el.value = val;
            el.dispatchEvent(new InputEvent('input', {{ bubbles: true, cancelable: true, inputType: 'insertText', data: val }}));
            el.dispatchEvent(new Event('change', {{ bubbles: true }}));
            return {{ ok: true, action: 'fill', tag: el.tagName.toLowerCase(), chars: val.length }};
        }}
        if (el.isContentEditable) {{
            const lines = val.split('\n');
            const nodes = lines.map(line => {{
                const p = document.createElement('p');
                p.textContent = line || ' ';
                return p;
            }});
            el.replaceChildren(...nodes);
            el.dispatchEvent(new InputEvent('input', {{ bubbles: true, cancelable: true, inputType: 'insertText', data: val }}));
            el.dispatchEvent(new Event('change', {{ bubbles: true }}));
            return {{ ok: true, action: 'fill', tag: 'contenteditable', chars: val.length }};
        }}
        return {{ ok: false, error: `Element <${{el.tagName.toLowerCase()}}> is not an input, textarea, or contenteditable` }};
    }}

    if (action === 'select') {{
        if (!(el instanceof HTMLSelectElement)) {{
            return {{ ok: false, error: `Element <${{el.tagName.toLowerCase()}}> is not a <select>` }};
        }}
        const opt = [...el.options].find(o => o.value === val || o.text.trim().toLowerCase() === val.trim().toLowerCase());
        if (!opt) return {{ ok: false, error: `No option matching '${{val}}'` }};
        el.value = opt.value;
        el.dispatchEvent(new Event('input', {{ bubbles: true }}));
        el.dispatchEvent(new Event('change', {{ bubbles: true }}));
        return {{ ok: true, action: 'select', selected: opt.text.trim(), value: opt.value }};
    }}

    if (action === 'press') {{
        const key = val || 'Enter';
        const codeMap = {{ Enter: 13, Escape: 27, Tab: 9, Backspace: 8, ArrowDown: 40, ArrowUp: 38 }};
        const keyCode = codeMap[key] || key.charCodeAt(0);
        const kOpts = {{ key, code: key, keyCode, which: keyCode, bubbles: true, cancelable: true }};
        el.dispatchEvent(new KeyboardEvent('keydown', kOpts));
        el.dispatchEvent(new KeyboardEvent('keypress', kOpts));
        el.dispatchEvent(new KeyboardEvent('keyup', kOpts));
        if (key === 'Enter' && el.form) {{
            if (el.form.requestSubmit) el.form.requestSubmit();
            else el.form.submit();
        }}
        return {{ ok: true, action: 'press', key }};
    }}

    if (action === 'scroll') {{
        const dir = (val || 'down').toLowerCase();
        const delta = dir === 'up' ? -400 : 400;
        el.scrollBy({{ top: delta, behavior: 'instant' }});
        return {{ ok: true, action: 'scroll', target: rawTarget }};
    }}

    return {{ ok: false, error: `Unsupported action '${{action}}'. Expected click, fill, press, select, hover, focus, or scroll.` }};
}})()"#
    )
}

/// Builds clean Readability-like Markdown extractor for `/read` (Agent-Reach killer, works on authenticated pages).
pub fn build_read_js(max_chars: usize) -> String {
    let cap = max_chars.clamp(1_000, 250_000);
    format!(
        r#"(() => {{
    const MAX_CHARS = {cap};
    const rawHtmlLen = document.documentElement?.outerHTML?.length || 0;

    // Pick primary content container if substantial, else body
    const pickRoot = () => {{
        const candidates = [
            document.querySelector('article'),
            document.querySelector('main'),
            document.querySelector('[role="main"]'),
            document.querySelector('#content, .content, .post-content, .markdown-body')
        ].filter(Boolean);
        const bodyLen = (document.body?.innerText || '').trim().length || 1;
        for (const c of candidates) {{
            const cLen = (c.innerText || '').trim().length;
            if (cLen > 280 && cLen >= bodyLen * 0.35) return c;
        }}
        return document.body || document.documentElement;
    }};

    const root = pickRoot().cloneNode(true);
    root.querySelectorAll([
        'script', 'style', 'noscript', 'svg', 'canvas', 'iframe', 'template',
        'nav', 'footer', '[aria-hidden="true"]', '[hidden]',
        '.cookie-banner', '#cookie-banner', '[id*="cookie" i][class*="banner" i]'
    ].join(',')).forEach(n => n.remove());

    const inlineMd = (node) => {{
        if (node.nodeType === Node.TEXT_NODE) {{
            return (node.nodeValue || '').replace(/\s+/g, ' ');
        }}
        if (node.nodeType !== Node.ELEMENT_NODE) return '';
        const tag = node.tagName.toLowerCase();
        if (tag === 'br') return '\n';
        const inner = [...node.childNodes].map(inlineMd).join('');
        if (!inner.trim() && tag !== 'img') return '';
        if (tag === 'strong' || tag === 'b') return `**${{inner.trim()}}** `;
        if (tag === 'em' || tag === 'i') return `*${{inner.trim()}}* `;
        if (tag === 'code' && node.parentElement?.tagName.toLowerCase() !== 'pre') return `\`${{inner.trim()}}\``;
        if (tag === 'a') {{
            const href = node.getAttribute('href') || '';
            if (!href || href.startsWith('#') || href.startsWith('javascript:')) return inner;
            try {{
                const abs = new URL(href, location.href).href;
                return `[${{inner.trim()}}](${{abs}})`;
            }} catch (_) {{
                return inner;
            }}
        }}
        return inner;
    }};

    const blocks = [];
    const walk = (node) => {{
        if (!node) return;
        if (node.nodeType === Node.TEXT_NODE) {{
            const t = (node.nodeValue || '').replace(/\s+/g, ' ').trim();
            if (t) blocks.push(t);
            return;
        }}
        if (node.nodeType !== Node.ELEMENT_NODE) return;
        const tag = node.tagName.toLowerCase();

        if (/^h[1-6]$/.test(tag)) {{
            const level = Number(tag[1]);
            const t = (node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim();
            if (t) blocks.push('\n' + '#'.repeat(level) + ' ' + t + '\n');
            return;
        }}
        if (tag === 'pre') {{
            const code = (node.textContent || '').trim();
            if (code) blocks.push('\n```\n' + code + '\n```\n');
            return;
        }}
        if (tag === 'li') {{
            const t = inlineMd(node).replace(/\s+/g, ' ').trim();
            if (t) blocks.push('- ' + t);
            return;
        }}
        if (tag === 'blockquote') {{
            const t = (node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim();
            if (t) blocks.push('> ' + t);
            return;
        }}
        if (tag === 'tr') {{
            const cells = [...node.querySelectorAll('th, td')].map(c => (c.innerText || c.textContent || '').replace(/\s+/g, ' ').trim().replace(/\|/g, '\\|'));
            if (cells.some(Boolean)) blocks.push('| ' + cells.join(' | ') + ' |');
            return;
        }}
        if (tag === 'p') {{
            const t = inlineMd(node).replace(/\s+/g, ' ').trim();
            if (t) blocks.push(t + '\n');
            return;
        }}
        for (const child of node.childNodes) walk(child);
    }};

    walk(root);
    let markdown = blocks.join('\n').replace(/\n{{3,}}/g, '\n\n').trim();
    if (!markdown) {{
        markdown = (document.body?.innerText || '').replace(/\n{{3,}}/g, '\n\n').trim();
    }}
    const truncated = markdown.length > MAX_CHARS;
    if (truncated) markdown = markdown.slice(0, MAX_CHARS) + '\n\n… [truncated]';

    const metaDesc = document.querySelector('meta[name="description"], meta[property="og:description"]')?.getAttribute('content') || '';
    const hasNextData = !!document.getElementById('__NEXT_DATA__');
    const jsonLdCount = document.querySelectorAll('script[type="application/ld+json"]').length;
    const savingsPct = rawHtmlLen > 0 ? Math.max(0, Math.round((1 - markdown.length / rawHtmlLen) * 1000) / 10) : 0;

    return {{
        title: document.title,
        url: location.href,
        description: metaDesc,
        markdown,
        markdown_chars: markdown.length,
        raw_html_chars: rawHtmlLen,
        token_savings_pct: savingsPct,
        estimated_tokens: Math.ceil(markdown.length / 4),
        truncated,
        structured_data: {{
            has_next_data: hasNextData,
            json_ld_blocks: jsonLdCount
        }}
    }};
}})()"#
    )
}

/// Chunked base64 DataTransfer file attachment — bypasses Chrome's user-gesture gate on file choosers.
pub fn mime_for_filename(name: &str) -> &'static str {
    match name.rsplit('.').next().unwrap_or("").to_ascii_lowercase().as_str() {
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "csv" => "text/csv",
        "txt" | "md" => "text/plain",
        "json" => "application/json",
        "doc" => "application/msword",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        _ => "application/octet-stream",
    }
}

pub fn build_upload_attach_js(selector_or_ref: &str) -> String {
    let sel_json = serde_json::to_string(selector_or_ref).unwrap_or_else(|_| "\"input[type=file]\"".into());
    format!(
        r#"(() => {{
    const raw = {sel_json}.trim();
    let input = null;
    const refMatch = raw.match(/^@?(e\d+)$/i);
    if (refMatch) {{
        input = document.querySelector(`[data-station-ref="${{refMatch[1].toLowerCase()}}"]`);
    }}
    if (!input && raw) {{
        try {{ input = document.querySelector(raw); }} catch (_) {{}}
    }}
    if (!input) input = document.querySelector('input[type="file"]');
    if (!(input instanceof HTMLInputElement) || input.type !== 'file') {{
        window.__stationUploadFiles = null;
        return {{ ok: false, error: `No <input type="file"> matched '${{raw || 'input[type=file]'}}'` }};
    }}
    const dt = new DataTransfer();
    for (const f of (window.__stationUploadFiles || [])) dt.items.add(f);
    input.files = dt.files;
    input.dispatchEvent(new Event('input', {{ bubbles: true }}));
    input.dispatchEvent(new Event('change', {{ bubbles: true }}));
    const attached = [...input.files].map(f => ({{ name: f.name, size: f.size, type: f.type }}));
    window.__stationUploadFiles = null;
    return {{ ok: true, count: attached.length, files: attached }};
}})()"#
    )
}

#[allow(dead_code)]
pub fn format_doctor_summary(report: &Value) -> String {
    serde_json::to_string_pretty(report).unwrap_or_default()
}

#[allow(dead_code)]
pub fn json_ok_summary(val: &Value) -> Value {
    json!({ "ok": true, "data": val })
}
