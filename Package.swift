// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "IPCamKit",
  platforms: [
    .iOS(.v16),
    .tvOS(.v16),
    .macCatalyst(.v16),
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "IPCamKit",
      targets: ["IPCamKit"]
    )
  ],
  targets: [
    .target(
      name: "IPCamKit",
      path: "Sources/IPCamKit"
    ),
    .executableTarget(
      name: "CameraViewer",
      dependencies: ["IPCamKit"],
      path: "Examples/CameraViewer"
    ),
    .testTarget(
      name: "IPCamKitTests",
      dependencies: ["IPCamKit"],
      path: "Tests/IPCamKitTests",
      resources: [.copy("TestData")]
    )
  ]
)
