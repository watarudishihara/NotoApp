//
//  MiniTeX.swift
//  NTex
//
//  Created by Wataru Ishihara on 9/11/25.
//

import Foundation

enum MiniNode {
    case document(meta: MiniMeta, blocks: [MiniBlock])
}

struct MiniMeta {
    var title: String?
    var author: String?
    var date: String?
}

enum MiniBlock {
    case heading(level: Int, text: String)
    case paragraph(inlines: [Inline])
    case ul(items: [[Inline]])
    case ol(items: [[Inline]])
    case blockquote(inlines: [Inline])
    case displayMath(String)   // content without surrounding $$
}

enum Inline {
    case text(String)
    case bold([Inline])
    case italic([Inline])
    case code(String)
    case inlineMath(String)    // content without surrounding $
}

struct MiniTeX {
    // MARK: - Public entry point
    static func render(_ source: String) -> String {
        // Normalize common slash-typo: /text{..} -> \text{..}
        let fixed = source.replacingOccurrences(
            of: #"(?<!\\)[/∕／⁄]\s*text\s*\{"#,
            with: #"\text{"#,
            options: .regularExpression
        )
        
        // Handle \\ line breaks - convert to paragraph breaks
        let withParagraphs = fixed
            .replacingOccurrences(of: "\\\\", with: "\n\n")
            .replacingOccurrences(of: "\\\n", with: "\n\n")
        
        // Auto-wrap standalone math expressions (like F=ma, E = \frac{1}{2}mv^2)
        let withMath = autoWrapMath(withParagraphs)
        
        let (meta, body) = parse(withMath)
        return html(doc: .document(meta: meta, blocks: body))
    }
    
    // MARK: - Auto-wrap standalone math expressions
    private static func autoWrapMath(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines
            if trimmed.isEmpty {
                result.append(line)
                continue
            }
            
            // Skip lines that are already wrapped in $ or are \text{...}
            if trimmed.hasPrefix("$") || trimmed.hasPrefix("\\text{") || trimmed.hasPrefix("$$") {
                result.append(line)
                continue
            }
            
            // Check if this looks like a math expression
            // Patterns: F=ma, E = \frac{1}{2}mv^2, etc.
            if isMathExpression(trimmed) {
                result.append("$" + trimmed + "$")
            } else {
                result.append(line)
            }
        }
        
        return result.joined(separator: "\n")
    }
    
    private static func isMathExpression(_ text: String) -> Bool {
        // Check for common math patterns
        let mathPatterns = [
            #"[A-Za-z]\s*=\s*[A-Za-z0-9]"#,  // F=ma, E=mc^2
            #"\\frac\{"#,                     // \frac{...}
            #"\\int"#,                        // \int
            #"\\sum"#,                        // \sum
            #"\\lim"#,                        // \lim
            #"\\sqrt"#,                       // \sqrt
            #"[A-Za-z]\s*=\s*\\"#,           // F = \frac{...}
            #"[A-Za-z]\s*=\s*-\s*[A-Za-z]"#, // F = -kx
        ]
        
        for pattern in mathPatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        
        return false
    }

    // MARK: - Very small parser
    private static func parse(_ s: String) -> (MiniMeta, [MiniBlock]) {
        var meta = MiniMeta()
        var lines = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)

        func takeMeta(_ key: String, setter: (String) -> Void) {
            let want = "\\\(key){"            // one leading backslash
            for (i, var line) in lines.enumerated() {
                line = line.trimmingCharacters(in: .whitespaces) // allow indentation
                guard line.hasPrefix(want), line.last == "}" else { continue }
                let start = want.count
                let val = String(line.dropFirst(start).dropLast())
                setter(val)
                lines.remove(at: i)           // remove the meta line from body
                break
            }
        }

        takeMeta("title")  { meta.title  = $0 }
        takeMeta("author") { meta.author = $0 }
        takeMeta("date")   { meta.date   = $0 }

        var blocks: [MiniBlock] = []
        var i = 0

        func flushParagraph(_ buf: inout [String]) {
            guard !buf.isEmpty else { return }
            let joined = buf.joined(separator: " ")
            blocks.append(.paragraph(inlines: parseInlines(joined)))
            buf.removeAll()
        }

        while i < lines.count {
            let line = lines[i]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1; continue
            }

            // Display math $$...$$ (single-line or start/end)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("$$") {
                var content = line.trimmingCharacters(in: .whitespaces)
                content.removeFirst(2)
                if content.hasSuffix("$$") {
                    content.removeLast(2)
                    blocks.append(.displayMath(content.trimmingCharacters(in: .whitespaces)))
                    i += 1; continue
                } else {
                    var acc = content + "\n"
                    i += 1
                    while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasSuffix("$$") {
                        acc += lines[i] + "\n"
                        i += 1
                    }
                    if i < lines.count {
                        var last = lines[i].trimmingCharacters(in: .whitespaces)
                        last.removeLast(2)
                        acc += last
                    }
                    blocks.append(.displayMath(acc))
                    i += 1; continue
                }
            }

            // Headings: \section{...} etc OR Markdown-style #, ##, ###
            if let h = parseHeading(line) {
                blocks.append(h)
                i += 1; continue
            }

            // Block quote
            if line.hasPrefix("> ") {
                let text = String(line.dropFirst(2))
                blocks.append(.blockquote(inlines: parseInlines(text)))
                i += 1; continue
            }

            // Lists (group consecutive lines)
            if line.hasPrefix("- ") || isNumbered(line) {
                var items: [[Inline]] = []
                let ordered = isNumbered(line)
                var j = i
                while j < lines.count {
                    let L = lines[j]
                    if ordered, let range = L.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                        let itemText = String(L[range.upperBound...])
                        items.append(parseInlines(String(itemText)))
                        j += 1
                    } else if L.hasPrefix("- ") {
                        items.append(parseInlines(String(L.dropFirst(2))))
                        j += 1
                    } else {
                        break
                    }
                }
                blocks.append(ordered ? .ol(items: items) : .ul(items: items))
                i = j; continue
            }

            // Paragraph accumulator (until blank or structural)
            var paraBuf: [String] = [line]
            var j = i + 1
            while j < lines.count {
                let L = lines[j]
                if L.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if L.hasPrefix("> ") || L.hasPrefix("- ") || isNumbered(L) || parseHeading(L) != nil || L.trimmingCharacters(in: .whitespaces).hasPrefix("$$") { break }
                paraBuf.append(L)
                j += 1
            }
            flushParagraph(&paraBuf)
            i = j
        }

        return (meta, blocks)
    }

    private static func parseHeading(_ line: String) -> MiniBlock? {
        if line.hasPrefix("\\section{"), line.hasSuffix("}") {
            return .heading(level: 1, text: String(line.dropFirst(9).dropLast()))
        }
        if line.hasPrefix("\\subsection{"), line.hasSuffix("}") {
            return .heading(level: 2, text: String(line.dropFirst(12).dropLast()))
        }
        if line.hasPrefix("\\subsubsection{"), line.hasSuffix("}") {
            return .heading(level: 3, text: String(line.dropFirst(15).dropLast()))
        }
        if line.hasPrefix("### ") { return .heading(level: 3, text: String(line.dropFirst(4))) }
        if line.hasPrefix("## ")  { return .heading(level: 2, text: String(line.dropFirst(3))) }
        if line.hasPrefix("# ")   { return .heading(level: 1, text: String(line.dropFirst(2))) }
        return nil
    }

    private static func isNumbered(_ line: String) -> Bool {
        line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }

    // Inline parser: bold **...**, italic *...*, code `...`, inline $...$
    private static func parseInlines(_ text: String) -> [Inline] {
        // Keep it simple: single-pass tokenization for the common cases.
        var out: [Inline] = []
        var i = text.startIndex
        let chars = Array(text)

        func pushText(_ s: String) { if !s.isEmpty { out.append(.text(s)) } }

        var buffer = ""
        while i < text.endIndex {
            let c = text[i]

            // inline code
            if c == "`" {
                if !buffer.isEmpty { pushText(buffer); buffer = "" }
                var j = text.index(after: i)
                var code = ""
                while j < text.endIndex, text[j] != "`" {
                    code.append(text[j]); j = text.index(after: j)
                }
                out.append(.code(code))
                i = j < text.endIndex ? text.index(after: j) : j
                continue
            }

            // bold
            if c == "*" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "*" {
                if !buffer.isEmpty { pushText(buffer); buffer = "" }
                var j = text.index(i, offsetBy: 2)
                var inner = ""
                while j < text.endIndex {
                    if text[j] == "*" &&
                        text.index(after: j) < text.endIndex &&
                        text[text.index(after: j)] == "*" { break }
                    inner.append(text[j]); j = text.index(after: j)
                }
                out.append(.bold(parseInlines(inner)))
                i = text.index(j, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }

            // italic
            if c == "*" {
                if !buffer.isEmpty { pushText(buffer); buffer = "" }
                var j = text.index(after: i)
                var inner = ""
                while j < text.endIndex, text[j] != "*" {
                    inner.append(text[j]); j = text.index(after: j)
                }
                out.append(.italic(parseInlines(inner)))
                i = j < text.endIndex ? text.index(after: j) : j
                continue
            }

            // inline math $...$
            if c == "$" {
                if !buffer.isEmpty { pushText(buffer); buffer = "" }
                var j = text.index(after: i)
                var inner = ""
                while j < text.endIndex, text[j] != "$" {
                    inner.append(text[j]); j = text.index(after: j)
                }
                out.append(.inlineMath(inner))
                i = j < text.endIndex ? text.index(after: j) : j
                continue
            }
            // LaTeX commands: \text{...}, \title{...}, \textbf{...}, \textit{...}
            if c == "\\" {
                let rest = String(text[i...])
                let commands = ["\\text", "\\title", "\\textbf", "\\textit"]
                var commandFound = false
                
                for cmd in commands {
                    if rest.hasPrefix(cmd) {
                        commandFound = true
                        if !buffer.isEmpty { pushText(buffer); buffer = "" }
                        
                        // Find the opening brace
                        var searchIndex = text.index(i, offsetBy: cmd.count)
                        while searchIndex < text.endIndex, text[searchIndex].isWhitespace {
                            searchIndex = text.index(after: searchIndex)
                        }
                        
                        if searchIndex < text.endIndex, text[searchIndex] == "{" {
                            // Find the matching closing brace
                            var braceIndex = text.index(after: searchIndex)
                            var inner = ""
                            var depth = 1
                            
                            while braceIndex < text.endIndex, depth > 0 {
                                let ch = text[braceIndex]
                                if ch == "{" { depth += 1 }
                                else if ch == "}" { depth -= 1; if depth == 0 { break } }
                                if depth > 0 { inner.append(ch) }
                                braceIndex = text.index(after: braceIndex)
                            }
                            
                            // Handle different commands
                            switch cmd {
                            case "\\text", "\\title":
                                out.append(.text(inner))
                            case "\\textbf":
                                out.append(.bold(parseInlines(inner)))
                            case "\\textit":
                                out.append(.italic(parseInlines(inner)))
                            default:
                                out.append(.text(inner))
                            }
                            
                            // Move past the closing brace
                            i = braceIndex < text.endIndex ? text.index(after: braceIndex) : braceIndex
                        } else {
                            // No opening brace found, treat as literal
                            buffer.append(cmd)
                        }
                        break
                    }
                }
                
                if !commandFound {
                    buffer.append(c)
                }
                continue
            }

            buffer.append(c)
            i = text.index(after: i)
        }
        if !buffer.isEmpty { pushText(buffer) }
        return out
    }

    // MARK: - HTML generation (KaTeX for math)
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func html(doc: MiniNode) -> String {
        switch doc {
        case .document(let meta, let blocks):
            var body = ""
            if let t = meta.title { body += "<h1 class='title'>\(esc(t))</h1>" }
            if meta.author != nil || meta.date != nil {
                body += "<div class='meta'>"
                if let a = meta.author { body += "<div class='author'>\(esc(a))</div>" }
                if let d = meta.date   { body += "<div class='date'>\(esc(d))</div>" }
                body += "</div>"
            }
            for b in blocks { body += html(block: b) }

            return body
        }
    }
    
    private static func getHeadingClass(level: Int) -> String {
        switch level {
        case 1: return "section"
        case 2: return "subsection" 
        case 3: return "subsubsection"
        default: return "heading"
        }
    }

    private static func html(block: MiniBlock) -> String {
        switch block {
        case .heading(let level, let text):
            let lv = max(1, min(level, 6))
            let cssClass = getHeadingClass(level: level)
            return "<h\(lv) class='\(cssClass)'>\(esc(text))</h\(lv)>"
        case .paragraph(let inlines):
            return "<p>\(html(inlines: inlines))</p>"
        case .ul(let items):
            let lis = items.map { "<li>\(html(inlines: $0))</li>" }.joined()
            return "<ul>\(lis)</ul>"
        case .ol(let items):
            let lis = items.map { "<li>\(html(inlines: $0))</li>" }.joined()
            return "<ol>\(lis)</ol>"
        case .blockquote(let inlines):
            return "<blockquote>\(html(inlines: inlines))</blockquote>"
        case .displayMath(let s):
            // We let KaTeX auto-render $$...$$ delimiters; but making it explicit helps:
            return "<div class='display-math'>$$\(esc(s))$$</div>"
        }
    }

    private static func html(inlines: [Inline]) -> String {
        inlines.map { inlineHTML($0) }.joined()
    }

    private static func inlineHTML(_ n: Inline) -> String {
        switch n {
        case .text(let t): return esc(t)
        case .bold(let ins): return "<strong>\(html(inlines: ins))</strong>"
        case .italic(let ins): return "<em>\(html(inlines: ins))</em>"
        case .code(let s): return "<code>\(esc(s))</code>"
        case .inlineMath(let s): return "$\(esc(s))$"
        }
    }
}
