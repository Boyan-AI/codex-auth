#!/usr/bin/env bash

set -euo pipefail

# 输出固定英文错误并拒绝把 NewAPI Token 交给 Codex。
fail_closed() {
    echo "Refusing to expose the NewAPI client token because Codex may send the local NewAPI request to a non-loopback proxy. Use direct or loopback macOS proxy settings, and add the NewAPI host to NO_PROXY (or no_proxy) for terminal proxies." >&2
    exit 78
}

# 按 reqwest 使用的大小写优先级读取第一个已定义环境变量。
first_defined_environment_value() {
    local variable_name=""
    for variable_name in "$@"; do
        if declare -p "${variable_name}" >/dev/null 2>&1; then
            printf '%s' "${!variable_name}"
            return 0
        fi
    done
    return 0
}

# 从已由 Codex Auth 校验的回环 Base URL 中提取协议和主机。
parse_loopback_base_url() {
    local base_url="$1"
    local authority=""
    local parsed_scheme=""
    local parsed_host=""

    case "${base_url}" in
        http://*) parsed_scheme="http" ;;
        https://*) parsed_scheme="https" ;;
        *) return 1 ;;
    esac
    authority="${base_url#*://}"
    authority="${authority%%/*}"
    [[ -n "${authority}" && "${authority}" != *"@"* ]] || return 1

    if [[ "${authority}" == \[* ]]; then
        [[ "${authority}" == *\]* ]] || return 1
        parsed_host="${authority#\[}"
        parsed_host="${parsed_host%%\]*}"
    else
        parsed_host="${authority%%:*}"
    fi

    shopt -s nocasematch
    case "${parsed_host}" in
        127.0.0.1|localhost|::1) ;;
        *) return 1 ;;
    esac
    shopt -u nocasematch
    printf '%s\n%s\n' "${parsed_scheme}" "${parsed_host}"
}

# 判断 NO_PROXY 是否包含目标回环主机或全局通配符。
no_proxy_matches_host() {
    local no_proxy_value="$1"
    local target_host="$2"
    local entry=""
    local entries=()
    local IFS=','
    [[ -n "${no_proxy_value}" ]] || return 1
    read -r -a entries <<< "${no_proxy_value}"
    shopt -s nocasematch
    for entry in "${entries[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        case "${entry}" in
            "*"|"${target_host}"|".${target_host}")
                shopt -u nocasematch
                return 0
                ;;
        esac
    done
    shopt -u nocasematch
    return 1
}

# 从环境变量中返回 reqwest 会优先用于指定协议的代理地址。
effective_environment_proxy() {
    local scheme="$1"
    local scheme_proxy=""
    local all_proxy=""
    if [[ "${scheme}" == "http" ]]; then
        scheme_proxy="$(first_defined_environment_value HTTP_PROXY http_proxy)"
    else
        scheme_proxy="$(first_defined_environment_value HTTPS_PROXY https_proxy)"
    fi
    all_proxy="$(first_defined_environment_value ALL_PROXY all_proxy)"
    if [[ -n "${scheme_proxy}" ]]; then
        printf '%s' "${scheme_proxy}"
    else
        printf '%s' "${all_proxy}"
    fi
}

# 判断代理地址的目标主机是否仍位于本机回环接口。
proxy_destination_is_loopback() {
    local proxy_value="$1"
    local authority="${proxy_value}"
    local proxy_host=""
    [[ -n "${proxy_value}" ]] || return 1
    if [[ "${authority}" == *"://"* ]]; then
        authority="${authority#*://}"
    fi
    authority="${authority%%/*}"
    authority="${authority##*@}"
    if [[ "${authority}" == \[* ]]; then
        [[ "${authority}" == *\]* ]] || return 1
        proxy_host="${authority#\[}"
        proxy_host="${proxy_host%%\]*}"
    else
        proxy_host="${authority%%:*}"
    fi
    shopt -s nocasematch
    case "${proxy_host}" in
        127.0.0.1|localhost|::1)
            shopt -u nocasematch
            return 0
            ;;
    esac
    shopt -u nocasematch
    return 1
}

# 判断 macOS 代理不会把请求送出本机；无法静态证明的自动代理失败关闭。
system_proxy_route_is_safe() {
    local scheme="$1"
    local enable_key="HTTPEnable"
    local proxy_key="HTTPProxy"
    local proxy_settings=""
    local automatic_proxy_enabled=""
    local enabled=""
    local proxy_host=""
    if [[ "${scheme}" != "http" ]]; then
        enable_key="HTTPSEnable"
        proxy_key="HTTPSProxy"
    fi
    proxy_settings="$(/usr/sbin/scutil --proxy 2>/dev/null)" || return 2
    automatic_proxy_enabled="$(/usr/bin/awk '
        ($1 == "ProxyAutoConfigEnable" || $1 == "ProxyAutoDiscoveryEnable") && $2 == ":" && $3 == "1" {
            print "1"
            exit
        }
    ' <<< "${proxy_settings}")"
    [[ "${automatic_proxy_enabled}" != "1" ]] || return 1

    enabled="$(/usr/bin/awk -v key="${enable_key}" '$1 == key && $2 == ":" { print $3; exit }' \
        <<< "${proxy_settings}")"
    if [[ "${enabled}" == "1" ]]; then
        proxy_host="$(/usr/bin/awk -v key="${proxy_key}" '$1 == key && $2 == ":" { print $3; exit }' \
            <<< "${proxy_settings}")"
        proxy_destination_is_loopback "${proxy_host}" || return 1
    fi
    return 0
}

# 仅在目标回环请求可确认直连时读取并输出受保护的 NewAPI Token。
main() {
    if [[ $# -ne 2 ]]; then
        echo "Usage: $0 <base-url> <client-config-path>" >&2
        exit 64
    fi

    local base_url="$1"
    local client_config_path="$2"
    local parsed_url=""
    local scheme=""
    local host=""
    local no_proxy_value=""
    local environment_proxy=""
    local proxy_status=0
    local api_key=""

    parsed_url="$(parse_loopback_base_url "${base_url}")" || fail_closed
    scheme="${parsed_url%%$'\n'*}"
    host="${parsed_url#*$'\n'}"
    no_proxy_value="$(first_defined_environment_value NO_PROXY no_proxy)"

    system_proxy_route_is_safe "${scheme}" || proxy_status=$?
    case "${proxy_status}" in
        0) ;;
        *) fail_closed ;;
    esac

    environment_proxy="$(effective_environment_proxy "${scheme}")"
    if [[ -n "${environment_proxy}" ]] && \
        ! proxy_destination_is_loopback "${environment_proxy}" && \
        ! no_proxy_matches_host "${no_proxy_value}" "${host}"; then
        fail_closed
    fi

    [[ "${client_config_path}" == /* && -f "${client_config_path}" ]] || fail_closed
    api_key="$(/usr/bin/plutil -extract api_key raw -o - "${client_config_path}" 2>/dev/null)" || fail_closed
    [[ -n "${api_key}" ]] || fail_closed
    printf '%s\n' "${api_key}"
}

main "$@"
