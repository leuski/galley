// swift-tools-version: 6.0
import PackageDescription
import Foundation

/// Prefer a sibling-directory checkout of `name` (typically a
/// symlink at `../<name>` from this package root) when it exists,
/// so library development can iterate without a publish/bump cycle.
/// Drop a `.use_remote` file next to `Package.swift` to force the
/// remote branch even when the local path is present.
func pickLocalOrRemotePackage(
  path relPath: String,
  url: String,
  branch: String
) -> Package.Dependency {
  let cwd = FileManager.default.currentDirectoryPath
  let fullPath = cwd + "/" + relPath
  let useRemoteHint = cwd + "/.use_remote"
  if FileManager.default.fileExists(atPath: fullPath),
     !FileManager.default.fileExists(atPath: useRemoteHint)
  {
    return .package(path: fullPath)
  }
  return .package(url: url, branch: branch)
}

let package = Package(
  name: "GalleyKit",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "GalleyCoreKit", targets: ["GalleyCoreKit"]),
    .library(name: "GalleyServerKit", targets: ["GalleyServerKit"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/swhitty/FlyingFox.git",
      from: "0.26.2"),
    .package(
      url: "https://github.com/swiftlang/swift-markdown",
      from: "0.7.3"),
    pickLocalOrRemotePackage(
      path: "../swift-core-kit",
      url: "https://github.com/leuski/swift-core-kit.git",
      branch: "main")
  ],
  targets: [
    .target(
      name: "GalleyCoreKit",
      dependencies: [
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "ALFoundation", package: "swift-core-kit")
      ],
      resources: [
        .process("Resources")
      ]
    ),
    .target(
      name: "GalleyServerKit",
      dependencies: [
        "GalleyCoreKit",
        .product(name: "FlyingFox", package: "FlyingFox"),
        .product(name: "FlyingSocks", package: "FlyingFox")
      ],
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "GalleyCoreKitTests",
      dependencies: [
        "GalleyCoreKit",
        .product(name: "ALFoundation", package: "swift-core-kit")
      ]
    ),
    .testTarget(
      name: "GalleyServerKitTests",
      dependencies: ["GalleyServerKit"]
    )
  ]
)
