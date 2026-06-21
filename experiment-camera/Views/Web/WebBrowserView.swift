import SwiftUI
import Combine
import UIKit
import WebKit

struct WebBrowserView: View {
    @ObservedObject var browserSession: BrowserSession
    let openRootHome: () -> Void
    let onUserActivity: () -> Void
    @State private var isNavigationBarVisible = true
    @State private var hideNavigationBarTask: Task<Void, Never>?

    private let navigationBarAutoHideDelay: Duration = .seconds(3)

    var body: some View {
        WebViewContainer(
            webView: browserSession.webView,
            onRefresh: browserSession.reloadCurrentPage,
            onRevealNavigationBar: revealNavigationBarTemporarily,
            onNavigateHome: openRootHome,
            onUserActivity: onUserActivity
        )
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isNavigationBarVisible ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    onUserActivity()
                    browserSession.reloadCurrentPage()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reload page")
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            browserSession.loadInitialPageIfNeeded()
            isNavigationBarVisible = true
            scheduleNavigationBarAutoHide()
        }
        .onDisappear {
            hideNavigationBarTask?.cancel()
        }
    }

    private func revealNavigationBarTemporarily() {
        withAnimation {
            isNavigationBarVisible = true
        }

        scheduleNavigationBarAutoHide()
    }

    private func scheduleNavigationBarAutoHide() {
        hideNavigationBarTask?.cancel()
        hideNavigationBarTask = Task {
            try? await Task.sleep(for: navigationBarAutoHideDelay)

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                withAnimation {
                    isNavigationBarVisible = false
                }
            }
        }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    let onRefresh: () -> Void
    let onRevealNavigationBar: () -> Void
    let onNavigateHome: () -> Void
    let onUserActivity: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            webView: webView,
            onRefresh: onRefresh,
            onRevealNavigationBar: onRevealNavigationBar,
            onNavigateHome: onNavigateHome,
            onUserActivity: onUserActivity
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.configureIfNeeded()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.attach(to: uiView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        private weak var webView: WKWebView?
        private let onRefresh: () -> Void
        private let onRevealNavigationBar: () -> Void
        private let onNavigateHome: () -> Void
        private let onUserActivity: () -> Void
        private let refreshControl = UIRefreshControl()
        private let tapGestureRecognizer = UITapGestureRecognizer()
        private let panGestureRecognizer = UIPanGestureRecognizer()
        private let tripleTapGestureRecognizer = UITapGestureRecognizer()
        private let twoFingerSwipeRightGestureRecognizer = UISwipeGestureRecognizer()
        private var isConfigured = false
        private var hasTriggeredNavigationBarRevealForCurrentDrag = false
        private let navigationBarRevealThreshold: CGFloat = 24

        init(
            webView: WKWebView,
            onRefresh: @escaping () -> Void,
            onRevealNavigationBar: @escaping () -> Void,
            onNavigateHome: @escaping () -> Void,
            onUserActivity: @escaping () -> Void
        ) {
            self.webView = webView
            self.onRefresh = onRefresh
            self.onRevealNavigationBar = onRevealNavigationBar
            self.onNavigateHome = onNavigateHome
            self.onUserActivity = onUserActivity
            super.init()
            refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
            tapGestureRecognizer.cancelsTouchesInView = false
            tapGestureRecognizer.delegate = self
            tapGestureRecognizer.addTarget(self, action: #selector(handleTap))

            panGestureRecognizer.cancelsTouchesInView = false
            panGestureRecognizer.delegate = self
            panGestureRecognizer.addTarget(self, action: #selector(handlePan))

            tripleTapGestureRecognizer.numberOfTapsRequired = 3
            tripleTapGestureRecognizer.numberOfTouchesRequired = 1
            tripleTapGestureRecognizer.cancelsTouchesInView = false
            tripleTapGestureRecognizer.delegate = self
            tripleTapGestureRecognizer.addTarget(self, action: #selector(handleTripleTap))

            twoFingerSwipeRightGestureRecognizer.direction = .right
            twoFingerSwipeRightGestureRecognizer.numberOfTouchesRequired = 2
            twoFingerSwipeRightGestureRecognizer.cancelsTouchesInView = false
            twoFingerSwipeRightGestureRecognizer.delegate = self
            twoFingerSwipeRightGestureRecognizer.addTarget(self, action: #selector(handleTwoFingerSwipeRight))
        }

        func configureIfNeeded() {
            guard !isConfigured, let webView else {
                return
            }

            attach(to: webView)
            isConfigured = true
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            webView.navigationDelegate = self
            webView.scrollView.delegate = self

            if webView.scrollView.refreshControl !== refreshControl {
                webView.scrollView.refreshControl = refreshControl
            }

            if tapGestureRecognizer.view !== webView {
                webView.addGestureRecognizer(tapGestureRecognizer)
            }

            if panGestureRecognizer.view !== webView {
                webView.addGestureRecognizer(panGestureRecognizer)
            }

            if tripleTapGestureRecognizer.view !== webView {
                webView.addGestureRecognizer(tripleTapGestureRecognizer)
            }

            if twoFingerSwipeRightGestureRecognizer.view !== webView {
                webView.addGestureRecognizer(twoFingerSwipeRightGestureRecognizer)
            }
        }

        @objc private func handleRefresh() {
            guard webView != nil else {
                refreshControl.endRefreshing()
                return
            }

            onUserActivity()
            onRefresh()
        }

        @objc private func handleTap() {
            onUserActivity()
        }

        @objc private func handlePan(_ gestureRecognizer: UIPanGestureRecognizer) {
            switch gestureRecognizer.state {
            case .began, .changed:
                onUserActivity()
            default:
                break
            }
        }

        @objc private func handleTripleTap() {
            onUserActivity()
            onRevealNavigationBar()
        }

        @objc private func handleTwoFingerSwipeRight() {
            onUserActivity()
            onNavigateHome()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            refreshControl.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            refreshControl.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            refreshControl.endRefreshing()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating {
                onUserActivity()
            }

            let isPullingDown = scrollView.panGestureRecognizer.translation(in: scrollView).y > 0
            let isAtTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top
            let hasExceededRevealThreshold = scrollView.contentOffset.y < -(scrollView.adjustedContentInset.top + navigationBarRevealThreshold)

            guard isPullingDown, isAtTop, hasExceededRevealThreshold else {
                if !isPullingDown {
                    hasTriggeredNavigationBarRevealForCurrentDrag = false
                }

                return
            }

            guard !hasTriggeredNavigationBarRevealForCurrentDrag else {
                return
            }

            hasTriggeredNavigationBarRevealForCurrentDrag = true
            onRevealNavigationBar()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            hasTriggeredNavigationBarRevealForCurrentDrag = false
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            hasTriggeredNavigationBarRevealForCurrentDrag = false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === tapGestureRecognizer
                || gestureRecognizer === panGestureRecognizer
                || gestureRecognizer === tripleTapGestureRecognizer
                || gestureRecognizer === twoFingerSwipeRightGestureRecognizer
        }
    }
}

private struct BrowserURLPersistenceStore: @unchecked Sendable {
    let userDefaults: UserDefaults

    func persist(url: URL?) {
        guard let url,
              let absoluteString = persistentURLString(from: url) else {
            return
        }

        userDefaults.set(absoluteString, forKey: BrowserSession.lastVisitedURLStorageKey)
    }

    private func persistentURLString(from url: URL) -> String? {
        let absoluteString = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        return absoluteString.isEmpty ? nil : absoluteString
    }
}

@MainActor
final class BrowserSession: ObservableObject {
    static let startupURLStorageKey = "webHomeStartupURL"
    static let lastVisitedURLStorageKey = "webHomeLastVisitedURL"
    static let defaultStartupURLString = "http://home-assistant.local:8123"

    let objectWillChange = ObservableObjectPublisher()
    let webView: WKWebView

    private let userDefaults: UserDefaults
    private let persistenceStore: BrowserURLPersistenceStore
    private var urlObservation: NSKeyValueObservation?
    private var hasLoadedInitialPage = false

    init(userDefaults: UserDefaults = .standard) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        self.userDefaults = userDefaults
        self.persistenceStore = BrowserURLPersistenceStore(userDefaults: userDefaults)
        self.webView = WKWebView(frame: .zero, configuration: configuration)

        let persistenceStore = self.persistenceStore
        urlObservation = webView.observe(\.url, options: [.new]) { webView, _ in
            persistenceStore.persist(url: webView.url)
        }
    }

    func loadInitialPageIfNeeded() {
        guard !hasLoadedInitialPage else {
            return
        }

        hasLoadedInitialPage = true
        loadRestoredPage()
    }

    func persistCurrentURLIfNeeded() {
        persistenceStore.persist(url: webView.url)
    }

    func reloadCurrentPage() {
        if webView.url != nil {
            webView.reload()
        } else {
            loadRestoredPage()
        }
    }

    private func loadRestoredPage() {
        guard let url = restoredURL() else {
            return
        }

        webView.load(URLRequest(url: url))
    }

    private func restoredURL() -> URL? {
        Self.normalizedURL(from: userDefaults.string(forKey: Self.lastVisitedURLStorageKey))
            ?? Self.normalizedURL(from: userDefaults.string(forKey: Self.startupURLStorageKey))
            ?? URL(string: Self.defaultStartupURLString)
    }

    nonisolated static func normalizedURL(from rawValue: String?) -> URL? {
        guard let rawValue else {
            return nil
        }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmedValue), let scheme = url.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" else {
                return nil
            }

            return url
        }

        guard let prefixedURL = URL(string: "https://\(trimmedValue)") else {
            return nil
        }

        return prefixedURL
    }
}
