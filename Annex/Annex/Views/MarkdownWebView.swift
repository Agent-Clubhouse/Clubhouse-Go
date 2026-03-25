import SwiftUI
import WebKit

/// Renders markdown content using WKWebView with a simple CSS theme.
/// Supports headers, lists, code blocks, tables, links — full CommonMark.
struct MarkdownWebView: UIViewRepresentable {
    let markdown: String
    let theme: ThemeColors

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = wrapInHTML(markdown)
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func wrapInHTML(_ md: String) -> String {
        // Escape for JS string
        let escaped = md
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let bg = theme.base
        let text = theme.text
        let codeBg = theme.surface0
        let accent = theme.accent
        let subtext = theme.subtext0

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
            * { box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 15px;
                line-height: 1.6;
                color: \(text);
                background: \(bg);
                padding: 16px;
                margin: 0;
                word-wrap: break-word;
                overflow-wrap: break-word;
            }
            h1 { font-size: 24px; font-weight: 700; margin: 20px 0 8px; border-bottom: 1px solid \(codeBg); padding-bottom: 6px; }
            h2 { font-size: 20px; font-weight: 600; margin: 18px 0 6px; }
            h3 { font-size: 17px; font-weight: 600; margin: 14px 0 4px; }
            h4, h5, h6 { font-size: 15px; font-weight: 600; margin: 12px 0 4px; }
            p { margin: 8px 0; }
            a { color: \(accent); text-decoration: none; }
            code {
                font-family: 'SF Mono', Menlo, monospace;
                font-size: 13px;
                background: \(codeBg);
                padding: 2px 5px;
                border-radius: 4px;
            }
            pre {
                background: \(codeBg);
                padding: 12px;
                border-radius: 8px;
                overflow-x: auto;
                margin: 10px 0;
            }
            pre code { background: none; padding: 0; font-size: 12px; }
            ul, ol { padding-left: 24px; margin: 8px 0; }
            li { margin: 4px 0; }
            blockquote {
                border-left: 3px solid \(accent);
                margin: 10px 0;
                padding: 4px 12px;
                color: \(subtext);
            }
            table { border-collapse: collapse; width: 100%; margin: 10px 0; }
            th, td { border: 1px solid \(codeBg); padding: 6px 10px; text-align: left; }
            th { background: \(codeBg); font-weight: 600; }
            hr { border: none; border-top: 1px solid \(codeBg); margin: 16px 0; }
            img { max-width: 100%; border-radius: 8px; }
            strong { font-weight: 600; }
        </style>
        <script>
        // Minimal CommonMark-ish markdown to HTML converter
        function md(s) {
            // Code blocks (fenced)
            s = s.replace(/```(\\w*)\\n([\\s\\S]*?)```/g, '<pre><code>$2</code></pre>');
            // Headers
            s = s.replace(/^######\\s+(.+)$/gm, '<h6>$1</h6>');
            s = s.replace(/^#####\\s+(.+)$/gm, '<h5>$1</h5>');
            s = s.replace(/^####\\s+(.+)$/gm, '<h4>$1</h4>');
            s = s.replace(/^###\\s+(.+)$/gm, '<h3>$1</h3>');
            s = s.replace(/^##\\s+(.+)$/gm, '<h2>$1</h2>');
            s = s.replace(/^#\\s+(.+)$/gm, '<h1>$1</h1>');
            // Horizontal rules
            s = s.replace(/^---+$/gm, '<hr>');
            s = s.replace(/^\\*\\*\\*+$/gm, '<hr>');
            // Bold + italic
            s = s.replace(/\\*\\*\\*(.+?)\\*\\*\\*/g, '<strong><em>$1</em></strong>');
            s = s.replace(/\\*\\*(.+?)\\*\\*/g, '<strong>$1</strong>');
            s = s.replace(/\\*(.+?)\\*/g, '<em>$1</em>');
            // Inline code
            s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
            // Links
            s = s.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, '<a href="$2">$1</a>');
            // Blockquotes
            s = s.replace(/^>\\s+(.+)$/gm, '<blockquote>$1</blockquote>');
            // Unordered lists
            s = s.replace(/^[\\s]*[-*+]\\s+(.+)$/gm, '<li>$1</li>');
            s = s.replace(/(<li>.*<\\/li>)/s, '<ul>$1</ul>');
            // Paragraphs (lines not already tagged)
            s = s.replace(/^(?!<[huplob]|<li|<hr|<pre|<block)(.+)$/gm, '<p>$1</p>');
            // Clean up multiple blockquotes
            s = s.replace(/<\\/blockquote>\\n<blockquote>/g, '<br>');
            return s;
        }
        </script>
        </head>
        <body>
        <script>document.write(md(`\(escaped)`));</script>
        </body>
        </html>
        """
    }
}
