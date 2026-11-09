// Template.swift — SlicePad slicer core: Bambu Studio template renderer.
//
// Bambu templates use two substitution syntaxes (research findings-machine
// section 6):
//   {expression}  — curly-brace expressions, including the block directives
//                   {if cond} {elsif cond} {else} {endif}, which may share a
//                   line with ordinary content.
//   [name]        — standalone square-bracket placeholders outside any {},
//                   including indexed forms like [flush_temperatures[next_extruder]]
//                   (note the doubled closing bracket in the raw text there).
//
// Expression grammar: numbers, "strings", identifiers, a[i] indexing
// (i = number or identifier/expression), + - * /, == != > < >= <=,
// && || !, parentheses, unary minus.
// Unbound identifiers render as an empty string and are recorded.

import Foundation

public enum TV {
    case num(Double)
    case str(String)
    case bool(Bool)
    case arr([TV])

    public var truthy: Bool {
        switch self {
        case .num(let v): return v != 0
        case .str(let s): return !s.isEmpty
        case .bool(let b): return b
        case .arr(let a): return !a.isEmpty
        }
    }
    public var number: Double {
        switch self {
        case .num(let v): return v
        case .bool(let b): return b ? 1 : 0
        case .str(let s): return Double(s) ?? 0
        case .arr: return 0
        }
    }
    /// Rendering used when a value is substituted into the output text.
    public var rendered: String {
        switch self {
        case .num(let v): return spNum(v, 4)
        case .str(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .arr: return ""
        }
    }
    static func equal(_ a: TV, _ b: TV) -> Bool {
        switch (a, b) {
        case (.num(let x), .num(let y)): return x == y
        case (.str(let x), .str(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.num(let x), .str(let y)): return spNum(x, 4) == y
        case (.str(let x), .num(let y)): return x == spNum(y, 4)
        default: return false
        }
    }
}

// MARK: - Expression parser (recursive descent over characters)

struct ExprParser {
    let chars: [Character]
    var pos: Int = 0
    let bindings: [String: TV]
    var unbound: [String] = []

    init(text: String, bindings: [String: TV]) {
        self.chars = Array(text)
        self.bindings = bindings
    }

    mutating func skipSpaces() {
        while pos < chars.count && (chars[pos] == " " || chars[pos] == "\t") { pos += 1 }
    }
    func peek() -> Character? { pos < chars.count ? chars[pos] : nil }
    mutating func consume(_ c: Character) -> Bool {
        skipSpaces()
        if peek() == c { pos += 1; return true }
        return false
    }
    mutating func consume2(_ a: Character, _ b: Character) -> Bool {
        skipSpaces()
        if pos + 1 < chars.count && chars[pos] == a && chars[pos + 1] == b { pos += 2; return true }
        return false
    }

    mutating func parseExpression() -> TV { parseOr() }

    mutating func parseOr() -> TV {
        var lhs = parseAnd()
        while consume2("|", "|") {
            let rhs = parseAnd()
            lhs = .bool(lhs.truthy || rhs.truthy)
        }
        return lhs
    }
    mutating func parseAnd() -> TV {
        var lhs = parseComparison()
        while consume2("&", "&") {
            let rhs = parseComparison()
            lhs = .bool(lhs.truthy && rhs.truthy)
        }
        return lhs
    }
    mutating func parseComparison() -> TV {
        let lhs = parseAdditive()
        skipSpaces()
        if consume2("=", "=") { return .bool(TV.equal(lhs, parseAdditive())) }
        if consume2("!", "=") { return .bool(!TV.equal(lhs, parseAdditive())) }
        if consume2(">", "=") { return .bool(lhs.number >= parseAdditive().number) }
        if consume2("<", "=") { return .bool(lhs.number <= parseAdditive().number) }
        if consume(">") { return .bool(lhs.number > parseAdditive().number) }
        if consume("<") { return .bool(lhs.number < parseAdditive().number) }
        return lhs
    }
    mutating func parseAdditive() -> TV {
        var lhs = parseMultiplicative()
        while true {
            if consume("+") {
                let rhs = parseMultiplicative()
                if case .str(let a) = lhs, case .str(let b) = rhs { lhs = .str(a + b) }
                else { lhs = .num(lhs.number + rhs.number) }
            } else if consume("-") {
                lhs = .num(lhs.number - parseMultiplicative().number)
            } else { break }
        }
        return lhs
    }
    mutating func parseMultiplicative() -> TV {
        var lhs = parseUnary()
        while true {
            if consume("*") {
                lhs = .num(lhs.number * parseUnary().number)
            } else if consume("/") {
                let d = parseUnary().number
                lhs = .num(d == 0 ? 0 : lhs.number / d)
            } else { break }
        }
        return lhs
    }
    mutating func parseUnary() -> TV {
        skipSpaces()
        if consume("!") { return .bool(!parseUnary().truthy) }
        if consume("-") { return .num(-parseUnary().number) }
        if consume("+") { return parseUnary() }
        return parsePrimary()
    }
    mutating func parsePrimary() -> TV {
        skipSpaces()
        guard let c = peek() else { return .str("") }
        if c == "(" {
            pos += 1
            let v = parseExpression()
            _ = consume(")")
            return v
        }
        if c == "\"" {
            pos += 1
            var s = ""
            while let ch = peek(), ch != "\"" { s.append(ch); pos += 1 }
            pos += 1 // closing quote
            return .str(s)
        }
        if c.isNumber || c == "." {
            var text = ""
            while let ch = peek(), ch.isNumber || ch == "." { text.append(ch); pos += 1 }
            return .num(Double(text) ?? 0)
        }
        if c.isLetter || c == "_" {
            var name = ""
            while let ch = peek(), ch.isLetter || ch.isNumber || ch == "_" { name.append(ch); pos += 1 }
            var value: TV
            if name == "true" { value = .bool(true) }
            else if name == "false" { value = .bool(false) }
            else if let bound = bindings[name] { value = bound }
            else {
                if !unbound.contains(name) { unbound.append(name) }
                value = .str("")
            }
            // Optional indexing: name[expr]
            while true {
                let save = pos
                skipSpaces()
                if peek() == "[" {
                    pos += 1
                    let idx = parseExpression()
                    _ = consume("]")
                    if case .arr(let elements) = value {
                        let i = Int(idx.number)
                        value = (i >= 0 && i < elements.count) ? elements[i] : .str("")
                    }
                    // Indexing a scalar yields the scalar itself (defensive;
                    // does not occur in the A1 mini templates).
                } else {
                    pos = save
                    break
                }
            }
            return value
        }
        // Unknown character: skip it and yield empty.
        pos += 1
        return .str("")
    }
}

/// Evaluate a single template expression against bindings.
public func evaluateTemplateExpression(_ text: String, bindings: [String: TV]) -> TV {
    var parser = ExprParser(text: text, bindings: bindings)
    return parser.parseExpression()
}

/// A bare (unindexed) array placeholder in Bambu templates — e.g.
/// `M109 S[nozzle_temperature_initial_layer]` in the A1 mini start
/// G-code — means "the value for the current filament". SlicePad binds
/// per-slot arrays with the same preset repeated, so the first element
/// is that value. Non-array values pass through unchanged.
private func scalarized(_ v: TV) -> TV {
    if case .arr(let elements) = v { return elements.first ?? .str("") }
    return v
}

// MARK: - Renderer

private struct IfFrame {
    var parentActive: Bool
    var taken: Bool
    var active: Bool
}

/// Render a Bambu template. Returns the rendered text plus the list of
/// identifiers that were not bound (they rendered as empty strings).
/// Rendering is line-based: Bambu's directives never span lines, and a
/// source line that contained only directives and renders to nothing is
/// dropped entirely, matching Bambu Studio's output shape.
public func renderTemplate(_ template: String, bindings: [String: TV]) -> (text: String, unbound: [String]) {
    var frames: [IfFrame] = []
    var unbound: [String] = []
    var outLines: [String] = []

    func allActive() -> Bool { frames.allSatisfy { $0.active } }

    for rawLine in template.components(separatedBy: "\n") {
        let chars = Array(rawLine)
        var rendered = ""
        var sawDirective = false
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                // Find the closing brace (no nested braces / braces in
                // strings occur in the A1 mini template set).
                var j = i + 1
                var content = ""
                while j < chars.count && chars[j] != "}" { content.append(chars[j]); j += 1 }
                if j >= chars.count {
                    // Unterminated: emit literally and stop.
                    rendered.append(chars[i])
                    i += 1
                    continue
                }
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                if trimmed == "else" {
                    sawDirective = true
                    if var top = frames.last {
                        top.active = top.parentActive && !top.taken
                        top.taken = true
                        frames[frames.count - 1] = top
                    }
                } else if trimmed == "endif" {
                    sawDirective = true
                    if !frames.isEmpty { frames.removeLast() }
                } else if trimmed.hasPrefix("if") && (trimmed.count == 2 || trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)] == " " || trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)] == "(") {
                    sawDirective = true
                    let exprText = String(trimmed.dropFirst(2))
                    let parent = allActive()
                    var cond = false
                    if parent {
                        var parser = ExprParser(text: exprText, bindings: bindings)
                        cond = parser.parseExpression().truthy
                        for u in parser.unbound where !unbound.contains(u) { unbound.append(u) }
                    }
                    frames.append(IfFrame(parentActive: parent, taken: cond, active: parent && cond))
                } else if trimmed.hasPrefix("elsif") {
                    sawDirective = true
                    let exprText = String(trimmed.dropFirst(5))
                    if var top = frames.last {
                        if top.parentActive && !top.taken {
                            var parser = ExprParser(text: exprText, bindings: bindings)
                            let cond = parser.parseExpression().truthy
                            for u in parser.unbound where !unbound.contains(u) { unbound.append(u) }
                            top.active = cond
                            top.taken = cond
                        } else {
                            top.active = false
                        }
                        frames[frames.count - 1] = top
                    }
                } else {
                    // Ordinary {expression} substitution.
                    if allActive() {
                        var parser = ExprParser(text: trimmed, bindings: bindings)
                        let value = scalarized(parser.parseExpression())
                        for u in parser.unbound where !unbound.contains(u) { unbound.append(u) }
                        rendered += value.rendered
                    }
                }
                i = j + 1
            } else if chars[i] == "[" && allActive() {
                // Standalone [name] / [name[idx]] substitution. Bracket
                // depth is counted so nested index brackets work.
                var depth = 0
                var j = i
                var content = ""
                var closed = false
                while j < chars.count {
                    if chars[j] == "[" {
                        depth += 1
                        if depth > 1 { content.append(chars[j]) }
                    } else if chars[j] == "]" {
                        depth -= 1
                        if depth == 0 { closed = true; break }
                        content.append(chars[j])
                    } else {
                        content.append(chars[j])
                    }
                    j += 1
                }
                if closed && !content.isEmpty {
                    var parser = ExprParser(text: content, bindings: bindings)
                    let value = scalarized(parser.parseExpression())
                    for u in parser.unbound where !unbound.contains(u) { unbound.append(u) }
                    rendered += value.rendered
                    i = j + 1
                } else {
                    rendered.append(chars[i])
                    i += 1
                }
            } else {
                if allActive() { rendered.append(chars[i]) }
                i += 1
            }
        }
        // Drop lines that held only directives and produced nothing.
        if sawDirective && rendered.trimmingCharacters(in: .whitespaces).isEmpty {
            continue
        }
        outLines.append(rendered)
    }
    return (outLines.joined(separator: "\n"), unbound)
}
