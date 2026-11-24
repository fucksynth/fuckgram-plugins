"""Signs index.json into index.signed.json for the client's catalog.

The client trusts the official repository only through this file: the
index bytes (base64) and their Ed25519 signature. The private key is the
secret CATALOG_SIGNING_KEY (PEM); its public half is built into the client.
"""
import base64
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX = os.path.join(ROOT, "index.json")
SIGNED = os.path.join(ROOT, "index.signed.json")


def main():
    key = os.environ.get("CATALOG_SIGNING_KEY", "").strip()
    if not key:
        print("CATALOG_SIGNING_KEY is not set: index.signed.json is not updated.")
        return 1
    data = open(INDEX, "rb").read()
    folder = tempfile.mkdtemp()
    key_path = os.path.join(folder, "key.pem")
    data_path = os.path.join(folder, "index.json")
    sig_path = os.path.join(folder, "index.sig")
    try:
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(key + "\n")
        with open(data_path, "wb") as f:
            f.write(data)
        subprocess.run(
            ["openssl", "pkeyutl", "-sign", "-rawin",
             "-inkey", key_path, "-in", data_path, "-out", sig_path],
            check=True)
        signature = open(sig_path, "rb").read()
    finally:
        for path in (key_path, data_path, sig_path):
            if os.path.exists(path):
                os.remove(path)
        os.rmdir(folder)
    if len(signature) != 64:
        print("Unexpected signature size:", len(signature))
        return 1
    result = {
        "index": base64.b64encode(data).decode("ascii"),
        "signature": base64.b64encode(signature).decode("ascii"),
    }
    with open(SIGNED, "w", encoding="utf-8", newline="\n") as f:
        json.dump(result, f, indent=1)
        f.write("\n")
    print(f"index.signed.json: {len(data)} bytes signed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
