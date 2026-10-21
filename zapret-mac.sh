#!/bin/bash
# ════════════════════════════════════════════════════════════════════
#  zapret-mac 2 — обход DPI-блокировок YouTube и Discord на macOS
#  https://github.com/getpaintoo/zapret-mac · лицензия MIT
#
#  Движок: tpws из bol-van/zapret в прозрачном режиме, как в оригинале.
#  pf заворачивает исходящий TCP 80/443 в tpws, поэтому обход работает для
#  любых программ — в том числе для апдейтера Discord, который системный
#  SOCKS-прокси игнорирует (из-за этого и висело «Checking for updates»).
#  Списки доменов — из Flowseal/zapret-discord-youtube; для YouTube и для
#  Discord стратегии подбираются отдельно, у каждого своя.
#
#  VPN: пока VPN в режиме TUN включён, сторож снимает перенаправление и весь
#  трафик идёт через VPN. Выключили VPN — обход включается сам за доли
#  секунды. Сторож же периодически проверяет YouTube и Discord и, если они
#  перестали открываться, сам подбирает новые стратегии.
#
#  Запуск:  bash zapret-mac.sh            — меню
#           bash zapret-mac.sh auto       — подобрать стратегии и включить
#           bash zapret-mac.sh start|stop|restart|status|check|test [all]|discord|update|uninstall
#
#  Если что-то пошло не так и пропал интернет:
#           sudo bash /opt/zapret-mac/zapret-mac.sh stop
#  или вручную: sudo pfctl -a com.apple/zapret-mac -F all
# ════════════════════════════════════════════════════════════════════

ZM_VERSION="2.1"
ZAPRET_TAG="v72.13"
TPWS_SHA256="441524a76f52597a0e5c816d25ed1adfd93e5c34cc56c56e0dc00533929d1761"

# всё лежит в папке root: её запускают системные демоны, править её может только админ
DIR="/opt/zapret-mac"
BIN_DIR="$DIR/bin"
TPWS="${ZM_TPWS:-$BIN_DIR/tpws}"   # ZM_TPWS — другой tpws, для тестов
LISTS="$DIR/lists"
LOGS="$DIR/log"
RUN="$DIR/run"
CONF="$DIR/config"
SELF="$DIR/zapret-mac.sh"
DNS_BACKUP="$DIR/dns-backup"
TP_PORT=988          # tpws в прозрачном режиме (сюда pf заворачивает трафик)
SOCKS_PORT=1080      # tpws в режиме SOCKS-прокси
TEST_PORT=1090       # временный tpws для подбора стратегий
LBL_TPWS="com.zapret-mac.tpws"
LBL_WD="com.zapret-mac.watchdog"
LBL_DS="com.zapret-mac.discord"   # LaunchAgent автозапуска Discord, лежит у пользователя
PL_TPWS="/Library/LaunchDaemons/$LBL_TPWS.plist"
PL_WD="/Library/LaunchDaemons/$LBL_WD.plist"
CHECK_EVERY=1800     # как часто сторож проверяет YouTube и Discord, секунд
CONTROL_URL="https://www.apple.com/library/test/success.html"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

# пользователь, за которым скрипт ухаживает: его рабочий стол, его Discord, его старая версия
if [ "$(id -u)" -eq 0 ]; then
  RUSER=${SUDO_USER:-$(stat -f %Su /dev/console 2>/dev/null)}
else
  RUSER=$(id -un)
fi
case $RUSER in root) RUSER="" ;; esac
RHOME=""
[ -n "$RUSER" ] && RHOME=$(dscl . -read "/Users/$RUSER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
SHORTCUT=""
[ -n "$RHOME" ] && SHORTCUT="$RHOME/Desktop/Zapret.command"

# ─── вывод ───────────────────────────────────────────────────────────
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; D=""; N=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s✗%s %s\n' "$R" "$N" "$*" >&2; }
die()  { err "$*"; exit 1; }
pause(){ [ -t 0 ] && { printf '\n%sEnter — назад в меню%s' "$D" "$N"; read -r _; }; }
log()  { [ -d "$LOGS" ] && printf '%s %s\n' "$(date '+%d.%m %H:%M:%S')" "$*" >> "$LOGS/watchdog.log"; }

[ "$(uname -s)" = "Darwin" ] || die "Этот скрипт только для macOS."

# ─── настройки (/opt/zapret-mac/config, строки КЛЮЧ=значение) ────────
#   MODE=transparent|socks  S_Y, S_D — стратегии для YouTube и для Discord
#   QUIC=1 — глушить QUIC к Google   AUTOFIX=1 — сторож сам подбирает стратегии
#   PF_ROOT=com.apple|zapret-mac — куда подключаются наши правила pf
cfg() { local v; v=$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1); printf '%s' "${v:-$2}"; }
cfg_set() {
  touch "$CONF" && chmod 644 "$CONF" || return 1
  if grep -q "^$1=" "$CONF"; then sed -i '' "s|^$1=.*|$1=$2|" "$CONF"
  else printf '%s=%s\n' "$1" "$2" >> "$CONF"; fi
}
mode_name() { [ "$(cfg MODE transparent)" = socks ] && printf 'SOCKS-прокси' || printf 'прозрачный'; }

# ─── стратегии tpws ──────────────────────────────────────────────────
# @HL подставляется как набор --hostlist (обход только для доменов из списков).
# На macOS --oob и --disorder для одного протокола вместе нельзя — tpws не запустится
# (работает только в Linux), поэтому OOB-стратегии здесь без disorder.
STRATEGIES=(
"general|@HL --filter-l7=tls --split-pos=1,midsld --disorder --tlsrec=sniext --new @HL --filter-l7=http --hostcase --split-pos=1 --disorder"
"ALT|@HL --filter-l7=tls --split-pos=1,midsld --oob --new @HL --filter-l7=http --hostcase --hostdot --split-pos=1 --oob"
"ALT2|@HL --filter-l7=tls --split-pos=1,sniext --disorder --tlsrec=sni --new @HL --filter-l7=http --methodeol --hostcase --split-pos=2 --disorder"
"MULTI|@HL --filter-l7=tls --split-pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1 --disorder --new @HL --filter-l7=http --split-pos=method+2,midsld --hostcase --disorder"
"ALT3|@HL --split-pos=1 --disorder --hostcase"
"ALT4|@HL --split-pos=1,midsld --disorder --hostcase"
"ALT5|@HL --tlsrec=sniext --split-pos=1 --disorder --hostcase"
"ALT6|@HL --tlsrec=sni --split-pos=1,midsld --disorder --hostcase"
"ALT7|@HL --oob --split-pos=1,midsld"
"ALT8|@HL --oob=tls --disorder=http --split-pos=1,midsld --hostcase"
"ALT9|@HL --split-pos=host --disorder --hostcase"
"ALT10|@HL --oob --methodeol --split-pos=1,midsld --hostcase --hostdot"
"ALT11|@HL --tlsrec=sni --oob --split-pos=1 --hostcase"
"ALT12|@HL --split-pos=2 --disorder=tls"
"TLSREC|@HL --tlsrec=midsld --split-pos=1,midsld --disorder"
"SIMPLE|@HL --split-pos=1"
)
NSTRAT=${#STRATEGIES[@]}

strat_name() { local s=${STRATEGIES[$(( $1 - 1 ))]}; printf '%s' "${s%%|*}"; }

strat_of() {   # $1 = Y (YouTube) | D (Discord и остальные сайты из списков)
  local n
  n=$(cfg "S_$1" 1)
  case $n in ''|*[!0-9]*) n=1 ;; esac
  { [ "$n" -ge 1 ] && [ "$n" -le "$NSTRAT" ]; } || n=1
  printf '%s' "$n"
}

# набор листов для профиля tpws; результат — массив HL
hl_set() {
  local -a ex=("--hostlist-exclude=$LISTS/list-exclude.txt" "--hostlist-exclude=$LISTS/list-exclude-mac.txt"
               "--hostlist-exclude=$LISTS/list-exclude-user.txt")
  case $1 in
    youtube) HL=("--hostlist=$LISTS/list-youtube.txt" "${ex[@]}") ;;
    general) HL=("--hostlist=$LISTS/list-general.txt" "--hostlist=$LISTS/list-user.txt" "${ex[@]}") ;;
    all)     HL=("--hostlist=$LISTS/list-youtube.txt" "--hostlist=$LISTS/list-general.txt" "--hostlist=$LISTS/list-user.txt" "${ex[@]}") ;;
    auto)    HL=("--hostlist-auto=$LISTS/list-auto.txt" "${ex[@]}") ;;
  esac
}

# дописывает в ARGS стратегию $1, подставляя вместо @HL массив HL
add_strategy() {
  local s raw tok
  s=${STRATEGIES[$(( $1 - 1 ))]}
  raw=${s#*|}
  set -f
  for tok in $raw; do
    if [ "$tok" = "@HL" ]; then ARGS+=("${HL[@]}"); else ARGS+=("$tok"); fi
  done
  set +f
}

# для автосписка: первый блок стратегии $1 без --filter-l7, чтобы он годился для http и tls
add_auto_strategy() {
  local s raw tok
  s=${STRATEGIES[$(( $1 - 1 ))]}
  raw=${s#*|}
  raw=${raw%% --new *}
  set -f
  for tok in $raw; do
    case $tok in
      @HL) ARGS+=("${HL[@]}") ;;
      --filter-l7=*) ;;
      *) ARGS+=("$tok") ;;
    esac
  done
  set +f
}

# основной tpws: профиль YouTube, профиль Discord и, если включён, профиль автосписка
# $1 = transparent|socks
build_main_args() {
  if [ "$1" = socks ]; then
    ARGS=(--socks --user=nobody --bind-addr=127.0.0.1 "--port=$SOCKS_PORT")
  else
    # --user=root обязателен: на macOS адрес назначения из pf отдают только root (см. docs/bsd.md)
    ARGS=(--user=root "--port=$TP_PORT" --bind-addr=127.0.0.1 --bind-iface6=lo0 --bind-linklocal=force --bind-wait-ip=20)
  fi
  ARGS+=(--maxconn=2048 --maxfiles=20480)
  hl_set youtube; add_strategy "$(strat_of Y)"
  ARGS+=(--new); hl_set general; add_strategy "$(strat_of D)"
  # автосписок выключен по умолчанию: tpws путает с блокировкой обычные обрывы (ocsp.apple.com
  # и т.п.), а у провайдеров с обрывом на 16 КБ обход ломает сайты на Cloudflare, которые и так работали
  if [ "$(cfg AUTOLIST 0)" = 1 ]; then
    ARGS+=(--new); hl_set auto; add_auto_strategy "$(strat_of D)"
  fi
}

# временный SOCKS-tpws для подбора; $1 = номер стратегии или cur (текущие), $2 = адрес для исходящих
build_test_args() {
  ARGS=(--socks --user=root --bind-addr=127.0.0.1 "--port=$TEST_PORT")
  [ -n "$2" ] && ARGS+=("--connect-bind-addr=$2")
  if [ "$1" = cur ]; then
    hl_set youtube; add_strategy "$(strat_of Y)"
    ARGS+=(--new); hl_set general; add_strategy "$(strat_of D)"
  else
    hl_set all; add_strategy "$1"
  fi
}

# ─── что проверяем ───────────────────────────────────────────────────
# группа|название|адрес. Группа Y — домены из list-youtube (туда же Flowseal
# отнёс сервер загрузок Discord), D — из list-general.
# Главная discord.com весит ~24 КБ — на ней видно, режет ли провайдер Cloudflare после 16 КБ
TARGETS=(
"D|Discord|https://discord.com/"
"D|Discord: шлюз|https://gateway.discord.gg/"
"D|Discord: CDN|https://cdn.discordapp.com/"
"D|Discord: проверка обновлений|https://updates.discord.com/distributions/app/manifests/latest?channel=stable&platform=osx&arch=arm64"
"Y|Discord: скачивание обновлений|https://stable.dl2.discordapp.net/"
"Y|YouTube|https://www.youtube.com/"
"Y|YouTube: картинки|https://i.ytimg.com/"
"Y|YouTube: видео|https://redirector.googlevideo.com/report_mapping?di=no"
)
NT=${#TARGETS[@]}
CHECK_LIGHT=0   # 1 — главную YouTube качать сжатой (сторож бережёт трафик)

t_label() { local l=${1#*|}; printf '%s' "${l%|*}"; }

# от чьего имени проверять «как видят программы»: pf заворачивает в tpws всех, кроме root
probe_user() {
  local u=$RUSER
  [ -n "$u" ] || u=$(stat -f %Su /dev/console 2>/dev/null)
  case $u in ""|root) u=nobody ;; esac
  printf '%s' "$u"
}

# параллельно открывает все TARGETS
#   $1 = direct     — напрямую через физический интерфейс, мимо обхода и VPN
#        socks:ПОРТ — через SOCKS-прокси tpws
#        apps       — как обычная программа: от имени пользователя, без прокси
# результат: LAST_RC[i] (ok|cut|fail), LAST_KB[i], SCORE_Y из NY, SCORE_D из ND, LAST_FAIL, LAST_CUT
#
# cut — TLS прошёл, ответ пошёл и замер на первых килобайтах. Так провайдер режет
# соединения с Cloudflare, в которых не смог прочитать имя сайта (а tpws его прячет).
# Стратегия своё дело сделала, другая тут не поможет — поэтому в баллы cut идёт как успех.
run_checks() {
  local how=$1 tmp i t url pu="" pids=() rc size tls
  local -a px comp pre
  tmp=$(mktemp -d /tmp/zapret-mac-chk.XXXXXX) || return 1
  case $how in
    direct)  [ -n "$PHYS" ] || detect_phys; px=(--noproxy '*'); [ -n "$PHYS" ] && px+=(--interface "$PHYS") ;;
    socks:*) px=(--socks5-hostname "127.0.0.1:${how#socks:}") ;;
    *)       px=(--noproxy '*'); [ "$(id -u)" -eq 0 ] && pu=$(probe_user) ;;
  esac
  for (( i=0; i<NT; i++ )); do
    url=${TARGETS[$i]##*|}
    comp=(--compressed)
    # главную YouTube качаем целиком (~1 МБ): так видно и замедление, а не только блокировку
    [ "$url" = "https://www.youtube.com/" ] && [ "$CHECK_LIGHT" != 1 ] && comp=()
    pre=(env -u ALL_PROXY -u all_proxy -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy)
    [ -n "$pu" ] && pre=(sudo -u "$pu")
    (
      out=$("${pre[@]}" /usr/bin/curl -s "${comp[@]}" -o /dev/null --connect-timeout 5 --max-time 8 -A "$UA" "${px[@]}" \
            -w '%{size_download} %{time_appconnect}' "$url")
      echo "$? $out" > "$tmp/$i"
    ) &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null
  SCORE_Y=0; SCORE_D=0; NY=0; ND=0; LAST_FAIL=""; LAST_CUT=""; LAST_RC=(); LAST_KB=()
  for (( i=0; i<NT; i++ )); do
    t=${TARGETS[$i]}
    rc=""; size=0; tls=0
    read -r rc size tls 2>/dev/null < "$tmp/$i"
    case $size in ''|*[!0-9]*) size=0 ;; esac
    LAST_KB[$i]=$(( size / 1024 ))
    LAST_RC[$i]=fail
    if [ "$rc" = 0 ]; then
      LAST_RC[$i]=ok
    elif [ "$rc" = 28 ] && [ "$size" -gt 0 ] && [ "$size" -le 32768 ] && [ -n "${tls//[0.,]/}" ]; then
      LAST_RC[$i]="cut"   # время TLS-рукопожатия не нулевое — значит, рукопожатие было
    fi
    if [ "${t%%|*}" = Y ]; then NY=$(( NY + 1 )); else ND=$(( ND + 1 )); fi
    case ${LAST_RC[$i]} in
      fail) LAST_FAIL="$LAST_FAIL, $(t_label "$t")" ;;
      *)    if [ "${t%%|*}" = Y ]; then SCORE_Y=$(( SCORE_Y + 1 )); else SCORE_D=$(( SCORE_D + 1 )); fi ;;
    esac
    [ "${LAST_RC[$i]}" = cut ] && LAST_CUT="$LAST_CUT, $(t_label "$t")"
  done
  LAST_FAIL=${LAST_FAIL#, }
  LAST_CUT=${LAST_CUT#, }
  rm -rf "$tmp"
}

print_checks() {
  local i
  for (( i=0; i<NT; i++ )); do
    case ${LAST_RC[$i]} in
      ok)  printf '   %s✓%s %s\n' "$G" "$N" "$(t_label "${TARGETS[$i]}")" ;;
      cut) printf '   %s!%s %s %s— оборвалось на %s КБ%s\n' "$Y" "$N" "$(t_label "${TARGETS[$i]}")" "$D" "${LAST_KB[$i]}" "$N" ;;
      *)   printf '   %s✗%s %s\n' "$R" "$N" "$(t_label "${TARGETS[$i]}")" ;;
    esac
  done
}

# объяснение для обрыва на 16 КБ; $1 — список того, что оборвалось
cut_note() {
  [ -n "$1" ] || return 0
  warn "Обрыв после ~16 КБ: $1."
  say  "   Это ограничение провайдера, а не стратегии: соединения с Cloudflare, в которых он"
  say  "   не может прочитать имя сайта, режутся после 16 КБ. А прятать имя — и есть работа tpws."
  say  "   Flowseal на Windows обходит это поддельными пакетами, на macOS их отправить нельзя."
  say  "   Обновления Discord это не задевает (они качаются с Google Cloud), а само приложение"
  say  "   Discord живёт на Cloudflare — для него на этом провайдере нужен VPN."
}

score_mark() {
  if [ "$1" -eq "$2" ]; then printf '%s%s/%s%s' "$G" "$1" "$2" "$N"
  elif [ "$1" -gt 0 ]; then printf '%s%s/%s%s' "$Y" "$1" "$2" "$N"
  else printf '%s%s/%s%s' "$R" "$1" "$2" "$N"; fi
}

# ─── сеть и порты ────────────────────────────────────────────────────
port_listening() { nc -z -G 1 127.0.0.1 "$1" >/dev/null 2>&1; }                 # для SOCKS-портов
wait_port() { local i; for (( i=0; i<$2; i++ )); do port_listening "$1" && return 0; sleep 0.1; done; return 1; }
# прозрачный порт проверяем без подключения: tpws не любит, когда к нему ходят напрямую (нужен root)
port_bound() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }
wait_bound() { local i; for (( i=0; i<$2; i++ )); do port_bound "$1" && return 0; sleep 0.1; done; return 1; }
port_owner() { local pid; pid=$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1); [ -n "$pid" ] && ps -p "$pid" -o comm= 2>/dev/null; }
port_busy_by_other() { local o; o=$(port_owner "$1"); [ -n "$o" ] || return 1; case $o in *tpws) return 1 ;; esac; return 0; }

main_port() { [ "${1:-$(cfg MODE transparent)}" = socks ] && printf '%s' "$SOCKS_PORT" || printf '%s' "$TP_PORT"; }
tpws_up() { port_bound "$(main_port "$1")"; }

services() { networksetup -listallnetworkservices 2>/dev/null | sed '1d' | grep -v '^\*' | grep -v '^$'; }

# службы с настоящим интерфейсом (Wi-Fi, Ethernet, iPhone USB) — без служб VPN-клиентов
hw_services() {
  networksetup -listnetworkserviceorder 2>/dev/null | awk '
    /^\([0-9]+\) / { name = $0; sub(/^\([0-9]+\) /, "", name); next }
    /Device: [A-Za-z]/ && name != "" { print name }
    { name = "" }'
}

# интерфейс, через который сейчас идёт интернет, если это VPN-туннель (TUN)
vpn_iface() {
  local i
  i=$(route -n get 8.8.8.8 2>/dev/null | awk '/interface:/ {print $2}')
  case $i in utun*|ipsec*|ppp*|tun*|wg*) printf '%s' "$i"; return 0 ;; esac
  return 1
}

# физический выход в интернет — даже когда VPN забрал маршрут по умолчанию.
# macOS держит для каждого интерфейса свой маршрут по умолчанию (флаг I).
# результат: PHYS (en0), PHYS_GW (192.168.0.1), PHYS_IP (192.168.0.10)
detect_phys() {
  local line
  PHYS=""; PHYS_GW=""; PHYS_IP=""
  line=$(netstat -rn -f inet 2>/dev/null |
         awk '$1=="default" && $2 ~ /^[0-9.]+$/ && $4 !~ /^(utun|ipsec|ppp|tun|wg|gif|stf)/ {print $2, $4; exit}')
  [ -n "$line" ] || return 1
  PHYS_GW=${line% *}; PHYS=${line#* }
  PHYS_IP=$(ipconfig getifaddr "$PHYS" 2>/dev/null)
  [ -n "$PHYS_IP" ]
}

my_ip() {   # $@ = как подключаться (curl-опции)
  /usr/bin/curl -s --connect-timeout 5 --max-time 8 "$@" https://api.ipify.org 2>/dev/null ||
  /usr/bin/curl -s --connect-timeout 5 --max-time 8 "$@" https://ifconfig.me/ip 2>/dev/null
}

# ─── системный SOCKS-прокси (режим SOCKS) ────────────────────────────
our_proxy_on() {
  local o
  o=$(networksetup -getsocksfirewallproxy "$1" 2>/dev/null)
  printf '%s\n' "$o" | grep -q '^Enabled: Yes' &&
  printf '%s\n' "$o" | grep -q '^Server: 127.0.0.1$' &&
  printf '%s\n' "$o" | grep -q "^Port: $SOCKS_PORT$"
}

proxy_on() {
  local svc done_list=""
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    networksetup -setsocksfirewallproxy "$svc" 127.0.0.1 "$SOCKS_PORT" >/dev/null 2>&1
    networksetup -setsocksfirewallproxystate "$svc" on >/dev/null 2>&1
    our_proxy_on "$svc" && done_list="$done_list, $svc"
  done <<< "$(hw_services)"
  done_list=${done_list#, }
  if [ -n "$done_list" ]; then ok "Системный SOCKS-прокси 127.0.0.1:$SOCKS_PORT включён: $done_list"
  else err "Не удалось включить системный прокси"; return 1; fi
}

proxy_off() {
  local svc
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    our_proxy_on "$svc" && networksetup -setsocksfirewallproxystate "$svc" off >/dev/null 2>&1
  done <<< "$(services)"
}

proxy_any_on() {
  local svc
  while IFS= read -r svc; do
    [ -n "$svc" ] && our_proxy_on "$svc" && return 0
  done <<< "$(services)"
  return 1
}

# VPN-клиент в режиме «системный прокси» перехватывает настройки прокси
proxy_mode_vpn() {
  local svc kind o
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    for kind in getwebproxy getsecurewebproxy getsocksfirewallproxy; do
      o=$(networksetup -"$kind" "$svc" 2>/dev/null)
      printf '%s\n' "$o" | grep -q '^Enabled: Yes' || continue
      [ "$kind" = getsocksfirewallproxy ] && our_proxy_on "$svc" && continue
      return 0
    done
  done <<< "$(services)"
  return 1
}

warn_other_proxies() {
  local svc
  if proxy_mode_vpn; then
    warn "VPN-клиент работает в режиме «системный прокси»."
    say  "   Это не мешает: программы, которые прокси не слушают, всё равно пойдут через обход."
    say  "   Но для чистого автопереключения лучше режим TUN (в Happ — под кнопкой включения)."
  fi
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    networksetup -getautoproxyurl "$svc" 2>/dev/null | grep -q '^Enabled: Yes' &&
      warn "В «$svc» включена автонастройка прокси (PAC) — она может перебивать обход."
  done <<< "$(services)"
}

# ─── pf: прозрачное перенаправление в tpws ───────────────────────────
# локальные сети не трогаем никогда
SKIP4="0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3"
SKIP6="::/127, fc00::/7, fe80::/10, ff00::/8"
# сервисы Google без Google Cloud (там бывают VPN-серверы, их QUIC трогать нельзя)
GOOGLE4="8.8.4.0/24, 8.8.8.0/24, 64.233.160.0/19, 66.102.0.0/20, 66.249.64.0/19, 72.14.192.0/18, 74.125.0.0/16, 108.170.192.0/18, 108.177.0.0/17, 142.250.0.0/15, 172.217.0.0/16, 172.253.0.0/16, 173.194.0.0/16, 192.178.0.0/15, 209.85.128.0/17, 216.58.192.0/19, 216.239.32.0/19"
GOOGLE6="2001:4860::/32, 2404:6800::/32, 2607:f8b0::/32, 2800:3f0::/32, 2a00:1450::/32, 2c0f:fb50::/32"

# В стандартном /etc/pf.conf есть якоря com.apple/* — наши правила живут там же
# и /etc/pf.conf не трогают. Если не сработает — как оригинальный zapret,
# прописываем свой якорь zapret-mac/* в /etc/pf.conf (PF_ROOT=zapret-mac).
anchor_main() { printf '%s/zapret-mac' "$(cfg PF_ROOT com.apple)"; }
anchor_test() { printf '%s/zapret-mac-test' "$(cfg PF_ROOT com.apple)"; }

# Правила из docs/bsd.md оригинала: исходящий TCP 80/443 уводится на lo0 (route-to),
# там rdr отдаёт его tpws. Трафик root не трогаем — от root работает сам tpws,
# иначе он завернул бы сам себя.
pf_rules_main() {
  local ports="{ 80, 443 }"
  printf 'table <zm_skip4> const { %s }\n' "$SKIP4"
  printf 'table <zm_skip6> const { %s }\n' "$SKIP6"
  if [ "$(cfg QUIC 1)" = 1 ]; then
    printf 'table <zm_quic4> const { %s }\n' "$GOOGLE4"
    printf 'table <zm_quic6> const { %s }\n' "$GOOGLE6"
  fi
  printf 'rdr pass on lo0 inet proto tcp from !127.0.0.0/8 to !<zm_skip4> port %s -> 127.0.0.1 port %s\n' "$ports" "$TP_PORT"
  printf 'rdr pass on lo0 inet6 proto tcp from !::1 to !<zm_skip6> port %s -> fe80::1 port %s\n' "$ports" "$TP_PORT"
  if [ "$(cfg QUIC 1)" = 1 ]; then
    # tpws умеет только TCP. QUIC (HTTP/3 по UDP) к Google отбиваем сразу,
    # и браузер без задержки уходит на TCP — то есть через обход
    printf '%s\n' 'block return out quick inet proto udp from any to <zm_quic4> port 443 user { >root }'
    printf '%s\n' 'block return out quick inet6 proto udp from any to <zm_quic6> port 443 user { >root }'
  fi
  printf 'pass out route-to (lo0 127.0.0.1) inet proto tcp from !127.0.0.0/8 to !<zm_skip4> port %s user { >root }\n' "$ports"
  printf 'pass out route-to (lo0 fe80::1) inet6 proto tcp from !::1 to !<zm_skip6> port %s user { >root }\n' "$ports"
}

pf_load() {   # $1 = якорь, правила — на stdin
  local out
  out=$(pfctl -q -a "$1" -f - 2>&1) && return 0
  err "pf не принял правила: $(printf '%s\n' "$out" | grep -v ALTQ | head -3)"
  return 1
}

pf_on() { pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; }
# pf работает, пока хоть кто-то держит «токен» включения (pfctl -E / -X)
pf_take() {   # $1 = файл для токена
  local t
  [ -s "$1" ] && pf_on && return 0
  t=$(pfctl -E 2>&1 | awk '/^Token/ {print $NF}')
  [ -n "$t" ] && printf '%s\n' "$t" > "$1"
  pf_on
}
pf_give() { [ -s "$1" ] && pfctl -X "$(cat "$1")" >/dev/null 2>&1; rm -f "$1"; }

fw_on() { pf_rules_main | pf_load "$(anchor_main)" && pf_take "$RUN/pf-token"; }
fw_off() { pfctl -q -a "$(anchor_main)" -F all >/dev/null 2>&1; }
fw_loaded() { pfctl -a "$(anchor_main)" -s nat 2>/dev/null | grep -q '^rdr'; }

# правда ли трафик программ доходит до tpws: открываем сайт от имени пользователя
# и ищем в таблице состояний pf соединение, завёрнутое на 127.0.0.1:988
redirect_works() {
  sudo -u "$(probe_user)" /usr/bin/curl -s -o /dev/null --noproxy '*' --connect-timeout 5 --max-time 8 -A "$UA" "$CONTROL_URL" || return 1
  pfctl -s state 2>/dev/null | grep -qF "127.0.0.1:$TP_PORT"
}

pf_conf_patch() {
  local f=/etc/pf.conf
  if ! grep -q '^rdr-anchor "zapret-mac/\*"$' "$f"; then
    [ -f "$DIR/pf.conf.orig" ] || cp "$f" "$DIR/pf.conf.orig"
    sed -i '' -e '/^rdr-anchor "com\.apple\/\*"$/i\
rdr-anchor "zapret-mac/*"
' "$f"
  fi
  grep -q '^anchor "zapret-mac/\*"$' "$f" || sed -i '' -e '/^anchor "com\.apple\/\*"$/i\
anchor "zapret-mac/*"
' "$f"
  grep -q '^rdr-anchor "zapret-mac/\*"$' "$f" && grep -q '^anchor "zapret-mac/\*"$' "$f" || {
    err "Не получилось вписать якоря в $f (он изменён вручную?)"
    return 1
  }
  pfctl -q -f "$f" >/dev/null 2>&1
}

pf_conf_unpatch() {
  grep -q 'zapret-mac/\*' /etc/pf.conf 2>/dev/null || return 0
  sed -i '' -e '/^rdr-anchor "zapret-mac\/\*"$/d' -e '/^anchor "zapret-mac\/\*"$/d' /etc/pf.conf
  pfctl -q -f /etc/pf.conf >/dev/null 2>&1
}

# включает перенаправление и проверяет, что оно работает
# 0 — работает; 1 — на этом Mac не работает; 2 — нет интернета, проверить нельзя
fw_try() {
  local patched=0
  if ! { detect_phys && /usr/bin/curl -s -o /dev/null --noproxy '*' --interface "$PHYS" \
           --connect-timeout 5 --max-time 8 "$CONTROL_URL"; }; then
    fw_on; return 2
  fi
  fw_on && redirect_works && return 0
  if [ "$(cfg PF_ROOT com.apple)" = com.apple ]; then
    fw_off
    pf_conf_patch || return 1
    patched=1
    cfg_set PF_ROOT zapret-mac
    fw_on && redirect_works && return 0
  fi
  fw_off
  if [ "$patched" = 1 ]; then pf_conf_unpatch; cfg_set PF_ROOT com.apple; fi
  return 1
}

# прозрачный режим не заработал — чтобы не оставить без интернета, уходим на SOCKS-прокси
tp_fallback() {
  fw_off
  cfg_set MODE socks; cfg_set TP_OK 0
  tpws_apply socks >/dev/null 2>&1 && proxy_on >/dev/null 2>&1
}

# Подбор при включённом VPN: временный tpws шлёт с адреса Wi-Fi, а это правило
# выпускает такие пакеты прямо в Wi-Fi мимо туннеля. Обычный трафик программ
# идёт с адреса VPN и правило не задевает. Результат: TEST_VPN, PHYS*
test_env_up() {
  local ip_direct ip_test
  TEST_VPN=""
  detect_phys || { err "Нет подключения к интернету."; return 1; }
  if port_listening "$TEST_PORT"; then err "Порт $TEST_PORT занят — подбор уже идёт (возможно, его запустил сторож). Подожди пару минут."; return 1; fi
  TEST_VPN=$(vpn_iface) || { TEST_VPN=""; return 0; }
  printf 'pass out quick on %s route-to (%s %s) inet proto tcp from %s to any\n' "$TEST_VPN" "$PHYS" "$PHYS_GW" "$PHYS_IP" |
    pf_load "$(anchor_test)" && pf_take "$RUN/pf-token-test" || { test_env_down; return 1; }
  ip_direct=$(my_ip --noproxy '*' --interface "$PHYS")
  ip_test=""
  if start_test 1 "$PHYS_IP"; then ip_test=$(my_ip --socks5-hostname "127.0.0.1:$TEST_PORT"); fi
  stop_test
  if [ -z "$ip_direct" ] || [ "$ip_direct" != "$ip_test" ]; then
    test_env_down
    err "VPN ($TEST_VPN) не даёт проверить сеть напрямую."
    say "   Выключи VPN на пару минут, подбери стратегии и включай его обратно — обход подхватит сам."
    return 1
  fi
  say "${D}VPN включён ($TEST_VPN) — проверяю провайдера напрямую через $PHYS, мимо VPN.${N}"
}

test_env_down() {
  [ -n "$TEST_VPN" ] || return 0
  pfctl -q -a "$(anchor_test)" -F all >/dev/null 2>&1
  pf_give "$RUN/pf-token-test"
  TEST_VPN=""
}

start_test() {   # $1 = номер стратегии или cur, $2 = адрес для исходящих (когда VPN включён)
  build_test_args "$1" "$2"
  "$TPWS" "${ARGS[@]}" >/dev/null 2>&1 &
  TPID=$!
  wait_port "$TEST_PORT" 40 && return 0
  stop_test
  return 1
}
stop_test() { [ -n "$TPID" ] && { kill "$TPID" 2>/dev/null; wait "$TPID" 2>/dev/null; }; TPID=""; }

# ─── launchd (системные демоны) ──────────────────────────────────────
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

write_plist() {   # $1 = метка, $2 = файл, $3 = лог, дальше — программа с аргументами
  local label=$1 file=$2 logf=$3 a
  shift 3
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
EOF
    for a in "$@"; do printf '    <string>%s</string>\n' "$(xml "$a")"; done
    cat <<EOF
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>SoftResourceLimits</key><dict><key>NumberOfFiles</key><integer>24576</integer></dict>
  <key>HardResourceLimits</key><dict><key>NumberOfFiles</key><integer>24576</integer></dict>
  <key>StandardOutPath</key><string>$(xml "$logf")</string>
  <key>StandardErrorPath</key><string>$(xml "$logf")</string>
</dict>
</plist>
EOF
  } > "$file.tmp" && chown root:wheel "$file.tmp" && chmod 644 "$file.tmp" && mv -f "$file.tmp" "$file"
}

job_loaded() { launchctl print "system/$1" >/dev/null 2>&1; }

job_unload() {
  local i
  launchctl bootout "system/$1" >/dev/null 2>&1
  for (( i=0; i<30; i++ )); do job_loaded "$1" || break; sleep 0.1; done
}

job_load() {   # $1 = метка, $2 = plist
  local i
  job_unload "$1"
  launchctl enable "system/$1" >/dev/null 2>&1
  for (( i=0; i<5; i++ )); do
    launchctl bootstrap system "$2" >/dev/null 2>&1 && return 0
    sleep 1
  done
  launchctl load -w "$2" >/dev/null 2>&1
}

# (пере)запускает основной tpws с текущими стратегиями; $1 = transparent|socks
tpws_apply() {
  local port
  port=$(main_port "$1")
  build_main_args "$1"
  if port_busy_by_other "$port"; then
    err "Порт $port занят программой «$(port_owner "$port")». Закрой её и попробуй снова."
    return 1
  fi
  if ! "$TPWS" "${ARGS[@]}" --dry-run >/dev/null 2>&1; then
    err "tpws не принял параметры стратегий:"
    "$TPWS" "${ARGS[@]}" --dry-run 2>&1 | tail -n 3 >&2
    return 1
  fi
  : > "$LOGS/tpws.log"
  write_plist "$LBL_TPWS" "$PL_TPWS" "$LOGS/tpws.log" "$TPWS" "${ARGS[@]}" || { err "Не могу записать $PL_TPWS"; return 1; }
  job_load "$LBL_TPWS" "$PL_TPWS"
  if ! wait_bound "$port" 60; then
    err "tpws не запустился. Последние строки лога:"
    tail -n 15 "$LOGS/tpws.log" >&2
    job_unload "$LBL_TPWS"; rm -f "$PL_TPWS"
    return 1
  fi
}

wd_load() {
  write_plist "$LBL_WD" "$PL_WD" "$LOGS/watchdog.err" /bin/bash "$SELF" daemon &&
  job_load "$LBL_WD" "$PL_WD"
}

# ─── установка ───────────────────────────────────────────────────────
HDR_YT="# YouTube и Google (Flowseal list-google). Файл перезаписывается при обновлении."
HDR_GEN="# Discord и остальное (Flowseal list-general). Файл перезаписывается при обновлении. Свои сайты — в list-user.txt"
HDR_EX="# Эти сайты обход не трогает (Flowseal list-exclude). Файл перезаписывается при обновлении. Свои — в list-exclude-user.txt"

# службы Apple обход трогать незачем, а их OCSP и iCloud автосписок любит принимать за блокировку
write_mac_exclude() {
  { say "# Службы Apple — обход их не трогает (zapret-mac). Свои исключения — в list-exclude-user.txt"
    tr ' ' '\n' <<'EOF'
apple.com icloud.com icloud-content.com me.com mzstatic.com apple-cloudkit.com cdn-apple.com aaplimg.com apple-dns.net apple.news itunes.com
EOF
  } > "$LISTS/list-exclude-mac.txt"
  chmod 644 "$LISTS/list-exclude-mac.txt"
}

write_lists() {
  mkdir -p "$LISTS"
  write_mac_exclude
  { say "$HDR_YT"; cat <<'EOF'
yt3.ggpht.com
yt4.ggpht.com
yt3.googleusercontent.com
googlevideo.com
jnn-pa.googleapis.com
stable.dl2.discordapp.net
wide-youtube.l.google.com
youtube-nocookie.com
youtube-ui.l.google.com
youtube.com
youtubeembeddedplayer.googleapis.com
youtubekids.com
youtube.googleapis.com
youtubei.googleapis.com
youtu.be
yt-video-upload.l.google.com
ytimg.com
ytimg.l.google.com
play.google.com
fonts.googleapis.com
www.gstatic.com
google.ru
EOF
  } > "$LISTS/list-youtube.txt"
  { say "$HDR_GEN"; cat <<'EOF'
^dns.google
^dns.quad9.net
^dns.nextdns.io
^doh.opendns.com
^doh.cleanbrowsing.org
^freedns.controld.com
^wikimedia-dns.org
^cloudflare-dns.com
cloudflare-ech.com
encryptedsni.com
cloudflareaccess.com
cloudflareapps.com
cloudflarebolt.com
cloudflareclient.com
cloudflareinsights.com
cloudflareok.com
cloudflarepartners.com
cloudflareportal.com
cloudflarepreview.com
cloudflareresolve.com
cloudflaressl.com
cloudflarestatus.com
cloudflarestorage.com
cloudflarestream.com
cloudflaretest.com
cloudfront.net
dis.gd
discord-attachments-uploads-prd.storage.googleapis.com
discord.app
discord.co
discord.com
discord.design
discord.dev
discord.gift
discord.gifts
discord.gg
discord.media
discord.new
discord.store
discord.status
discord-activities.com
discordactivities.com
discordapp.com
discordapp.net
discordcdn.com
discordmerch.com
discordpartygames.com
discordsays.com
discordsez.com
discordstatus.com
zendesk.com
frankerfacez.com
ffzap.com
betterttv.net
7tv.app
7tv.io
localizeapi.com
klipy.com
live-video.net
EOF
  } > "$LISTS/list-general.txt"
  { say "$HDR_EX"; tr ' ' '\n' <<'EOF'
pusher.com twitch.tv steampowered.com steamcommunity.com steamusercontent.com nvidia.com msi.com marketplace.visualstudio.com gallery.vsassets.io gallerycdn.vsassets.io libreoffice.org documentfoundation.org 7-zip.org aida64.com battlepass.ru finargot.ru calibre-ebook.com ccleaner.com filezilla-project.org freecad.org gpg4win.org handbrake.fr sumatrapdfreader.org win-rar.com mail.ru citilink.ru yandex.com yandex.net yandex.org yandex.md yandex.ru yandexadexchange.net yandexcloud.net yandexcom.net yandexmetrica.com yandexwebcache.net yandexwebcache.org yastat.net yastatic-net.ru yastatic.net ya.ru adfox.ru admetrica.ru naydex.net rostaxi.org turbopages.org webvisor.com webvisor.org donationalerts.com vk.com yandex.kz mts.ru multimc.org dns-shop.ru habr.com 3dnews.ru microsoft.com microsoftonline.com live.com sharepoint.com minecraft.net xboxlive.com akamaitechnologies.com 2ip.ru boosty.to tanki.su lesta.ru lesta.pw korabli.su tanksblitz.ru reg.ru epicgames.dev epicgames.com unrealengine.com riotgames.com riotcdn.net leagueoflegends.com playvalorant.com gosuslugi.ru gov.ru nalog.ru spb.ru mos.ru vk.ru vk.me vkvideo.ru ok.ru mycdn.me okcdn.ru odkl.ru wb.ru geobasket.ru paywb.com rwb.ru wb-basket.ru wbbasket.ru wbpay.ru wibes.ru wildberries.ru ozon.by ozon.com ozon.com.by ozon.com.kz ozon.kz ozon.ru ozon.tm ozone.ru ozonru.me ozonusercontent.com alfabank.ru gazprombank.ru gpb.ru dbo-dengi.online mtsdengi.ru psbank.ru bankline.ru rosbank.ru abr.ru rshb.ru sber.ru sberbank.com sberbank.ru cdn-tinkoff.ru tbank-online.com tbank.ru t-bank-app.ru tochka-tech.com tochka.com vtb.ru
EOF
  } > "$LISTS/list-exclude.txt"
  [ -f "$LISTS/list-user.txt" ] || say "# Свои домены для обхода, по одному в строке (поддомены учитываются сами)" > "$LISTS/list-user.txt"
  [ -f "$LISTS/list-exclude-user.txt" ] || say "# Домены, которые НЕ трогать, даже если они попали в списки выше" > "$LISTS/list-exclude-user.txt"
  [ -f "$LISTS/list-auto.txt" ] || : > "$LISTS/list-auto.txt"
  chmod 644 "$LISTS"/*.txt
}

# свежий список Flowseal; принимаем, только если в нём одни домены
fetch_list() {   # $1 = имя у Flowseal, $2 = наш файл, $3 = заголовок
  local tmp
  tmp=$(mktemp /tmp/zapret-mac-list.XXXXXX) || return 1
  if curl -fsSL --connect-timeout 10 --max-time 30 \
       "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/$1" 2>/dev/null | tr -d '\r' > "$tmp" &&
     [ "$(grep -c . "$tmp")" -ge 5 ] && ! grep -vqE '^(\^?[A-Za-z0-9*][A-Za-z0-9.*-]*)?$' "$tmp"; then
    { say "$3"; cat "$tmp"; } > "$2.new" && chmod 644 "$2.new" && mv -f "$2.new" "$2"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

install_tpws() {
  local tag=$1 want=$2 tmp url got member old="$RHOME/.zapret-mac/bin/tpws"
  mkdir -p "$BIN_DIR" || die "Не могу создать $BIN_DIR"
  # tpws от первой версии скрипта подойдёт, если это тот же файл
  if [ "$tag" = "$ZAPRET_TAG" ] && [ -n "$RHOME" ] && [ -f "$old" ] &&
     [ "$(shasum -a 256 "$old" | awk '{print $1}')" = "$want" ]; then
    install -m 755 -o root -g wheel "$old" "$TPWS" && printf '%s\n' "$tag" > "$DIR/zapret-version" &&
      { ok "tpws $tag перенесён из прежней версии (контрольная сумма проверена)"; return 0; }
  fi
  tmp=$(mktemp -d /tmp/zapret-mac.XXXXXX) || die "Не могу создать временную папку"
  url="https://github.com/bol-van/zapret/releases/download/$tag/zapret-$tag.tar.gz"
  member="zapret-$tag/binaries/mac64/tpws"
  say "Скачиваю zapret $tag с GitHub…"
  if ! curl -fL --progress-bar --connect-timeout 15 -o "$tmp/z.tgz" "$url"; then
    rm -rf "$tmp"; die "Не удалось скачать $url — проверь интернет и попробуй ещё раз."
  fi
  tar -xzf "$tmp/z.tgz" -C "$tmp" "$member" 2>/dev/null || { rm -rf "$tmp"; die "В архиве нет tpws для macOS."; }
  got=$(shasum -a 256 "$tmp/$member" | awk '{print $1}')
  if [ "$got" != "$want" ]; then
    rm -rf "$tmp"; die "Контрольная сумма tpws не совпала — файл повреждён или подменён. Установка отменена."
  fi
  install -m 755 -o root -g wheel "$tmp/$member" "$TPWS.new" && mv -f "$TPWS.new" "$TPWS"
  xattr -c "$TPWS" 2>/dev/null
  rm -rf "$tmp"
  "$TPWS" --version >/dev/null 2>&1 || die "tpws не запускается на этом Mac."
  printf '%s\n' "$tag" > "$DIR/zapret-version"
  ok "tpws $tag установлен (контрольная сумма проверена)"
}

self_install() {
  local me
  me=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")
  if [ -f "$me" ] && [ "$me" != "$SELF" ] && ! cmp -s "$me" "$SELF"; then
    install -m 755 -o root -g wheel "$me" "$SELF" || die "Не могу скопировать скрипт в $DIR"
  fi
  if [ -n "$SHORTCUT" ] && [ -d "${SHORTCUT%/*}" ] && ! grep -qF "$SELF" "$SHORTCUT" 2>/dev/null; then
    printf '#!/bin/bash\nexec /bin/bash "%s"\n' "$SELF" > "$SHORTCUT" 2>/dev/null && chmod 755 "$SHORTCUT" &&
      chown "$RUSER" "$SHORTCUT" 2>/dev/null &&
      ok "На рабочем столе ярлык Zapret.command — двойной клик открывает это меню"
  fi
}

# первая версия жила в ~/.zapret-mac как агент пользователя с SOCKS-прокси:
# гасим её и забираем свои списки, DNS-бэкап и выбранную стратегию
migrate_v1() {
  local od="$RHOME/.zapret-mac" uid n m f
  [ -n "$RHOME" ] && [ -d "$od" ] || return 0
  uid=$(id -u "$RUSER" 2>/dev/null)
  [ -n "$uid" ] && launchctl bootout "gui/$uid/com.zapret-mac.tpws" >/dev/null 2>&1
  rm -f "$RHOME/Library/LaunchAgents/com.zapret-mac.tpws.plist"
  pkill -f "$od/bin/tpws" >/dev/null 2>&1
  proxy_off
  [ -f "$od/dns-backup" ] && [ ! -f "$DNS_BACKUP" ] && cp "$od/dns-backup" "$DNS_BACKUP"
  for f in list-user.txt list-exclude-user.txt; do
    [ -f "$od/lists/$f" ] || continue
    grep -vE '^#|^$' "$od/lists/$f" | while IFS= read -r n; do
      grep -qxF "$n" "$LISTS/$f" || printf '%s\n' "$n" >> "$LISTS/$f"
    done
  done
  n=$(cat "$od/strategy" 2>/dev/null)
  case $n in
    1|2|3) m=$n ;;
    14) m=16 ;;
    4|5|6|7|8|9|10|11|12|13) m=$(( n + 1 )) ;;   # в v2 после ALT2 добавилась MULTI
    *) m="" ;;
  esac
  if [ -n "$m" ] && ! grep -q '^S_Y=' "$CONF" 2>/dev/null; then cfg_set S_Y "$m"; cfg_set S_D "$m"; fi
  rm -rf "$od"
  ok "Первая версия убрана: свои сайты, стратегия и DNS-настройки перенесены"
}

ensure_installed() {
  mkdir -p "$BIN_DIR" "$LISTS" "$LOGS" "$RUN" || die "Не могу создать $DIR"
  chown root:wheel "$DIR" "$BIN_DIR" "$LISTS" "$LOGS" "$RUN" 2>/dev/null
  chmod 755 "$DIR" "$BIN_DIR" "$LISTS" "$LOGS" "$RUN"
  self_install
  [ -x "$TPWS" ] || install_tpws "$ZAPRET_TAG" "$TPWS_SHA256"
  [ -f "$LISTS/list-youtube.txt" ] || write_lists
  [ -f "$LISTS/list-exclude-mac.txt" ] || write_mac_exclude
  migrate_v1
}

# ─── команды (все, кроме меню и discord, работают от root) ───────────
cmd_install() {
  ensure_installed
  ok "zapret-mac $ZM_VERSION установлен в $DIR"
  [ -f "$PL_TPWS" ] && cmd_start   # обновление поверх включённого — перезапускаем с новым кодом
  return 0
}

cmd_start() {
  local mode v rc
  ensure_installed
  mode=$(cfg MODE transparent)
  job_unload "$LBL_WD"   # сторож не должен вмешиваться, пока настраиваем
  if ! tpws_apply "$mode"; then
    fw_off; proxy_off   # tpws не поднялся — перенаправлять некуда, отпускаем трафик напрямую
    return 1
  fi
  if [ "$mode" = transparent ]; then
    proxy_off
    if v=$(vpn_iface); then
      fw_off
      ok "Обход готов. Сейчас включён VPN ($v) — пока он работает, всё идёт через него."
      say "   Выключишь VPN — обход включится сам, ничего нажимать не нужно."
      [ "$(cfg TP_OK 0)" = 1 ] || say "   ${D}Прозрачный режим на этом Mac ещё не проверен — сторож проверит его сразу после выключения VPN.${N}"
    else
      fw_try; rc=$?
      case $rc in
        0) cfg_set TP_OK 1
           ok "Обход включён — прозрачный режим: через tpws идут все программы, включая апдейтер Discord" ;;
        2) warn "Нет интернета — перенаправление включено, сторож проверит его, когда сеть появится." ;;
        *) warn "Прозрачный режим на этом Mac не заработал — переключаюсь на SOCKS-прокси."
           say  "   В режиме SOCKS часть программ (апдейтер Discord) обход не увидит."
           cfg_set MODE socks; cfg_set TP_OK 0; mode=socks
           tpws_apply socks || return 1 ;;
      esac
    fi
  else
    fw_off
  fi
  [ "$mode" = socks ] && { proxy_on || return 1; }
  wd_load || warn "Сторож не запустился — автопереключение с VPN работать не будет."
  log "Включён: режим $(mode_name), YouTube — $(strat_of Y), Discord — $(strat_of D)"
  say "   Стратегии: YouTube — $(strat_of Y) ($(strat_name "$(strat_of Y)")), Discord — $(strat_of D) ($(strat_name "$(strat_of D)"))"
  say "   Работает в фоне и сам включается после перезагрузки, пока не выберешь «Выключить»."
  say "   VPN можно включать и выключать как обычно — сторож переключает обход сам."
  warn_other_proxies
  return 0
}

cmd_stop() {
  job_unload "$LBL_WD"; rm -f "$PL_WD"
  job_unload "$LBL_TPWS"; rm -f "$PL_TPWS"
  pkill -f "$BIN_DIR/tpws" >/dev/null 2>&1
  fw_off
  pfctl -q -a "$(anchor_test)" -F all >/dev/null 2>&1
  pf_give "$RUN/pf-token"; pf_give "$RUN/pf-token-test"
  proxy_off
  [ -d "$RUN" ] && printf 'off\n' > "$RUN/status"
  log "Выключен"
  ok "Обход выключен, перенаправление и прокси сняты."
}

# подбор стратегий. $1 = all — прогнать все; auto — для сторожа: сначала проверить текущие
# результат: SEL_Y, SEL_D (номера), SEL_SY, SEL_SD (баллы), SEL_PATH=1 если текущие и так рабочие,
# SEL_CUT — что обрывалось на 16 КБ
select_strategies() {
  local i by bd sy=-1 sd=-1 bind=""
  SEL_PATH=0; SEL_CUT=""
  test_env_up || return 1
  trap 'stop_test; test_env_down; exit 130' INT TERM HUP
  [ -n "$TEST_VPN" ] && bind=$PHYS_IP
  by=$(strat_of Y); bd=$(strat_of D)
  say ""
  say "${B}Без обхода${N} ${D}(напрямую через $PHYS)${N}"
  run_checks direct
  print_checks
  if [ "$SCORE_Y" -eq "$NY" ] && [ "$SCORE_D" -eq "$ND" ]; then
    warn "Всё открывается и без обхода — блокировок сейчас нет. Подбор всё равно проведу."
  fi
  if [ "$1" = auto ] && start_test cur "$bind"; then
    run_checks "socks:$TEST_PORT"; stop_test
    sy=$SCORE_Y; sd=$SCORE_D; SEL_CUT=$LAST_CUT
    say "Текущие стратегии: YouTube $(score_mark "$sy" "$NY") · Discord $(score_mark "$sd" "$ND")"
    if [ "$sy" -eq "$NY" ] && [ "$sd" -eq "$ND" ]; then
      SEL_PATH=1; SEL_Y=$by; SEL_D=$bd; SEL_SY=$sy; SEL_SD=$sd
      test_env_down; trap - INT TERM HUP
      return 0
    fi
  fi
  say ""
  say "${B}Перебираю стратегии${N} ${D}(до 10 секунд на каждую)${N}"
  for (( i=1; i<=NSTRAT; i++ )); do
    if ! start_test "$i" "$bind"; then
      printf ' [%2d/%d] %-7s не запустилась\n' "$i" "$NSTRAT" "$(strat_name "$i")"
      continue
    fi
    run_checks "socks:$TEST_PORT"; stop_test
    printf ' [%2d/%d] %-7s YouTube %s  Discord %s' "$i" "$NSTRAT" "$(strat_name "$i")" \
      "$(score_mark "$SCORE_Y" "$NY")" "$(score_mark "$SCORE_D" "$ND")"
    [ -n "$LAST_FAIL" ] && printf '  %sне открылось: %s%s' "$D" "$LAST_FAIL" "$N"
    [ -n "$LAST_CUT" ] && { printf '  %sобрыв на 16 КБ: %s%s' "$D" "$LAST_CUT" "$N"; SEL_CUT=$LAST_CUT; }
    printf '\n'
    [ "$SCORE_Y" -gt "$sy" ] && { by=$i; sy=$SCORE_Y; }
    [ "$SCORE_D" -gt "$sd" ] && { bd=$i; sd=$SCORE_D; }
    [ "$1" != all ] && [ "$sy" -eq "$NY" ] && [ "$sd" -eq "$ND" ] && break
  done
  test_env_down
  trap - INT TERM HUP
  SEL_Y=$by; SEL_D=$bd; SEL_SY=$sy; SEL_SD=$sd
  [ "$sy" -ge 0 ]
}

report_group() {   # $1 = название, $2 = стратегия, $3 = балл, $4 = из скольких
  if [ "$3" -eq "$4" ]; then ok "$1: стратегия $2 ($(strat_name "$2")) — открывается всё"
  else warn "$1: лучшая — стратегия $2 ($(strat_name "$2")): $3 из $4. Часть может не работать."; fi
}

cmd_test() {   # $1 = all — прогнать все, иначе остановиться, когда нашлись рабочие для обоих
  ensure_installed
  select_strategies "$1" || return 1
  say ""
  if [ "$SEL_SY" -le 0 ] && [ "$SEL_SD" -le 0 ]; then
    err "Ни одна стратегия не помогла."
    say "   Что попробовать: пункт «DNS Google/Cloudflare» и подбор заново; другая сеть; на это время — VPN."
    return 1
  fi
  if [ "$SEL_SY" -gt 0 ]; then cfg_set S_Y "$SEL_Y"; report_group YouTube "$SEL_Y" "$SEL_SY" "$NY"
  else warn "YouTube не открылся ни с одной стратегией — оставил прежнюю."; fi
  if [ "$SEL_SD" -gt 0 ]; then cfg_set S_D "$SEL_D"; report_group Discord "$SEL_D" "$SEL_SD" "$ND"
  else warn "Discord не открылся ни с одной стратегией — оставил прежнюю."; fi
  cut_note "$SEL_CUT"
  say "   ${D}Звонки Discord идут по UDP, а tpws умеет только TCP. Если голос не подключается — на время звонка включи VPN.${N}"
  log "Подбор: YouTube — $SEL_Y ($SEL_SY/$NY), Discord — $SEL_D ($SEL_SD/$ND)"
  return 0
}

cmd_auto() {
  cmd_test && cmd_start
}

cmd_choose() {
  local i n y d
  y=$(strat_of Y); d=$(strat_of D)
  say ""
  for (( i=1; i<=NSTRAT; i++ )); do
    printf '  %2d  %-7s' "$i" "$(strat_name "$i")"
    [ "$i" = "$y" ] && printf '  %s← YouTube%s' "$B" "$N"
    [ "$i" = "$d" ] && printf '  %s← Discord%s' "$B" "$N"
    printf '\n'
  done
  printf '\nСтратегия для YouTube (Enter — оставить %s): ' "$y"
  read -r n
  case $n in
    '') ;;
    *[!0-9]*) err "Нет такой стратегии"; return ;;
    *) { [ "$n" -ge 1 ] && [ "$n" -le "$NSTRAT" ]; } || { err "Нет такой стратегии"; return; }; y=$n ;;
  esac
  printf 'Стратегия для Discord (Enter — оставить %s): ' "$d"
  read -r n
  case $n in
    '') ;;
    *[!0-9]*) err "Нет такой стратегии"; return ;;
    *) { [ "$n" -ge 1 ] && [ "$n" -le "$NSTRAT" ]; } || { err "Нет такой стратегии"; return; }; d=$n ;;
  esac
  cfg_set S_Y "$y"; cfg_set S_D "$d"
  cmd_start
}

cmd_check() {
  local v mode
  ensure_installed
  mode=$(cfg MODE transparent)
  say ""
  if v=$(vpn_iface); then
    say "${B}VPN включён${N} ($v) — сейчас всё идёт через VPN. ${B}Как открывается:${N}"
    run_checks apps
    print_checks
    [ -f "$PL_TPWS" ] || return 0
    say ""
    say "${B}Обход наготове — так будет, когда выключишь VPN:${N}"
    if test_env_up; then
      trap 'stop_test; test_env_down; exit 130' INT TERM HUP
      if start_test cur "$PHYS_IP"; then run_checks "socks:$TEST_PORT"; print_checks; cut_note "$LAST_CUT"; fi
      stop_test; test_env_down
      trap - INT TERM HUP
    fi
    return 0
  fi
  say "${B}Напрямую, без обхода:${N}"
  run_checks direct
  print_checks
  if [ ! -f "$PL_TPWS" ]; then warn "Обход выключен."; return 0; fi
  say "${B}Как видят программы — через обход (режим: $(mode_name)):${N}"
  if [ "$mode" = socks ]; then run_checks "socks:$SOCKS_PORT"; else run_checks apps; fi
  print_checks
  if [ "$SCORE_Y" -ne "$NY" ] || [ "$SCORE_D" -ne "$ND" ]; then warn "Не всё открывается — подбери стратегии заново (пункт 1)."
  elif [ -z "$LAST_CUT" ]; then ok "YouTube и Discord открываются."
  fi
  cut_note "$LAST_CUT"
}

cmd_status() {
  local mode n v
  mode=$(cfg MODE transparent)
  say ""
  if [ -x "$TPWS" ]; then ok "tpws установлен: $(cat "$DIR/zapret-version" 2>/dev/null) · zapret-mac $ZM_VERSION"; else warn "tpws ещё не установлен"; fi
  say "   Режим: $(mode_name)"
  say "   Стратегии: YouTube — $(strat_of Y) ($(strat_name "$(strat_of Y)")), Discord — $(strat_of D) ($(strat_name "$(strat_of D)"))"
  if job_loaded "$LBL_TPWS" && tpws_up "$mode"; then ok "tpws работает на 127.0.0.1:$(main_port "$mode")"
  elif job_loaded "$LBL_TPWS"; then warn "tpws запущен, но порт $(main_port "$mode") не отвечает — смотри лог: $LOGS/tpws.log"
  else say "   tpws не запущен"; fi
  if job_loaded "$LBL_WD"; then
    ok "Сторож работает: следит за VPN, проверяет YouTube и Discord (автоподбор: $([ "$(cfg AUTOFIX 1)" = 1 ] && echo вкл || echo выкл))"
  else say "   Сторож не запущен"; fi
  if [ "$mode" = transparent ]; then
    if fw_loaded && pf_on; then ok "Перенаправление pf включено ($(anchor_main)), QUIC к Google: $([ "$(cfg QUIC 1)" = 1 ] && echo глушится || echo не трогается)"
    else say "   Перенаправление pf сейчас снято"; fi
  elif proxy_any_on; then ok "Системный SOCKS-прокси включён"
  else say "   Системный прокси выключен"; fi
  if v=$(vpn_iface); then say "   ${B}VPN включён${N} ($v): трафик идёт через VPN, обход ждёт"; else say "   VPN: выключен"; fi
  n=$(grep -c . "$LISTS/list-auto.txt" 2>/dev/null)
  say "   Автосписок: $([ "$(cfg AUTOLIST 0)" = 1 ] && echo "вкл, ${n:-0} сайтов" || echo выкл) · свои сайты: $LISTS/list-user.txt"
  [ -f "$DNS_BACKUP" ] && say "   DNS: Google/Cloudflare (включено скриптом)"
  if [ -s "$LOGS/watchdog.log" ]; then
    say ""
    say "${B}Журнал сторожа:${N}"
    tail -n 10 "$LOGS/watchdog.log" | sed 's/^/   /'
  fi
  warn_other_proxies
}

discord_app() {   # ищет Discord.app → DS_APP
  local p
  DS_APP=""
  for p in "/Applications/Discord.app" "$HOME/Applications/Discord.app"; do
    [ -d "$p" ] && { DS_APP=$p; return 0; }
  done
  return 1
}

ds_running() { pgrep -x -U "$(id -u)" Discord >/dev/null 2>&1; }

# открывает Discord так, как нужно в текущем режиме: в SOCKS — с прокси обхода
discord_launch() {
  if [ "$(cfg MODE transparent)" = socks ]; then
    ALL_PROXY="socks5h://127.0.0.1:$SOCKS_PORT" all_proxy="socks5h://127.0.0.1:$SOCKS_PORT" \
    HTTPS_PROXY="socks5h://127.0.0.1:$SOCKS_PORT" https_proxy="socks5h://127.0.0.1:$SOCKS_PORT" \
      nohup "$DS_APP/Contents/MacOS/Discord" --proxy-server="socks5://127.0.0.1:$SOCKS_PORT" >/dev/null 2>&1 &
    disown 2>/dev/null
  else
    open -a "$DS_APP"
  fi
}

cmd_discord() {   # от имени пользователя
  local i
  discord_app || die "Discord не найден в «Программах»."
  [ -f "$PL_TPWS" ] || die "Сначала включи обход (пункт 1 или 2)."
  if ds_running; then
    osascript -e 'tell application "Discord" to quit' >/dev/null 2>&1
    for (( i=0; i<30; i++ )); do ds_running || break; sleep 0.3; done
    pkill -x Discord >/dev/null 2>&1
    sleep 1
  fi
  discord_launch
  if [ "$(cfg MODE transparent)" = socks ]; then
    ok "Discord перезапущен через SOCKS-прокси обхода."
    say "   Апдейтер Discord прокси не слушает — если висит «Checking for updates», верни прозрачный режим (пункт 9)."
  else
    ok "Discord перезапущен."
    say "   В прозрачном режиме обход видит и апдейтер — «Checking for updates» проходит за несколько секунд."
  fi
}

# состояние, которое пишет сторож (direct|vpn|down|off) → WD_ST. После перезагрузки
# в файле может остаться старое, поэтому верим ему, только если он записан после загрузки
wd_read_state() {
  local boot m
  WD_ST=""
  [ -f "$RUN/status" ] || return 1
  boot=$(sysctl -n kern.boottime 2>/dev/null | awk -F'[ ,]+' '{print $4}')
  m=$(stat -f %m "$RUN/status" 2>/dev/null)
  case "$boot$m" in ''|*[!0-9]*) ;; *) [ "$m" -ge "$boot" ] || return 1 ;; esac
  read -r WD_ST _ < "$RUN/status"
  [ -n "$WD_ST" ]
}

# ждёт до $1 секунд, пока поднимется обход. Если включён VPN, ждать нечего
ds_wait_ready() {
  local i
  for (( i=0; i<$1; i++ )); do
    if wd_read_state; then
      case $WD_ST in
        vpn) return 0 ;;
        direct) { [ "$(cfg MODE transparent)" != socks ] || port_listening "$SOCKS_PORT"; } && return 0 ;;
      esac
    fi
    sleep 1
  done
  return 1
}

# вызывается из LaunchAgent при входе в систему
cmd_discord_auto() {
  discord_app || exit 0
  ds_running && exit 0                                        # уже открыт — не трогаем
  if [ ! -f "$PL_TPWS" ]; then open -a "$DS_APP"; exit 0; fi  # обход выключен — обычный запуск
  ds_wait_ready 120 || say "$(date '+%d.%m %H:%M:%S') обход не поднялся за 2 минуты, открываю Discord как есть"
  ds_running && exit 0                                        # пока ждали, его открыли руками
  discord_launch
}

ds_agent() { printf '%s/Library/LaunchAgents/%s.plist' "$RHOME" "$LBL_DS"; }
ds_autostart_state() { if [ -f "$(ds_agent)" ]; then printf '%sвкл%s' "$G" "$N"; else printf 'выкл'; fi; }

cmd_ds_autostart() {   # от имени пользователя: включает и выключает автозапуск
  local pl logf
  [ -n "$RHOME" ] || die "Не нашёл домашнюю папку пользователя."
  pl=$(ds_agent)
  if [ -f "$pl" ]; then
    launchctl bootout "gui/$(id -u)/$LBL_DS" >/dev/null 2>&1
    rm -f "$pl"
    ok "Автозапуск Discord выключен."
    return 0
  fi
  [ -f "$SELF" ] || die "Сначала установи zapret-mac (пункт 1)."
  discord_app || die "Discord не найден в «Программах»."
  logf="$RHOME/Library/Logs/zapret-mac-discord.log"
  mkdir -p "${pl%/*}" "${logf%/*}"
  # AbandonProcessGroup — чтобы launchd не убил Discord, запущенный в режиме SOCKS, вместе со скриптом
  cat > "$pl" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LBL_DS</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml "$SELF")</string>
    <string>discord-auto</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$(xml "$logf")</string>
  <key>StandardErrorPath</key><string>$(xml "$logf")</string>
</dict>
</plist>
EOF
  plutil -lint "$pl" >/dev/null 2>&1 || { rm -f "$pl"; die "Не получилось записать $pl"; }
  ok "Discord будет открываться сам при входе в систему, когда поднимется обход."
  say "   Если Discord есть в «Системные настройки → Основные → Объекты входа», убери его оттуда:"
  say "   иначе он стартует раньше обхода, а в режиме SOCKS — мимо прокси."
}

cmd_add() {
  local d
  ensure_installed
  printf 'Домен, который тоже надо пускать через обход (например, rutracker.org): '
  read -r d
  d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]' | sed -E 's#^[a-z]+://##; s#[/:?].*$##; s/^www\.//; s/[[:space:]]//g')
  [ -n "$d" ] || return
  case $d in *[!a-z0-9.-]*|.*|*.|*..*) err "Это не похоже на домен: $d"; return ;; esac
  if grep -qxF "$d" "$LISTS/list-user.txt" "$LISTS/list-general.txt" "$LISTS/list-youtube.txt" 2>/dev/null; then
    ok "$d уже в списке"
    return
  fi
  printf '%s\n' "$d" >> "$LISTS/list-user.txt"
  ok "$d добавлен — tpws перечитает список сам, перезапуск не нужен"
}

cmd_autolist() {
  local f="$LISTS/list-auto.txt" n a
  n=$(grep -c . "$f" 2>/dev/null)
  say ""
  say "Автосписок — сюда tpws сам добавляет сайты, на которых заметил блокировку: ${n:-0}"
  if [ "$(cfg AUTOLIST 0)" = 1 ]; then say "   Сейчас: ${G}включён${N}"
  else say "   Сейчас: выключен — включается в «Настройках» (пункт 9). ${D}Может сломать сайты на Cloudflare у провайдеров с обрывом на 16 КБ.${N}"; fi
  [ "${n:-0}" -gt 0 ] && sed 's/^/   /' "$f"
  say "${D}Если какой-то сайт попал сюда зря и стал хуже работать — добавь его в $LISTS/list-exclude-user.txt${N}"
  [ "${n:-0}" -gt 0 ] || return 0
  printf 'Очистить автосписок? [y/N] '
  read -r a
  case $a in y|Y|д|Д|yes|да) : > "$f"; ok "Автосписок очищен" ;; esac
}

cmd_settings() {
  local c
  while true; do
    say ""
    say "  1  Глушить QUIC к Google, чтобы браузер сразу шёл через обход: $([ "$(cfg QUIC 1)" = 1 ] && echo "${G}вкл${N}" || echo выкл)"
    say "  2  Сторож сам подбирает стратегии, если YouTube/Discord отвалились: $([ "$(cfg AUTOFIX 1)" = 1 ] && echo "${G}вкл${N}" || echo выкл)"
    say "  3  Режим: $(mode_name) — переключить на $([ "$(cfg MODE transparent)" = socks ] && echo прозрачный || echo SOCKS-прокси)"
    say "  4  Автосписок (tpws сам добавляет сайты, где заметил блокировку): $([ "$(cfg AUTOLIST 0)" = 1 ] && echo "${G}вкл${N}" || echo выкл)"
    say "  0  Назад"
    printf '\nВыбор: '
    read -r c || return 0
    case $c in
      1) if [ "$(cfg QUIC 1)" = 1 ]; then cfg_set QUIC 0; else cfg_set QUIC 1; fi
         fw_loaded && fw_on && ok "Правила pf обновлены" ;;
      2) if [ "$(cfg AUTOFIX 1)" = 1 ]; then cfg_set AUTOFIX 0; else cfg_set AUTOFIX 1; fi ;;
      3) if [ "$(cfg MODE transparent)" = socks ]; then cfg_set MODE transparent; else cfg_set MODE socks; fi
         if [ -f "$PL_TPWS" ]; then cmd_start; else ok "Режим: $(mode_name) — заработает при включении"; fi ;;
      4) if [ "$(cfg AUTOLIST 0)" = 1 ]; then cfg_set AUTOLIST 0; else cfg_set AUTOLIST 1; fi
         if [ -f "$PL_TPWS" ]; then tpws_apply "$(cfg MODE transparent)" && ok "tpws перезапущен"; fi ;;
      *) return 0 ;;
    esac
  done
}

cmd_dns() {
  local svc cur
  if [ -f "$DNS_BACKUP" ]; then
    while IFS=$'\t' read -r svc cur; do
      [ -n "$svc" ] || continue
      if [ -z "$cur" ]; then networksetup -setdnsservers "$svc" Empty
      else set -f; networksetup -setdnsservers "$svc" $cur; set +f; fi
    done < "$DNS_BACKUP"
    rm -f "$DNS_BACKUP"
    ok "DNS возвращён как был."
  else
    mkdir -p "$DIR"; : > "$DNS_BACKUP"
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      cur=$(networksetup -getdnsservers "$svc" 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' | tr '\n' ' ')
      printf '%s\t%s\n' "$svc" "${cur% }" >> "$DNS_BACKUP"
      networksetup -setdnsservers "$svc" 8.8.8.8 1.1.1.1 8.8.4.4 1.0.0.1
    done <<< "$(hw_services)"
    ok "DNS переключён на Google и Cloudflare (повторный выбор пункта — вернуть как было)."
  fi
}

cmd_update() {
  local tag sum
  ensure_installed
  say "Проверяю последнюю версию zapret…"
  tag=$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/bol-van/zapret/releases/latest 2>/dev/null |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  if [ -z "$tag" ]; then
    warn "GitHub не ответил — tpws не обновлён."
  elif [ "$tag" = "$(cat "$DIR/zapret-version" 2>/dev/null)" ] && [ -x "$TPWS" ]; then
    ok "tpws последней версии ($tag)"
  else
    sum=$(curl -fsSL --connect-timeout 10 "https://github.com/bol-van/zapret/releases/download/$tag/sha256sum.txt" 2>/dev/null |
          awk -v f="zapret-$tag/binaries/mac64/tpws" '$2==f {print $1}')
    if [ -n "$sum" ]; then install_tpws "$tag" "$sum"; else warn "Не нашёл контрольную сумму для $tag — tpws не обновлён."; fi
  fi
  say "Обновляю списки доменов Flowseal…"
  if fetch_list list-google.txt "$LISTS/list-youtube.txt" "$HDR_YT" &&
     fetch_list list-general.txt "$LISTS/list-general.txt" "$HDR_GEN" &&
     fetch_list list-exclude.txt "$LISTS/list-exclude.txt" "$HDR_EX"; then
    ok "Списки обновлены"
  else
    warn "Списки не скачались целиком — оставил прежние"
  fi
  [ -f "$PL_TPWS" ] && cmd_start
  return 0
}

cmd_uninstall() {
  local a
  printf 'Удалить zapret-mac полностью? [y/N] '
  read -r a
  case $a in y|Y|д|Д|yes|да) ;; *) return ;; esac
  cmd_stop
  [ -f "$DNS_BACKUP" ] && cmd_dns
  pf_conf_unpatch
  migrate_v1 >/dev/null 2>&1
  rm -rf "$DIR"
  rm -f "$PL_TPWS" "$PL_WD"
  if [ -n "$RHOME" ] && [ -f "$(ds_agent)" ]; then
    launchctl bootout "gui/$(id -u "$RUSER")/$LBL_DS" >/dev/null 2>&1
    rm -f "$(ds_agent)"
  fi
  [ -n "$SHORTCUT" ] && grep -qF "$SELF" "$SHORTCUT" 2>/dev/null && rm -f "$SHORTCUT"
  ok "zapret-mac удалён. Сеть вернулась к обычным настройкам."
}

# ─── сторож (LaunchDaemon от root) ───────────────────────────────────
# Ловит события маршрутизации (route monitor), поэтому VPN замечает сразу:
#   VPN (TUN) включился  → снимает перенаправление, весь трафик идёт в VPN
#   VPN выключился       → возвращает перенаправление, работает обход
#   tpws упал            → снимает перенаправление, чтобы не пропал интернет
# Плюс раз в CHECK_EVERY секунд (и после смены сети) проверяет YouTube и Discord
# и при сбое сам подбирает стратегии в фоне.
WD_STATE=""; WD_VPN=""; WD_NET=""; FAILS=0; NEXT_CHECK=0; BACKOFF=$CHECK_EVERY
SEL_PID=""; LAST_FULL=0; FAIL_NOTIFIED=0; CUT_NOTIFIED=0

wd_status() { printf '%s %s\n' "$1" "$2" > "$RUN/status.new" && chmod 644 "$RUN/status.new" && mv -f "$RUN/status.new" "$RUN/status"; }

# действующие настройки прокси одним быстрым вызовом (networksetup по всем службам — долго для каждых 5 секунд)
sys_proxy_ours() {
  scutil --proxy 2>/dev/null | awk -v p="$SOCKS_PORT" '
    /SOCKSEnable : 1/ {e=1} /SOCKSProxy : 127\.0\.0\.1$/ {h=1} $0 ~ "SOCKSPort : " p "$" {o=1}
    END {exit !(e && h && o)}'
}
sys_proxy_other() {
  scutil --proxy 2>/dev/null | grep -qE 'HTTPEnable : 1|HTTPSEnable : 1|ProxyAutoConfigEnable : 1' && return 0
  scutil --proxy 2>/dev/null | grep -q 'SOCKSEnable : 1' && ! sys_proxy_ours
}

notify() {
  local uid
  uid=$(stat -f %u /dev/console 2>/dev/null)
  [ -n "$uid" ] && [ "$uid" -gt 0 ] || return 0
  launchctl asuser "$uid" sudo -u "#$uid" /usr/bin/osascript \
    -e "display notification \"$1\" with title \"zapret-mac\"" >/dev/null 2>&1 &
}

reconcile() {   # $1 = full — проверить pf и tpws; без него — только не сменился ли VPN
  local vpn mode st net
  vpn=$(vpn_iface)
  [ "$1" = full ] || [ "$vpn" != "$WD_VPN" ] || return 0
  mode=$(cfg MODE transparent)
  if [ -n "$vpn" ]; then
    st=vpn
    if [ "$vpn" != "$WD_VPN" ]; then log "VPN включён ($vpn) — весь трафик идёт через VPN"; sel_stop; fi
    if [ "$mode" = transparent ] && fw_loaded; then
      fw_off
      # соединения, завёрнутые в tpws до включения VPN, сбрасываем — программы переподключатся уже через VPN
      launchctl kickstart -k "system/$LBL_TPWS" >/dev/null 2>&1
    fi
  elif ! tpws_up "$mode"; then
    st=down
    if [ "$mode" = transparent ]; then
      fw_loaded && { fw_off; log "tpws не отвечает — перенаправление снято, чтобы не пропал интернет"; }
    else
      sys_proxy_ours && { proxy_off; log "tpws не отвечает — системный прокси снят"; }
    fi
  else
    st=direct
    [ -n "$WD_VPN" ] && log "VPN выключен — работает обход"
    if [ "$mode" = transparent ]; then
      if ! fw_loaded || ! pf_on; then
        if fw_on >/dev/null 2>&1; then log "Перенаправление pf включено"; else log "Не удалось включить перенаправление pf"; fi
      fi
    elif ! sys_proxy_ours && ! sys_proxy_other; then
      # VPN-клиент в режиме прокси, выключаясь, сбрасывает и наш прокси — возвращаем
      proxy_on >/dev/null 2>&1 && log "Системный SOCKS-прокси восстановлен"
    fi
    net=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default" {print $2, $4; exit}')
    if [ "$WD_STATE" != direct ] || [ "$net" != "$WD_NET" ]; then
      [ "$WD_STATE" = direct ] && log "Сеть сменилась ($net) — скоро проверю YouTube и Discord"
      NEXT_CHECK=$(( SECONDS + 8 )); FAILS=0; BACKOFF=$CHECK_EVERY
    fi
    WD_NET=$net
  fi
  { [ "$st" != "$WD_STATE" ] || [ "$vpn" != "$WD_VPN" ]; } && wd_status "$st" "$vpn"
  WD_STATE=$st; WD_VPN=$vpn
}

sel_start() {
  log "YouTube или Discord не открываются — подбираю стратегии (ход подбора: $LOGS/select.log)"
  rm -f "$RUN/select.result"
  (
    trap 'stop_test; exit 1' TERM
    select_strategies auto > "$LOGS/select.log" 2>&1 &&
      printf '%s %s %s %s %s\n' "$SEL_PATH" "$SEL_Y" "$SEL_D" "$SEL_SY" "$SEL_SD" > "$RUN/select.result"
  ) &
  SEL_PID=$!
}

sel_stop() {
  [ -n "$SEL_PID" ] || return 0
  kill "$SEL_PID" 2>/dev/null; wait "$SEL_PID" 2>/dev/null
  SEL_PID=""
  log "Подбор прерван"
}

sel_poll() {
  local r p y d sy sd cur_y cur_d
  [ -n "$SEL_PID" ] || return 0
  kill -0 "$SEL_PID" 2>/dev/null && return 0
  wait "$SEL_PID" 2>/dev/null; SEL_PID=""
  r=$(cat "$RUN/select.result" 2>/dev/null); rm -f "$RUN/select.result"
  if [ -z "$r" ]; then log "Подбор не удался — подробности в $LOGS/select.log"; return 0; fi
  set -f; set -- $r; set +f
  p=$1; y=$2; d=$3; sy=$4; sd=$5
  cur_y=$(strat_of Y); cur_d=$(strat_of D)
  # стратегия, с которой не открылось ничего, ничем не лучше текущей
  [ "$sy" -gt 0 ] || y=$cur_y
  [ "$sd" -gt 0 ] || d=$cur_d
  if [ "$p" = 1 ]; then
    log "Стратегии рабочие — перезапускаю tpws и перенаправление"
    fw_off
    launchctl kickstart -k "system/$LBL_TPWS" >/dev/null 2>&1
    wait_bound "$(main_port)" 50
    if [ "$(cfg MODE transparent)" = transparent ]; then
      fw_try >/dev/null 2>&1
      if [ $? -eq 1 ]; then
        log "Перенаправление pf перестало работать — переключаюсь на SOCKS-прокси"
        tp_fallback
        notify "Прозрачный режим перестал работать — включил SOCKS-прокси"
      fi
    fi
    NEXT_CHECK=$(( SECONDS + 60 ))
    return 0
  fi
  if [ "$y" != "$cur_y" ] || [ "$d" != "$cur_d" ]; then
    cfg_set S_Y "$y"; cfg_set S_D "$d"
    if tpws_apply "$(cfg MODE transparent)" >/dev/null 2>&1; then
      log "Новые стратегии: YouTube — $y ($(strat_name "$y")) $sy/$NY, Discord — $d ($(strat_name "$d")) $sd/$ND"
      notify "Обход перенастроен: YouTube — $(strat_name "$y"), Discord — $(strat_name "$d")"
    else
      log "tpws не запустился с новыми стратегиями"
    fi
  fi
  if [ "$sy" -lt "$NY" ] || [ "$sd" -lt "$ND" ]; then
    log "Полностью рабочих стратегий нет: YouTube $sy/$NY, Discord $sd/$ND"
    if [ "$FAIL_NOTIFIED" != 1 ]; then
      notify "YouTube или Discord не открываются даже через обход — включи VPN"
      FAIL_NOTIFIED=1
    fi
    NEXT_CHECK=$(( SECONDS + BACKOFF ))
    BACKOFF=$(( BACKOFF * 2 )); [ "$BACKOFF" -gt 14400 ] && BACKOFF=14400
  else
    NEXT_CHECK=$(( SECONDS + 60 ))   # убедиться, что помогло
  fi
}

health_tick() {
  local rc
  sel_poll
  [ -z "$SEL_PID" ] || return 0
  [ "$WD_STATE" = direct ] || return 0
  [ "$SECONDS" -ge "$NEXT_CHECK" ] || return 0
  # прозрачный режим, включённый при VPN, ещё ни разу не проверялся на этом Mac — проверяем первым делом
  if [ "$(cfg MODE transparent)" = transparent ] && [ "$(cfg TP_OK 0)" != 1 ]; then
    fw_try >/dev/null 2>&1; rc=$?
    case $rc in
      0) cfg_set TP_OK 1; log "Прозрачный режим проверен — работает" ;;
      1) log "Прозрачный режим на этом Mac не работает — переключаюсь на SOCKS-прокси"
         tp_fallback
         notify "Прозрачный режим не заработал — включил SOCKS-прокси"
         return 0 ;;
      *) NEXT_CHECK=$(( SECONDS + 60 )); return 0 ;;
    esac
  fi
  [ "$(cfg AUTOFIX 1)" = 1 ] || return 0
  NEXT_CHECK=$(( SECONDS + CHECK_EVERY ))
  detect_phys || return 0
  # интернета нет вообще — это не блокировка, подбирать нечего
  /usr/bin/curl -s -o /dev/null --noproxy '*' --interface "$PHYS" --connect-timeout 5 --max-time 8 "$CONTROL_URL" || return 0
  if [ "$(cfg MODE transparent)" = socks ]; then run_checks "socks:$SOCKS_PORT"; else run_checks apps; fi
  # обрыв на 16 КБ стратегией не лечится — сообщаем один раз и подбор из-за него не запускаем
  if [ -n "$LAST_CUT" ]; then
    if [ "$CUT_NOTIFIED" != 1 ]; then
      log "Обрыв после 16 КБ: $LAST_CUT — провайдер режет Cloudflare без видимого имени сайта, нужен VPN"
      notify "Discord на этом провайдере режется после 16 КБ — для Discord включи VPN"
      CUT_NOTIFIED=1
    fi
  else
    CUT_NOTIFIED=0
  fi
  if [ "$SCORE_Y" -eq "$NY" ] && [ "$SCORE_D" -eq "$ND" ]; then
    { [ "$FAILS" -gt 0 ] || [ "$FAIL_NOTIFIED" = 1 ]; } && log "Проверка: YouTube и Discord снова открываются"
    FAILS=0; FAIL_NOTIFIED=0; BACKOFF=$CHECK_EVERY
    return 0
  fi
  FAILS=$(( FAILS + 1 ))
  log "Проверка: не открылось — $LAST_FAIL"
  if [ "$FAILS" -lt 2 ]; then NEXT_CHECK=$(( SECONDS + 45 )); return 0; fi   # перепроверить, вдруг случайность
  FAILS=0
  sel_start
}

log_rotate() {
  local f
  for f in "$LOGS/watchdog.log" "$LOGS/watchdog.err" "$LOGS/tpws.log"; do
    [ -f "$f" ] && [ "$(stat -f %z "$f" 2>/dev/null || echo 0)" -gt 524288 ] || continue
    tail -n 2000 "$f" > "$f.tmp" && cat "$f.tmp" > "$f"; rm -f "$f.tmp"
  done
}

daemon_main() {
  local line t0 ev
  [ "$(id -u)" -eq 0 ] || die "Сторож запускается только из launchd."
  mkdir -p "$LOGS" "$RUN"
  CHECK_LIGHT=1
  log "Сторож запущен (zapret-mac $ZM_VERSION, режим: $(mode_name))"
  pf_give "$RUN/pf-token"   # токен от прошлого запуска — новый возьмём ниже
  # остатки подбора, прерванного вместе с терминалом
  pfctl -q -a "$(anchor_test)" -F all >/dev/null 2>&1; pf_give "$RUN/pf-token-test"
  trap 'sel_stop; log "Сторож остановлен"; exit 0' TERM INT
  reconcile full; LAST_FULL=$SECONDS
  exec 3< <(exec route -n monitor 2>/dev/null)
  while true; do
    ev=0; t0=$SECONDS
    if read -r -t 5 line <&3; then
      case $line in RTM_ADD*|RTM_DELETE*|RTM_CHANGE*|RTM_IFINFO*|RTM_NEWADDR*|RTM_DELADDR*) ev=1 ;; esac
    elif [ $(( SECONDS - t0 )) -lt 2 ]; then
      # монитор маршрутов закрылся — открываем заново
      sleep 3
      exec 3<&-
      exec 3< <(exec route -n monitor 2>/dev/null)
    fi
    [ "$ev" = 1 ] && reconcile
    if [ $(( SECONDS - LAST_FULL )) -ge 5 ]; then
      reconcile full; LAST_FULL=$SECONDS
      health_tick
      log_rotate
    fi
  done
}

# ─── меню (от имени пользователя) ────────────────────────────────────
as_root() {
  sudo -n true 2>/dev/null || say "${D}Нужен пароль от Mac (при вводе символы не видны).${N}"
  sudo /bin/bash "$SELF" "$@"
}

# первый запуск или новая версия скрипта: ставим копию в /opt/zapret-mac
user_bootstrap() {
  local me
  me=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")
  [ "$me" = "$SELF" ] && return 0
  [ -f "$me" ] || die "Запусти скрипт из файла: bash zapret-mac.sh"
  [ -f "$SELF" ] && cmp -s "$me" "$SELF" && return 0
  say "Устанавливаю zapret-mac $ZM_VERSION в $DIR…"
  sudo -n true 2>/dev/null || say "${D}Нужен пароль от Mac (при вводе символы не видны).${N}"
  sudo /bin/bash "$me" install || die "Установка не удалась."
}

menu_status() {
  local st="" v="" names
  [ -f "$PL_TPWS" ] || { printf '%sвыключен%s' "$D" "$N"; return; }
  [ -f "$RUN/status" ] && read -r st v < "$RUN/status"
  names="YouTube — $(strat_name "$(strat_of Y)"), Discord — $(strat_name "$(strat_of D)")"
  if ! pgrep -f "$SELF daemon" >/dev/null 2>&1; then
    printf '%sвключён, но сторож не работает%s — выбери 2' "$R" "$N"
    return
  fi
  case $st in
    direct) printf '%sВКЛЮЧЁН%s · %s · режим: %s' "$G" "$N" "$names" "$(mode_name)" ;;
    vpn)    printf '%sнаготове%s · сейчас работает VPN (%s), обход включится сам, когда его выключишь' "$G" "$N" "$v" ;;
    down)   printf '%stpws не отвечает%s — выбери 2' "$R" "$N" ;;
    *)      printf 'запускается…' ;;
  esac
}

menu() {
  local c
  while true; do
    clear 2>/dev/null
    say "${B}zapret для macOS${N} — обход блокировок YouTube и Discord  ${D}v$ZM_VERSION${N}"
    say "Статус: $(menu_status)"
    say "────────────────────────────────────────────"
    say "  1  Подобрать стратегии и включить"
    say "  2  Включить (сохранённые стратегии)"
    say "  3  Выбрать стратегии вручную"
    say "  4  Выключить"
    say "  5  Проверить, что открывается"
    say "  6  Перезапустить Discord"
    say "  7  Добавить свой сайт в обход"
    say "  8  Автосписок сайтов"
    say "  9  Настройки: QUIC, автоподбор, режим"
    say " 10  DNS Google/Cloudflare: вкл/выкл"
    say " 11  Подробный статус и журнал"
    say " 12  Перебрать все стратегии (полный тест)"
    say " 13  Обновить tpws и списки"
    say " 14  Удалить всё"
    say " 15  Открывать Discord при входе: $(ds_autostart_state)"
    say "  0  Выход"
    printf '\nВыбор: '
    read -r c || exit 0
    case $c in
      1)  as_root auto; pause ;;
      2)  as_root start; pause ;;
      3)  as_root choose; pause ;;
      4)  as_root stop; pause ;;
      5)  as_root check; pause ;;
      6)  ( cmd_discord ); pause ;;
      7)  as_root add; pause ;;
      8)  as_root autolist; pause ;;
      9)  as_root settings ;;
      10) as_root dns; pause ;;
      11) as_root status; pause ;;
      12) as_root test all; pause ;;
      13) as_root update; pause ;;
      14) as_root uninstall; [ -d "$DIR" ] || exit 0; pause ;;
      15) ( cmd_ds_autostart ); pause ;;
      0|q|Q) exit 0 ;;
    esac
  done
}

usage() {
  say "Использование: bash $0 [auto|start|stop|restart|test [all]|check|status|discord|autostart|add|dns|update|uninstall]"
}

# для тестов: ZM_LIB=1 . zapret-mac.sh — подключить функции, ничего не запуская
[ "${ZM_LIB:-}" = 1 ] && { return 0 2>/dev/null || exit 0; }

if [ "$(id -u)" -eq 0 ]; then
  case "${1:-}" in
    ""|menu|discord|discord-auto|autostart) die "Меню и Discord запускай без sudo: bash $0 — пароль скрипт спросит сам." ;;
    install)   cmd_install ;;
    auto)      cmd_auto ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_stop; cmd_start ;;
    test)      cmd_test "${2:-}" ;;
    choose)    cmd_choose ;;
    check)     cmd_check ;;
    status)    cmd_status ;;
    add)       cmd_add ;;
    autolist)  cmd_autolist ;;
    settings)  cmd_settings ;;
    dns)       cmd_dns ;;
    update)    cmd_update ;;
    uninstall) cmd_uninstall ;;
    daemon)    daemon_main ;;
    *)         usage ;;
  esac
else
  case "${1:-}" in
    ""|menu)        user_bootstrap; menu ;;
    discord)        cmd_discord ;;
    discord-auto)   cmd_discord_auto ;;
    autostart)      cmd_ds_autostart ;;
    daemon)         die "Сторож запускается только из launchd." ;;
    help|-h|--help) usage ;;
    *)              user_bootstrap; as_root "$@" ;;
  esac
fi
