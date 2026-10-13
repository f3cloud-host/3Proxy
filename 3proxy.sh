#!/usr/bin/env bash
#
# 3proxy Manager by F3 Cloud
# Installs 3proxy (HTTP/S and SOCKS5 proxy) and manages its users.
#
# Usage:
#   cd /root && curl -fsSL -o 3proxy.sh https://raw.githubusercontent.com/f3cloud-host/3Proxy/main/3proxy.sh && chmod +x 3proxy.sh
#   /root/3proxy.sh
#
# Supported: Debian 11+, Ubuntu 20.04+, AlmaLinux / Rocky / CentOS Stream 8+, with systemd.
# Source: https://github.com/f3cloud-host/3Proxy

set -o pipefail

MANAGER_VERSION="1.1.0"

# 3proxy LTS branch (0.9.x, bugfixes only), built from the official release tarball
PROXY_VERSION="0.9.9.1"
PROXY_SHA256="13711040af096f09d5202b0cb516ec08db7c08130ed21719063d2e570215fb34"
PROXY_URL="https://github.com/3proxy/3proxy/releases/download/${PROXY_VERSION}/3proxy-${PROXY_VERSION}.tar.gz"

BIN="/usr/local/bin/3proxy"
CONF_DIR="/etc/3proxy"
CONF="${CONF_DIR}/3proxy.cfg"
USERS_FILE="${CONF_DIR}/passwd"
STATE="${CONF_DIR}/manager.conf"
UNIT="/etc/systemd/system/3proxy.service"
SERVICE_USER="proxy3"

if [ -t 1 ]; then
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
fi

LINE="------------------------------------------------"

info() { echo "${C_GREEN}$*${C_RESET}"; }
warn() { echo "${C_YELLOW}$*${C_RESET}"; }
die()  { echo "${C_RED}Ошибка: $*${C_RESET}" >&2; exit 1; }

header() {
  echo
  echo "${C_BOLD}3proxy Manager v${MANAGER_VERSION} от F3 Cloud${C_RESET}"
  echo
}

# ---------- checks ----------

require_root() {
  [ "$(id -u)" -eq 0 ] || die "запустите скрипт от имени root, например sudo $0"
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    die "нужна система с systemd"
  fi
}

detect_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG="yum"
  else
    die "система не поддерживается, нужен apt, dnf или yum"
  fi
}

is_installed() {
  [ -f "$STATE" ] && [ -x "$BIN" ]
}

load_state() {
  HTTP_PORT=""; SOCKS_PORT=""; FW=""
  # shellcheck disable=SC1090
  [ -f "$STATE" ] && . "$STATE"
}

# ---------- helpers ----------

ask_yes_no() {
  # ask_yes_no "Question" default(y|n)
  local answer hint="y/n"
  [ "$2" = "y" ] && hint="Y/n"
  [ "$2" = "n" ] && hint="y/N"
  while true; do
    read -r -p "$1 ($hint): " answer
    answer="${answer:-$2}"
    case "$answer" in
      y|Y|yes|YES|д|Д|да|Да) return 0 ;;
      n|N|no|NO|н|Н|нет|Нет) return 1 ;;
      *) warn "Ответьте y (да) или n (нет)." ;;
    esac
  done
}

port_in_use() {
  ss -Htln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
}

ask_port() {
  # ask_port "Prompt" default other_port -> sets REPLY_PORT
  local port
  while true; do
    read -r -p "$1 [$2]: " port
    port="${port:-$2}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      warn "Порт должен быть числом от 1 до 65535."
    elif [ -n "$3" ] && [ "$port" = "$3" ]; then
      warn "Этот порт уже выбран для другого прокси, укажите другой."
    elif port_in_use "$port"; then
      warn "Порт $port уже занят другой программой, укажите другой."
    else
      REPLY_PORT="$port"
      return 0
    fi
  done
}

random_password() {
  local p=""
  while [ "${#p}" -lt 12 ]; do
    p="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"
  done
  echo "$p"
}

server_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  # Behind NAT the local address is private, so ask an external service instead
  if [ -z "$ip" ] || [[ "$ip" =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; then
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null)"
  fi
  echo "${ip:-SERVER_IP}"
}

user_count() {
  grep -c ':CL:' "$USERS_FILE" 2>/dev/null || true
}

user_exists() {
  awk -F: -v u="$1" '$1 == u {found = 1} END {exit !found}' "$USERS_FILE" 2>/dev/null
}

restart_proxy() {
  echo "Применяем изменения..."
  write_config
  systemctl restart 3proxy >/dev/null 2>&1
  sleep 1
  if ! systemctl is-active --quiet 3proxy; then
    die "3proxy не запустился, подробности покажет команда journalctl -u 3proxy -n 50"
  fi
}

print_details() {
  # print_details user password
  local ip
  ip="$(server_ip)"
  echo
  echo "Данные для подключения:"
  echo "$LINE"
  [ -n "$HTTP_PORT" ] && echo "http://${ip}:${HTTP_PORT}:$1:$2"
  [ -n "$SOCKS_PORT" ] && echo "socks5://${ip}:${SOCKS_PORT}:$1:$2"
  echo "$LINE"
  echo
}

# ---------- firewall ----------

firewall_open() {
  local port
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for port in "$@"; do [ -n "$port" ] && ufw allow "${port}/tcp" >/dev/null; done
    FW="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for port in "$@"; do [ -n "$port" ] && firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null; done
    firewall-cmd --reload >/dev/null
    FW="firewalld"
  fi
}

firewall_close() {
  local port
  for port in "$@"; do
    [ -n "$port" ] || continue
    case "$FW" in
      ufw) ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true ;;
      firewalld) firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true ;;
    esac
  done
  if [ "$FW" = "firewalld" ]; then
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

# ---------- install ----------

install_deps() {
  echo "Устанавливаем инструменты для сборки..."
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null || die "не удалось обновить список пакетов"
      apt-get install -y -qq gcc make tar curl ca-certificates iproute2 >/dev/null || die "не удалось установить пакеты"
      ;;
    dnf|yum)
      "$PKG" install -y -q gcc make tar curl ca-certificates iproute >/dev/null || die "не удалось установить пакеты"
      ;;
  esac
}

build_proxy() {
  local tmp
  tmp="$(mktemp -d)"
  echo "Скачиваем 3proxy ${PROXY_VERSION}..."
  curl -fsSL --retry 3 -o "${tmp}/3proxy.tar.gz" "$PROXY_URL" || { rm -rf "$tmp"; die "не удалось скачать $PROXY_URL"; }
  echo "${PROXY_SHA256}  ${tmp}/3proxy.tar.gz" | sha256sum -c --status || { rm -rf "$tmp"; die "контрольная сумма не совпала, архив повреждён"; }

  echo "Собираем 3proxy, это займёт около минуты..."
  tar xzf "${tmp}/3proxy.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "не удалось распаковать архив"; }
  (cd "${tmp}/3proxy-${PROXY_VERSION}" && make -f Makefile.Linux -j"$(nproc)" >"${tmp}/build.log" 2>&1) || {
    tail -n 20 "${tmp}/build.log" >&2
    rm -rf "$tmp"
    die "сборка не удалась"
  }
  install -m 755 "${tmp}/3proxy-${PROXY_VERSION}/bin/3proxy" "$BIN" || { rm -rf "$tmp"; die "не удалось установить программу"; }
  rm -rf "$tmp"
}

write_config() {
  local uid gid
  uid="$(id -u "$SERVICE_USER")"
  gid="$(id -g "$SERVICE_USER")"
  {
    echo "# Создано 3proxy Manager (F3 Cloud). Пользователей меняйте через /root/3proxy.sh"
    echo "nserver 1.1.1.1"
    echo "nserver 8.8.8.8"
    echo "nscache 65536"
    echo "timeouts 1 5 30 60 180 1800 15 60"
    # 3proxy refuses an empty users file, so the line is added only when there are users
    [ -s "$USERS_FILE" ] && echo "users \$${USERS_FILE}"
    echo "setgid ${gid}"
    echo "setuid ${uid}"
    echo "auth strong"
    echo "allow *"
    [ -n "$HTTP_PORT" ] && echo "proxy -n -a -p${HTTP_PORT}"
    [ -n "$SOCKS_PORT" ] && echo "socks -p${SOCKS_PORT}"
  } >"$CONF"
  chmod 600 "$CONF"
}

write_state() {
  {
    echo "HTTP_PORT=\"${HTTP_PORT}\""
    echo "SOCKS_PORT=\"${SOCKS_PORT}\""
    echo "FW=\"${FW}\""
  } >"$STATE"
  chmod 600 "$STATE"
}

write_unit() {
  cat >"$UNIT" <<EOF
[Unit]
Description=3proxy proxy server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} ${CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

do_install() {
  echo
  echo "Установка 3proxy..."
  echo

  HTTP_PORT=""; SOCKS_PORT=""; FW=""
  if ask_yes_no "Включить HTTP/S-прокси?" y; then
    ask_port "Порт HTTP/S-прокси" 3128 ""
    HTTP_PORT="$REPLY_PORT"
  fi
  if ask_yes_no "Включить SOCKS5-прокси?" y; then
    ask_port "Порт SOCKS5-прокси" 1080 "$HTTP_PORT"
    SOCKS_PORT="$REPLY_PORT"
  fi
  [ -n "$HTTP_PORT" ] || [ -n "$SOCKS_PORT" ] || die "нужно включить хотя бы один тип прокси"
  echo

  install_deps
  build_proxy

  id "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER" \
    || die "не удалось создать системного пользователя $SERVICE_USER"

  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR"
  [ -f "$USERS_FILE" ] || : >"$USERS_FILE"
  chmod 600 "$USERS_FILE"

  firewall_open "$HTTP_PORT" "$SOCKS_PORT"
  write_state
  write_unit

  systemctl daemon-reload
  systemctl enable 3proxy >/dev/null 2>&1
  restart_proxy

  echo
  info "3proxy ${PROXY_VERSION} успешно установлен"
  [ -n "$FW" ] && echo "Порты открыты в брандмауэре ${FW}: ${HTTP_PORT} ${SOCKS_PORT}"
  echo
  echo "Теперь создайте первого пользователя прокси."
  do_add_user
}

# ---------- users ----------

do_add_user() {
  local name pass
  echo
  while true; do
    read -r -p "Логин: " name
    if ! [[ "$name" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; then
      warn "Логин может содержать от 1 до 32 символов, это латинские буквы, цифры, точка, дефис и подчёркивание."
    elif user_exists "$name"; then
      warn "Пользователь $name уже есть."
    else
      break
    fi
  done
  while true; do
    read -r -p "Пароль (Enter, чтобы придумать автоматически): " pass
    [ -n "$pass" ] || pass="$(random_password)"
    if [[ "$pass" =~ ^[A-Za-z0-9._@!%+=-]{4,64}$ ]]; then
      break
    fi
    warn "Пароль может содержать от 4 до 64 символов, это латинские буквы, цифры и . _ @ ! % + = -"
  done

  echo "${name}:CL:${pass}" >>"$USERS_FILE"
  restart_proxy
  print_details "$name" "$pass"
}

do_delete_user() {
  local name
  if [ "$(user_count)" -eq 0 ]; then
    echo
    warn "Пользователей пока нет."
    echo
    return
  fi
  do_list_users
  read -r -p "Логин пользователя, которого нужно удалить: " name
  if [ -z "$name" ] || ! user_exists "$name"; then
    warn "Такого пользователя нет."
    echo
    return
  fi
  awk -F: -v u="$name" '$1 != u' "$USERS_FILE" >"${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"
  chmod 600 "$USERS_FILE"
  restart_proxy
  echo
  info "Пользователь $name удалён"
  echo
}

do_list_users() {
  echo
  echo "Пользователи ($(user_count)):"
  echo "$LINE"
  [ -s "$USERS_FILE" ] && sed -n 's/^\([^:]*\):CL:\(.*\)$/\1:\2/p' "$USERS_FILE"
  echo "$LINE"
  echo
}

# ---------- uninstall ----------

do_uninstall() {
  echo
  ask_yes_no "Удалить 3proxy вместе со всеми пользователями?" n || { echo "Отменено."; echo; return; }
  systemctl disable --now 3proxy >/dev/null 2>&1 || true
  rm -f "$UNIT"
  systemctl daemon-reload
  firewall_close "$HTTP_PORT" "$SOCKS_PORT"
  rm -f "$BIN"
  rm -rf "$CONF_DIR"
  id "$SERVICE_USER" >/dev/null 2>&1 && userdel "$SERVICE_USER" >/dev/null 2>&1
  echo
  info "3proxy удалён"
  echo
  exit 0
}

# ---------- menu ----------

main() {
  require_root
  require_systemd
  detect_pkg
  header

  local choice
  if ! is_installed; then
    echo "Выберите действие:"
    echo
    echo "  1. Установить 3proxy"
    echo "  2. Выход"
    echo
    read -r -p "Ваш выбор: " choice
    case "$choice" in
      1) do_install ;;
      *) exit 0 ;;
    esac
    return
  fi

  load_state
  echo "Выберите действие:"
  echo
  echo "  1. Добавить пользователя"
  echo "  2. Удалить пользователя"
  echo "  3. Список пользователей"
  echo "  4. Удалить 3proxy"
  echo "  5. Выход"
  echo
  read -r -p "Ваш выбор: " choice
  case "$choice" in
    1) do_add_user ;;
    2) do_delete_user ;;
    3) do_list_users ;;
    4) do_uninstall ;;
    *) exit 0 ;;
  esac
}

main "$@"
