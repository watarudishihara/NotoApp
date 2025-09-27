// LatexService.swift
import Foundation
import UIKit
import WebKit
import FoundationModels
import Vision
// MARK: - Abstraction

protocol LatexConverting {
    func convert(image: UIImage) async throws -> String
}

enum LatexService {
    static func loadShell(into webView: WKWebView) {
        guard let url = Bundle.main.url(forResource: "PreviewShell", withExtension: "html") else {
            assertionFailure("PreviewShell.html missing from bundle")
            return
        }
        // IMPORTANT: allow bundle root so "katex/.../auto-render.min.js" and fonts resolve.
        webView.loadFileURL(url, allowingReadAccessTo: Bundle.main.bundleURL)
    }

    static func setHTML(_ s: String, on webView: WKWebView) {
        // Escape the string for JS, but preserve $ for math rendering
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            // Don't escape $ - KaTeX needs them for math delimiters
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        let js = "window.Noto && window.Noto.setHTML(`\(escaped)`);"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

enum LatexServiceError: LocalizedError {
    case invalidBaseURL
    case badStatus(Int, String)
    case noData
    case decodeFailed
    case imageEncodingFailed
    case onDeviceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Server URL is not valid. Open Settings and set your Mac’s LAN URL (e.g. http://192.168.x.x:8000)."
        case .badStatus(let code, let body):
            return "Server returned \(code).\n\(body)"
        case .noData:
            return "Server response was empty."
        case .decodeFailed:
            return "Could not decode server response."
        case .imageEncodingFailed:
            return "Could not encode the image for upload."
        case .onDeviceUnavailable(let why):
            return "On-device conversion isn’t available: \(why)"
        }
    }
}

struct LatexResponse: Decodable { let latex: String }

// MARK: - Network backend (your existing flow)

struct NetworkLatexConverter: LatexConverting {
    let apiKey: String

    func convert(image: UIImage) async throws -> String {
        // --- Image as JPEG (like you originally had), and MIME matches ---
        guard let png = image.pngData() else { throw LatexServiceError.noData }
        let b64 = png.base64EncodedString()

        // --- Prompt.txt straight from bundle; short, no extra rules ---
        let promptText: String = {
            if let url = Bundle.main.url(forResource: "Prompt", withExtension: "txt"),
               let s = try? String(contentsOf: url, encoding: .utf8) {
                return s
            }
            return "Convert the handwriting in the image to LaTeX. Return ONLY LaTeX."
        }()

        // --- URL: AI Studio endpoint (NOT Vertex). Model with dot, not hyphen. ---
        let model = "gemini-2.0-flash"   // you can also try "gemini-2.0-flash"
        var comps = URLComponents(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        comps.queryItems = [URLQueryItem(name: "key",
                                         value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))]
        let url = comps.url!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        // --- Minimal body: just contents [{ text, inline_data }] (like before) ---

        let body: [String: Any] = [
          "contents": [[
            "role": "user",
            "parts": [
              ["text": promptText],  // from Prompt.txt
              ["inline_data": ["mime_type": "image/png", "data": b64]]
            ]
          ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Debug
        print("Noto::Gemini URL =>", request.url!.absoluteString)

        // --- Send ---
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LatexServiceError.noData
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw LatexServiceError.badStatus(http.statusCode, snippet)
        }

        // --- Parse (keep whatever parser you already had) ---
        struct GeminiResponse: Decodable {
            struct Candidate: Decodable { let content: Content? }
            struct Content: Decodable { let parts: [Part]? }
            struct Part: Decodable { let text: String? }
            let candidates: [Candidate]?
        }
        let resp = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = resp.candidates?.first?.content?.parts?.compactMap { $0.text }.joined() ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - On-device backend (stub you can later wire to Apple’s on-device model)
#if canImport(FoundationModels)
#if canImport(FoundationModels)
import Vision

struct OnDeviceLatexConverter: LatexConverting {
    func convert(image: UIImage) async throws -> String {
        // Step 1. OCR → plain text
        guard let cg = image.cgImage else {
            throw LatexServiceError.imageEncodingFailed
        }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        try handler.perform([request])
        let recognized = request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ") ?? ""

        guard !recognized.isEmpty else {
            throw LatexServiceError.decodeFailed
        }

        // Step 2. Send to Apple’s on-device LLM
        let session = LanguageModelSession()
        let prompt = """
        You are a LaTeX converter.
        Convert the following math into valid LaTeX.
        Input: \(recognized)
        Output:
        """

        let response = try await session.respond(to: prompt)
        let latex = response.content
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !latex.isEmpty else {
            throw LatexServiceError.decodeFailed
        }
        return latex
    }
}
#else
struct OnDeviceLatexConverter: LatexConverting {
    func convert(image: UIImage) async throws -> String {
        throw LatexServiceError.onDeviceUnavailable("This iOS SDK doesn’t include FoundationModels.")
    }
}
#endif
#else
struct OnDeviceLatexConverter: LatexConverting {
    func convert(image: UIImage) async throws -> String {
        throw LatexServiceError.onDeviceUnavailable("This iOS SDK doesn’t include FoundationModels.")
    }
}
#endif
