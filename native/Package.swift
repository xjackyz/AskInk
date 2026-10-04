// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AskInk", platforms: [.macOS(.v12)], targets: [
    .target(name: "InkAlgorithms", path: "AskInk", exclude: ["AskInkApp.swift", "ReaderStore.swift", "PDFReader.swift", "Recognition.swift", "ReaderScreen.swift", "ProviderKey.swift", "InkRecognition.swift", "PencilCanvas.swift", "PaddleOCR"], sources: ["InkGrouping.swift", "InkDynamics.swift", "AIProvider.swift", "AutomaticQuestionState.swift", "InkRendering.swift", "InkTool.swift"]),
    .testTarget(name: "InkAlgorithmsTests", dependencies: ["InkAlgorithms"], path: "Tests/InkAlgorithmsTests")
])
