"""A file sealed for the Kaggle workflow: the speaker's recordings must not be readable in this
public repository. The workflow's X25519 key comes from the secret KAGGLE_KEY; anyone may seal to
its public key, only the workflow opens.

sealed.py pub                    (env KAGGLE_KEY) prints the public key, hex
sealed.py seal PUBHEX IN OUT     ephemeral X25519 + HKDF-SHA256 + AES-256-GCM
sealed.py open IN OUT            (env KAGGLE_KEY)
sealed.py enc KEYHEX IN OUT / dec KEYHEX IN OUT   AES-256-GCM with a shared key (for the results)
"""
import hashlib, os, sys
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

RAW = (serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def private():
    return X25519PrivateKey.from_private_bytes(hashlib.sha256(b"keyless-speaker-v1:" + os.environ["KAGGLE_KEY"].strip().encode()).digest())


def key(shared, eph, pub):
    return HKDF(hashes.SHA256(), 32, eph + pub, b"keyless-speaker").derive(shared)


cmd = sys.argv[1]
if cmd == "pub":
    print(private().public_key().public_bytes(*RAW).hex())
elif cmd == "seal":
    pub = bytes.fromhex(sys.argv[2])
    e = X25519PrivateKey.generate()
    eph = e.public_key().public_bytes(*RAW)
    k = key(e.exchange(X25519PublicKey.from_public_bytes(pub)), eph, pub)
    open(sys.argv[4], "wb").write(eph + AESGCM(k).encrypt(b"\0" * 12, open(sys.argv[3], "rb").read(), None))
elif cmd == "open":
    blob = open(sys.argv[2], "rb").read()
    p = private()
    k = key(p.exchange(X25519PublicKey.from_public_bytes(blob[:32])), blob[:32], p.public_key().public_bytes(*RAW))
    open(sys.argv[3], "wb").write(AESGCM(k).decrypt(b"\0" * 12, blob[32:], None))
elif cmd == "enc":
    n = os.urandom(12)
    open(sys.argv[4], "wb").write(n + AESGCM(bytes.fromhex(sys.argv[2])).encrypt(n, open(sys.argv[3], "rb").read(), None))
elif cmd == "dec":
    blob = open(sys.argv[3], "rb").read()
    open(sys.argv[4], "wb").write(AESGCM(bytes.fromhex(sys.argv[2])).decrypt(blob[:12], blob[12:], None))
