// ONNX Runtime's C API for OnnxModel.swift (the Persian voice). The app links the iOS framework
// (setup.sh downloads it into Frameworks/); Tests/TTSCheck builds against the macOS library.
#if __has_include(<onnxruntime/onnxruntime_c_api.h>)
#include <onnxruntime/onnxruntime_c_api.h>
#else
#include "onnxruntime_c_api.h"
#endif
