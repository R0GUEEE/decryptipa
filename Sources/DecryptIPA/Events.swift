import Foundation

// MARK: - Helper events

enum EventParser {
    /// Parses `@evt event=NAME level=LVL msg="text" k=v …` records.
    static func parse(_ line: String) -> [String: String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@evt ") else { return nil }

        var attributes: [String: String] = [:]
        for token in splitTokens(String(trimmed.dropFirst(5))) {
            guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { continue }
            let key = String(token[token.startIndex..<eq])
            var value = String(token[token.index(after: eq)...])
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            attributes[key] = value
        }
        return attributes["event"] == nil ? nil : attributes
    }

    private static func splitTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == " " && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
