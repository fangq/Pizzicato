#!/usr/bin/env bash
# Package the converted models (made by tools/fetch_models.sh) into the
# per-feature zip bundles Pizzicato downloads on first use (src/pzmodels.pas).
# Upload the zips to the server PZ_MODELS_URL points at, then paste the
# printed table into PZ_BUNDLES in src/pzmodels.pas.
#
#   tools/package_models.sh [bundle ...]     # default: all
#
# PZ_MODELS   where the models are (default ~/.local/share/pizzicato/models)
# PZ_DIST     where the zips go     (default $PZ_MODELS/dist)
#
# Each zip holds its files with paths relative to the model directory, so
# unzipping it there installs the feature. The bundle version (-v1) changes
# whenever a model in it does.
set -euo pipefail

PZ_MODELS="${PZ_MODELS:-$HOME/.local/share/pizzicato/models}"
PZ_DIST="${PZ_DIST:-$PZ_MODELS/dist}"
VER=v1
mkdir -p "$PZ_DIST"

# bundle -> files (keep in step with PZ_BUNDLES in src/pzmodels.pas)
declare -A FILES=(
    [denoise]="nafnet_sidd.mnn"
    [denoise-hq]="scunet_real.mnn"
    [upscale]="esrgan_x4v3.mnn"
    [remove]="mobilesam_enc.mnn mobilesam_dec2.mnn mobilesam_dec3.mnn mobilesam_dec4.mnn mobilesam_dec5.mnn mobilesam_dec6.mnn lama.mnn"
    [search]="clip_vision.mnn clip_text.mnn clip_vocab.json clip_merges.txt"
    [faces]="face_yunet.mnn face_sface.mnn"
    [captions]="smolvlm256m/config.json smolvlm256m/llm_config.json smolvlm256m/llm.mnn smolvlm256m/llm.mnn.weight smolvlm256m/visual.mnn smolvlm256m/visual.mnn.weight smolvlm256m/tokenizer.mtok smolvlm256m/embeddings_bf16.bin"
)
ALL=(denoise denoise-hq upscale remove search faces captions)

for b in "${@:-${ALL[@]}}"; do
    [[ -n "${FILES[$b]:-}" ]] || { echo "unknown bundle $b" >&2; exit 1; }
    zipf="$PZ_DIST/pizzicato-$b-$VER.zip"
    rm -f "$zipf"
    # -X: no extra attributes, so the same files give the same zip
    (cd "$PZ_MODELS" && zip -q -X -9 "$zipf" ${FILES[$b]})
    printf "    (Name: '%s'; Zip: '%s'; Bytes: %d; Sha256: '%s'),\n" "$b" "$(basename "$zipf")" \
        "$(stat -c %s "$zipf")" "$(sha256sum "$zipf" | cut -c1-64)"
done
echo "[package_models] zips in $PZ_DIST" >&2
