//
//  UniversalLinkManager.swift
//  Reynard
//
//  Created by Minh Ton on 12/8/26.
//

import Foundation
import GeckoView
import MessageUI
import UIKit

final class UniversalLinkManager: NSObject, MFMessageComposeViewControllerDelegate {
    private struct HandoffKey: Hashable {
        let session: ObjectIdentifier
        let uri: String
    }

    // In-flight handoffs per (session, uri); waiting callers join the first one.
    private var handoffCompletions: [HandoffKey: [(AllowOrDeny) -> Void]] = [:]
    private var failedHandoffs = Set<HandoffKey>()
    private var recentExternalHandoffs = Set<HandoffKey>()

    func decideHandoff(
        for request: LoadRequest,
        in session: GeckoSession,
        completion: @escaping (AllowOrDeny) -> Void
    ) {
        if handleExternalScheme(for: request, in: session, completion: completion) {
            return
        }
        guard
            Prefs.BrowsingSettings.openLinksInExternalApps,
            !session.isPrivateMode,
            request.isUserInitiatedNavigation,
            let url = URL(string: request.uri),
            URLUtils.isWebURL(url)
        else {
            completion(.allow)
            return
        }

        if let triggerUri = request.triggerUri,
           let triggerURL = URL(string: triggerUri),
           let triggerHost = triggerURL.host,
           let destinationHost = url.host,
           triggerHost.caseInsensitiveCompare(destinationHost) == .orderedSame {
            completion(.allow)
            return
        }

        let key = HandoffKey(session: ObjectIdentifier(session), uri: request.uri)
        if failedHandoffs.contains(key) {
            completion(.allow)
            return
        }
        if handoffCompletions[key] != nil {
            handoffCompletions[key]?.append(completion)
            return
        }
        handoffCompletions[key] = [completion]

        open(url) { [weak self] didOpen in
            guard let self else { return }
            let completions = self.handoffCompletions.removeValue(forKey: key) ?? []
            if didOpen {
                self.failedHandoffs.remove(key)
            } else {
                self.failedHandoffs.insert(key)
            }
            for completion in completions {
                completion(didOpen ? .deny : .allow)
            }
        }
    }

    // Gecko cannot load native iOS schemes itself. Only hand off schemes we
    // explicitly recognize, and only for a navigation initiated by the user.
    // Do not pass Android intent:// or arbitrary schemes to UIApplication.
    private func handleExternalScheme(
        for request: LoadRequest,
        in session: GeckoSession,
        completion: @escaping (AllowOrDeny) -> Void
    ) -> Bool {
        guard let colon = request.uri.firstIndex(of: ":") else { return false }
        let scheme = request.uri[..<colon].lowercased()
        guard ["sms", "smsto", "tel", "mailto", "facetime", "facetime-audio"].contains(scheme) else {
            return false
        }
        guard !session.isPrivateMode,
              request.hasUserGesture || request.isUserInitiatedNavigation else {
            return false
        }

        let key = HandoffKey(session: ObjectIdentifier(session), uri: request.uri)
        if recentExternalHandoffs.contains(key) {
            completion(.deny)
            return true
        }
        if handoffCompletions[key] != nil {
            handoffCompletions[key]?.append(completion)
            return true
        }
        handoffCompletions[key] = [completion]
        let finish: (Bool) -> Void = { [weak self] didOpen in
            guard let self else { return }
            if didOpen {
                self.recentExternalHandoffs.insert(key)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.recentExternalHandoffs.remove(key)
                }
            }
            let callbacks = self.handoffCompletions.removeValue(forKey: key) ?? []
            callbacks.forEach { $0(didOpen ? .deny : .allow) }
        }

        if scheme == "sms" || scheme == "smsto" {
            presentMessageComposer(for: request.uri, completion: finish)
        } else if let url = URL(string: request.uri) {
            UIApplication.shared.open(url, options: [:], completionHandler: finish)
        } else {
            finish(false)
        }
        return true
    }

    // Google sometimes passes sms:/%2B...%3Fbody%3D%25E5..., where the
    // outer URI and the body have each been percent-encoded once. Decode each
    // layer separately; never send a message without showing iOS's composer.
    private func presentMessageComposer(
        for rawURI: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard MFMessageComposeViewController.canSendText(),
              let decoded = rawURI.removingPercentEncoding else {
            completion(false)
            return
        }
        let schemeEnd = decoded.firstIndex(of: ":") ?? decoded.startIndex
        let afterScheme = decoded.index(after: schemeEnd)
        let addressAndQuery = decoded[afterScheme...].drop(while: { $0 == "/" })
        let parts = addressAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let recipient = String(parts[0])
        let allowed = CharacterSet(charactersIn: "+0123456789,; ")
        guard !recipient.isEmpty, recipient.count <= 64,
              recipient.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            completion(false)
            return
        }
        let body: String?
        if parts.count > 1, parts[1].lowercased().hasPrefix("body=") {
            body = String(parts[1].dropFirst(5)).removingPercentEncoding
        } else {
            body = nil
        }
        guard body == nil || (body!.count <= 2048 && !body!.contains("\u{0000}")) else {
            completion(false)
            return
        }
        guard let root = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            completion(false)
            return
        }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = self
        composer.recipients = [recipient]
        composer.body = body
        presenter.present(composer, animated: true) { completion(true) }
    }

    func messageComposeViewController(
        _ controller: MFMessageComposeViewController,
        didFinishWith result: MessageComposeResult
    ) {
        controller.dismiss(animated: true)
    }

    func didCommitNavigation(in session: GeckoSession) {
        let sessionID = ObjectIdentifier(session)
        failedHandoffs = Set(failedHandoffs.filter { $0.session != sessionID })
        recentExternalHandoffs = Set(recentExternalHandoffs.filter { $0.session != sessionID })
    }

    func didCreateNewSession(from session: GeckoSession, for uri: String) {
        failedHandoffs.remove(
            HandoffKey(session: ObjectIdentifier(session), uri: uri)
        )
    }

    // Must run on the main thread (decideHandoff is invoked from engine
    // delegates, which dispatch there). The 5-second timeout mirrors the
    // upstream gate so a stuck open() call can't wedge navigation.
    private func open(_ url: URL, completion: @escaping (Bool) -> Void) {
        var finished = false
        let finish: (Bool) -> Void = { result in
            guard !finished else { return }
            finished = true
            completion(result)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            finish(false)
        }
        UIApplication.shared.open(
            url,
            options: [.universalLinksOnly: true],
            completionHandler: { success in
                finish(success)
            }
        )
    }
}
