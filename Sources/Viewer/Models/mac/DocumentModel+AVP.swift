//
//  DocumentModel+AVP.swift
//  Galley
//
//  Created by Anton Leuski on 5/22/26.
//

import Foundation
import GalleyCoreKit
import os

private let log = Logger(
  subsystem: bundleIdentifier, category: "DocumentModel+AVP")

extension DocumentModel {
  func showOnVisionPro(kosmos: KosmosViewerService) {
    let docURL = documentURL
    let kosmos = kosmos
    Task {
      do {
        let reply = try await kosmos.routeToAVP(
          DocumentTarget(url: docURL))
        if reply.accepted {
          log.notice("""
                Show on Vision Pro: dispatched \
                \(docURL.lastPathComponent, privacy: .public)
                """)
        } else {
          log.error("""
                Show on Vision Pro: Server declined for \
                \(docURL.path, privacy: .public)
                """)
        }
      } catch {
        // `String(reflecting:)` prints the enum case + payload
        // ("KosmosClientError.linkUnavailable(\"no session…\")"),
        // which is far more useful in logs than the bridged
        // `localizedDescription` even when LocalizedError is
        // wired up. Keep both — the bridged form is what the
        // user would see in a UI alert if we ever surface one.
        log.error("""
              Show on Vision Pro: routeToAVP failed. \
              type=\(String(reflecting: type(of: error)), privacy: .public) \
              case=\(String(reflecting: error), privacy: .public) \
              message=\(error.localizedDescription, privacy: .public)
              """)
      }
    }
  }
}
