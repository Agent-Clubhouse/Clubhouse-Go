import SwiftUI

/// Renders markdown content using Swift-native AttributedString.
/// Replaces the previous WKWebView + JS renderer to eliminate XSS vectors.
struct MarkdownWebView: View {
    let markdown: String
    let theme: ThemeColors

    var body: some View {
        ScrollView {
            Text(renderedMarkdown)
                .font(.system(size: 15))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var renderedMarkdown: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        // Try full markdown parsing first, fall back to inline-only, then plain text
        if let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)) {
            return attributed
        }
        if let attributed = try? AttributedString(markdown: markdown, options: options) {
            return attributed
        }
        return AttributedString(markdown)
    }
}
