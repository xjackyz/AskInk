// Adapted from PaddlePaddle/PaddleOCR deploy/ios_demo, Apache-2.0.
// Production adapter uses public ONNX Runtime APIs, one CPU provider, no profiling.
import Foundation

struct ORTSessionTuningOptions { var intraOpThreads: Int = 2 }
actor ORTSessionManager {
    private var env: ORTEnv?
    private var det: ORTSession?
    private var rec: ORTSession?
    func loadModels(tuning: ORTSessionTuningOptions = .init()) async throws {
        let environment = try ORTEnv(loggingLevel:.warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(Int32(max(1,tuning.intraOpThreads)))
        let detector = try ORTSession(env:environment,modelPath:ModelConfig.detection().modelPath,sessionOptions:options)
        let recognizer = try ORTSession(env:environment,modelPath:ModelConfig.recognition().modelPath,sessionOptions:options)
        env = environment; det = detector; rec = recognizer
    }
    func runDetection(inputData: [Float], shape: [Int]) async throws -> [String:(data:[Float],shape:[Int])] {
        try run(det,inputData:inputData,shape:shape)
    }
    func runRecognition(inputData: [Float], shape: [Int]) async throws -> [String:(data:[Float],shape:[Int])] {
        try run(rec,inputData:inputData,shape:shape)
    }
    private func run(_ session: ORTSession?, inputData: [Float], shape: [Int]) throws -> [String:(data:[Float],shape:[Int])] {
        guard let session, shape.allSatisfy({$0 > 0}), shape.reduce(1,*) == inputData.count,
              let name = try session.inputNames().first else { throw ReaderError.message("本机识别模型尚未就绪或输入格式不正确。") }
        let bytes = inputData.withUnsafeBytes { NSMutableData(bytes:$0.baseAddress!,length:$0.count) }
        let tensor = try ORTValue(tensorData:bytes,elementType:.float,shape:shape.map { NSNumber(value:$0) })
        let outputs = try session.run(withInputs:[name:tensor],outputNames:Set(session.outputNames()),runOptions:nil)
        var result: [String:(data:[Float],shape:[Int])] = [:]
        for (key,value) in outputs {
            let info = try value.tensorTypeAndShapeInfo()
            let data = try value.tensorData() as Data
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
            guard floats.allSatisfy(\.isFinite) else { throw ReaderError.message("本机识别模型输出异常。") }
            result[key] = (floats, info.shape.map(\.intValue))
        }
        return result
    }
}
