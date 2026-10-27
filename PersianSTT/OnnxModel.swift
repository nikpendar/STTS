import Foundation

/// One ONNX model run with ONNX Runtime's C API (the Persian voice and its phonemizer): float and
/// int64 tensors in, the first output out as floats. Not thread safe; one caller at a time.
final class OnnxModel {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A tensor to feed: int64 or float values and the shape.
    enum Input {
        case int64([Int64], [Int64])
        case float([Float], [Int64])
    }

    private static let api: OrtApi = unwrapped(unwrapped(OrtGetApiBase()).pointee.GetApi(UInt32(ORT_API_VERSION))).pointee
    private static let env: OpaquePointer? = {
        var env: OpaquePointer?
        try? check(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "keyless", &env))
        return env
    }()
    private static let memory: OpaquePointer? = {
        var info: OpaquePointer?
        try? check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &info))
        return info
    }()

    private let session: OpaquePointer
    private let inputNames: [String]
    private let outputName: String

    init(url: URL, threads: Int = 2) throws {
        let api = Self.api
        var options: OpaquePointer?
        try Self.check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        try Self.check(api.SetIntraOpNumThreads(options, Int32(threads)))
        try Self.check(api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        var session: OpaquePointer?
        try Self.check(api.CreateSession(Self.env, url.path, options, &session))
        guard let session else { throw Failure(message: "no session for \(url.lastPathComponent)") }
        self.session = session

        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try Self.check(api.GetAllocatorWithDefaultOptions(&allocator))
        func names(count: (OpaquePointer?, UnsafeMutablePointer<Int>?) -> OpaquePointer?,
                   name: (OpaquePointer?, Int, UnsafeMutablePointer<OrtAllocator>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OpaquePointer?) throws -> [String] {
            var n = 0
            try Self.check(count(session, &n))
            return try (0..<n).map { i in
                var raw: UnsafeMutablePointer<CChar>?
                try Self.check(name(session, i, allocator, &raw))
                defer { _ = api.AllocatorFree(allocator, raw) }
                return String(cString: raw!)
            }
        }
        inputNames = try names(count: api.SessionGetInputCount, name: api.SessionGetInputName)
        outputName = try names(count: api.SessionGetOutputCount, name: api.SessionGetOutputName)[0]
    }

    deinit { Self.api.ReleaseSession(session) }

    /// Runs the model on `inputs`, in the model's input order; returns the first output and its shape.
    func run(_ inputs: [Input]) throws -> (values: [Float], shape: [Int64]) {
        let api = Self.api
        var values: [OpaquePointer?] = []
        // The tensors point into these buffers, which must live until the run ends.
        var buffers: [UnsafeMutableRawBufferPointer] = []
        defer {
            values.forEach { api.ReleaseValue($0) }
            buffers.forEach { $0.deallocate() }
        }
        for input in inputs {
            let (bytes, shape, type): (UnsafeMutableRawBufferPointer, [Int64], ONNXTensorElementDataType)
            switch input {
            case .int64(let data, let s):
                bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, data.count * 8), alignment: 8)
                data.withUnsafeBytes { bytes.copyMemory(from: $0) }
                (shape, type) = (s, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
            case .float(let data, let s):
                bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, data.count * 4), alignment: 4)
                data.withUnsafeBytes { bytes.copyMemory(from: $0) }
                (shape, type) = (s, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
            }
            buffers.append(bytes)
            var value: OpaquePointer?
            try shape.withUnsafeBufferPointer { dims in
                try Self.check(api.CreateTensorWithDataAsOrtValue(Self.memory, bytes.baseAddress, bytes.count,
                                                                  dims.baseAddress, dims.count, type, &value))
            }
            values.append(value)
        }

        var output: OpaquePointer?
        let names = inputNames.map { strdup($0) }
        let outName = strdup(outputName)
        defer {
            names.forEach { free($0) }
            free(outName)
        }
        let inNames: [UnsafePointer<CChar>?] = names.map { UnsafePointer($0) }
        let outNames: [UnsafePointer<CChar>?] = [UnsafePointer(outName)]
        try Self.check(api.Run(session, nil, inNames, values, values.count, outNames, 1, &output))
        defer { api.ReleaseValue(output) }

        var info: OpaquePointer?
        try Self.check(api.GetTensorTypeAndShape(output, &info))
        defer { api.ReleaseTensorTypeAndShapeInfo(info) }
        var rank = 0
        try Self.check(api.GetDimensionsCount(info, &rank))
        var shape = [Int64](repeating: 0, count: rank)
        try Self.check(api.GetDimensions(info, &shape, rank))
        var count = 0
        try Self.check(api.GetTensorShapeElementCount(info, &count))
        var data: UnsafeMutableRawPointer?
        try Self.check(api.GetTensorMutableData(output, &data))
        guard let data else { throw Failure(message: "no output") }
        return (Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)), shape)
    }

    private static func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = String(cString: unwrapped(api.GetErrorMessage(status)))
        api.ReleaseStatus(status)
        throw Failure(message: message)
    }
}

/// The C API's pointers are optional in the iOS headers and not in the macOS ones; this takes both.
private func unwrapped<T>(_ value: T?) -> T { value! }
