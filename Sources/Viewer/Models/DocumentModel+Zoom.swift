//
//  DocumentModel+Zoom.swift
//  Galley
//

import Observation
import WebKit
import GalleyCoreKit

extension DocumentModel {
  /// Drives WebKit page zoom for one document window. Holds the model
  /// weakly so it can read the live `page`; `zoomScale` is observed so
  /// the toolbar's zoom label updates.
  @MainActor @Observable
  final class ZoomController: WebPageZoomController {
    var zoomScale: Double = 1

    var page: WebPage? { model?.page }

    weak var model: DocumentModel?
  }
}
