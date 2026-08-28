#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/etc/backhaul/config.toml"
SERVICE="/etc/systemd/system/backhaul.service"
BACKUP_DIR="/etc/backhaul/backups"
DEFAULT_BIN="/root/backhaul"

die(){ echo -e "\n[خطا] $*\n"; exit 1; }
pause(){ read -r -p $'\nEnter برای ادامه... ' _ || true; }
need_root(){ [[ $EUID -eq 0 ]] || die "اسکریپت باید با root اجرا شود."; }

choose_bin(){
  if [[ -x "$DEFAULT_BIN" ]]; then BIN="$DEFAULT_BIN"
  elif command -v backhaul >/dev/null 2>&1; then BIN="$(command -v backhaul)"
  else
    read -r -p "مسیر کامل فایل backhaul: " BIN
    [[ -x "$BIN" ]] || die "فایل اجرایی پیدا نشد: $BIN"
  fi
}

valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

backup_config(){
  mkdir -p "$BACKUP_DIR"
  [[ -f "$CONFIG" ]] && cp -a "$CONFIG" "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).toml"
}

write_service(){
  local role="$1"
  cat > "$SERVICE" <<EOF
[Unit]
Description=Backhaul Tunnel $role
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/root
ExecStart=$BIN -c $CONFIG
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable backhaul >/dev/null
  systemctl restart backhaul || systemctl start backhaul
  echo
  systemctl --no-pager --full status backhaul || true
}

write_server(){
  read -r -p "پورت کنترل Backhaul [3080]: " bind_port
  bind_port="${bind_port:-3080}"
  valid_port "$bind_port" || die "پورت نامعتبر."

  read -r -s -p "Token: " token; echo
  [[ -n "$token" ]] || die "Token خالی است."

  echo "پروتکل: 1) TCP  2) TCPMUX  3) WS  4) WSS"
  read -r -p "انتخاب [1]: " p; p="${p:-1}"
  case "$p" in
    1) proto="tcp";; 2) proto="tcpmux";; 3) proto="ws";; 4) proto="wss";;
    *) die "انتخاب نامعتبر.";;
  esac

  cert=""; key=""
  if [[ "$proto" == "wss" ]]; then
    read -r -p "مسیر TLS Certificate: " cert
    read -r -p "مسیر TLS Private Key: " key
    [[ -f "$cert" && -f "$key" ]] || die "Certificate/Key پیدا نشد."
  fi

  echo
  echo "Forwardها را به صورت local=remote وارد کنید."
  echo "مثال: 443=8080"
  echo "برای پایان Enter خالی بزنید."
  ports=()
  while :; do
    read -r -p "Forward: " x
    [[ -z "$x" ]] && break
    [[ "$x" =~ ^([^=]+)=([^=]+)$ ]] || { echo "فرمت نادرست."; continue; }
    lp="${BASH_REMATCH[1]##*:}"; rp="${BASH_REMATCH[2]##*:}"
    valid_port "$lp" || { echo "پورت سمت ایران نامعتبر."; continue; }
    valid_port "$rp" || { echo "پورت مقصد نامعتبر."; continue; }
    ports+=("$x")
  done

  mkdir -p /etc/backhaul
  backup_config
  {
    echo "[server]"
    printf 'bind_addr = "0.0.0.0:%s"\n' "$bind_port"
    printf 'transport = "%s"\n' "$proto"
    printf 'token = "%s"\n' "$token"
    echo "keepalive_period = 75"
    echo "nodelay = true"
    echo "heartbeat = 40"
    echo "channel_size = 2048"
    echo "sniffer = false"
    echo "web_port = 0"
    echo 'log_level = "info"'
    [[ "$proto" == "wss" ]] && {
      printf 'tls_cert = "%s"\n' "$cert"
      printf 'tls_key = "%s"\n' "$key"
    }
    echo
    echo "ports = ["
    for x in "${ports[@]}"; do printf '    "%s",\n' "$x"; done
    echo "]"
  } > "$CONFIG"

  write_service "Server"
}

write_client(){
  read -r -p "IP یا دامنه سرور ایران: " ip
  [[ -n "$ip" ]] || die "آدرس خالی است."

  read -r -p "پورت کنترل سرور ایران [3080]: " remote_port
  remote_port="${remote_port:-3080}"
  valid_port "$remote_port" || die "پورت نامعتبر."

  read -r -s -p "Token (دقیقاً مثل Server): " token; echo
  [[ -n "$token" ]] || die "Token خالی است."

  echo "پروتکل: 1) TCP  2) TCPMUX  3) WS  4) WSS"
  read -r -p "انتخاب [1]: " p; p="${p:-1}"
  case "$p" in
    1) proto="tcp";; 2) proto="tcpmux";; 3) proto="ws";; 4) proto="wss";;
    *) die "انتخاب نامعتبر.";;
  esac

  read -r -p "Connection Pool [8]: " pool
  pool="${pool:-8}"
  [[ "$pool" =~ ^[0-9]+$ ]] || die "Connection Pool نامعتبر."

  edge=""
  [[ "$proto" == "wss" ]] && read -r -p "Edge IP (اختیاری): " edge

  mkdir -p /etc/backhaul
  backup_config
  {
    echo "[client]"
    printf 'remote_addr = "%s:%s"\n' "$ip" "$remote_port"
    [[ -n "$edge" ]] && printf 'edge_ip = "%s"\n' "$edge"
    printf 'transport = "%s"\n' "$proto"
    printf 'token = "%s"\n' "$token"
    printf 'connection_pool = %s\n' "$pool"
    echo "aggressive_pool = false"
    echo "keepalive_period = 75"
    echo "dial_timeout = 10"
    echo "retry_interval = 3"
    echo "nodelay = true"
    echo "sniffer = false"
    echo "web_port = 0"
    echo 'log_level = "info"'
  } > "$CONFIG"

  write_service "Client"
}

show_status(){
  systemctl --no-pager --full status backhaul || true
  echo
  echo "پورت‌های مرتبط:"
  ss -lntp 2>/dev/null | grep -E 'backhaul|:3080\b|:443\b|:2087\b|:2096\b|:8443\b|:2020\b' || true
}

show_logs(){ journalctl -u backhaul -n 50 --no-pager; }
restart_service(){ systemctl restart backhaul; systemctl --no-pager status backhaul; }
start_service(){ systemctl start backhaul; systemctl --no-pager status backhaul; }
stop_service(){ systemctl stop backhaul; echo "سرویس متوقف شد."; }

uninstall_service(){
  read -r -p "فقط systemd service حذف شود؟ [y/N]: " a
  [[ "$a" =~ ^[Yy]$ ]] || return
  systemctl disable --now backhaul 2>/dev/null || true
  rm -f "$SERVICE"
  systemctl daemon-reload
  echo "Service حذف شد؛ کانفیگ و باینری باقی ماندند."
}

menu(){
  while :; do
    clear || true
    echo "╔════════════════════════════════════════════╗"
    echo "║        Backhaul Manager - فارسی          ║"
    echo "╚════════════════════════════════════════════╝"
    echo
    echo "1) 🇮🇷 تنظیم Server"
    echo "2) 🌍 تنظیم Client"
    echo "3) 📊 وضعیت سرویس"
    echo "4) 📋 مشاهده Log"
    echo "5) 🔄 Restart"
    echo "6) ▶ Start"
    echo "7) ⏹ Stop"
    echo "8) 🗑 حذف systemd service"
    echo "9) 💾 مسیر باینری"
    echo "0) خروج"
    echo
    read -r -p "انتخاب: " c
    case "$c" in
      1) choose_bin; write_server; pause;;
      2) choose_bin; write_client; pause;;
      3) show_status; pause;;
      4) show_logs; pause;;
      5) restart_service; pause;;
      6) start_service; pause;;
      7) stop_service; pause;;
      8) uninstall_service; pause;;
      9) choose_bin; echo "Backhaul: $BIN"; pause;;
      0) exit 0;;
      *) echo "انتخاب نامعتبر."; sleep 1;;
    esac
  done
}

need_root
menu
