import Foundation

public final class PromptSynthesizer: PromptSynthesizerPort, Sendable {
    public init() {}

    public func synthesizeInjectionJS(prompt: String) -> String {
        guard let promptData = try? JSONEncoder().encode(prompt),
              let escapedPrompt = String(data: promptData, encoding: .utf8) else {
            return "(() => ({ error: 'Encoding failed' }))()"
        }

        return """
        (() => {
            let el = document.querySelector('rich-textarea div[contenteditable="true"]');
            if (!el) el = document.querySelector('div[contenteditable="true"].ProseMirror');
            if (!el) el = document.querySelector('div[contenteditable="true"]');
            if (!el) el = document.querySelector('textarea, input[type="text"]');
            if (!el) return { error: 'No input element found on active page' };

            el.focus();
            if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
                el.value = \(escapedPrompt);
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return { injected: true, chars: el.value.length };
            }

            const rawText = \(escapedPrompt);
            const lines = rawText.split('\\n');
            const ps = lines.map(line => {
                const p = document.createElement('p');
                p.textContent = line || ' ';
                return p;
            });
            el.replaceChildren(...ps);

            const sel = window.getSelection();
            if (sel) {
                const range = document.createRange();
                range.selectNodeContents(el);
                range.collapse(false);
                sel.removeAllRanges();
                sel.addRange(range);
            }

            document.execCommand('insertText', false, ' ');
            el.dispatchEvent(new InputEvent('input', {
                bubbles: true,
                cancelable: true,
                inputType: 'insertText',
                data: ' '
            }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return { injected: true, chars: el.innerText.length };
        })()
        """
    }

    public func synthesizeSendClickJS() -> String {
        return """
        (() => {
            const btn = document.querySelector('button[aria-label*="Send" i], button[aria-label*="Envoyer" i], button[data-testid="send-button"], button.send-button');
            if (btn && !btn.disabled) {
                btn.click();
                return { sent: true, method: 'button_click' };
            }
            const editor = document.querySelector('.ql-editor, [contenteditable="true"]');
            if (editor) {
                const enterDown = new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true });
                const enterUp = new KeyboardEvent("keyup", { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true });
                editor.dispatchEvent(enterDown);
                editor.dispatchEvent(enterUp);
                return { sent: true, method: "enter_key" };
            }
            return { sent: false, hasBtn: !!btn, disabled: btn ? btn.disabled : true };
        })()
        """
    }

    public func synthesizeGenerationCheckJS() -> String {
        return """
        (() => {
            const stopBtn = document.querySelector('button[aria-label*="Stop" i], button[aria-label*="Interrompre" i], button[aria-label*="Arrêter" i]');
            const mcs = document.querySelectorAll('message-content');
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
                chars: chars
            };
        })()
        """
    }

    public func synthesizeResponseExtractJS() -> String {
        return """
        (() => {
            const mcs = document.querySelectorAll('message-content');
            if (mcs && mcs.length > 0) return mcs[mcs.length - 1].innerText;
            const turns = document.querySelectorAll('model-response');
            const last = turns[turns.length - 1];
            return last ? (last.querySelector('.markdown')?.innerText || last.innerText) : '';
        })()
        """
    }

    public func synthesizeModelSwitchJS(mode: String) -> String {
        return """
        (() => {
            // Find model picker button in Gemini header
            const pickerBtn = document.querySelector('button[aria-haspopup="menu"][aria-label*="model" i], button.model-picker-btn, div[aria-label*="mode" i]');
            if (pickerBtn) {
                pickerBtn.click();
                return { clickedPicker: true };
            }
            return { clickedPicker: false };
        })()
        """
    }
}
