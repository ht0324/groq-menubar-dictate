#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="${GROQ_DICTATE_LOCAL_SIGN_IDENTITY:-Groq MenuBar Dictate Local Code Signing}"
KEYCHAIN_PATH="${GROQ_DICTATE_KEYCHAIN:-$(security login-keychain | tr -d '"' | xargs)}"

identity_exists() {
  security find-identity -v -p codesigning "${KEYCHAIN_PATH}" 2>/dev/null \
    | grep -F "\"${IDENTITY_NAME}\"" >/dev/null
}

if identity_exists; then
  echo "Code-signing identity already exists: ${IDENTITY_NAME}"
  security find-identity -v -p codesigning "${KEYCHAIN_PATH}" | grep -F "\"${IDENTITY_NAME}\""
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

OPENSSL_CONFIG="${TMP_DIR}/openssl.cnf"
CERT_PATH="${TMP_DIR}/local-codesign.crt"
KEY_PATH="${TMP_DIR}/local-codesign.key"
P12_PATH="${TMP_DIR}/local-codesign.p12"
P12_PASSWORD="$(uuidgen)"

cat > "${OPENSSL_CONFIG}" <<CONFIG
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = ${IDENTITY_NAME}

[v3_req]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CONFIG

openssl req \
  -new \
  -newkey rsa:2048 \
  -nodes \
  -x509 \
  -days 3650 \
  -sha256 \
  -config "${OPENSSL_CONFIG}" \
  -keyout "${KEY_PATH}" \
  -out "${CERT_PATH}" >/dev/null 2>&1

openssl pkcs12 \
  -export \
  -inkey "${KEY_PATH}" \
  -in "${CERT_PATH}" \
  -out "${P12_PATH}" \
  -passout "pass:${P12_PASSWORD}" >/dev/null 2>&1

security import "${P12_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -f pkcs12 \
  -P "${P12_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "${KEYCHAIN_PATH}" \
  "${CERT_PATH}" >/dev/null

if ! identity_exists; then
  echo "Created certificate, but it is not valid for code signing yet." >&2
  echo "Open Keychain Access and trust '${IDENTITY_NAME}' for code signing, then rerun:" >&2
  echo "  security find-identity -v -p codesigning" >&2
  exit 1
fi

echo "Created code-signing identity: ${IDENTITY_NAME}"
security find-identity -v -p codesigning "${KEYCHAIN_PATH}" | grep -F "\"${IDENTITY_NAME}\""
