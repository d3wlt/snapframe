import AppKit
import Vision

public enum TextRecognizer {
    /// Recognises text in the image using Vision. Honours ocrLanguage ("auto" = automatic detection),
    /// ocrKeepLineBreaks (false joins lines with spaces) and ocrDetectLinks.
    public static func recognize(_ image: CGImage) async throws -> String {
        let language = Prefs.string(PrefKey.ocrLanguage)
        let keep = Prefs.bool(PrefKey.ocrKeepLineBreaks)
        let links = Prefs.bool(PrefKey.ocrDetectLinks)
        let lines = try await Task.detached(priority: .userInitiated) {
            try recognizeLines(image, language: language)
        }.value
        return TextJoiner.join(lines, keepLineBreaks: keep, detectLinks: links)
    }

    /// Recognised lines in reading order (top to bottom, then left to right).
    static func recognizeLines(_ image: CGImage, language: String) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if language.isEmpty || language == "auto" {
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = [language]
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted {
            // Same line (within half a line height): left to right; else top (larger y) first.
            let tol = min($0.boundingBox.height, $1.boundingBox.height) * 0.5
            if abs($0.boundingBox.midY - $1.boundingBox.midY) < tol { return $0.boundingBox.minX < $1.boundingBox.minX }
            return $0.boundingBox.midY > $1.boundingBox.midY
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }
}

/// Joins recognised lines into one string.
public enum TextJoiner {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// A URL that ends a line with one of these is assumed to continue on the next line.
    private static let continuesAtEnd = Set("/-_=&?#%~+")
    /// A next line starting with one of these continues a URL that ended the previous line.
    private static let continuesAtStart = Set("/?&=#%_.~")

    public static func join(_ rawLines: [String], keepLineBreaks: Bool, detectLinks: Bool) -> String {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if keepLineBreaks { return lines.joined(separator: "\n") }
        var out = ""
        var previous = ""
        for line in lines {
            if out.isEmpty {
                out = line
            } else {
                out += (detectLinks && splitsURL(previous, line)) ? line : " " + line
            }
            previous = line
        }
        return out
    }

    /// True when `first` ends inside a URL that evidently continues at the start of `next`.
    static func splitsURL(_ first: String, _ next: String) -> Bool {
        guard let token = first.split(whereSeparator: { $0.isWhitespace }).last.map(String.init),
              isURL(token), let last = token.last, let head = next.first else { return false }
        if continuesAtEnd.contains(last) { return true }
        let nextToken = next.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? next
        return continuesAtStart.contains(head) && nextToken.count > 1
    }

    /// The whole token is a link (so "example." or plain words don't count).
    static func isURL(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..., in: token)
        guard let match = linkDetector?.firstMatch(in: token, options: [], range: range) else { return false }
        return match.range.location == 0 && match.range.length >= range.length - 1
    }
}
