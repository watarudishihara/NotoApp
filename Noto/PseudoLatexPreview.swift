//
//  PseudoLatexPreview.swift
//  NTex
//
//  Created by Wataru Ishihara on 9/11/25.
//
import SwiftUI
import WebKit

struct PseudoLatexPreview: UIViewRepresentable {
    let text: String
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var ready = false
        var pending: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let html = pending {
                LatexService.setHTML(html, on: webView)
                pending = nil
            }
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = context.coordinator

        LatexService.loadShell(into: wv)

        // ⚠️ Don't push HTML before the shell finishes loading.
        // Content will be set via updateUIView when ready

        return wv
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.ready {
            LatexService.setHTML(text, on: webView)
        } else {
            context.coordinator.pending = text
        }
    }
}
