#!/bin/zsh
# 建立一个稳定的本地代码签名身份。
#
# 为什么需要：make_app.sh 之前用 ad-hoc 签名（codesign -s -），每次重新打包
# CDHash 都会变，macOS 会把新包当成"另一个 App"，于是桌面/文稿/下载、
# 自动化等权限每次启动都重新弹窗。换成固定证书后，TCC 授权按
# 「签名身份 + bundle id」记住，重打包不再重复询问。
#
# 幂等：身份已存在就只打印信息，不改动钥匙串。
set -euo pipefail

IDENTITY="Sweep Local Signing"
STORE="$HOME/Library/Application Support/Sweep/signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✅ 已存在签名身份：$IDENTITY"
    exit 0
fi

echo "→ 生成自签名证书：$IDENTITY"
mkdir -p "$STORE"
cd "$STORE"

cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Sweep Local Signing
O = Sweep Local
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
    -days 3650 -config cert.cnf >/dev/null 2>&1
openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 \
    -name "$IDENTITY" -passout pass:sweep-local >/dev/null 2>&1

echo "→ 导入登录钥匙串（只授权 codesign 使用私钥）"
security import identity.p12 -k "$KEYCHAIN" -P sweep-local \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
rm -f identity.p12

echo "→ 把证书标记为本地可信（仅代码签名用途）"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem >/dev/null

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✅ 签名身份就绪：$IDENTITY"
else
    echo "⚠️ 证书已生成但未被信任，将退回 ad-hoc 签名（TCC 授权可能重复询问）"
    exit 0
fi
