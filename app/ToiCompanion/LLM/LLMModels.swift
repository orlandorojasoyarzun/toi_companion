import Foundation

/// OpenAI Chat Completions wire types. Worker forwards these verbatim,
/// so the field names must match exactly what OpenAI's API expects.

public enum Role: String, Codable, Sendable {
    case system
    case user
    case assistant
}

public struct ChatMessage: Codable, Sendable {
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatRequest: Codable, Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let stream: Bool
    public let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case maxTokens = "max_tokens"
    }

    public init(model: String, messages: [ChatMessage], stream: Bool, maxTokens: Int? = nil) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.maxTokens = maxTokens
    }
}

/// A single SSE chunk from the OpenAI stream. We only care about the
/// first choice's delta content — the rest is metadata for log noise.
public struct ChatChunk: Codable, Sendable {
    public let choices: [Choice]

    public struct Choice: Codable, Sendable {
        public let delta: Delta?
        public let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    public struct Delta: Codable, Sendable {
        public let content: String?
        public let role: Role?
    }
}