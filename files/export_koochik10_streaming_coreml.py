#!/usr/bin/env python3
"""Export Shenava Koochik 1.0 (114.8M) true cache-aware streaming CTC step to CoreML.

One cache-aware encoder step + auxiliary CTC head, as an iOS14-target CoreML
NeuralNetwork (valid on iOS15+; ANE-friendly on modern iPhones), fp16 weights —
the same proven path as the deployed 32M staticmask model.

  processed_signal [1,80,feature_frames] + caches -> logits + next caches

feature_frames is derived correctly as pre_encode_cache_size + chunk_size (NOT the
stale shift+2 formula): e.g. att[70,1] -> 9+16 = 25, matching the deployed 32M Swift.
"""

from __future__ import annotations

import argparse
import json
import time
import types
from pathlib import Path

import coremltools as ct
from coremltools.models.neural_network import quantization_utils
import nemo.collections.asr as nemo_asr
import numpy as np
import torch


def install_static_full_cache_masks(encoder, att_context: list[int]) -> None:
    """Freeze mask creation for the steady-state full-cache streaming step.

    The traced graph always feeds a full feature chunk and a full left-cache.
    NeMo's generic mask builder uses dynamic shape ops the CoreML NeuralNetwork
    frontend chokes on; this emits equivalent constant masks for that fixed case.
    """

    def _static_create_masks(self, att_context_size, padding_length, max_audio_length, offset, device):
        total = int(max_audio_length)
        rows = torch.arange(total, device=device).view(total, 1)
        cols = torch.arange(total, device=device).view(1, total)
        left, right = int(att_context[0]), int(att_context[1])
        if self.att_context_style == "chunked_limited":
            chunk_size = right + 1
            row_chunk = torch.div(rows, chunk_size, rounding_mode="trunc")
            col_chunk = torch.div(cols, chunk_size, rounding_mode="trunc")
            diff_chunks = row_chunk - col_chunk
            left_chunks = left // chunk_size if left >= 0 else 10000
            allowed = torch.logical_and(diff_chunks <= left_chunks, diff_chunks >= 0)
        else:
            allowed = torch.ones((total, total), dtype=torch.bool, device=device)
            if left >= 0:
                allowed = torch.logical_and(allowed, cols >= rows - left)
            if right >= 0:
                allowed = torch.logical_and(allowed, cols <= rows + right)
        att_mask = torch.logical_not(allowed).unsqueeze(0)
        pad_mask = torch.zeros((1, total), dtype=torch.bool, device=device)
        return pad_mask, att_mask

    encoder._create_masks = types.MethodType(_static_create_masks, encoder)


class StreamingCTCStep(torch.nn.Module):
    def __init__(self, model, att_context: list[int], feature_frames: int, constant_cache_len: int, local_attn: bool):
        super().__init__()
        self.encoder = model.encoder
        # Hybrid RNNT/CTC models expose the CTC head as `ctc_decoder`; pure-CTC
        # models (the smallest student) expose it as `decoder`.
        self.ctc_decoder = getattr(model, "ctc_decoder", None) or model.decoder
        self.encoder.change_attention_model(
            self_attention_model="rel_pos_local_attn" if local_attn else None,
            att_context_size=att_context,
            update_config=False,
            device=torch.device("cpu"),
        )
        self.encoder.setup_streaming_params(att_context_size=att_context)
        self.feature_frames = int(feature_frames)
        self.constant_cache_len = int(constant_cache_len)

    def forward(self, processed_signal, cache_last_channel, cache_last_time):
        processed_signal_length = processed_signal.new_full((1,), self.feature_frames, dtype=torch.int64)
        cache_last_channel_len = processed_signal.new_full((1,), self.constant_cache_len, dtype=torch.int64)
        encoded, _encoded_len, next_channel, next_time, _next_len = self.encoder.cache_aware_stream_step(
            processed_signal=processed_signal,
            processed_signal_length=processed_signal_length,
            cache_last_channel=cache_last_channel,
            cache_last_time=cache_last_time,
            cache_last_channel_len=cache_last_channel_len,
            keep_all_outputs=False,
        )
        logits = self.ctc_decoder(encoder_output=encoded)
        return logits, next_channel, next_time


def package_size(path: Path) -> int:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file()) if path.is_dir() else path.stat().st_size


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--nemo", required=True, type=Path)
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument("--att-context", default="70,1")
    ap.add_argument("--name", required=True)
    ap.add_argument("--local-attn", action="store_true", help="use rel_pos_local_attn instead of static-mask full attention")
    ap.add_argument("--keep-fp32", action="store_true")
    args = ap.parse_args()

    att_context = [int(x.strip()) for x in args.att_context.split(",")]
    out_dir = args.out_dir.expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    local_attn = bool(args.local_attn)

    print(f"[restore] {args.nemo}", flush=True)
    model = nemo_asr.models.ASRModel.restore_from(str(args.nemo.expanduser().resolve()), map_location="cpu").eval()
    model.encoder.change_attention_model(
        self_attention_model="rel_pos_local_attn" if local_attn else None,
        att_context_size=att_context,
        update_config=False,
        device=torch.device("cpu"),
    )
    model.encoder.setup_streaming_params(att_context_size=att_context)
    if not local_attn:
        install_static_full_cache_masks(model.encoder, att_context)

    cfg = model.encoder.streaming_cfg
    pre_encode = int(cfg.pre_encode_cache_size[1] if isinstance(cfg.pre_encode_cache_size, list) else cfg.pre_encode_cache_size)
    chunk = int(cfg.chunk_size[1] if isinstance(cfg.chunk_size, list) else cfg.chunk_size)
    shift = int(cfg.shift_size[1] if isinstance(cfg.shift_size, list) else cfg.shift_size)
    feature_frames = pre_encode + chunk  # left-context cache frames + streaming chunk
    constant_cache_len = int(cfg.last_channel_cache_size)
    valid_out_len = int(cfg.valid_out_len)

    step = StreamingCTCStep(model, att_context, feature_frames, constant_cache_len, local_attn=local_attn).eval()
    cache_channel, cache_time, _cache_len = model.encoder.get_initial_cache_state(1, torch.float32, torch.device("cpu"))
    x = torch.randn(1, 80, feature_frames, dtype=torch.float32)
    with torch.no_grad():
        logits, next_channel, next_time = step(x, cache_channel, cache_time)
    print(
        f"[probe] att={att_context} pre_encode={pre_encode} chunk={chunk} shift={shift} "
        f"feature_frames={feature_frames} valid_out_len={valid_out_len} logits={tuple(logits.shape)} "
        f"cache_channel={tuple(cache_channel.shape)} cache_time={tuple(cache_time.shape)}",
        flush=True,
    )

    ts_path = out_dir / f"{args.name}.torchscript.pt"
    print(f"[trace] {ts_path}", flush=True)
    with torch.no_grad():
        traced = torch.jit.trace(step, (x, cache_channel, cache_time), strict=False, check_trace=False).eval()
        traced.save(str(ts_path))

    fp32_path = out_dir / f"{args.name.replace('_fp16', '_fp32')}.mlmodel"
    fp16_path = out_dir / f"{args.name}.mlmodel"
    for p in [fp32_path, fp16_path]:
        if p.exists():
            p.unlink()
    print(f"[convert] neuralnetwork iOS14-target fp32 -> {fp32_path}", flush=True)
    mlmodel = ct.convert(
        traced,
        source="pytorch",
        convert_to="neuralnetwork",
        minimum_deployment_target=ct.target.iOS14,
        inputs=[
            ct.TensorType(name="processed_signal", shape=x.shape, dtype=np.float32),
            ct.TensorType(name="cache_last_channel", shape=cache_channel.shape, dtype=np.float32),
            ct.TensorType(name="cache_last_time", shape=cache_time.shape, dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="logits"),
            ct.TensorType(name="cache_last_channel_next"),
            ct.TensorType(name="cache_last_time_next"),
        ],
    )
    mlmodel.save(str(fp32_path))

    print(f"[quantize] fp16 weights -> {fp16_path}", flush=True)
    fp16_model = quantization_utils.quantize_weights(mlmodel, nbits=16)
    fp16_model.save(str(fp16_path))
    if not args.keep_fp32 and fp32_path.exists():
        fp32_path.unlink()

    smoke = ct.models.MLModel(str(fp16_path))
    pred = smoke.predict({
        "processed_signal": x.numpy().astype(np.float32),
        "cache_last_channel": cache_channel.numpy().astype(np.float32),
        "cache_last_time": cache_time.numpy().astype(np.float32),
    })
    pred_shapes = {k: list(np.asarray(v).shape) for k, v in pred.items()}
    # argmax agreement of the CoreML fp16 step vs the torch fp32 step on this input
    torch_arg = logits.detach().numpy().reshape(-1, logits.shape[-1]).argmax(-1)
    cm_logits = np.asarray(pred["logits"]).reshape(-1, logits.shape[-1])
    cm_arg = cm_logits.argmax(-1)
    n = min(len(torch_arg), len(cm_arg))
    agree = float((torch_arg[:n] == cm_arg[:n]).mean()) if n else 0.0

    manifest = {
        "created_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source_repo": "Reza2kn/Shenava-Koochik-1.0",
        "source_nemo": str(args.nemo.expanduser().resolve()),
        "format": "CoreML NeuralNetwork iOS14-target fp16-weight true cache-aware streaming CTC step",
        "att_context": att_context,
        "self_attention_model": "rel_pos_local_attn" if local_attn else "static_full_cache_mask",
        "pre_encode_cache_size": pre_encode,
        "chunk_size": chunk,
        "shift_size": shift,
        "feature_frames": feature_frames,
        "audio_ms_per_prediction": feature_frames * 10,
        "valid_out_len": valid_out_len,
        "constant_cache_len": constant_cache_len,
        "vocab_size": int(logits.shape[-1]),
        "inputs": {
            "processed_signal": list(x.shape),
            "cache_last_channel": list(cache_channel.shape),
            "cache_last_time": list(cache_time.shape),
        },
        "outputs": {
            "logits": list(logits.shape),
            "cache_last_channel_next": list(next_channel.shape),
            "cache_last_time_next": list(next_time.shape),
        },
        "coreml_predict_shapes": pred_shapes,
        "fp16_vs_fp32_argmax_agreement": agree,
        "artifacts": {"mlmodel": str(fp16_path), "bytes": package_size(fp16_path)},
    }
    (out_dir / f"{args.name}_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[done] {args.name} | feature_frames={feature_frames} valid_out={valid_out_len} "
          f"argmax_agree={agree:.4f} bytes={package_size(fp16_path)}", flush=True)


if __name__ == "__main__":
    main()
