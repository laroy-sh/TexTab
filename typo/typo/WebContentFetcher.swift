//
//  WebContentFetcher.swift
//  typo
//
//  Fetches and extracts readable text content from web URLs.
//

import Foundation
import AppKit

// MARK: - Web Content Error

enum WebContentError: LocalizedError {
    case invalidURL
    case fetchFailed
    case encodingError
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The selected text is not a valid URL"
        case .fetchFailed: return "Failed to fetch the webpage"
        case .encodingError: return "Could not read the webpage content"
        case .emptyContent: return "The webpage appears to be empty"
        }
    }
}

// MARK: - Web Content Fetcher

class WebContentFetcher {
    static let shared = WebContentFetcher()

    /// Maximum characters to send to AI (~3-4K tokens)
    private let maxContentLength = 12000

    /// Check if a string is a standalone URL and extract it
    func extractURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try the entire string as a URL with scheme
        if let url = URL(string: trimmed), let scheme = url.scheme,
           (scheme == "http" || scheme == "https"), url.host != nil {
            return url
        }

        // Auto-prefix https:// for bare domains (e.g. "example.com")
        if !trimmed.contains(" ") && trimmed.contains(".") {
            let withScheme = "https://" + trimmed
            if let url = URL(string: withScheme), url.host != nil {
                return url
            }
        }

        // Try NSDataDetector as a last resort
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = detector.firstMatch(in: trimmed, range: range),
               let url = match.url,
               match.range.length == range.length {
                return url
            }
        }

        return nil
    }

    /// Fetch webpage content and extract readable text
    func fetchContent(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw WebContentError.fetchFailed
        }

        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else {
            throw WebContentError.encodingError
        }

        let text = stripHTML(html)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebContentError.emptyContent
        }

        return truncateContent(text)
    }

    // MARK: - Private

    /// Strip HTML tags and extract readable text
    private func stripHTML(_ html: String) -> String {
        // Primary: Use NSAttributedString with HTML (built into AppKit)
        if let data = html.data(using: .utf8),
           let attributed = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue
               ],
               documentAttributes: nil
           ) {
            return attributed.string
        }

        // Fallback: regex-based stripping
        var text = html
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>",
                                          with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>",
                                          with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ",
                                          options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "\\s+", with: " ",
                                          options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncate content to stay within token limits
    private func truncateContent(_ text: String) -> String {
        if text.count <= maxContentLength {
            return text
        }
        return String(text.prefix(maxContentLength)) + "\n\n[Content truncated]"
    }
}
