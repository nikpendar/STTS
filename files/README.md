---
language:
- fa
license: apache-2.0
library_name: coreml
pipeline_tag: automatic-speech-recognition
base_model:
- Reza2kn/Shenava-Koochik-v1.0
base_model_relation: quantized
tags:
- coreml
- neuralnetwork
- ios
- ios15
- ios14
- persian
- farsi
- asr
- fastconformer
- streaming
- ctc
- fp16
- on-device
- shenava
- shenava-1
- visualears
---

# 🍎📱🎙️ Shenava Koochik 1.0 — Core ML streaming for iOS 15

Cache-aware FP16 Core ML **NeuralNetwork** export for Apple devices that cannot use the newer ML Program package. It uses Core ML specification version 5, has iOS 14/macOS 11 availability, and is designed to compile and run on iOS 15.

## ✨ At a glance | معرفی سریع

| | English | فارسی |
|---|---|---|
| 📱 Role | Streaming ASR for older Apple devices | تشخیص گفتار جریانی برای دستگاه‌های قدیمی‌تر اپل |
| 📦 Format | FP16 Core ML NeuralNetwork | NeuralNetwork با وزن‌های FP16 |
| ⏱️ Step | One prediction per 170 ms | یک پیش‌بینی در هر ۱۷۰ میلی‌ثانیه |
| 🧠 State | Cache-aware; caches cross calls | cacheها بین فراخوانی‌ها منتقل می‌شوند |
| 🎯 Target | iOS 15; spec supports iOS 14/macOS 11 | هدف iOS 15 با سازگاری spec قدیمی‌تر |

- Canonical repository: [`Reza2kn/Shenava-Koochik-1.0-CoreML-iOS15-fp16`](https://huggingface.co/Reza2kn/Shenava-Koochik-1.0-CoreML-iOS15-fp16)
- PersianML mirror: [`PersianML/Shenava-Koochik-1.0-CoreML-iOS15-fp16`](https://huggingface.co/PersianML/Shenava-Koochik-1.0-CoreML-iOS15-fp16)
- Parent: [`Reza2kn/Shenava-Koochik-v1.0`](https://huggingface.co/Reza2kn/Shenava-Koochik-v1.0)

## 🌊 Streaming contract

Each call produces one CTC step from a 170 ms feature window and returns the caches for the next call.

Inputs:

- `processed_signal`: FP32 `[1, 80, 17]`
- `cache_last_channel`: FP32 `[17, 1, 70, 512]`
- `cache_last_time`: FP32 `[17, 1, 512, 8]`

Outputs:

- `logits`: FP32 `[1, 1, 1025]`
- `cache_last_channel_next`: FP32 `[17, 1, 70, 512]`
- `cache_last_time_next`: FP32 `[17, 1, 512, 8]`

The graph uses 9 frames of pre-encode cache plus an 8-frame chunk, 17 conformer layers, and a constant channel-cache length of 70. Initialize both caches to zero and thread each `*_next` output into the next call.

## 📦 Files

- `*_ios15_fp16.mlmodel`: 212 MB NeuralNetwork model.
- `*_manifest.json`: authoritative streaming shapes and export provenance.
- `tokens.json`, `mel_filters_slaney_80x257.json`, `preprocessor.json`: tokenizer/feature assets.
- `export_koochik10_streaming_coreml.py`: reproducible exporter.

For the streaming graph, treat `shenava_koochik_1_0_ctc_streaming_att70_0_ios15_fp16_manifest.json` and the export script as authoritative. The fixed-window fields retained in `preprocessor.json` describe the shared feature pipeline, not this graph’s 17-frame tensor contract.

Published FP16-versus-FP32 argmax agreement: 1.000.

## 🛠️ Compile for iOS 15

```bash
xcrun coremlcompiler compile \
  shenava_koochik_1_0_ctc_streaming_att70_0_ios15_fp16.mlmodel \
  ./CompiledModels \
  --deployment-target 15.0 \
  --platform ios
```

## 🇮🇷 خلاصهٔ فارسی

این نسخه برای اجرای جریانی روی iOS 15 و دستگاه‌های قدیمی‌تر اپل ساخته شده است. در هر فراخوانی ۱۷۰ میلی‌ثانیه پردازش می‌شود و cacheهای خروجی باید به فراخوانی بعدی داده شوند. قرارداد دقیق tensorها در فایل manifest قرار دارد.

## 🌌 Explore Shenava-1

[🧠 Koochik source](https://huggingface.co/Reza2kn/Shenava-Koochik-v1.0) · [🍎 Modern fixed-window Core ML](https://huggingface.co/Reza2kn/Shenava-Koochik-v1.0-CoreML-fp16) · **📱 iOS 15 streaming** · [🌐 Browser ONNX](https://huggingface.co/Reza2kn/Shenava-Koochik-v1.0-ONNX-fp16) · [🦀 Rust streaming](https://huggingface.co/Reza2kn/Shenava-Koochik-v1.0-tract-streaming)

Apache-2.0. Output numbers are spoken-form Persian unless the host applies ITN.
