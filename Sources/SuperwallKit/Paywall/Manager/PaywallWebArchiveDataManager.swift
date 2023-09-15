//
//  PaywallWebArchiveDataManager.swift
//  
//
//  Created by Jinwoo Kim on 9/15/23.
//

import WebKit
import UniformTypeIdentifiers

@globalActor
actor PaywallWebArchiveDataManager: NSObject {
  static let shared = PaywallWebArchiveDataManager()

  private var webViews: [Paywall: (WKWebView, CheckedContinuation<Data, Error>)] = [:]

  private var baseURL: URL {
    if #available(iOS 16.0, *) {
      return .cachesDirectory
        .appending(component: "PaywallWebArchiveData", directoryHint: .isDirectory)
    } else {
      return FileManager
        .default
        .urls(for: .cachesDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("PaywallWebArchiveData", isDirectory: true)
    }
  }

  private override init() {
    super.init()
  }

  func webArchive(paywall: Paywall) throws -> Data? {
    let webArchiveURL = url(for: paywall)

    guard FileManager.default.fileExists(atPath: webArchiveURL.path) else {
      return nil
    }

    return try .init(contentsOf: webArchiveURL)
  }

  func saveWebArchive(paywall: Paywall) async throws {
    if let oldWebView = webViews[paywall]?.0 {
      await oldWebView.stopLoading()
    }

    let request = URLRequest(url: paywall.url)
    
    let webView: WKWebView = await MainActor.run {
      let webView = WKWebView()
      webView.navigationDelegate = self
      return webView
    }

    try await withTaskCancellationHandler {
      let webArchiveData: Data = try await withCheckedThrowingContinuation { continuation in
        Task {
          webViews[paywall] = (webView, continuation)
          await webView.load(request)
        }
      }

      let baseURL = baseURL
      if !FileManager.default.fileExists(atPath: baseURL.path) {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
      }

      try webArchiveData.write(to: url(for: paywall), options: .atomic)
    } onCancel: {
      Task { @MainActor in
        webView.stopLoading()
      }
    }
  }

  private func url(for paywall: Paywall) -> URL {
    if #available(iOS 16.0, *) {
      return baseURL
        .appendingPathComponent(paywall.databaseId, conformingTo: .webArchive)
    } else {
      return baseURL
        .appendingPathComponent(paywall.databaseId, conformingTo: .webArchive)
    }
  }

  private func remove(webView: WKWebView) {
    webViews = webViews
      .filter { $0.value.0 != webView }
  }

  private func removeWebview(forKey key: Paywall) {
    webViews.removeValue(forKey: key)
  }
}

extension PaywallWebArchiveDataManager: WKNavigationDelegate {
  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task {
      let webArchiveData: Data = try await withCheckedThrowingContinuation { continuation in
        Task { @MainActor in
          webView.createWebArchiveData { result in
            switch result {
            case .success(let data):
              continuation.resume(with: .success(data))
            case .failure(let error):
              continuation.resume(with: .failure(error))
            }
          }
        }
      }

      let webViews = await webViews

      for (key, value) in webViews {
        guard value.0 == webView else { continue }
        value.1.resume(with: .success(webArchiveData))
        await removeWebview(forKey: key)
      }
    }
  }

  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    Task {
      let webViews = await webViews

      for (key, value) in webViews {
        guard value.0 == webView else { continue }
        value.1.resume(with: .failure(error))
        await removeWebview(forKey: key)
      }
    }
  }
}
