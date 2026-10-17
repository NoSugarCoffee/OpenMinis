import Foundation

public enum RemoteRunOutcome: Equatable, Sendable {
    case running
    case exited(Int32)
    case cancelled
    case abnormal
}

public struct RemoteOutputBuffer: Sendable {
    public private(set) var offset: Int = 0
    private var pending: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> String {
        offset += bytes.count
        let combined = pending + bytes
        let held = Self.incompleteTailLength(combined)
        pending = Array(combined.suffix(held))
        return String(decoding: combined.dropLast(held), as: UTF8.self)
    }

    public mutating func flush() -> String {
        let text = String(decoding: pending, as: UTF8.self)
        pending = []
        return text
    }

    private static func incompleteTailLength(_ bytes: [UInt8]) -> Int {
        let maxTail = min(3, bytes.count)
        guard maxTail > 0 else { return 0 }
        for tailLength in 1...maxTail {
            let lead = bytes[bytes.count - tailLength]
            let expected: Int
            switch lead {
            case 0xC2...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF4: expected = 4
            case 0x80...0xBF: continue
            default: return 0
            }
            return tailLength < expected ? tailLength : 0
        }
        return 0
    }
}

public enum RemoteRunState {
    public static func classify(statusOutput: String) -> RemoteRunOutcome {
        let trimmed = statusOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "cancelled" { return .cancelled }
        if trimmed == "running 1" { return .running }
        if let code = Int32(trimmed) { return .exited(code) }
        return .abnormal
    }

    // Mirrors the local shell_execute cap in AIChatViewModel+ConcurrentTools.swift (head/tail halves joined by "...").
    public static func truncateForModel(_ text: String, outputPath: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let half = limit / 2
        return String(text.prefix(half))
            + "\n\n...\n\n"
            + String(text.suffix(half))
            + "\n\n[OUTPUT TRUNCATED] Full output (\(text.count) chars) saved to: \(outputPath)"
    }
}
