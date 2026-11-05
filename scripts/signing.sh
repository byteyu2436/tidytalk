# 由 build-app.sh、make-dmg.sh 引用：决定用哪个身份签名。
#
# 没有设置 SIGN_IDENTITY 时，按顺序选：
#   1. 钥匙串里的 Developer ID Application 证书（0.4.2 起的正式版都用它，并经过苹果公证）；
#   2. 作者的自签名证书"Tidytalk Self-Signed"（0.3.0 到 0.4.1 的正式版用它）；
#   3. 临时签名（-）。
# 系统按签名证书识别 Tidytalk：别的程序冒充同一个 bundle id 也拿不到它的权限，
# 升级后辅助功能、麦克风等授权不会失效。Developer ID 按团队 ID 识别，同一团队换一张新证书不影响授权；
# 换成另一种签名（例如从自签名换到 Developer ID）后，用户要重新授权一次。
# 证书和私钥的备份不在仓库里。
SELF_SIGNED_IDENTITY="Tidytalk Self-Signed"
if [[ -z "${SIGN_IDENTITY+x}" ]]; then
  DEVELOPER_ID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  if [[ -n "$DEVELOPER_ID_IDENTITY" ]]; then
    SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY"
  elif security find-identity -p codesigning 2>/dev/null | grep -q "\"$SELF_SIGNED_IDENTITY\""; then
    SIGN_IDENTITY="$SELF_SIGNED_IDENTITY"
  else
    SIGN_IDENTITY="-"
  fi
fi
export SIGN_IDENTITY
