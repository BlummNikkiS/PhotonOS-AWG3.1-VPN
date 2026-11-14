#!/usr/bin/env bash
# =============================================================================
#  split-gw: шлюз на Photon OS
#    РФ + локальная сеть  -> напрямую
#    всё остальное        -> AmneziaWG -> Латвия
#  Запуск:  bash /opt/split-gw/setup.sh        (можно запускать повторно)
#  Нужно:   /opt/split-gw/awg.conf  (клиентский конфиг AmneziaWG)
# =============================================================================
set -euo pipefail

WORK=/opt/split-gw
RAW="$WORK/awg.conf"
READY="$WORK/awg0.conf"
AWG_IMG=awg-gw-img
SB_IMG=ghcr.io/sagernet/sing-box:v1.14.0

say()  { printf '\n\033[1;36m>>> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  OK:\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ]  || die "запускайте от root"
[ -f "$RAW" ]       || die "нет файла $RAW (положите туда конфиг AmneziaWG)"
for c in docker iptables ip curl awk sed; do
  command -v "$c" >/dev/null || die "не найдена команда: $c (tdnf install -y $c)"
done
mkdir -p "$WORK/data"

# ---------------------------------------------------------------------------
say "1/9  Остановка старого (корректно, чтобы sing-box убрал свои маршруты)"
# ---------------------------------------------------------------------------
systemctl enable --now docker >/dev/null 2>&1 || true
# ip-forward-no-drop есть только в Docker 28+, на 23.x он ломает запуск Docker
if [ -f /etc/docker/daemon.json ] && grep -q 'ip-forward-no-drop' /etc/docker/daemon.json; then
  mv /etc/docker/daemon.json /etc/docker/daemon.json.bak
  systemctl restart docker
  warn "убран несовместимый /etc/docker/daemon.json (копия: daemon.json.bak)"
fi
docker info >/dev/null 2>&1 || die "Docker не запущен: journalctl -xeu docker"

docker stop -t 15 split-gw >/dev/null 2>&1 || true
docker stop -t 10 awg      >/dev/null 2>&1 || true
docker rm -f split-gw awg  >/dev/null 2>&1 || true
# остатки sing-box после аварийной остановки (иначе сеть «чёрная дыра»)
for _ in $(seq 1 20); do
  pref=$(ip rule show | awk -F: '/lookup 2022/ {print $1; exit}' || true)
  [ -n "${pref:-}" ] || break
  ip rule del pref "$pref" 2>/dev/null || break
done
ip route flush table 2022 2>/dev/null || true
ip link del tun0 2>/dev/null || true
command -v nft >/dev/null && nft delete table inet sing-box 2>/dev/null || true

NET_IFACE=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$NET_IFACE" ] || die "не найден внешний интерфейс (ip route)"
say "Внешний интерфейс: $NET_IFACE"
ORIG_IP=$(curl -4 -sS -m 10 https://ifconfig.me 2>/dev/null || true)
[ -n "$ORIG_IP" ] && ok "ваш обычный внешний IP: $ORIG_IP" || warn "не удалось узнать обычный IP (не критично)"

# ---------------------------------------------------------------------------
say "2/9  Системные настройки (форвардинг, без IPv6-утечек)"
# ---------------------------------------------------------------------------
modprobe tun 2>/dev/null || true
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-router.conf <<SYSCTL
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.${NET_IFACE}.rp_filter = 2
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL
sysctl --system >/dev/null
ok "ip_forward=1, IPv6 выключен (иначе он ходил бы мимо туннеля)"

# ---------------------------------------------------------------------------
say "3/9  Файрвол (постоянный, переживает перезагрузку и рестарт Docker)"
# ---------------------------------------------------------------------------
mkdir -p /usr/local/sbin /etc/systemd/system
cat > /usr/local/sbin/split-gw-fw.sh <<FW
#!/bin/sh
IFACE="$NET_IFACE"
add() { c="\$1"; shift; iptables -C "\$c" "\$@" 2>/dev/null || iptables -I "\$c" "\$@"; }

# трафик самого шлюза через tun0 / awg0
add INPUT  -i tun0 -j ACCEPT
add INPUT  -i awg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
add OUTPUT -o tun0 -j ACCEPT
add OUTPUT -o awg0 -j ACCEPT

# пересылка клиентов: отдельная цепочка, пересоздаётся при каждом запуске
iptables -N SPLITGW_FWD 2>/dev/null || true
iptables -F SPLITGW_FWD
for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
  iptables -A SPLITGW_FWD -i "\$IFACE" -o "\$IFACE" -d "\$n" -j ACCEPT   # локалка <-> локалка
done
# KILL-SWITCH: клиентский трафик в интернет не может уйти мимо туннеля
iptables -A SPLITGW_FWD -i "\$IFACE" -o "\$IFACE" -j DROP
iptables -A SPLITGW_FWD -j ACCEPT
iptables -C FORWARD -j SPLITGW_FWD 2>/dev/null || iptables -I FORWARD 1 -j SPLITGW_FWD

# MSS под размер туннеля (иначе часть сайтов «виснет»)
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
exit 0
FW
chmod +x /usr/local/sbin/split-gw-fw.sh

cat > /etc/systemd/system/split-gw-fw.service <<'UNIT'
[Unit]
Description=split-gw firewall rules
After=docker.service iptables.service network-online.target
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/split-gw-fw.sh

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable split-gw-fw.service >/dev/null 2>&1
systemctl restart split-gw-fw.service
ok "правила применены и включены в автозапуск"

# ---------------------------------------------------------------------------
say "4/9  Подготовка конфига AmneziaWG"
# ---------------------------------------------------------------------------
# убираем DNS/Table/Pre/Post/SaveConfig, IPv6-адреса; добавляем Table = off
tr -d '\r' < "$RAW" \
 | grep -vE '^[[:space:]]*(DNS|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' \
 | awk '
   /^[[:space:]]*(Address|AllowedIPs)[[:space:]]*=/ {
     key = substr($0, 1, index($0, "=") - 1); val = substr($0, index($0, "=") + 1)
     n = split(val, a, ","); out = ""
     for (i = 1; i <= n; i++) { gsub(/[[:space:]]/, "", a[i]); if (a[i] != "" && a[i] !~ /:/) out = out (out == "" ? "" : ", ") a[i] }
     print key "= " out; next }
   /^\[Interface\]/ { print; print "Table = off"; next }
   { print }' > "$READY"
chmod 600 "$READY"
grep -q '^Endpoint' "$READY"   || die "в $RAW нет строки Endpoint"
grep -q '^PrivateKey' "$READY" || die "в $RAW нет PrivateKey"
ok "$READY готов"

# ---------------------------------------------------------------------------
say "5/9  Образ AmneziaWG и образ sing-box"
# ---------------------------------------------------------------------------
if ! docker image inspect "$AWG_IMG" >/dev/null 2>&1; then
  if ! swapon --show 2>/dev/null | grep -q .; then
    dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    SWAP_TMP=1
  fi
  cat > "$WORK/Dockerfile" <<'DOCKERFILE'
FROM golang:alpine AS builder
RUN apk add --no-cache git make gcc musl-dev linux-headers
ENV GOMAXPROCS=1 GOGC=20
RUN git clone https://github.com/amnezia-vpn/amneziawg-go.git /src/go && cd /src/go && make && cp amneziawg-go /usr/local/bin/
RUN git clone https://github.com/amnezia-vpn/amneziawg-tools.git /src/tools && cd /src/tools/src && make && make WITH_WGQUICK=yes install
FROM alpine:latest
RUN apk add --no-cache iptables iproute2 bash
COPY --from=builder /usr/local/bin/amneziawg-go /usr/local/bin/
COPY --from=builder /usr/bin/awg /usr/bin/awg
COPY --from=builder /usr/bin/awg-quick /usr/bin/awg-quick
DOCKERFILE
  docker build -t "$AWG_IMG" "$WORK"
  if [ "${SWAP_TMP:-0}" = 1 ]; then swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; fi
else
  ok "образ $AWG_IMG уже собран, пропускаю (пересборка: docker rmi $AWG_IMG)"
fi
docker pull "$SB_IMG" >/dev/null || die "не удалось скачать $SB_IMG"
ok "sing-box: $(docker run --rm "$SB_IMG" version | head -1)"

# ---------------------------------------------------------------------------
say "6/9  Запуск AmneziaWG и ПРОВЕРКА туннеля (до sing-box)"
# ---------------------------------------------------------------------------
docker run -d --name awg --restart unless-stopped --network host \
  --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun \
  --log-opt max-size=10m --log-opt max-file=3 \
  -v "$READY:/etc/amnezia/amneziawg/awg0.conf:ro" "$AWG_IMG" \
  /bin/bash -c 'export WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go; awg-quick up awg0; trap "awg-quick down awg0; exit 0" TERM INT; sleep infinity & wait $!' >/dev/null

for _ in $(seq 1 15); do ip link show awg0 >/dev/null 2>&1 && break; sleep 1; done
ip link show awg0 >/dev/null 2>&1 || { docker logs awg --tail 30; die "интерфейс awg0 не поднялся (см. лог выше)"; }

TUN_OK=0
for _ in 1 2 3; do
  if T=$(curl -4 -sS -m 10 --interface awg0 https://1.1.1.1/cdn-cgi/trace 2>/dev/null) && echo "$T" | grep -q '^ip='; then
    TUN_OK=1; LV_IP=$(echo "$T" | sed -n 's/^ip=//p'); break
  fi
  sleep 2
done
if [ "$TUN_OK" != 1 ]; then
  echo; docker exec awg awg show || true
  die "ТУННЕЛЬ НЕ ПРОПУСКАЕТ ДАННЫЕ. sing-box НЕ запущен, интернет шлюза не затронут.
   Проверьте: 1) в 'awg show' есть 'latest handshake'? Если нет — неверный Endpoint/порт/ключи/параметры Jc,S1,H1...
              2) НЕ используется ли этот же ключ/peer на другом устройстве (один peer = одно устройство)
              3) сервер Латвии: форвардинг и NAT включены, порт открыт."
fi
ok "туннель работает, выходной IP через Латвию: $LV_IP"

# адрес(а) сервера Латвии -> исключаем из tun0 (иначе петля и 100% CPU)
EP_IPS=$(docker exec awg awg show awg0 endpoints | awk '{print $2}' | sed -E 's/:[0-9]+$//' | sort -u)
EXCL='"10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","224.0.0.0/4"'
for ip in $EP_IPS; do
  case "$ip" in \[*) die "IPv6 Endpoint не поддерживается этим скриптом: $ip";; esac
  EXCL="$EXCL,\"$ip/32\""
done
ok "исключены из tun0: сервер(а) $(echo $EP_IPS) и локальные сети"

# ---------------------------------------------------------------------------
say "7/9  Конфиг sing-box"
# ---------------------------------------------------------------------------
cat > "$WORK/config.json" <<JSON
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "https", "tag": "dns-remote", "server": "1.1.1.1", "detour": "latvia-awg" },
      { "type": "udp",   "tag": "dns-direct", "server": "77.88.8.8", "detour": "direct" }
    ],
    "rules": [
      { "domain_suffix": ["ru", "su", "xn--p1ai"], "server": "dns-direct" },
      { "rule_set": ["geosite-ru"], "server": "dns-direct" }
    ],
    "final": "dns-remote",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "address": ["172.19.0.1/30"],
      "mtu": 1280,
      "auto_route": true,
      "strict_route": false,
      "route_exclude_address": [ $EXCL ]
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "latvia-awg", "bind_interface": "awg0" },
    { "type": "direct", "tag": "direct",     "bind_interface": "$NET_IFACE" }
  ],
  "route": {
    "default_domain_resolver": "dns-direct",
    "rule_set": [
      { "tag": "geosite-ru", "type": "remote", "format": "binary", "download_detour": "latvia-awg",
        "url": "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-category-ru.srs" },
      { "tag": "geoip-ru",   "type": "remote", "format": "binary", "download_detour": "latvia-awg",
        "url": "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru.srs" }
    ],
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "domain_suffix": ["ru", "su", "xn--p1ai"], "outbound": "direct" },
      { "rule_set": ["geosite-ru", "geoip-ru"], "outbound": "direct" }
    ],
    "final": "latvia-awg"
  },
  "experimental": {
    "cache_file": { "enabled": true, "path": "/data/cache.db" }
  }
}
JSON
docker run --rm -v "$WORK/config.json:/c.json:ro" "$SB_IMG" check -c /c.json || die "конфиг sing-box невалиден"
ok "конфиг прошёл проверку"

# ---------------------------------------------------------------------------
say "8/9  Запуск sing-box"
# ---------------------------------------------------------------------------
docker run -d --name split-gw --restart unless-stopped --network host \
  --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun \
  --log-opt max-size=10m --log-opt max-file=3 \
  -v "$WORK/config.json:/etc/sing-box/config.json:ro" \
  -v "$WORK/data:/data" \
  "$SB_IMG" run -c /etc/sing-box/config.json >/dev/null

# ---------------------------------------------------------------------------
say "9/9  Итоговая проверка (при провале — автоматический откат)"
# ---------------------------------------------------------------------------
rollback() {
  docker update --restart=no split-gw >/dev/null 2>&1 || true
  docker stop -t 15 split-gw >/dev/null 2>&1 || true
  echo; docker logs split-gw --tail 30 2>&1 || true
  die "$1
   sing-box ОСТАНОВЛЕН, интернет шлюза вернулся в обычное состояние. Пришлите вывод выше."
}
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Running}}' split-gw 2>/dev/null)" = true ] && ip link show tun0 >/dev/null 2>&1 && break
  sleep 1
done
sleep 5
[ "$(docker inspect -f '{{.State.Running}}' split-gw)" = true ] || rollback "sing-box упал при старте"
ip link show tun0 >/dev/null 2>&1 || rollback "интерфейс tun0 не появился"

EXT=""
for _ in 1 2 3; do EXT=$(curl -4 -sS -m 12 https://ifconfig.me 2>/dev/null || true); [ -n "$EXT" ] && break; sleep 3; done
[ -n "$EXT" ] || rollback "интернет через шлюз не работает (ifconfig.me не ответил)"
[ "$EXT" = "$LV_IP" ] || rollback "зарубежный трафик выходит с IP $EXT, а туннель даёт $LV_IP: трафик идёт мимо туннеля"
ok "зарубежный трафик выходит с IP: $EXT  (совпадает с туннелем)"
if [ "${ORIG_IP:-}" = "$LV_IP" ]; then
  warn "ваш обычный IP без шлюза тоже $ORIG_IP: вышестоящий роутер уже выходит через Латвию, различие РФ/не-РФ по IP проверить нельзя"
fi

RU=$(curl -4 -sS -m 12 https://2ip.ru 2>/dev/null | tr -d '[:space:]' || true)
CODE=$(curl -4 -sS -m 12 -o /dev/null -w '%{http_code}' https://ya.ru 2>/dev/null || true)
ok "ya.ru отвечает: HTTP $CODE"
if [ -n "$RU" ] && [ "${#RU}" -le 15 ]; then
  if [ "$RU" = "$EXT" ] && [ "${ORIG_IP:-}" != "$LV_IP" ]; then warn "российский сайт видит IP $RU — идёт через Латвию, проверьте правила"; else ok "российский сайт видит IP: $RU  (напрямую)"; fi
fi

cat <<DONE

==================== ГОТОВО ====================
 Клиенты: шлюз по умолчанию (и DNS) = IP этой машины.
 Статус:    docker exec awg awg show
 Логи:      docker logs split-gw --tail 30
 CPU:       docker stats --no-stream      (в простое — единицы %)
 Стоп:      docker update --restart=no split-gw && docker stop split-gw
==================================================
DONE
