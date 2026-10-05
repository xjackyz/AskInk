// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AskInk", platforms: [.macOS(.v12)], targets: [
    .target(name: "InkAlgorithms", path: "AskInk", exclude: ["AskInkApp.swift", "ReaderStore.swift", "PDFReader.swift", "Recognition.swift", "ReaderScreen.swift", "ProviderKey.swift", "InkRecognition.swift", "PaddleOCR", "QuestionPreparation.swift", "AnswerOverlay.swift", "InkEngine.swift", "LocalDocumentIndex.swift", "BookSummary.swift", "ReadingToolsPane.swift", "DocumentActions.swift", "QuestionRecovery.swift", "PDFDocumentAdapter.swift", "NativeSemanticIndex.swift", "AIReadingPipeline.swift"], sources: ["InkGrouping.swift", "AIProvider.swift", "AutomaticQuestionState.swift", "InkTool.swift", "QuestionInteraction.swift", "DocumentAlgorithms.swift", "DocumentGraph.swift", "ContextPlanner.swift", "LocalSearchIndex.swift", "AIConversation.swift", "AIStreaming.swift", "AIHistory.swift"], linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "InkAlgorithmsTests", dependencies: ["InkAlgorithms"], path: "Tests/InkAlgorithmsTests")
])
