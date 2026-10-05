import SwiftUI
import ScarfCore
import ScarfDesign
import WebKit
import os

struct WebviewWidgetView: View {
    let widget: DashboardWidget
    var fullCanvas: Bool = false

    /// The widget's URL, accepted only when it is `https` with a host.
    ///
    /// The `url` field comes from `.scarf/dashboard.json`, which the agent
    /// writes — so it is untrusted input rendered in a webview that sits
    /// inside the app. `http` is refused (a plaintext page in-app is
    /// trivially MITM-able into script we then run), and so is everything
    /// else: `file:` would turn a dashboard widget into an arbitrary local
    /// file reader, and custom schemes can hand the URL to another app.
    private var webURL: URL? {
        guard let urlString = widget.url,
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Message shown when the URL isn't loadable — wrong scheme or missing.
    private var invalidURLReason: String {
        guard let raw = widget.url, !raw.isEmpty else { return "No URL provided" }
        return "\(raw)\n\nOnly https:// URLs can be shown in a webview widget."
    }

    private var viewHeight: CGFloat {
        CGFloat(widget.height ?? 400)
    }

    @State private var blockedNavigation: String?

    var body: some View {
        if fullCanvas {
            fullCanvasView
        } else {
            cardView
        }
    }

    // MARK: - Full Canvas (Site tab)

    private var fullCanvasView: some View {
        VStack(spacing: 0) {
            if let url = webURL {
                blockedBanner
                // The full-canvas Site tab can use SwiftUI's WebPage on OS 26.
                // The inline card stays on WKWebView, and so does this tab
                // below OS 26. The page is https-only, pinned to the declared
                // host, and uses a non-persistent store. No script handler.
                if #available(macOS 26, *) {
                    SiteWebPage(url: url, blocked: $blockedNavigation)
                        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
                } else {
                    WebViewRepresentable(url: url, blocked: $blockedNavigation)
                        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
                }
            } else {
                ContentUnavailableView {
                    Label("Invalid URL", systemImage: "globe")
                } description: {
                    Text(invalidURLReason)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Card (inline widget)

    private var cardView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let icon = widget.icon {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .scarfStyle(.caption)
                }
                Text(widget.title)
                    .scarfStyle(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let urlString = widget.url {
                    Text(urlString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let url = webURL {
                blockedBanner
                WebViewRepresentable(url: url, blocked: $blockedNavigation)
                    .frame(height: viewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ContentUnavailableView {
                    Label("Invalid URL", systemImage: "globe")
                } description: {
                    Text(invalidURLReason)
                }
                .frame(height: viewHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }

    @ViewBuilder
    private var blockedBanner: some View {
        if let blockedNavigation {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(ScarfColor.warning)
                Text("Blocked navigation to \(blockedNavigation) — this widget is pinned to its declared site.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Dismiss") { self.blockedNavigation = nil }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - OS 26 Site tab

/// Full-canvas Site tab on OS 26. Same rules as `WebViewRepresentable`:
/// https only, main frame pinned to the declared host, non-persistent
/// data store, no script message handler. A refused navigation is visible.
///
/// The page and its decider are created once. SwiftUI rebuilds this view
/// often; a sink allocated in `init` would not be the one the page holds.
@available(macOS 26, *)
private struct SiteWebPage: View {
    let url: URL
    @Binding var blocked: String?
    @State private var session: SiteWebSession?

    var body: some View {
        Group {
            if let session {
                WebView(session.page)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            let session = session ?? SiteWebSession(url: url)
            if self.session == nil { self.session = session }
            session.pin.host = url.host?.lowercased() ?? ""
            session.pin.report = { blocked = $0 }
            // `load` returns a sequence; the navigation starts when it is
            // iterated. Cancelling this task (url change, disappear) stops it.
            do {
                for try await _ in session.page.load(URLRequest(url: url)) {}
            } catch {
                // The decider reports a refused navigation. A failed load
                // leaves that message in place.
            }
        }
    }
}

@available(macOS 26, *)
private final class SiteWebSession {
    let page: WebPage
    let pin: SiteNavigationPin

    init(url: URL) {
        let pin = SiteNavigationPin(host: url.host?.lowercased() ?? "")
        self.pin = pin
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        self.page = WebPage(
            configuration: configuration,
            navigationDecider: SiteNavigationDecider(pin: pin)
        )
    }
}

@available(macOS 26, *)
private final class SiteNavigationPin {
    var host: String
    var report: ((String) -> Void)?

    init(host: String) {
        self.host = host
    }
}

@available(macOS 26, *)
private struct SiteNavigationDecider: WebPage.NavigationDeciding {
    let pin: SiteNavigationPin

    mutating func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        _ = preferences
        let requestURL = action.request.url
        let scheme = requestURL?.scheme?.lowercased()
        let host = requestURL?.host?.lowercased()
        guard scheme == "https" else {
            pin.report?(requestURL?.scheme.map { "\($0):" } ?? "an unknown scheme")
            return .cancel
        }
        // `target` is nil for a new-window navigation. Treat that as the
        // main frame so it stays on the declared host. Subframes may be
        // https anywhere (CDNs, embeds).
        let mainFrame = action.target?.isMainFrame ?? true
        if !mainFrame {
            return .allow
        }
        let pinnedHost = pin.host
        guard !pinnedHost.isEmpty, let host,
              host == pinnedHost || host.hasSuffix("." + pinnedHost) else {
            pin.report?(host ?? "an unknown host")
            return .cancel
        }
        return .allow
    }

    mutating func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        .allow
    }
}

// MARK: - WKWebView Wrapper

private struct WebViewRepresentable: NSViewRepresentable {
    let url: URL
    /// Set to the host (or scheme) of a navigation the delegate refused, so
    /// the widget can SAY it blocked something instead of just showing a
    /// page that mysteriously never changes.
    @Binding var blocked: String?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.pinnedHost = url.host?.lowercased()
        context.coordinator.onBlocked = { blocked = $0 }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pinnedHost = url.host?.lowercased()
        context.coordinator.onBlocked = { blocked = $0 }
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Pins the widget to the site its `url` declared.
    ///
    /// Without a policy delegate the widget was an open browser: the loaded
    /// page (or any script on it) could navigate itself anywhere —
    /// `file:///Users/…`, turning a dashboard widget into a local-file
    /// viewer; a phishing origin wearing the dashboard's chrome; or a
    /// custom scheme that hands off to another app. There is no address bar
    /// here, so nothing would tell the user it had happened.
    ///
    /// Policy: main-frame navigation must be `https` on the declared host
    /// (or a subdomain of it); subresource / subframe loads must be `https`
    /// but may go anywhere, since a normal page's images, fonts and frames
    /// legitimately come from CDNs. Everything else is cancelled and
    /// surfaced in the widget.
    class Coordinator: NSObject, WKNavigationDelegate {
        private let logger = Logger(subsystem: "com.scarf", category: "WebviewWidgetView")

        var pinnedHost: String?
        var onBlocked: ((String) -> Void)?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased()
            let host = url?.host?.lowercased()

            guard scheme == "https" else {
                block(url?.absoluteString ?? "?", label: scheme.map { "\($0):" } ?? "an unknown scheme")
                decisionHandler(.cancel)
                return
            }
            // Subresources / iframes: https anywhere is fine (CDNs, embeds).
            guard navigationAction.targetFrame?.isMainFrame ?? true else {
                decisionHandler(.allow)
                return
            }
            guard let pinnedHost, let host,
                  host == pinnedHost || host.hasSuffix("." + pinnedHost) else {
                block(url?.absoluteString ?? "?", label: host ?? "an unknown host")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func block(_ full: String, label: String) {
            // The URL is page-controlled: the public log line carries the
            // decision, the payload goes to `.private`.
            logger.warning("blocked webview widget navigation off the pinned host")
            logger.debug("blocked webview widget navigation: \(full, privacy: .private)")
            onBlocked?(label)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.warning("WebView navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            logger.warning("WebView failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }
}
