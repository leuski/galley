//
//  DocumentModel+Configuration.swift
//  Galley
//
//  Created by Anton Leuski on 5/16/26.
//

import GalleyCoreKit
#if os(visionOS)
import KosmosHTTPTunnel
#endif
import SwiftUI
import WebKit
import KosmosAppKit

extension DocumentModel {
  func tocColumnVisibility(reduceMotion: Bool)
  -> Binding<NavigationSplitViewVisibility>
  {
    Binding(
      get: { [weak self] in self?.showsTOC == true ? .all : .detailOnly },
      set: { [weak self] newValue in
        self?.setShowsTOC(newValue != .detailOnly, reduceMotion: reduceMotion)
      }
    )
  }

  func toggleTOC(reduceMotion: Bool) {
    setShowsTOC(!showsTOC, reduceMotion: reduceMotion)
  }

  func setShowsTOC(_ value: Bool, reduceMotion: Bool) {
    willToggleTOC()
    withAnimationAsNeeded(reduceMotion) {
      showsTOC = value
    } completion: {
      self.didToggleTOC()
    }
  }

  private func willToggleTOC() {
#if os(visionOS)
    pinnedDetailWidth = pinnedDetailWidth ?? liveDetailWidth
#endif
  }

  private func didToggleTOC() {
#if os(visionOS)
    pinnedDetailWidth = nil
#endif
  }
}

/// Type-erased holder so the (visionOS-only) tunnel-client type
/// doesn't leak into the shared `makeConfiguration` signature on
/// macOS. The macOS slice ignores the parameter; visionOS reads the
/// inner client and registers the scheme handler.
struct KosmosTunnelClientRef {
#if os(visionOS)
  let client: Client
#else
  /// macOS keeps the type around for source compatibility but
  /// can't construct it.
  var client: Never? { nil }
#endif
}
