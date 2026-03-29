import SwiftUI

struct FileContentView: View {
    let projectId: String
    let path: String

    @Environment(AppStore.self) private var store
    @State private var content: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var showRenderedMarkdown = true

    private var filename: String {
        (path as NSString).lastPathComponent
    }

    private var fileExtension: String {
        (filename as NSString).pathExtension.lowercased()
    }

    private var isMarkdown: Bool {
        fileExtension == "md" || fileExtension == "markdown"
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading file...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("Unable to Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if let content {
                if isMarkdown && showRenderedMarkdown {
                    MarkdownWebView(markdown: content, theme: store.theme)
                } else {
                    ScrollView {
                        Text(highlightedContent(content))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .background(store.theme.baseColor)
        .navigationTitle(filename)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isMarkdown && content != nil {
                    Button {
                        showRenderedMarkdown.toggle()
                    } label: {
                        Image(systemName: showRenderedMarkdown ? "doc.plaintext" : "doc.richtext")
                    }
                }

                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .task(id: path) {
            await loadContent()
        }
    }

    // MARK: - Syntax Highlighting

    private func highlightedContent(_ text: String) -> AttributedString {
        guard let language = SyntaxHighlighter.language(for: fileExtension) else {
            return AttributedString(text)
        }
        return SyntaxHighlighter.highlight(text, language: language)
    }

    // MARK: - Load

    private func loadContent() async {
        guard let instance = store.instance(forProject: projectId) else {
            error = "Not connected"
            isLoading = false
            return
        }
        guard let apiClient = instance.apiClient,
              let token = instance.token else {
            error = "Not connected"
            isLoading = false
            return
        }
        do {
            content = try await apiClient.getFileContent(
                projectId: projectId, path: path, token: token
            )
            isLoading = false
        } catch {
            self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - Lightweight Syntax Highlighter

enum SyntaxLanguage {
    case swift, python, javascript, go, rust, ruby, java, kotlin, csharp
    case cpp, html, css, shell, json, yaml, toml, sql
}

enum SyntaxHighlighter {
    static func language(for ext: String) -> SyntaxLanguage? {
        switch ext {
        case "swift": return .swift
        case "py": return .python
        case "js", "jsx", "mjs": return .javascript
        case "ts", "tsx": return .javascript
        case "go": return .go
        case "rs": return .rust
        case "rb": return .ruby
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "cs": return .csharp
        case "c", "cpp", "cc", "cxx", "h", "hpp": return .cpp
        case "html", "htm": return .html
        case "css", "scss", "less": return .css
        case "sh", "bash", "zsh", "fish": return .shell
        case "json": return .json
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "sql": return .sql
        default: return nil
        }
    }

    static func highlight(_ text: String, language: SyntaxLanguage) -> AttributedString {
        var result = AttributedString(text)

        let commentColor = Color(red: 0.45, green: 0.55, blue: 0.45)
        let stringColor = Color(red: 0.8, green: 0.55, blue: 0.35)
        let keywordColor = Color(red: 0.55, green: 0.45, blue: 0.8)
        let numberColor = Color(red: 0.7, green: 0.7, blue: 0.45)
        let typeColor = Color(red: 0.45, green: 0.7, blue: 0.75)

        // Strings (double and single quoted)
        applyPattern(&result, text: text, pattern: #""(?:[^"\\]|\\.)*""#, color: stringColor)
        applyPattern(&result, text: text, pattern: #"'(?:[^'\\]|\\.)*'"#, color: stringColor)

        // Numbers
        applyPattern(&result, text: text, pattern: #"\b\d+\.?\d*\b"#, color: numberColor)

        // Language-specific keywords and comments
        switch language {
        case .swift:
            applyKeywords(&result, text: text, words: swiftKeywords, color: keywordColor)
            applyKeywords(&result, text: text, words: swiftTypes, color: typeColor)
            applyPattern(&result, text: text, pattern: #"//.*$"#, color: commentColor, multiline: true)
        case .python:
            applyKeywords(&result, text: text, words: pythonKeywords, color: keywordColor)
            applyPattern(&result, text: text, pattern: #"#.*$"#, color: commentColor, multiline: true)
        case .javascript:
            applyKeywords(&result, text: text, words: jsKeywords, color: keywordColor)
            applyPattern(&result, text: text, pattern: #"//.*$"#, color: commentColor, multiline: true)
        case .go:
            applyKeywords(&result, text: text, words: goKeywords, color: keywordColor)
            applyPattern(&result, text: text, pattern: #"//.*$"#, color: commentColor, multiline: true)
        case .rust:
            applyKeywords(&result, text: text, words: rustKeywords, color: keywordColor)
            applyPattern(&result, text: text, pattern: #"//.*$"#, color: commentColor, multiline: true)
        case .ruby:
            applyKeywords(&result, text: text, words: rubyKeywords, color: keywordColor)
            applyPattern(&result, text: text, pattern: #"#.*$"#, color: commentColor, multiline: true)
        case .java, .kotlin, .csharp, .cpp:
            applyKeywords(&result, text: text, words: cLikeKeywords, color: keywordColor)
            applyPattern(&result, text: text, pattern: #"//.*$"#, color: commentColor, multiline: true)
        case .html:
            applyPattern(&result, text: text, pattern: #"</?[a-zA-Z][a-zA-Z0-9]*"#, color: keywordColor)
            applyPattern(&result, text: text, pattern: #"<!--.*?-->"#, color: commentColor)
        case .css:
            applyPattern(&result, text: text, pattern: #"[a-zA-Z-]+(?=\s*:)"#, color: keywordColor)
            applyPattern(&result, text: text, pattern: #"/\*.*?\*/"#, color: commentColor)
        case .shell:
            applyKeywords(&result, text: text, words: shellKeywords, color: keywordColor)
            applyPattern(&result, text: text, pattern: #"#.*$"#, color: commentColor, multiline: true)
        case .json:
            applyPattern(&result, text: text, pattern: #""[^"]*"\s*(?=:)"#, color: keywordColor)
        case .yaml:
            applyPattern(&result, text: text, pattern: #"^[a-zA-Z_][a-zA-Z0-9_]*(?=:)"#, color: keywordColor, multiline: true)
            applyPattern(&result, text: text, pattern: #"#.*$"#, color: commentColor, multiline: true)
        case .toml:
            applyPattern(&result, text: text, pattern: #"\[[^\]]+\]"#, color: keywordColor)
            applyPattern(&result, text: text, pattern: #"#.*$"#, color: commentColor, multiline: true)
        case .sql:
            applyKeywords(&result, text: text, words: sqlKeywords, color: keywordColor)
            applyPattern(&result, text: text, pattern: #"--.*$"#, color: commentColor, multiline: true)
        }

        return result
    }

    private static func applyPattern(_ result: inout AttributedString, text: String, pattern: String, color: Color, multiline: Bool = false) {
        let options: NSRegularExpression.Options = multiline ? [.anchorsMatchLines] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            guard let range = Range(match.range, in: text),
                  let attrRange = result.range(of: text[range], locale: nil) else { continue }
            result[attrRange].foregroundColor = color
        }
    }

    private static func applyKeywords(_ result: inout AttributedString, text: String, words: [String], color: Color) {
        let pattern = "\\b(" + words.joined(separator: "|") + ")\\b"
        applyPattern(&result, text: text, pattern: pattern, color: color)
    }

    // MARK: - Keyword Lists

    private static let swiftKeywords = [
        "import", "func", "var", "let", "if", "else", "guard", "return", "class", "struct",
        "enum", "protocol", "extension", "private", "public", "internal", "static", "self",
        "for", "in", "while", "switch", "case", "default", "break", "continue", "throw",
        "throws", "try", "catch", "await", "async", "some", "any", "nil", "true", "false",
        "init", "deinit", "override", "final", "mutating", "weak", "unowned", "lazy",
    ]

    private static let swiftTypes = [
        "String", "Int", "Double", "Float", "Bool", "Array", "Dictionary", "Set",
        "Optional", "Result", "Error", "Void", "Any", "AnyObject", "URL", "Data", "Date",
        "View", "State", "Binding", "ObservableObject", "Published",
    ]

    private static let pythonKeywords = [
        "def", "class", "if", "elif", "else", "return", "import", "from", "as", "try",
        "except", "finally", "raise", "with", "for", "in", "while", "break", "continue",
        "pass", "yield", "lambda", "and", "or", "not", "is", "None", "True", "False",
        "self", "async", "await", "global", "nonlocal",
    ]

    private static let jsKeywords = [
        "const", "let", "var", "function", "return", "if", "else", "for", "while", "do",
        "switch", "case", "default", "break", "continue", "class", "extends", "new",
        "this", "super", "import", "export", "from", "async", "await", "try", "catch",
        "throw", "typeof", "instanceof", "in", "of", "true", "false", "null", "undefined",
        "interface", "type", "enum", "readonly", "public", "private", "protected",
    ]

    private static let goKeywords = [
        "func", "var", "const", "type", "struct", "interface", "map", "chan", "go",
        "select", "case", "default", "if", "else", "for", "range", "switch", "return",
        "break", "continue", "defer", "package", "import", "nil", "true", "false",
    ]

    private static let rustKeywords = [
        "fn", "let", "mut", "const", "if", "else", "match", "for", "in", "while", "loop",
        "return", "break", "continue", "struct", "enum", "impl", "trait", "pub", "use",
        "mod", "self", "super", "crate", "async", "await", "move", "unsafe", "where",
        "true", "false", "Some", "None", "Ok", "Err",
    ]

    private static let rubyKeywords = [
        "def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until",
        "for", "in", "do", "begin", "rescue", "ensure", "raise", "return", "yield",
        "block_given?", "self", "true", "false", "nil", "require", "include", "attr_accessor",
    ]

    private static let cLikeKeywords = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
        "return", "class", "struct", "enum", "interface", "public", "private", "protected",
        "static", "final", "abstract", "void", "int", "long", "float", "double", "bool",
        "char", "string", "var", "val", "new", "this", "super", "null", "true", "false",
        "try", "catch", "throw", "throws", "import", "package", "namespace", "using",
        "const", "override", "virtual", "extern", "inline", "template", "typename",
    ]

    private static let shellKeywords = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
        "case", "esac", "function", "return", "exit", "echo", "export", "source", "local",
        "readonly", "set", "unset", "true", "false",
    ]

    private static let sqlKeywords = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "JOIN", "LEFT", "RIGHT", "INNER",
        "OUTER", "ON", "AND", "OR", "NOT", "NULL", "IS", "IN", "AS", "ORDER", "BY",
        "GROUP", "HAVING", "LIMIT", "OFFSET", "UNION", "DISTINCT", "COUNT", "SUM", "AVG",
    ]
}
