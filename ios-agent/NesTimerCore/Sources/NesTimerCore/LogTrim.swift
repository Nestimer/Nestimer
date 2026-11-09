import Foundation

/// Keeps the shared debug log bounded: once the file passes `maxBytes`, only the last lines stay.
public enum LogTrim {
    public static let maxBytes = 64 * 1024
    public static let keepLines = 500

    public static func needsTrim(fileSize: Int, maxBytes: Int = maxBytes) -> Bool {
        fileSize > maxBytes
    }

    /// The last `keepingLines` lines of `text`. A final line without a newline counts as a line.
    public static func tail(_ text: String, keepingLines n: Int = keepLines) -> String {
        guard !text.isEmpty, n > 0 else { return n > 0 ? text : "" }
        var newlines = 0
        var idx = text.endIndex
        // Skip the terminating newline so it isn't counted as a line boundary.
        if text.last == "\n" { idx = text.index(before: idx) }
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            if text[prev] == "\n" {
                newlines += 1
                if newlines == n { return String(text[idx...]) }
            }
            idx = prev
        }
        return text
    }
}
