#!/usr/bin/env bash

storpulse_signing_fail() {
  echo "$1" >&2
  return 1
}

storpulse_resolve_development_signing() {
  local signing_config="$1"
  if [[ ! -f "${signing_config}" ]]; then
    storpulse_signing_fail \
      "未找到 ${signing_config}；请填写 DEVELOPMENT_TEAM，或显式使用 --adhoc。"
    return 1
  fi

  local development_team
  development_team="$(
    sed -nE \
      's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Za-z0-9]+)[[:space:]]*$/\1/p' \
      "${signing_config}" |
      tail -n 1
  )"
  if [[ -z "${development_team}" ]]; then
    storpulse_signing_fail "Config.local.xcconfig 缺少有效的 DEVELOPMENT_TEAM。"
    return 1
  fi

  local configured_identity
  configured_identity="$(
    sed -nE \
      's/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=[[:space:]]*(Apple Development:.+[^[:space:]])[[:space:]]*$/\1/p' \
      "${signing_config}" |
      tail -n 1
  )"

  local identities
  if ! identities="$(security find-identity -v -p codesigning 2>&1)"; then
    storpulse_signing_fail "无法读取本机代码签名身份：${identities}"
    return 1
  fi

  local identity_line
  local candidate
  local signing_identity=""
  local match_count=0
  while IFS= read -r identity_line; do
    if [[ "${identity_line}" != *'"Apple Development:'* ]]; then
      continue
    fi
    candidate="${identity_line#*\"}"
    candidate="${candidate%%\"*}"
    if [[ -n "${configured_identity}" && "${candidate}" != "${configured_identity}" ]]; then
      continue
    fi
    signing_identity="${candidate}"
    match_count=$((match_count + 1))
  done <<<"${identities}"

  if [[ "${match_count}" -eq 0 ]]; then
    storpulse_signing_fail "未找到可用的 Apple Development 签名身份。"
    return 1
  fi
  if [[ "${match_count}" -gt 1 ]]; then
    storpulse_signing_fail \
      "存在多个 Apple Development 身份；请在 Config.local.xcconfig 中填写 CODE_SIGN_IDENTITY。"
    return 1
  fi

  printf '%s\t%s\n' "${development_team}" "${signing_identity}"
}

storpulse_verify_development_certificate() {
  local signing_identity="$1"
  local development_team="$2"
  local debug_directory="$3"
  local certificate_path="${debug_directory}/apple-development-certificate.pem"
  local certificate_subject
  local verification_output

  if ! security find-certificate -c "${signing_identity}" -p >"${certificate_path}"; then
    rm -f "${certificate_path}"
    storpulse_signing_fail "无法导出 Apple Development 公钥证书用于信任链校验。"
    return 1
  fi
  if ! certificate_subject="$(
    openssl x509 -in "${certificate_path}" -noout -subject 2>&1
  )"; then
    rm -f "${certificate_path}"
    storpulse_signing_fail "无法读取 Apple Development 证书主题：${certificate_subject}"
    return 1
  fi
  if [[ "${certificate_subject}" != *"OU=${development_team}"* &&
    "${certificate_subject}" != *"OU = ${development_team}"* ]]; then
    rm -f "${certificate_path}"
    storpulse_signing_fail "Apple Development 证书不属于配置的团队 ${development_team}。"
    return 1
  fi
  if ! verification_output="$(
    security verify-cert -c "${certificate_path}" -p codeSign 2>&1
  )"; then
    rm -f "${certificate_path}"
    storpulse_signing_fail \
      "Apple Development 证书信任链校验失败：${verification_output}"
    return 1
  fi
  rm -f "${certificate_path}"
}

storpulse_sign_debug_app() {
  local signing_mode="$1"
  local signing_context="$2"
  local app_bundle="$3"
  local bundle_identifier="$4"
  local debug_directory="$5"
  local development_team=""
  local signing_identity=""

  if [[ "${signing_mode}" == "development" ]]; then
    development_team="${signing_context%%$'\t'*}"
    signing_identity="${signing_context#*$'\t'}"
    if [[ -z "${development_team}" || -z "${signing_identity}" ]]; then
      storpulse_signing_fail "Development 签名上下文无效。"
      return 1
    fi
    storpulse_verify_development_certificate \
      "${signing_identity}" \
      "${development_team}" \
      "${debug_directory}"
    echo "使用 Apple Development 签名（Team：${development_team}）"
    codesign \
      --force \
      --sign "${signing_identity}" \
      --identifier "${bundle_identifier}" \
      --timestamp=none \
      --preserve-metadata=entitlements \
      "${app_bundle}"
  else
    echo "使用本机 ad-hoc 签名"
    codesign \
      --force \
      --sign - \
      --identifier "${bundle_identifier}" \
      --timestamp=none \
      --preserve-metadata=entitlements \
      "${app_bundle}"
  fi

  local verification_output
  if ! verification_output="$(
    codesign --verify --deep --strict --verbose=2 "${app_bundle}" 2>&1
  )"; then
    if [[ "${signing_mode}" == "development" ]] &&
      grep -Fq "CSSMERR_TP_NOT_TRUSTED" <<<"${verification_output}"; then
      echo "codesign 报告本机信任提示；Apple Development 证书链已独立校验通过。"
    else
      storpulse_signing_fail "Debug 应用签名完整性校验失败：${verification_output}"
      return 1
    fi
  fi

  local signing_details
  signing_details="$(codesign -dvvv "${app_bundle}" 2>&1)"
  if ! grep -Fq "Identifier=${bundle_identifier}" <<<"${signing_details}"; then
    storpulse_signing_fail "Debug 应用签名后的 Bundle 标识不正确。"
    return 1
  fi
  if [[ "${signing_mode}" == "development" ]] &&
    ! grep -Fq "TeamIdentifier=${development_team}" <<<"${signing_details}"; then
    storpulse_signing_fail "Debug 应用签名后的 Team Identifier 不正确。"
    return 1
  fi

  local entitlements
  entitlements="$(codesign -d --entitlements - "${app_bundle}" 2>&1)"
  if ! grep -Fq "com.apple.security.get-task-allow" <<<"${entitlements}"; then
    storpulse_signing_fail "Debug 应用签名后缺少 LLDB 所需的调试权限。"
    return 1
  fi
}
