#!/usr/bin/env bash
# Download Pizzicato's AI models (ONNX, from their public releases), check
# their sha256, and convert them to fp16 .mnn with MNN's converter
# (`pip install MNN` provides `mnnconvert`).
#
#   tools/fetch_models.sh [name ...]      # default: all
#
# PZ_MODELS      where the .mnn files go (default ~/.local/share/pizzicato/models)
# PZ_MODELS_SRC  where the downloads go  (default $PZ_MODELS/src)
#
# Every model here has a GPL-compatible licence (listed per entry).
set -euo pipefail

PZ_MODELS="${PZ_MODELS:-$HOME/.local/share/pizzicato/models}"
SRC="${PZ_MODELS_SRC:-$PZ_MODELS/src}"
CONVERT="${MNNCONVERT:-$(command -v mnnconvert || command -v MNNConvert || true)}"
mkdir -p "$PZ_MODELS" "$SRC"
HF=https://huggingface.co
QAI=https://qaihub-public-assets.s3.us-west-2.amazonaws.com/qai-hub-models/models

fetch() { # url dest sha256
    local url=$1 dest=$2 sum=$3
    mkdir -p "$(dirname "$dest")"
    if [[ ! -f "$dest" ]] || ! echo "$sum  $dest" | sha256sum -c --quiet - 2>/dev/null; then
        echo "[fetch_models] $url"
        curl -fL --retry 3 -o "$dest.part" "$url"
        mv "$dest.part" "$dest"
    fi
    echo "$sum  $dest" | sha256sum -c --quiet - || { echo "checksum mismatch: $dest" >&2; exit 1; }
}

convert() { # onnx mnn
    local onnx=$1 out="$PZ_MODELS/$2"
    [[ -f "$out" && "$out" -nt "$onnx" ]] && return 0
    [[ -n "$CONVERT" ]] || { echo "mnnconvert not found (pip install MNN)" >&2; exit 1; }
    echo "[fetch_models] converting $(basename "$onnx") -> $2"
    "$CONVERT" -f ONNX --modelFile "$onnx" --MNNModel "$out" --bizCode pizzicato --fp16 >"$out.log" 2>&1
}

model_nafnet() { # denoise, default (MIT, megvii-research/NAFNet SIDD width64; export by Qualcomm AI Hub)
    fetch "$QAI/nafnet_denoise/releases/v0.66.0/nafnet_denoise-onnx-float.zip" "$SRC/nafnet/nafnet.zip" \
        d4278669af02a04320389dbd8fd3d1a24c06f887701a2735d2b311fdff27ac62
    (cd "$SRC/nafnet" && unzip -oq nafnet.zip)
    convert "$SRC/nafnet/nafnet_denoise-onnx-float/nafnet_denoise.onnx" nafnet_sidd.mnn
}

model_scunet() { # denoise, high quality (Apache-2.0, cszn/SCUNet color_real_psnr)
    local u=$HF/Heliosoph/scunet-onnx/resolve/main
    fetch "$u/scunet_color_real_psnr.onnx" "$SRC/scunet/scunet_color_real_psnr.onnx" \
        231be201ab413dbc999d7951caa9844846b93a12a40a41e037d6b5888ed4e88c
    fetch "$u/scunet_color_real_psnr.onnx.data" "$SRC/scunet/scunet_color_real_psnr.onnx.data" \
        98825ea1210b641c71e5f052f582c70c49fd44b35387ebe2c034268c17df3feb
    convert "$SRC/scunet/scunet_color_real_psnr.onnx" scunet_real.mnn
}

model_esrgan() { # super-resolution x4 (BSD-3, xinntao/Real-ESRGAN general-x4v3; export by Qualcomm AI Hub)
    fetch "$QAI/real_esrgan_general_x4v3/releases/v0.66.0/real_esrgan_general_x4v3-onnx-float.zip" \
        "$SRC/esrgan/esrgan.zip" fc094329b24a00c936ebc1cc4c51bc59633e7dc36f4a553344342171cbd3c7cf
    (cd "$SRC/esrgan" && unzip -oq esrgan.zip)
    convert "$SRC/esrgan/real_esrgan_general_x4v3-onnx-float/real_esrgan_general_x4v3.onnx" esrgan_x4v3.mnn
}

model_mobilesam() { # subject selection (Apache-2.0 MobileSAM; ONNX export by Acly, MIT)
    local u=$HF/Acly/MobileSAM/resolve/main
    fetch "$u/mobile_sam_image_encoder.onnx" "$SRC/mobilesam/mobile_sam_image_encoder.onnx" \
        580f5fb648ea1062c0aabc26217aed56921985f03f0cbbd852bba81d760cc749
    fetch "$u/sam_mask_decoder_single.onnx" "$SRC/mobilesam/sam_mask_decoder_single.onnx" \
        93915fc7c993ab9d59ab8c9ccd3bce37f7509c81ab4150a74abd4d2abbd8570d
    convert "$SRC/mobilesam/mobile_sam_image_encoder.onnx" mobilesam_enc.mnn
    convert "$SRC/mobilesam/sam_mask_decoder_single.onnx" mobilesam_dec.mnn
}

model_clip() { # search by description (MIT, OpenAI CLIP ViT-B/32; ONNX export by Xenova)
    local u=$HF/Xenova/clip-vit-base-patch32/resolve/main
    fetch "$u/onnx/vision_model.onnx" "$SRC/clip/vision_model.onnx" \
        fd6e1402a588279d1723c7534d4bcba5bc0b14b47dfab0e46f8c47b8270d7d40
    fetch "$u/onnx/text_model.onnx" "$SRC/clip/text_model.onnx" \
        3f6571f5bad13a97c469c1622e1cfc4d9aef78b79fdbfcff804ca357bfada8cc
    fetch "$u/vocab.json" "$SRC/clip/vocab.json" 5047b556ce86ccaf6aa22b3ffccfc52d391ea4accdab9c2f2407da5b742d4363
    fetch "$u/merges.txt" "$SRC/clip/merges.txt" 9fd691f7c8039210e0fced15865466c65820d09b63988b0174bfe25de299051a
    convert "$SRC/clip/vision_model.onnx" clip_vision.mnn
    convert "$SRC/clip/text_model.onnx" clip_text.mnn
    cp "$SRC/clip/vocab.json" "$PZ_MODELS/clip_vocab.json"
    cp "$SRC/clip/merges.txt" "$PZ_MODELS/clip_merges.txt"
}

model_faces() { # People: YuNet detection (MIT) and SFace recognition (Apache-2.0), OpenCV zoo
    fetch "$HF/opencv/face_detection_yunet/resolve/main/face_detection_yunet_2023mar.onnx" \
        "$SRC/face/yunet.onnx" 8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4
    fetch "$HF/opencv/face_recognition_sface/resolve/main/face_recognition_sface_2021dec.onnx" \
        "$SRC/face/sface.onnx" 0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79
    convert "$SRC/face/yunet.onnx" face_yunet.mnn
    convert "$SRC/face/sface.onnx" face_sface.mnn
}

ALL=(nafnet scunet esrgan mobilesam clip faces)
for m in "${@:-${ALL[@]}}"; do
    "model_$m"
done
echo "[fetch_models] models in $PZ_MODELS"
