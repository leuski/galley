//
//  GalleyApp.swift
//  Galley
//
//  Created by Anton Leuski on 4/25/26.
//

import AppKit
import Darwin
import SwiftUI
import GalleyCoreKit
import GalleyServerKit
import os

private let bootLog = Logger(
  subsystem: bundleIdentifier, category: "ServerApp")

@main
struct ServerApp: App {
  @State private var boot: AppBoot
  @NSApplicationDelegateAdaptor private var appDelegate: ServerAppDelegate

  init() {
    Self.enforceSingleInstance()
    _boot = State(wrappedValue: AppBoot())
  }

  var body: some Scene {
    MenuBarExtra {
      if let model = boot.model {
        MenuBarContent(
          model: model,
          server: model.server)
          .onAppear { appDelegate.boot = boot }
      } else {
        Text("Starting…")
          .onAppear { appDelegate.boot = boot }
      }
    } label: {
      Image("MenuBarIcon")
    }
    .menuBarExtraStyle(.menu)
  }

  /// If another `net.leuski.galley.server` is already running, exit
  /// immediately. Defense against double-spawn scenarios — Viewer's
  /// stale-server reaper now uses `launchctl kickstart -k` which is
  /// race-free, but this guard catches the cases where two Servers
  /// are launched by different paths (Login Item + explicit
  /// `open Galley\ Server.app`, e.g.) before either is reaped.
  ///
  /// We exit instead of waiting on `NSApplication` lifecycle hooks
  /// because the duplicate process must not bind to the port file
  /// even transiently — see PreviewServer's flock guard.
  private static func enforceSingleInstance() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let myPID = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication
      .runningApplications(withBundleIdentifier: bundleID)
      .filter { $0.processIdentifier != myPID }
    guard !others.isEmpty else { return }
    bootLog.notice("""
      Another \(bundleID, privacy: .public) is already running \
      (pid=\(others.first?.processIdentifier ?? -1, privacy: .public)). \
      Exiting this instance to avoid double-spawn.
      """)
    Darwin.exit(0)
  }
}
