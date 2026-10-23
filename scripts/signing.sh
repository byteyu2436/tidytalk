# 由 build-app.sh、make-dmg.sh 引用：决定用哪个身份签名。
#
# 没有设置 SIGN_IDENTITY 时，钥匙串里有作者的自签名证书"Tidytalk Self-Signed"就用它，否则用临时签名（-）。
# 自签名证书让系统按证书识别 Tidytalk：别的程序冒充同一个 bundle id 也拿不到它的权限，
# 而且每个版本用同一张证书签名，升级后辅助功能、麦克风等授权不会失效。
# 证书和私钥的备份不在仓库里，丢了以后再发版，所有用户都要重新授权一次。
SELF_SIGNED_IDENTITY="Tidytalk Self-Signed"
if [[ -z "${SIGN_IDENTITY+x}" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SELF_SIGNED_IDENTITY\""; then
    SIGN_IDENTITY="$SELF_SIGNED_IDENTITY"
  else
    SIGN_IDENTITY="-"
  fi
fi
export SIGN_IDENTITY
