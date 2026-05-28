#!/bin/bash
set -u -E

GEMINI_API_KEY="${GEMINI_API_KEY:?GEMINI_API_KEY must be set}"
MODEL_ID="gemini-3.1-flash-image-preview"
GENERATE_CONTENT_API="streamGenerateContent"
SOURCE_IMAGE="/Users/julsh/Downloads/AppIcon-iOS-Default-1024x1024@1x.png"
OUT_DIR="/Users/julsh/git/clipkitty/generated"
PROMPT="update this icon so the clipboard is vertically aligned"
START=${START:-1}
N=${N:-20}

cd "$OUT_DIR"

REQUEST_FILE="$OUT_DIR/request.json"
SOURCE_IMAGE="$SOURCE_IMAGE" PROMPT="$PROMPT" REQUEST_FILE="$REQUEST_FILE" python3 <<'PY'
import base64, json, os
src = os.environ["SOURCE_IMAGE"]
prompt = os.environ["PROMPT"]
req_path = os.environ["REQUEST_FILE"]
with open(src, "rb") as f:
    b64 = base64.b64encode(f.read()).decode("ascii")
body = {
    "contents": [
        {
            "role": "user",
            "parts": [
                {"text": prompt},
                {"inlineData": {"mimeType": "image/png", "data": b64}},
            ],
        }
    ],
    "generationConfig": {
        "responseModalities": ["IMAGE", "TEXT"],
        "thinkingConfig": {"thinkingLevel": "HIGH"},
        "imageConfig": {
            "aspectRatio": "1:1",
            "imageSize": "1K",
        },
    },
}
with open(req_path, "w") as f:
    json.dump(body, f)
print(f"request.json: {os.path.getsize(req_path)} bytes")
PY

URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL_ID}:${GENERATE_CONTENT_API}?key=${GEMINI_API_KEY}"

generate_one() {
    local idx=$1
    local raw="$OUT_DIR/raw_${idx}.json"
    local png="$OUT_DIR/image_${idx}.png"
    local status

    status=$(curl -sS -o "$raw" -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        "$URL" \
        --data-binary "@$REQUEST_FILE")

    if [[ "$status" != "200" ]]; then
        echo "[$idx] HTTP $status"
        head -c 400 "$raw"; echo
        return 1
    fi

    python3 - "$raw" "$png" "$idx" <<'PY'
import base64, json, sys
raw_path, png_path, idx = sys.argv[1], sys.argv[2], sys.argv[3]
with open(raw_path) as f:
    chunks = json.load(f)
image_b64 = None
text_bits = []
for chunk in chunks:
    for cand in chunk.get("candidates", []):
        for part in cand.get("content", {}).get("parts", []):
            if "inlineData" in part and image_b64 is None:
                image_b64 = part["inlineData"].get("data")
            if "text" in part:
                text_bits.append(part["text"])
if image_b64 is None:
    print(f"[{idx}] no image in response. text: {''.join(text_bits)[:300]}")
    sys.exit(2)
with open(png_path, "wb") as f:
    f.write(base64.b64decode(image_b64))
print(f"[{idx}] saved {png_path}")
PY
}

export -f generate_one
export OUT_DIR REQUEST_FILE URL

pids=()
END=$((START + N - 1))
for i in $(seq "$START" "$END"); do
    idx=$(printf "%02d" "$i")
    generate_one "$idx" &
    pids+=($!)
done

fail=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        fail=$((fail+1))
    fi
done

echo "done. failures: $fail"
ls -la "$OUT_DIR"/image_*.png 2>/dev/null | wc -l | xargs echo "images on disk:"
