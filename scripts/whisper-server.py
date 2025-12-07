#!/usr/bin/env python3
from flask import Flask, request, jsonify
from lightning_whisper_mlx import LightningWhisperMLX
import tempfile
import time
import os

app = Flask(__name__)

print("Loading Lightning Whisper MLX (distil-large-v3 model)...")
start = time.time()
whisper = LightningWhisperMLX(model="distil-large-v3", batch_size=12)
print(f"Model loaded in {time.time()-start:.2f}s")

@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "ok", "model": "distil-large-v3"})

@app.route('/transcribe', methods=['POST'])
def transcribe():
    if 'audio' not in request.files:
        return jsonify({"error": "No audio file provided"}), 400

    audio_file = request.files['audio']

    with tempfile.NamedTemporaryFile(delete=False, suffix='.wav') as tmp:
        audio_file.save(tmp.name)
        tmp_path = tmp.name

    try:
        start = time.time()
        result = whisper.transcribe(tmp_path)
        elapsed_ms = int((time.time() - start) * 1000)

        return jsonify({
            "text": result['text'].strip(),
            "elapsed_ms": elapsed_ms
        })
    finally:
        os.unlink(tmp_path)

if __name__ == '__main__':
    print("Starting Lightning Whisper server on port 5050...")
    app.run(host='0.0.0.0', port=5050, threaded=False)
