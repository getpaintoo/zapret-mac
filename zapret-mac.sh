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
#  Discord: второй движок — utunws из Flowseal/zapret-mac-discord-youtube
#  (nfqws, который получает пакеты через utun и отправляет через BPF).
#  pf уводит в него трафик к адресам Discord и голос по UDP. utunws шлёт
#  поддельный ClientHello с именем www.google.com, и провайдер пропускает
#  соединение с Discord, приняв его за соединение с Google.
#
#  VPN: пока VPN в режиме TUN включён, сторож снимает перенаправление и весь
#  трафик идёт через VPN. Выключили VPN — обход включается сам за доли
#  секунды. Сторож же периодически проверяет YouTube и Discord и, если они
#  перестали открываться, сам подбирает новые стратегии. Подобранные стратегии
#  он запоминает для каждой сети (по MAC шлюза) и ставит их сразу, когда
#  Mac снова в ней оказывается — в том числе после пробуждения.
#
#  Стратегии лежат в strategies.conf; раз в сутки сторож скачивает свежий
#  с GitHub. Приложение Zapret в строке меню (папка app/) — пульт к этому
#  скрипту: команды on, off, pause, resume и другие оно запускает через sudo
#  без пароля (правило /etc/sudoers.d/zapret-mac ставит gui-install).
#
#  Запуск:  bash zapret-mac.sh            — меню
#           bash zapret-mac.sh auto       — подобрать стратегии и включить
#           bash zapret-mac.sh start|stop|restart|status|check|test [all]|discord|update|uninstall
#
#  Если что-то пошло не так и пропал интернет:
#           sudo bash /opt/zapret-mac/zapret-mac.sh stop
#  или вручную: sudo pfctl -a com.apple/zapret-mac -F all
#           (если якорь в /etc/pf.conf — sudo pfctl -a zapret-mac/zapret-mac -F all)
# ════════════════════════════════════════════════════════════════════

ZM_VERSION="3.0"
ZAPRET_TAG="v72.13"
TPWS_SHA256="441524a76f52597a0e5c816d25ed1adfd93e5c34cc56c56e0dc00533929d1761"
# utunws и поддельные пакеты для него — из релиза Flowseal/zapret-mac-discord-youtube
UTUNWS_TAG="1.1.2"
UTUNWS_URL="https://github.com/Flowseal/zapret-mac-discord-youtube/releases/download/$UTUNWS_TAG/ZapretMac-macOS-universal.zip"
UTUNWS_SHA256="d8ecffeb91df7e5d76c3d926037d44959f29079add2fd12a16574f5ad2beb4a8"
FAKE_TLS_SHA256="936c2bee4cfb80aa3c426b2dcbcc834b3fbcd1adb17172959dc569c73a14275c"   # tls_clienthello_www_google_com.bin
FAKE_DS_SHA256="2fe18b3bd20807d36704d0b072092ee49ae84edca907a4420ab9a0f0f28fddcf"    # ACTIVE_DISCORD_UDP.bin
FAKE_4PDA_SHA256="eefeaf09dde8d69b1f176212541f63c68b314a33a335eced99a8a29f17254da8"  # tls_clienthello_4pda_to.bin
FAKE_MAX_SHA256="4ee0870abe0a0128600b0095189987ba1d210dae8bf963bc725aff49cf922624"   # tls_clienthello_max_ru.bin
FAKE_STUN_SHA256="9cd5469309780ca56c0bd97266524a48c7ee529d02c3179cfecb20b260a59641"  # stun.bin
FAKE_STUN2_SHA256="b7c2497496039c541f7337ac8536813f0a1cf52363ab2faa5213b7816d458813" # stun2.bin
# поддельные пакеты, которые ставятся рядом с utunws, и их контрольные суммы
UT_FAKES="tls_clienthello_www_google_com.bin:$FAKE_TLS_SHA256 ACTIVE_DISCORD_UDP.bin:$FAKE_DS_SHA256
tls_clienthello_4pda_to.bin:$FAKE_4PDA_SHA256 tls_clienthello_max_ru.bin:$FAKE_MAX_SHA256
stun.bin:$FAKE_STUN_SHA256 stun2.bin:$FAKE_STUN2_SHA256"

# всё лежит в папке root: её запускают системные демоны, править её может только админ
DIR="/opt/zapret-mac"
BIN_DIR="$DIR/bin"
TPWS="${ZM_TPWS:-$BIN_DIR/tpws}"   # ZM_TPWS — другой tpws, для тестов
UTUNWS="${ZM_UTUNWS:-$BIN_DIR/utunws}"   # ZM_UTUNWS — другой utunws, поддельные пакеты лежат рядом с ним
LISTS="$DIR/lists"
LOGS="$DIR/log"
RUN="$DIR/run"
CONF="$DIR/config"
SELF="$DIR/zapret-mac.sh"
DNS_BACKUP="$DIR/dns-backup"
STRAT_FILE="${ZM_STRAT:-$DIR/strategies.conf}"   # ZM_STRAT — другой файл стратегий, для тестов
STRAT_URL="https://raw.githubusercontent.com/getpaintoo/zapret-mac/main/strategies.conf"
NETS="$DIR/networks"   # стратегии, которые сработали в каждой сети
PAUSE_F="$RUN/pause"   # пауза до этого времени (секунды с 1970), 0 — пока не снимут
SUDOERS="/etc/sudoers.d/zapret-mac"
APP_PROC="Zapret"      # процесс приложения в строке меню: если оно открыто, уведомления показывает оно
UPDATE_EVERY=86400     # как часто сторож скачивает свежие стратегии и списки, секунд
TP_PORT=988          # tpws в прозрачном режиме (сюда pf заворачивает трафик)
SOCKS_PORT=1080      # tpws в режиме SOCKS-прокси
TEST_PORT=1090       # временный tpws для подбора стратегий
LBL_TPWS="com.zapret-mac.tpws"
LBL_WD="com.zapret-mac.watchdog"
LBL_DS="com.zapret-mac.discord"   # LaunchAgent автозапуска Discord, лежит у пользователя
LBL_UT="com.zapret-mac.utunws"
PL_TPWS="/Library/LaunchDaemons/$LBL_TPWS.plist"
PL_WD="/Library/LaunchDaemons/$LBL_WD.plist"
PL_UT="/Library/LaunchDaemons/$LBL_UT.plist"
UT_UNIT=51           # utunws открывает utun с этим номером, интерфейс получается utun50
UT_IF=utun50
UT_LOCAL=10.77.0.1   # адреса точка-точка на utun50: pf шлёт туда пакеты через route-to
UT_PEER=10.77.0.2
UT_TEST_UNIT=52      # временный utunws для подбора — utun51, чтобы не трогать рабочий
UT_TEST_IF=utun51
UT_TEST_LOCAL=10.77.1.1
UT_TEST_PEER=10.77.1.2
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
#   MODE=transparent|socks  S_Y, S_D — стратегии tpws (названия) для YouTube и для
#   Discord со своими сайтами   QUIC=1 — глушить QUIC к Google
#   AUTOFIX=1 — сторож сам подбирает стратегии   USER_SITES=1 — пускать в обход свои сайты
#   PF_ROOT=com.apple|zapret-mac — куда подключаются наши правила pf
#   UTUNWS=1 — Discord через utunws; 0 — через tpws, как в 2.1
#   UT_D — стратегия utunws для Discord   YT=tpws|utunws — чем обходить YouTube
#   До 3.0 S_Y, S_D и UT_D хранили номера стратегий — cfg_migrate переводит их в названия
cfg() { local v; v=$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1); printf '%s' "${v:-$2}"; }
cfg_set() {
  touch "$CONF" && chmod 644 "$CONF" || return 1
  if grep -q "^$1=" "$CONF"; then sed -i '' "s|^$1=.*|$1=$2|" "$CONF"
  else printf '%s=%s\n' "$1" "$2" >> "$CONF"; fi
}
mode_name() { [ "$(cfg MODE transparent)" = socks ] && printf 'SOCKS-прокси' || printf 'прозрачный'; }

# ─── стратегии tpws ──────────────────────────────────────────────────
# Встроенные стратегии — на случай, если strategies.conf нет или он битый; в репозитории
# они те же, что в strategies.conf. @HL подставляется как набор --hostlist (обход только
# для доменов из списков). На macOS --oob и --disorder для одного протокола вместе нельзя —
# tpws не запустится (работает только в Linux), поэтому OOB-стратегии здесь без disorder.
STRAT_VER=2026102401
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

strat_name() { local s=${STRATEGIES[$(( $1 - 1 ))]}; printf '%s' "${s%%|*}"; }
# $1 = Y (YouTube) | D (Discord, свои сайты и остальное из списков)
strat_of() { strat_idx "$(cfg "S_$1" general)" tpws; }

# набор листов для профиля tpws; результат — массив HL
hl_set() {
  local -a ex=("--hostlist-exclude=$LISTS/list-exclude.txt" "--hostlist-exclude=$LISTS/list-exclude-mac.txt"
               "--hostlist-exclude=$LISTS/list-exclude-user.txt")
  local -a us=()
  [ "$(cfg USER_SITES 1)" = 1 ] && us=("--hostlist=$LISTS/list-user.txt")
  case $1 in
    youtube) HL=("--hostlist=$LISTS/list-youtube.txt" "${ex[@]}") ;;
    general) HL=("--hostlist=$LISTS/list-general.txt" "${us[@]}" "${ex[@]}") ;;
    all)     HL=("--hostlist=$LISTS/list-youtube.txt" "--hostlist=$LISTS/list-general.txt" "${us[@]}" "${ex[@]}") ;;
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
  [ "$(cfg DEBUG 0)" = 1 ] && ARGS+=(--debug=1)   # подробный журнал каждого соединения — в tpws.log
  hl_set youtube; add_strategy "$(strat_of Y)"
  ARGS+=(--new); hl_set general; add_strategy "$(strat_of D)"
  # автосписок выключен по умолчанию: tpws путает с блокировкой обычные обрывы (ocsp.apple.com
  # и т.п.) и начинает трогать сайты, которые и так работали
  if [ "$(cfg AUTOLIST 0)" = 1 ]; then
    ARGS+=(--new); hl_set auto; add_auto_strategy "$(strat_of D)"
  fi
}

# ─── стратегии utunws (из Flowseal) ─────────────────────────────────
# Провайдеры по-разному относятся к поддельным пакетам: домашний пропускает Discord
# с простым fake, а мобильный МегаФон fake игнорирует и пропускает только seqovl.
# Поэтому стратегию для Discord подбирает подбор, как и для tpws. @F — папка
# с поддельными пакетами (рядом с utunws).
UT_STRAT_D=(
"SEQOVL|--dpi-desync=multisplit --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern=@F/tls_clienthello_4pda_to.bin"
"FAKE|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fake-tls=@F/tls_clienthello_www_google_com.bin"
"FAKESEQOVL|--dpi-desync=fake,multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=10000000 --dpi-desync-repeats=8 --dpi-desync-split-seqovl-pattern=@F/tls_clienthello_www_google_com.bin --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"
# дальше — остальные варианты Flowseal для Discord (zapret-mac-discord-youtube 1.1.2):
# поддельные STUN и ClientHello с max.ru, hostfakesplit, badseq. Подбор идёт по порядку
"ALT|--dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls=@F/stun.bin --dpi-desync-fake-tls=@F/tls_clienthello_www_google_com.bin"
"ALT2|--dpi-desync=multisplit --dpi-desync-split-seqovl=652 --dpi-desync-split-pos=2 --dpi-desync-split-seqovl-pattern=@F/tls_clienthello_www_google_com.bin"
"ALT3|--dpi-desync=fake,hostfakesplit --dpi-desync-fake-tls-mod=rnd,dupsid,sni=ya.ru --dpi-desync-hostfakesplit-mod=host=ya.ru,altorder=1 --dpi-desync-fooling=ts"
"ALT4|--dpi-desync=fake,multisplit --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=1000 --dpi-desync-fake-tls=@F/stun.bin --dpi-desync-fake-tls=@F/tls_clienthello_www_google_com.bin"
"ALT6|--dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern=@F/tls_clienthello_www_google_com.bin"
"ALT7|--dpi-desync=multisplit --dpi-desync-split-pos=2,sniext+1 --dpi-desync-split-seqovl=679 --dpi-desync-split-seqovl-pattern=@F/tls_clienthello_www_google_com.bin"
"ALT8|--dpi-desync=fake --dpi-desync-fake-tls-mod=none --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=2"
"ALT9|--dpi-desync=hostfakesplit --dpi-desync-repeats=4 --dpi-desync-fooling=ts,md5sig --dpi-desync-hostfakesplit-mod=host=ozon.ru"
"ALT10|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fake-tls=@F/stun.bin --dpi-desync-fake-tls=@F/tls_clienthello_4pda_to.bin"
"ALT11|--dpi-desync=fake,multisplit --dpi-desync-split-seqovl=664 --dpi-desync-split-pos=1 --dpi-desync-fooling=ts --dpi-desync-repeats=8 --dpi-desync-split-seqovl-pattern=@F/tls_clienthello_max_ru.bin --dpi-desync-fake-tls=@F/stun2.bin --dpi-desync-fake-tls=@F/tls_clienthello_max_ru.bin"
"ALT12|--dpi-desync=fake,multisplit --dpi-desync-split-seqovl=664 --dpi-desync-split-pos=1 --dpi-desync-fooling=ts --dpi-desync-repeats=8 --dpi-desync-split-seqovl-pattern=@F/tls_clienthello_max_ru.bin --dpi-desync-fake-tls=@F/stun.bin --dpi-desync-fake-tls=@F/tls_clienthello_max_ru.bin"
"EXP|--dpi-desync=fake,multisplit --dpi-desync-split-seqovl=480 --dpi-desync-split-pos=1 --dpi-desync-fooling=ts --dpi-desync-repeats=4 --dpi-desync-split-seqovl-pattern=@F/stun2.bin --dpi-desync-fake-tls=@F/tls_clienthello_max_ru.bin"
"FAKEALT|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=2 --dpi-desync-fake-tls=@F/stun2.bin --dpi-desync-fake-tls=@F/tls_clienthello_www_google_com.bin"
"FAKEALT2|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fake-tls=@F/stun2.bin --dpi-desync-fake-tls=@F/tls_clienthello_max_ru.bin"
"AUTOALT|--dpi-desync=fake,fakedsplit --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=2 --dpi-desync-repeats=8 --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"
"AUTOALT3|--dpi-desync=fake,multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-fooling=ts --dpi-desync-repeats=8 --dpi-desync-split-seqovl-pattern=@F/tls_clienthello_www_google_com.bin --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"
)
# YouTube через utunws (YT=utunws) — на сетях, где tpws не справляется
UT_YT="--ip-id=zero --dpi-desync=hostfakesplit --dpi-desync-fooling=ts --dpi-desync-hostfakesplit-mod=host=www.google.com"
# по встроенному порядку cfg_migrate переводит номера стратегий из 2.x в названия
BUILTIN_TP=("${STRATEGIES[@]}"); BUILTIN_UT=("${UT_STRAT_D[@]}")

# ─── strategies.conf ─────────────────────────────────────────────────
# Строки «вид|название|параметры»: tpws — стратегия tpws, ut — utunws для Discord,
# utyt — utunws для YouTube; «version|ГГГГММДДNN» — версия файла. Файл приходит с GitHub,
# а параметры получает root, поэтому принимаем только знакомые опции, без путей к файлам
# (кроме поддельных пакетов @F/*.bin), и у tpws в каждом блоке должен быть @HL — иначе
# стратегия трогала бы все сайты подряд.
strat_tok_ok() {   # $1 = tpws|ut, $2 = токен
  local o=${2%%=*} v=""
  case $2 in *=*) v=${2#*=} ;; esac
  case $1:$2 in tpws:@HL|tpws:--new) return 0 ;; esac
  case $v in *[!A-Za-z0-9._,:+=@/-]*) return 1 ;; esac
  case $1:$v in
    tpws:*/*) return 1 ;;
    ut:*/*) case $v in @F/tls_clienthello_www_google_com.bin|@F/tls_clienthello_4pda_to.bin|@F/ACTIVE_DISCORD_UDP.bin|\
                       @F/tls_clienthello_max_ru.bin|@F/stun.bin|@F/stun2.bin) ;; *) return 1 ;; esac ;;
  esac
  case $1:$o in
    tpws:--filter-l7|tpws:--split-pos|tpws:--disorder|tpws:--oob|tpws:--oob-data|tpws:--tlsrec|tpws:--hostcase|\
    tpws:--hostdot|tpws:--hosttab|tpws:--hostnospace|tpws:--hostpad|tpws:--domcase|tpws:--methodspace|\
    tpws:--methodeol|tpws:--unixeol|tpws:--mss|tpws:--tamper-start|tpws:--tamper-cutoff|tpws:--split-any-protocol|\
    tpws:--fix-seg) return 0 ;;
    ut:--dpi-desync|ut:--dpi-desync-*|ut:--ip-id|ut:--dup|ut:--dup-*|ut:--orig-*|ut:--wssize|ut:--wssize-cutoff|\
    ut:--hostcase|ut:--hostnospace|ut:--domcase|ut:--methodeol) return 0 ;;
  esac
  return 1
}

strat_line_ok() {   # $1 = tpws|ut|utyt, $2 = параметры
  local tok k=$1 hl=0 n=0
  [ "$k" = utyt ] && k=ut
  set -f
  for tok in $2; do
    n=$(( n + 1 ))
    strat_tok_ok "$k" "$tok" || { set +f; return 1; }
    case $tok in
      @HL) hl=1 ;;
      --new) [ "$hl" = 1 ] || { set +f; return 1; }; hl=0 ;;
    esac
  done
  set +f
  [ "$n" -gt 0 ] && { [ "$k" = ut ] || [ "$hl" = 1 ]; }
}

# читает файл стратегий $1 в NEW_TP, NEW_UT, NEW_YT, NEW_VER; 1 — файла нет или он битый
strat_parse() {
  local kind name params line ver=""
  NEW_TP=(); NEW_UT=(); NEW_YT=""; NEW_VER=0
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in ''|'#'*) continue ;; esac
    case $line in *'|'*) ;; *) return 1 ;; esac
    kind=${line%%|*}; line=${line#*|}
    name=${line%%|*}; params=${line#*|}
    if [ "$kind" = version ]; then
      case $name in ''|*[!0-9]*) return 1 ;; esac
      ver=$name; continue
    fi
    case $name in ''|*[!A-Za-z0-9_.+-]*) return 1 ;; esac
    [ "${#name}" -le 20 ] && [ "$name" != "$params" ] || return 1
    strat_line_ok "$kind" "$params" || return 1
    case $kind in
      tpws) NEW_TP+=("$name|$params") ;;
      ut)   NEW_UT+=("$name|$params") ;;
      utyt) NEW_YT=$params ;;
      *)    return 1 ;;
    esac
  done < "$1"
  [ -n "$ver" ] && [ "${#NEW_TP[@]}" -ge 1 ] && [ "${#NEW_UT[@]}" -ge 1 ] && [ -n "$NEW_YT" ] || return 1
  NEW_VER=$ver
}

# стратегии из strategies.conf, если он цел; иначе остаются встроенные
strat_reload() {
  if strat_parse "$STRAT_FILE"; then
    STRATEGIES=("${NEW_TP[@]}"); UT_STRAT_D=("${NEW_UT[@]}"); UT_YT=$NEW_YT; STRAT_VER=$NEW_VER
  fi
  NSTRAT=${#STRATEGIES[@]}; NUT=${#UT_STRAT_D[@]}
}
strat_reload

# номер стратегии по названию из настроек; номер (как хранила 2.x) принимается как есть.
# Такой стратегии нет — 1 и код возврата 1
strat_idx() {   # $1 = название или номер, $2 = tpws|ut
  local i n=$NSTRAT s
  [ "$2" = ut ] && n=$NUT
  case $1 in
    ''|*[!0-9]*) ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le "$n" ] && { printf '%s' "$1"; return 0; } ;;
  esac
  for (( i=1; i<=n; i++ )); do
    if [ "$2" = ut ]; then s=${UT_STRAT_D[$(( i - 1 ))]}; else s=${STRATEGIES[$(( i - 1 ))]}; fi
    [ "${s%%|*}" = "$1" ] && { printf '%s' "$i"; return 0; }
  done
  printf 1
  return 1
}

# 2.x хранила номера стратегий — переводим в названия по встроенному порядку
cfg_migrate() {
  local k v s
  for k in S_Y S_D UT_D; do
    v=$(cfg "$k")
    case $v in ''|*[!0-9]*) continue ;; esac
    [ "$v" -ge 1 ] || continue
    if [ "$k" = UT_D ]; then s=${BUILTIN_UT[$(( v - 1 ))]}; else s=${BUILTIN_TP[$(( v - 1 ))]}; fi
    [ -n "$s" ] && cfg_set "$k" "${s%%|*}"
  done
}

ut_strat_name() { local s=${UT_STRAT_D[$(( $1 - 1 ))]}; printf '%s' "${s%%|*}"; }
ut_of() { strat_idx "$(cfg UT_D SEQOVL)" ut; }   # стратегия utunws для Discord из настроек
yt_engine() { if [ "$(cfg YT tpws)" = utunws ]; then printf utunws; else printf tpws; fi; }

# дописывает в UT_ARGS строку параметров $1, подставляя папку с поддельными пакетами
add_ut_tokens() {
  local tok
  set -f
  for tok in $1; do UT_ARGS+=("${tok//@F/${UTUNWS%/*}}"); done
  set +f
}

# параметры utunws: $1 — стратегия для Discord, $2 = 1 — ещё и YouTube. Результат — UT_ARGS.
# Каждый профиль привязан к адресам (--ipset-ip): pf отдаёт utunws только Discord, голос
# и, если YT=utunws, Google. Пропускать что-то без обработки нельзя: macOS отдаёт пакеты
# в utun не по порядку, utunws так их и отправляет, и провайдер, не прочитав имя сайта,
# может оборвать соединение.
build_ut_args() {
  local d=${UTUNWS%/*} s
  s=${UT_STRAT_D[$(( $1 - 1 ))]}
  UT_ARGS=("--filter-tcp=443,2053,2083,2087,2096,8443" "--ipset-ip=${DS4//, /,}")
  add_ut_tokens "${s#*|}"
  if [ "$2" = 1 ]; then
    UT_ARGS+=(--new --filter-tcp=443 "--ipset-ip=${GOOGLE4//, /,}")
    add_ut_tokens "$UT_YT"
  fi
  UT_ARGS+=(--new "--filter-udp=19294-19344,50000-50100" "--filter-l7=discord,stun"
            --dpi-desync=fake --dpi-desync-repeats=6
            "--dpi-desync-fake-discord=$d/ACTIVE_DISCORD_UDP.bin" "--dpi-desync-fake-stun=$d/ACTIVE_DISCORD_UDP.bin"
            --user=nobody)
  [ "$(cfg DEBUG 0)" = 1 ] && UT_ARGS+=(--debug=1)   # в utunws.log
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
# группа|название|адрес. Y — YouTube, D — Discord, U — свои сайты (первые USER_MAX из
# list-user.txt, их добавляет user_targets). Сторож подбирает стратегии, только когда
# не открываются YouTube или Discord: свой сайт может быть закрыт по адресу, и тогда
# обход ему не поможет. Для своих сайтов подбор — отдельная команда sites-select.
USER_MAX=5
TARGETS_BASE=(
"D|Discord|https://discord.com/"
"D|Discord: шлюз|https://gateway.discord.gg/"
"D|Discord: CDN|https://cdn.discordapp.com/"
"D|Discord: проверка обновлений|https://updates.discord.com/distributions/app/manifests/latest?channel=stable&platform=osx&arch=arm64"
"D|Discord: скачивание обновлений|https://stable.dl2.discordapp.net/"
"Y|YouTube|https://www.youtube.com/"
"Y|YouTube: картинки|https://i.ytimg.com/"
"Y|YouTube: видео|https://redirector.googlevideo.com/report_mapping?di=no"
)
TARGETS=("${TARGETS_BASE[@]}")
NT=${#TARGETS[@]}
NU=0
CHECK_LIGHT=0   # 1 — главную YouTube качать сжатой (сторож бережёт трафик)
CHECK_ONLY=""   # буквы групп (Y, D, U), которые проверять; пусто — все

t_label() { local l=${1#*|}; printf '%s' "${l%|*}"; }
t_want() { [ -z "$CHECK_ONLY" ] && return 0; case $CHECK_ONLY in *"${1%%|*}"*) return 0 ;; esac; return 1; }

# свои сайты, если они включены, — в конец TARGETS; результат — TARGETS, NT, NU
user_targets() {
  local d
  TARGETS=("${TARGETS_BASE[@]}"); NU=0
  if [ "$(cfg USER_SITES 1)" = 1 ] && [ -f "$LISTS/list-user.txt" ]; then
    while IFS= read -r d || [ -n "$d" ]; do
      case $d in ''|'#'*|*[!a-z0-9.-]*) continue ;; esac
      TARGETS+=("U|$d|https://$d/"); NU=$(( NU + 1 ))
      [ "$NU" -ge "$USER_MAX" ] && break
    done < "$LISTS/list-user.txt"
  fi
  NT=${#TARGETS[@]}
}

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
#        utun       — от имени пользователя через физический интерфейс: при включённом
#                     VPN так видно utunws (правила для этого грузит ut_test_on)
# результат: LAST_RC[i] (ok|fail|skip), LAST_CODE[i] — код curl, если не открылось,
# SCORE_Y из NY, SCORE_D из ND, SCORE_U из NU, LAST_FAIL
run_checks() {
  local how=$1 tmp i t url pu="" pids=() rc
  local -a px comp pre
  user_targets
  tmp=$(mktemp -d /tmp/zapret-mac-chk.XXXXXX) || return 1
  case $how in
    direct)  [ -n "$PHYS" ] || detect_phys; px=(--noproxy '*'); [ -n "$PHYS" ] && px+=(--interface "$PHYS") ;;
    socks:*) px=(--socks5-hostname "127.0.0.1:${how#socks:}") ;;
    utun)    [ -n "$PHYS" ] || detect_phys; px=(--noproxy '*' --interface "$PHYS"); [ "$(id -u)" -eq 0 ] && pu=$(probe_user) ;;
    *)       px=(--noproxy '*'); [ "$(id -u)" -eq 0 ] && pu=$(probe_user) ;;
  esac
  for (( i=0; i<NT; i++ )); do
    t_want "${TARGETS[$i]}" || continue
    url=${TARGETS[$i]##*|}
    comp=(--compressed)
    # главную YouTube качаем целиком (~1 МБ): так видно и замедление, а не только блокировку
    [ "$url" = "https://www.youtube.com/" ] && [ "$CHECK_LIGHT" != 1 ] && comp=()
    pre=(env -u ALL_PROXY -u all_proxy -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy)
    [ -n "$pu" ] && pre=(sudo -u "$pu")
    (
      "${pre[@]}" /usr/bin/curl -s "${comp[@]}" -o /dev/null --connect-timeout 5 --max-time 8 -A "$UA" "${px[@]}" "$url"
      echo "$?" > "$tmp/$i"
    ) &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null
  SCORE_Y=0; SCORE_D=0; SCORE_U=0; NY=0; ND=0; LAST_FAIL=""; LAST_RC=(); LAST_CODE=()
  for (( i=0; i<NT; i++ )); do
    t=${TARGETS[$i]}
    # NY и ND — размер группы целиком, даже если проверяли только другую
    case ${t%%|*} in Y) NY=$(( NY + 1 )) ;; D) ND=$(( ND + 1 )) ;; esac
    if ! t_want "$t"; then LAST_RC[$i]=skip; continue; fi
    rc=""
    read -r rc 2>/dev/null < "$tmp/$i"
    if [ "$rc" = 0 ]; then
      LAST_RC[$i]=ok
      case ${t%%|*} in Y) SCORE_Y=$(( SCORE_Y + 1 )) ;; D) SCORE_D=$(( SCORE_D + 1 )) ;; *) SCORE_U=$(( SCORE_U + 1 )) ;; esac
    else
      LAST_RC[$i]=fail; LAST_CODE[$i]=${rc:-?}
      LAST_FAIL="$LAST_FAIL, $(t_label "$t")"
    fi
  done
  LAST_FAIL=${LAST_FAIL#, }
  rm -rf "$tmp"
}

# Стратегию, которая открыла всё, проверяем ещё раз: на нестабильной сети ТСПУ иногда
# пропускает соединение случайно, и подбор сохранил бы стратегию, которая не работает.
# Баллы — меньшие из двух проверок. $1 — как проверять (как у run_checks)
recheck_full() {
  local y=$SCORE_Y d=$SCORE_D u=$SCORE_U
  run_checks "$1"
  [ "$SCORE_Y" -gt "$y" ] && SCORE_Y=$y
  [ "$SCORE_D" -gt "$d" ] && SCORE_D=$d
  [ "$SCORE_U" -gt "$u" ] && SCORE_U=$u
  return 0
}

# код curl — по-человечески: видно, режут ли соединение, рвут или оно просто не ответило
curl_why() {
  case $1 in
    6)  printf 'не нашёлся адрес' ;;
    7)  printf 'нет соединения' ;;
    28) printf 'тайм-аут' ;;
    35) printf 'оборвался TLS' ;;
    52|56) printf 'соединение сброшено' ;;
    60) printf 'чужой сертификат' ;;
    *)  printf 'код %s' "$1" ;;
  esac
}

print_checks() {
  local i
  for (( i=0; i<NT; i++ )); do
    case ${LAST_RC[$i]} in
      skip) ;;
      ok)  printf '   %s✓%s %s\n' "$G" "$N" "$(t_label "${TARGETS[$i]}")" ;;
      *)   printf '   %s✗%s %s %s(%s)%s\n' "$R" "$N" "$(t_label "${TARGETS[$i]}")" "$D" "$(curl_why "${LAST_CODE[$i]}")" "$N" ;;
    esac
  done
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
      warn "В «${svc}» включена автонастройка прокси (PAC) — она может перебивать обход."
  done <<< "$(services)"
}

# ─── pf: прозрачное перенаправление в tpws ───────────────────────────
# локальные сети не трогаем никогда
SKIP4="0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3"
SKIP6="::/127, fc00::/7, fe80::/10, ff00::/8"
# сервисы Google без Google Cloud (там бывают VPN-серверы, их QUIC трогать нельзя)
GOOGLE4="8.8.4.0/24, 8.8.8.0/24, 64.233.160.0/19, 66.102.0.0/20, 66.249.64.0/19, 72.14.192.0/18, 74.125.0.0/16, 108.170.192.0/18, 108.177.0.0/17, 142.250.0.0/15, 172.217.0.0/16, 172.253.0.0/16, 173.194.0.0/16, 192.178.0.0/15, 209.85.128.0/17, 216.58.192.0/19, 216.239.32.0/19"
GOOGLE6="2001:4860::/32, 2404:6800::/32, 2607:f8b0::/32, 2800:3f0::/32, 2a00:1450::/32, 2c0f:fb50::/32"
# адреса Discord: discord.com, gateway.discord.gg, cdn.discordapp.com, media.discordapp.net,
# discord.media — на Cloudflare, 162.159.128.0–162.159.139.255; обновления
# (stable.dl2.discordapp.net) — в Google Cloud. По IPv6 есть только discord.media;
# его не пускаем, чтобы Discord шёл по IPv4 через utunws
DS4="162.159.128.0/21, 162.159.136.0/22, 34.126.226.51/32"
DS6="2606:4700:7::a29f:8000/116"
DS_TCP="443, 2053, 2083, 2087, 2096, 8443"
DS_UDP="19294:19344, 50000:50100"   # голос Discord

# В стандартном /etc/pf.conf есть якоря com.apple/* — наши правила живут там же
# и /etc/pf.conf не трогают. Если не сработает — как оригинальный zapret,
# прописываем свой якорь zapret-mac/* в /etc/pf.conf (PF_ROOT=zapret-mac).
anchor_main() { printf '%s/zapret-mac' "${FORCE_ROOT:-$(cfg PF_ROOT com.apple)}"; }   # FORCE_ROOT — для redirect-test
anchor_test() { printf '%s/zapret-mac-test' "$(cfg PF_ROOT com.apple)"; }

# Discord → utunws. pf выпускает пакет из физического интерфейса в utun50 (route-to),
# utunws добавляет поддельные и сам пишет всё в физический интерфейс через BPF — мимо pf.
# $1 = tables | filter: таблицы идут до rdr, правила фильтра — после. Нужен PHYS (detect_phys)
ut_rules() {
  if [ "$1" = tables ]; then
    printf 'table <zm_ds4> const { %s }\n' "$DS4"
    printf 'table <zm_ds6> const { %s }\n' "$DS6"
    if [ "$(yt_engine)" = utunws ]; then
      printf 'table <zm_g4> const { %s }\n' "$GOOGLE4"
      printf 'table <zm_g6> const { %s }\n' "$GOOGLE6"
    fi
    return 0
  fi
  # пакет, отправленный в utun50, pf проверяет ещё раз — уже там. Без этого правила
  # его перехватило бы правило tpws ниже, у которого нет привязки к интерфейсу
  printf 'pass out quick on %s all no state\n' "$UT_IF"
  printf 'pass out quick on %s route-to (%s %s) inet proto tcp from any to <zm_ds4> port { %s } user { >root } no state\n' \
    "$PHYS" "$UT_IF" "$UT_PEER" "$DS_TCP"
  printf 'pass out quick on %s route-to (%s %s) inet proto udp from any to !<zm_skip4> port { %s } user { >root } no state\n' \
    "$PHYS" "$UT_IF" "$UT_PEER" "$DS_UDP"
  # Ответы — тоже своим правилом quick и без состояния. Иначе их подберёт чужое правило
  # с keep state (общий доступ к интернету, его включают и виртуальные машины, ставит
  # «pass on en0 all flags any keep state»): по ответу на SYN появится состояние, и
  # дальше пакеты соединения пойдут по нему напрямую, мимо utunws, — он увидит один SYN
  printf 'pass in quick on %s inet proto tcp from <zm_ds4> port { %s } to any no state\n' "$PHYS" "$DS_TCP"
  printf 'pass in quick on %s inet proto udp from any port { %s } to any no state\n' "$PHYS" "$DS_UDP"
  # QUIC к Discord — сразу отказ, приложение уходит на TCP, то есть в utunws
  printf 'block return out quick on %s inet proto udp from any to <zm_ds4> port 443 user { >root }\n' "$PHYS"
  printf 'block return out quick on %s inet6 proto { tcp, udp } from any to <zm_ds6> user { >root }\n' "$PHYS"
  [ "$(yt_engine)" = utunws ] || return 0
  # YouTube через utunws: TCP к Google — туда же, QUIC и IPv6 к Google — отказ
  printf 'pass out quick on %s route-to (%s %s) inet proto tcp from any to <zm_g4> port 443 user { >root } no state\n' \
    "$PHYS" "$UT_IF" "$UT_PEER"
  printf 'pass in quick on %s inet proto tcp from <zm_g4> port 443 to any no state\n' "$PHYS"
  printf 'block return out quick on %s inet proto udp from any to <zm_g4> port 443 user { >root }\n' "$PHYS"
  printf 'block return out quick on %s inet6 proto { tcp, udp } from any to <zm_g6> port 443 user { >root }\n' "$PHYS"
}

# Правила из docs/bsd.md оригинала: исходящий TCP 80/443 уводится на lo0 (route-to),
# там rdr отдаёт его tpws. Трафик root не трогаем — от root работает сам tpws,
# иначе он завернул бы сам себя.
pf_rules_main() {
  local ports="{ 80, 443 }" ut=0
  ut_active && detect_phys && ut=1
  printf 'table <zm_skip4> const { %s }\n' "$SKIP4"
  printf 'table <zm_skip6> const { %s }\n' "$SKIP6"
  if [ "$(cfg QUIC 1)" = 1 ]; then
    printf 'table <zm_quic4> const { %s }\n' "$GOOGLE4"
    printf 'table <zm_quic6> const { %s }\n' "$GOOGLE6"
  fi
  [ "$ut" = 1 ] && ut_rules tables
  printf 'rdr pass on lo0 inet proto tcp from !127.0.0.0/8 to !<zm_skip4> port %s -> 127.0.0.1 port %s\n' "$ports" "$TP_PORT"
  printf 'rdr pass on lo0 inet6 proto tcp from !::1 to !<zm_skip6> port %s -> fe80::1 port %s\n' "$ports" "$TP_PORT"
  [ "$ut" = 1 ] && ut_rules filter
  if [ "$(cfg QUIC 1)" = 1 ]; then
    # tpws умеет только TCP. QUIC (HTTP/3 по UDP) к Google отбиваем сразу,
    # и браузер без задержки уходит на TCP — то есть через обход
    printf '%s\n' 'block return out quick inet proto udp from any to <zm_quic4> port 443 user { >root }'
    printf '%s\n' 'block return out quick inet6 proto udp from any to <zm_quic6> port 443 user { >root }'
  fi
  # quick обязателен: без него побеждает последнее подходящее правило, а общий доступ к
  # интернету (и виртуальные машины с общей сетью) добавляет после нас «pass on en0 all
  # keep state» — и программы шли бы мимо tpws напрямую. Пересылаемый трафик (той же
  # виртуальной машины) правило не задевает: у него нет владельца, и user > 0 не совпадает
  printf 'pass out quick route-to (lo0 127.0.0.1) inet proto tcp from !127.0.0.0/8 to !<zm_skip4> port %s user { >root }\n' "$ports"
  printf 'pass out quick route-to (lo0 fe80::1) inet6 proto tcp from !::1 to !<zm_skip6> port %s user { >root }\n' "$ports"
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
fw_ut_loaded() { pfctl -a "$(anchor_main)" -s rules 2>/dev/null | grep -qF "route-to ($UT_IF "; }
# правила utunws должны быть загружены ровно тогда, когда он работает: иначе
# Discord уходил бы в utun50, где его никто не ждёт
ut_rules_ok() { if ut_active; then fw_ut_loaded; else ! fw_ut_loaded; fi; }

# правда ли трафик программ доходит до tpws: открываем сайт от имени пользователя со своего
# локального порта и ищем в таблице состояний pf именно это соединение, завёрнутое на
# 127.0.0.1:988. Просто «есть такие состояния» не годится: долгие соединения остаются
# в таблице с тех пор, когда перехват работал, и проверка проходила бы и без него
# Результат — ещё и REDIR_INFO для журнала: код curl и состояния pf этого соединения (по ним
# видно, ушло ли оно в tpws, напрямую или не ушло никуда)
redirect_works() {
  local port=$(( 40000 + RANDOM % 20000 )) rc st
  sudo -u "$(probe_user)" /usr/bin/curl -s -o /dev/null --noproxy '*' --connect-timeout 5 --max-time 8 \
    --local-port "$port" -A "$UA" "$CONTROL_URL"; rc=$?
  st=$(pfctl -s state 2>/dev/null | grep -F ":$port ")
  REDIR_INFO="curl rc=$rc, порт $port, состояния: $(printf '%s' "${st:-нет}" | tr -s ' ' | tr '\n' ';' | cut -c1-400)"
  [ "$rc" = 0 ] && printf '%s\n' "$st" | grep -qF "127.0.0.1:$TP_PORT"
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
  log "Перехват в tpws не работает с якорем $(anchor_main): $REDIR_INFO"
  # Пробуем второй якорь. com.apple/* есть в системном наборе pf всегда; zapret-mac/* —
  # только пока в загруженном наборе есть строки из /etc/pf.conf (его перезагружают и
  # другие программы)
  fw_off
  if [ "$(cfg PF_ROOT com.apple)" = com.apple ]; then
    if pf_conf_patch; then patched=1; cfg_set PF_ROOT zapret-mac; fi
  else
    cfg_set PF_ROOT com.apple; patched=2
  fi
  if [ "$patched" != 0 ]; then
    if fw_on && redirect_works; then log "Перехват работает с якорем $(anchor_main)"; return 0; fi
    log "Перехват в tpws не работает и с якорем $(anchor_main): $REDIR_INFO"
    fw_off
  fi
  case $patched in
    1) pf_conf_unpatch; cfg_set PF_ROOT com.apple ;;
    2) cfg_set PF_ROOT zapret-mac ;;
  esac
  return 1
}

# прозрачный режим не заработал — чтобы не оставить без интернета, уходим на SOCKS-прокси
tp_fallback() {
  fw_off
  ut_unload   # utunws живёт только в прозрачном режиме
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
  test_rules | pf_load "$(anchor_test)" && pf_take "$RUN/pf-token-test" || { test_env_down; return 1; }
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

test_rules() {   # $1 = ut — ещё и правила utunws: соединения с адреса Wi-Fi к Discord идут в него
  [ -n "$TEST_VPN" ] &&
    printf 'pass out quick on %s route-to (%s %s) inet proto tcp from %s to any\n' "$TEST_VPN" "$PHYS" "$PHYS_GW" "$PHYS_IP"
  [ "$1" = ut ] || return 0
  printf 'table <zm_skip4> const { %s }\n' "$SKIP4"
  ut_rules tables
  ut_rules filter
}
# проверка utunws при включённом VPN: run_checks utun идёт мимо туннеля, и эти правила
# отдают его соединения с Discord в utunws. Обычный трафик программ идёт в VPN и их не задевает
ut_test_on() { [ -n "$TEST_VPN" ] && ut_active && test_rules ut | pf_load "$(anchor_test)"; }
ut_test_off() { [ -n "$TEST_VPN" ] && test_rules | pf_load "$(anchor_test)"; }

# Подбор для utunws: временный utunws на utun51 со стратегией $1 для Discord и, если $2 = 1,
# для YouTube. Проверочные запросы идут от root через физический интерфейс (run_checks direct):
# правила основного якоря трафик root не трогают, а эти отдают его временному utunws.
# Рабочий utunws на utun50 и Discord пользователя при этом не трогаются
ut_try_rules() {
  test_rules
  printf 'table <zm_t4> const { %s }\n' "$DS4"
  printf 'pass out quick on %s all no state\n' "$UT_TEST_IF"
  printf 'pass out quick on %s route-to (%s %s) inet proto tcp from any to <zm_t4> port { %s } user root no state\n' \
    "$PHYS" "$UT_TEST_IF" "$UT_TEST_PEER" "$DS_TCP"
  printf 'pass in quick on %s inet proto tcp from <zm_t4> port { %s } to any no state\n' "$PHYS" "$DS_TCP"
  printf 'block return out quick on %s inet proto udp from any to <zm_t4> port 443 user root\n' "$PHYS"
  [ "$1" = 1 ] || return 0
  printf 'table <zm_tg4> const { %s }\n' "$GOOGLE4"
  printf 'pass out quick on %s route-to (%s %s) inet proto tcp from any to <zm_tg4> port 443 user root no state\n' \
    "$PHYS" "$UT_TEST_IF" "$UT_TEST_PEER"
  printf 'pass in quick on %s inet proto tcp from <zm_tg4> port 443 to any no state\n' "$PHYS"
  printf 'block return out quick on %s inet proto udp from any to <zm_tg4> port 443 user root\n' "$PHYS"
}

ut_try_start() {
  local mac i
  UT_TPID=""
  ifconfig "$UT_TEST_IF" >/dev/null 2>&1 && return 1
  mac=$(gw_mac "$PHYS_GW") || return 1
  build_ut_args "$1" "$2"
  ZAPRET_IFACE=$PHYS ZAPRET_GATEWAY_MAC=$mac ZAPRET_UTUN_UNIT=$UT_TEST_UNIT "$UTUNWS" "${UT_ARGS[@]}" >/dev/null 2>&1 &
  UT_TPID=$!
  for (( i=0; i<50; i++ )); do ifconfig "$UT_TEST_IF" >/dev/null 2>&1 && break; sleep 0.1; done
  if ! ifconfig "$UT_TEST_IF" "$UT_TEST_LOCAL" "$UT_TEST_PEER" netmask 255.255.255.255 up >/dev/null 2>&1 ||
     ! ut_try_rules "$2" | pf_load "$(anchor_test)" || ! pf_take "$RUN/pf-token-test"; then
    ut_try_stop
    return 1
  fi
}

ut_try_stop() {
  local i
  [ -n "$UT_TPID" ] && { kill "$UT_TPID" 2>/dev/null; wait "$UT_TPID" 2>/dev/null; }
  UT_TPID=""
  for (( i=0; i<30; i++ )); do ifconfig "$UT_TEST_IF" >/dev/null 2>&1 || break; sleep 0.1; done
  if [ -n "$TEST_VPN" ]; then
    test_rules | pf_load "$(anchor_test)"
  else
    pfctl -q -a "$(anchor_test)" -F all >/dev/null 2>&1
    pf_give "$RUN/pf-token-test"
  fi
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

# ─── utunws: второй движок для Discord ───────────────────────────────
# utunws работает только в прозрачном режиме: в режиме SOCKS pf не трогаем совсем
ut_wanted() { [ "$(cfg UTUNWS 1)" = 1 ] && [ "$(cfg MODE transparent)" = transparent ] && [ -x "$UTUNWS" ]; }
ut_up() { ifconfig "$UT_IF" 2>/dev/null | grep -qF "inet $UT_LOCAL "; }
ut_active() { ut_wanted && ut_up; }

gw_mac() {   # MAC шлюза $1 — на него utunws адресует свои кадры
  local m
  ping -c 1 -t 1 "$1" >/dev/null 2>&1   # освежить ARP; ответ не важен
  m=$(arp -n "$1" 2>/dev/null | awk '/ at / {print $4; exit}')
  case $m in *:*:*:*:*:*) printf '%s' "$m" ;; *) return 1 ;; esac
}

# utunws адресует кадры шлюзу, который был при запуске. Сменились интерфейс, шлюз
# или его MAC (другой роутер с тем же 192.168.1.1) — utunws надо перезапустить
ut_net_changed() {
  local ifc gw mac cur
  [ -s "$RUN/utunws.net" ] || return 1
  read -r ifc gw mac < "$RUN/utunws.net"
  detect_phys || return 1
  { [ "$PHYS" = "$ifc" ] && [ "$PHYS_GW" = "$gw" ]; } || return 0
  cur=$(arp -n "$gw" 2>/dev/null | awk '/ at / {print $4; exit}')
  [ -n "$cur" ] && [ "$cur" != "$mac" ]   # пропавшую запись ARP за смену сети не считаем
}

# запускается из launchd (метка com.zapret-mac.utunws): ждёт сеть, узнаёт MAC шлюза,
# поднимает utunws и адреса на utun50. utunws упал — выходим, launchd запустит снова
ut_run() {
  local pid="" mac i t0
  [ "$(id -u)" -eq 0 ] || die "utunws запускается только из launchd."
  mkdir -p "$LOGS" "$RUN"
  trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -f "$RUN/utunws.net"; exit 0' TERM INT
  until detect_phys && mac=$(gw_mac "$PHYS_GW"); do sleep 5; done
  build_ut_args "$(ut_of)" "$([ "$(yt_engine)" = utunws ] && echo 1)"
  say "$(date '+%d.%m %H:%M:%S') запускаю utunws: $PHYS, шлюз $PHYS_GW ($mac), Discord — $(ut_strat_name "$(ut_of)"), YouTube — $(yt_engine)"
  t0=$SECONDS
  ZAPRET_IFACE=$PHYS ZAPRET_GATEWAY_MAC=$mac ZAPRET_UTUN_UNIT=$UT_UNIT "$UTUNWS" "${UT_ARGS[@]}" &
  pid=$!
  for (( i=0; i<100; i++ )); do
    ifconfig "$UT_IF" >/dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if ifconfig "$UT_IF" >/dev/null 2>&1 && ifconfig "$UT_IF" "$UT_LOCAL" "$UT_PEER" netmask 255.255.255.255 up; then
    printf '%s %s %s\n' "$PHYS" "$PHYS_GW" "$mac" > "$RUN/utunws.net"
    wait "$pid"
  else
    kill "$pid" 2>/dev/null
  fi
  rm -f "$RUN/utunws.net"
  say "$(date '+%d.%m %H:%M:%S') utunws остановился"
  # падает сразу после запуска (интерфейс не Ethernet, utun50 занят) — не дёргаем его каждые 5 секунд
  [ $(( SECONDS - t0 )) -lt 10 ] && sleep 30
  exit 1
}

ut_unload() {
  job_unload "$LBL_UT"; rm -f "$PL_UT"
  pkill -f "$UTUNWS" >/dev/null 2>&1
  rm -f "$RUN/utunws.net"
}

# (пере)запускает utunws, если он нужен. 1 — не поднялся: Discord пойдёт через tpws
ut_apply() {
  local i
  if ! ut_wanted; then ut_unload; return 0; fi
  ut_unload
  for (( i=0; i<30; i++ )); do ifconfig "$UT_IF" >/dev/null 2>&1 || break; sleep 0.1; done
  if ifconfig "$UT_IF" >/dev/null 2>&1; then
    err "Интерфейс $UT_IF уже занят другой программой (ZPRT Connection или ZapretMac?) — закрой её."
    return 1
  fi
  : > "$LOGS/utunws.log"
  write_plist "$LBL_UT" "$PL_UT" "$LOGS/utunws.log" /bin/bash "$SELF" utunws-run || { err "Не могу записать $PL_UT"; return 1; }
  job_load "$LBL_UT" "$PL_UT"
  for (( i=0; i<150; i++ )); do ut_up && return 0; sleep 0.1; done
  # сети нет — utunws ждёт её сам и поднимется, когда она появится
  if ! { detect_phys && gw_mac "$PHYS_GW" >/dev/null; }; then
    warn "Нет сети — utunws запустится, когда она появится."
    return 0
  fi
  err "utunws не запустился. Последние строки лога:"
  tail -n 10 "$LOGS/utunws.log" >&2
  ut_unload
  return 1
}

# utunws нужной версии и все поддельные пакеты на месте
ut_files_ok() {
  local f
  [ -x "$UTUNWS" ] && [ "$(cat "$DIR/utunws-version" 2>/dev/null)" = "$UTUNWS_TAG" ] || return 1
  for f in $UT_FAKES; do [ -f "${UTUNWS%/*}/${f%%:*}" ] || return 1; done
}

# ставит utunws, если он нужен и его ещё нет; неудача не мешает остальному обходу
ut_ensure() {
  [ "$(cfg UTUNWS 1)" = 1 ] || return 0
  ut_files_ok && return 0
  install_utunws || warn "Discord пойдёт через tpws, как раньше. Повторить установку — пункт 13 «Обновить»."
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

install_utunws() {
  local tmp p="ZapretMac.app/Contents/Resources/Payload/bin" f want got
  local -a names=(utunws)
  mkdir -p "$BIN_DIR" || { err "Не могу создать $BIN_DIR"; return 1; }
  tmp=$(mktemp -d /tmp/zapret-mac-ut.XXXXXX) || return 1
  say "Скачиваю utunws (Flowseal/zapret-mac-discord-youtube $UTUNWS_TAG) с GitHub…"
  if ! curl -fL --progress-bar --connect-timeout 15 -o "$tmp/z.zip" "$UTUNWS_URL"; then
    rm -rf "$tmp"; err "Не удалось скачать $UTUNWS_URL"; return 1
  fi
  for f in $UT_FAKES; do names+=("${f%%:*}"); done
  if ! unzip -q -o "$tmp/z.zip" "${names[@]/#/$p/}" -d "$tmp" 2>/dev/null; then
    rm -rf "$tmp"; err "В архиве Flowseal нет utunws или поддельных пакетов."; return 1
  fi
  for f in "utunws:$UTUNWS_SHA256" $UT_FAKES; do
    want=${f#*:}; f=${f%%:*}
    got=$(shasum -a 256 "$tmp/$p/$f" | awk '{print $1}')
    if [ "$got" != "$want" ]; then
      rm -rf "$tmp"; err "Контрольная сумма $f не совпала — файл повреждён или подменён. utunws не установлен."; return 1
    fi
  done
  for f in $UT_FAKES; do
    install -m 644 -o root -g wheel "$tmp/$p/${f%%:*}" "$BIN_DIR/" || { rm -rf "$tmp"; return 1; }
  done
  install -m 755 -o root -g wheel "$tmp/$p/utunws" "$UTUNWS.new" && mv -f "$UTUNWS.new" "$UTUNWS"
  xattr -c "$UTUNWS" 2>/dev/null
  rm -rf "$tmp"
  "$UTUNWS" --version >/dev/null 2>&1 || { err "utunws не запускается на этом Mac."; return 1; }
  printf '%s\n' "$UTUNWS_TAG" > "$DIR/utunws-version"
  ok "utunws $UTUNWS_TAG установлен (контрольные суммы проверены)"
}

self_install() {
  local me src have
  me=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")
  if [ -f "$me" ] && [ "$me" != "$SELF" ] && ! cmp -s "$me" "$SELF"; then
    install -m 755 -o root -g wheel "$me" "$SELF" || die "Не могу скопировать скрипт в $DIR"
  fi
  # strategies.conf рядом со скриптом (в репозитории, в приложении) — если он новее установленного
  src="${me%/*}/strategies.conf"
  if [ "$src" != "$STRAT_FILE" ] && [ -f "$src" ]; then
    if strat_parse "$STRAT_FILE"; then have=$NEW_VER; else have=0; fi
    if strat_parse "$src" && [ "$NEW_VER" -gt "$have" ]; then
      install -m 644 -o root -g wheel "$src" "$STRAT_FILE" && strat_reload
    fi
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
  cfg_migrate
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
  [ "$mode" = transparent ] && ut_ensure
  ut_apply || warn "Discord пойдёт через tpws, как раньше."
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
           ut_unload
           tpws_apply socks || return 1 ;;
      esac
    fi
  else
    fw_off
  fi
  [ "$mode" = socks ] && { proxy_on || return 1; }
  wd_load || warn "Сторож не запустился — автопереключение с VPN работать не будет."
  log "Включён: режим $(mode_name), YouTube — $(yt_desc), Discord — $(ds_desc)"
  say "   YouTube — $(yt_desc), Discord — $(ds_desc)"
  ut_active && ok "Discord и звонки идут через utunws"
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
  ut_unload
  pfctl -q -a "$(anchor_test)" -F all >/dev/null 2>&1
  pf_give "$RUN/pf-token"; pf_give "$RUN/pf-token-test"
  proxy_off
  rm -f "$PAUSE_F" "$RUN/progress"
  [ -d "$RUN" ] && wd_status off
  log "Выключен"
  ok "Обход выключен, перенаправление и прокси сняты."
}

# можно ли подбирать стратегии utunws: он включён, установлен целиком и работает прозрачный режим
ut_selectable() { ut_wanted && ut_files_ok; }

# одна строка подбора: $1 — номер, $2 — из скольких, $3 — название, дальше — что показать (Y, D, U)
sel_line() {
  local i=$1 n=$2 name=$3 g
  shift 3
  printf ' [%2d/%d] %-10s' "$i" "$n" "$name"
  for g in "$@"; do
    case $g in
      Y) printf ' YouTube %s' "$(score_mark "$SCORE_Y" "$NY")" ;;
      D) printf ' Discord %s' "$(score_mark "$SCORE_D" "$ND")" ;;
      U) [ "$NU" -gt 0 ] && printf ' свои сайты %s' "$(score_mark "$SCORE_U" "$NU")" ;;
    esac
  done
  [ -n "$LAST_FAIL" ] && printf '  %sне открылось: %s%s' "$D" "$LAST_FAIL" "$N"
  printf '\n'
}

# ход подбора для приложения, файл $RUN/progress: «проценты|что сейчас|кто подбирает».
# PROG_T — сколько шагов всего, prog — следующий шаг
PROG_K=0; PROG_T=1
prog() {
  PROG_K=$(( PROG_K + 1 ))
  [ -w "$RUN" ] || return 0
  printf '%s|%s|%s\n' "$(( PROG_K * 100 / PROG_T ))" "$1" "${SEL_WHO:-cli}" > "$RUN/progress.new" &&
    chmod 644 "$RUN/progress.new" && mv -f "$RUN/progress.new" "$RUN/progress"
}
prog_done() { [ -w "$RUN" ] && rm -f "$RUN/progress"; return 0; }

# Подбор стратегий. $1 = all — прогнать все; auto — сначала проверить текущие.
# С utunws Discord подбирается среди стратегий utunws, YouTube — среди стратегий tpws, а если
# tpws открывает не всё, ещё и через utunws. Без utunws обе группы подбираются через tpws.
# Результат: SEL_Y, SEL_STY — лучшая стратегия tpws для YouTube и её балл; SEL_YT — tpws|utunws;
# SEL_SY — балл YouTube выбранным способом; SEL_D, SEL_SD — Discord (номер utunws, если SEL_UT=1,
# иначе tpws) и балл; SEL_PATH=1 — текущие и так рабочие
select_strategies() {
  local i by bd ud yt sy=-1 sd=-1 tsy=-1 bind="" ut=0 only=""
  SEL_PATH=0
  test_env_up || return 1
  trap 'stop_test; ut_try_stop; test_env_down; prog_done; exit 130' INT TERM HUP
  [ -n "$TEST_VPN" ] && bind=$PHYS_IP
  ut_selectable && { ut=1; only=Y; }
  by=$(strat_of Y); bd=$(strat_of D); ud=$(ut_of); yt=tpws
  [ "$ut" = 1 ] && yt=$(yt_engine)
  PROG_K=0; PROG_T=$(( 1 + NSTRAT ))
  [ "$1" = auto ] && PROG_T=$(( PROG_T + 1 ))
  [ "$ut" = 1 ] && PROG_T=$(( PROG_T + NUT + 1 ))
  say ""
  say "${B}Без обхода${N} ${D}(напрямую через $PHYS)${N}"
  prog "Проверяю сеть без обхода"
  CHECK_ONLY=""; run_checks direct
  print_checks
  if [ "$SCORE_Y" -eq "$NY" ] && [ "$SCORE_D" -eq "$ND" ]; then
    warn "Всё открывается и без обхода — блокировок сейчас нет. Подбор всё равно проведу."
  fi
  if [ "$1" = auto ]; then
    # текущие стратегии: если всё открывается, сломался не обход, а перенаправление
    prog "Проверяю сохранённые стратегии"
    if [ "$ut" = 1 ]; then
      if ut_try_start "$ud" "$([ "$yt" = utunws ] && echo 1)"; then
        CHECK_ONLY=D; [ "$yt" = utunws ] && CHECK_ONLY=YD
        run_checks direct; ut_try_stop
        sd=$SCORE_D; [ "$yt" = utunws ] && { sy=$SCORE_Y; tsy=0; }
      fi
    fi
    if [ "$yt" = tpws ] && start_test cur "$bind"; then
      CHECK_ONLY=$only; [ -n "$only" ] || CHECK_ONLY=YD
      run_checks "socks:$TEST_PORT"; stop_test
      sy=$SCORE_Y; tsy=$sy; [ "$ut" = 1 ] || sd=$SCORE_D
    fi
    CHECK_ONLY=""
    say "Текущие стратегии: YouTube $(score_mark "$sy" "$NY") · Discord $(score_mark "$sd" "$ND")"
    if [ "$sy" -eq "$NY" ] && [ "$sd" -eq "$ND" ]; then
      SEL_PATH=1; SEL_Y=$by; SEL_STY=$tsy; SEL_YT=$yt; SEL_SY=$sy; SEL_UT=$ut; SEL_SD=$sd
      if [ "$ut" = 1 ]; then SEL_D=$ud; else SEL_D=$bd; fi
      test_env_down; prog_done; trap - INT TERM HUP
      return 0
    fi
    sy=-1; sd=-1; tsy=-1
  fi

  say ""
  if [ "$ut" = 1 ]; then say "${B}YouTube через tpws${N} ${D}(до 10 секунд на стратегию)${N}"
  else say "${B}YouTube и Discord через tpws${N} ${D}(до 10 секунд на стратегию)${N}"; fi
  [ -n "$only" ] || only=YD
  for (( i=1; i<=NSTRAT; i++ )); do
    prog "tpws: $(strat_name "$i") — $i из $NSTRAT"
    if ! start_test "$i" "$bind"; then
      printf ' [%2d/%d] %-10s не запустилась\n' "$i" "$NSTRAT" "$(strat_name "$i")"
      continue
    fi
    CHECK_ONLY=$only; run_checks "socks:$TEST_PORT"
    [ "$SCORE_Y" -eq "$NY" ] && recheck_full "socks:$TEST_PORT"
    stop_test; CHECK_ONLY=""
    if [ "$ut" = 1 ]; then sel_line "$i" "$NSTRAT" "$(strat_name "$i")" Y
    else sel_line "$i" "$NSTRAT" "$(strat_name "$i")" Y D; fi
    [ "$SCORE_Y" -gt "$tsy" ] && { by=$i; tsy=$SCORE_Y; }
    [ "$ut" = 1 ] || { [ "$SCORE_D" -gt "$sd" ] && { bd=$i; sd=$SCORE_D; }; }
    [ "$1" != all ] && [ "$tsy" -eq "$NY" ] && { [ "$ut" = 1 ] || [ "$sd" -eq "$ND" ]; } && break
  done
  sy=$tsy; yt=tpws

  if [ "$ut" = 1 ]; then
    PROG_K=$(( 1 + NSTRAT )); [ "$1" = auto ] && PROG_K=$(( PROG_K + 1 ))   # tpws мог закончить раньше
    say ""
    say "${B}Discord через utunws${N}"
    for (( i=1; i<=NUT; i++ )); do
      prog "utunws для Discord: $(ut_strat_name "$i") — $i из $NUT"
      if ! ut_try_start "$i"; then
        printf ' [%2d/%d] %-10s не запустилась\n' "$i" "$NUT" "$(ut_strat_name "$i")"
        continue
      fi
      CHECK_ONLY=D; run_checks direct
      [ "$SCORE_D" -eq "$ND" ] && recheck_full direct
      ut_try_stop; CHECK_ONLY=""
      sel_line "$i" "$NUT" "$(ut_strat_name "$i")" D
      [ "$SCORE_D" -gt "$sd" ] && { ud=$i; sd=$SCORE_D; }
      [ "$1" != all ] && [ "$sd" -eq "$ND" ] && break
    done
    if [ "$1" = all ] || [ "$tsy" -lt "$NY" ]; then
      say ""
      say "${B}YouTube через utunws${N}"
      prog "utunws для YouTube"
      if ut_try_start "$ud" 1; then
        CHECK_ONLY=Y; run_checks direct; ut_try_stop; CHECK_ONLY=""
        sel_line 1 1 HOSTFAKESPLIT Y
        [ "$SCORE_Y" -gt "$tsy" ] && { yt=utunws; sy=$SCORE_Y; }
      else
        say "   не запустился"
      fi
    fi
  fi
  test_env_down
  prog_done
  trap - INT TERM HUP
  SEL_Y=$by; SEL_STY=$tsy; SEL_YT=$yt; SEL_SY=$sy; SEL_UT=$ut; SEL_SD=$sd
  if [ "$ut" = 1 ]; then SEL_D=$ud; else SEL_D=$bd; fi
  [ "$sy" -ge 0 ] || [ "$sd" -ge 0 ]
}

# Подбор стратегии tpws для своих сайтов (S_D). Когда Discord идёт через tpws (без utunws),
# у него та же стратегия — тогда смотрим на Discord и свои сайты вместе, и Discord важнее.
# Результат: SEL_D, SEL_SU — стратегия и сколько своих сайтов с ней открылось
sites_select() {
  local i best key bk=-1 bind="" only=U
  user_targets
  [ "$NU" -gt 0 ] || { err "Своих сайтов нет или они выключены."; return 1; }
  test_env_up || return 1
  trap 'stop_test; test_env_down; prog_done; exit 130' INT TERM HUP
  [ -n "$TEST_VPN" ] && bind=$PHYS_IP
  ut_active || only=DU
  best=$(strat_of D); SEL_SU=-1
  PROG_K=0; PROG_T=$NSTRAT
  say ""
  say "${B}Свои сайты через tpws${N} ${D}(до 10 секунд на стратегию)${N}"
  for (( i=1; i<=NSTRAT; i++ )); do
    prog "Свои сайты: $(strat_name "$i") — $i из $NSTRAT"
    if ! start_test "$i" "$bind"; then
      printf ' [%2d/%d] %-10s не запустилась\n' "$i" "$NSTRAT" "$(strat_name "$i")"
      continue
    fi
    CHECK_ONLY=$only; run_checks "socks:$TEST_PORT"
    [ "$SCORE_U" -eq "$NU" ] && recheck_full "socks:$TEST_PORT"
    stop_test; CHECK_ONLY=""
    if [ "$only" = U ]; then sel_line "$i" "$NSTRAT" "$(strat_name "$i")" U; key=$SCORE_U
    else sel_line "$i" "$NSTRAT" "$(strat_name "$i")" D U; key=$(( SCORE_D * 10 + SCORE_U )); fi
    [ "$key" -gt "$bk" ] && { best=$i; bk=$key; SEL_SU=$SCORE_U; }
    [ "$SCORE_U" -eq "$NU" ] && { [ "$only" = U ] || [ "$SCORE_D" -eq "$ND" ]; } && break
  done
  test_env_down
  prog_done
  trap - INT TERM HUP
  SEL_D=$best
  [ "$SEL_SU" -gt 0 ]
}

report_group() {   # $1 = название, $2 = что выбрано, $3 = балл, $4 = из скольких
  if [ "$3" -eq "$4" ]; then ok "$1: $2 — открывается всё"
  else warn "$1: лучшее — $2: $3 из $4. Часть может не работать."; fi
}

# сохраняет итог подбора в настройки (названиями стратегий) и запоминает для этой сети
sel_save() {
  [ "$SEL_STY" -gt 0 ] && cfg_set S_Y "$(strat_name "$SEL_Y")"
  [ "$SEL_UT" = 1 ] && [ "$SEL_SY" -gt 0 ] && cfg_set YT "$SEL_YT"
  if [ "$SEL_SD" -gt 0 ]; then
    if [ "$SEL_UT" = 1 ]; then cfg_set UT_D "$(ut_strat_name "$SEL_D")"; else cfg_set S_D "$(strat_name "$SEL_D")"; fi
  fi
  { [ "$SEL_SY" -gt 0 ] || [ "$SEL_SD" -gt 0 ]; } && net_save
  return 0
}

# что сейчас выбрано, для сообщений
yt_desc() { if [ "$(yt_engine)" = utunws ] && ut_wanted; then printf 'utunws'; else printf 'tpws, %s' "$(strat_name "$(strat_of Y)")"; fi; }
ds_desc() { if ut_wanted; then printf 'utunws, %s' "$(ut_strat_name "$(ut_of)")"; else printf 'tpws, %s' "$(strat_name "$(strat_of D)")"; fi; }
us_desc() { printf 'tpws, %s' "$(strat_name "$(strat_of D)")"; }

# ─── стратегии для каждой сети ───────────────────────────────────────
# Сеть узнаём по MAC шлюза: у домашнего роутера и у iPhone с раздачей он свой, даже
# если адреса совпадают. В $NETS/<id> — стратегии, которые в этой сети сработали.
NET_KEYS="S_Y S_D UT_D YT"

net_id() {   # → NET_ID, NET_LABEL; 1 — сети нет
  local mac kind
  NET_ID=""; NET_LABEL=""
  detect_phys || return 1
  mac=$(arp -n "$PHYS_GW" 2>/dev/null | awk '/ at / {print $4; exit}')
  case $mac in
    *:*:*:*:*:*) NET_ID=$(printf '%s' "$mac" | tr -d ':' | tr '[:upper:]' '[:lower:]') ;;
    *) NET_ID="${PHYS}_$(printf '%s' "$PHYS_GW" | tr '.' '_')" ;;
  esac
  case $NET_ID in *[!a-z0-9_]*) return 1 ;; esac
  kind=$(networksetup -listallhardwareports 2>/dev/null |
         awk -v d="$PHYS" '/^Hardware Port:/ {sub(/^Hardware Port: /, ""); p=$0} /^Device:/ && $2==d {print p; exit}')
  [ "$PHYS_GW" = 172.20.10.1 ] && kind="iPhone"   # так раздаёт интернет любой iPhone
  NET_LABEL="${kind:-$PHYS} · $PHYS_GW"
}

net_save() {
  local k
  net_id || return 0
  mkdir -p "$NETS" 2>/dev/null && [ -w "$NETS" ] || return 0
  { printf 'LABEL=%s\n' "$NET_LABEL"
    for k in $NET_KEYS; do printf '%s=%s\n' "$k" "$(cfg "$k")"; done
    printf 'SAVED=%s\n' "$(date +%s)"
  } > "$NETS/$NET_ID.new" && chmod 644 "$NETS/$NET_ID.new" && mv -f "$NETS/$NET_ID.new" "$NETS/$NET_ID"
}

# ставит в настройки стратегии, запомненные для этой сети; 0 — что-то поменялось
net_load() {
  local f k v rc=1
  net_id || return 1
  f="$NETS/$NET_ID"
  [ -f "$f" ] || return 1
  for k in $NET_KEYS; do
    v=$(sed -n "s/^$k=//p" "$f" | tail -n 1)
    case $v in ''|*[!A-Za-z0-9_.+-]*) continue ;; esac
    [ "$v" != "$(cfg "$k")" ] && { cfg_set "$k" "$v"; rc=0; }
  done
  return $rc
}

# сеть сменилась — перезапускаем то, чьи стратегии поменялись из-за net_load
net_apply() {
  local old_tp old_ut
  old_tp="$(strat_of Y) $(strat_of D)"; old_ut="$(ut_of) $(yt_engine)"
  net_load || return 0
  log "Сеть «${NET_LABEL}» знакома — ставлю её стратегии: YouTube — $(yt_desc), Discord — $(ds_desc)"
  if [ "$old_tp" != "$(strat_of Y) $(strat_of D)" ]; then
    tpws_apply "$(cfg MODE transparent)" >/dev/null 2>&1 || log "tpws не запустился со стратегиями этой сети"
  fi
  if [ "$old_ut" != "$(ut_of) $(yt_engine)" ] && [ -f "$PL_UT" ]; then
    fw_loaded && fw_on >/dev/null 2>&1   # YouTube мог уйти из utunws — сначала правила
    ut_apply >/dev/null 2>&1 || log "utunws не запустился со стратегиями этой сети"
    fw_loaded && fw_on >/dev/null 2>&1
  fi
}

cmd_test() {   # $1 = all — прогнать все, иначе остановиться, когда нашлись рабочие для обоих
  ensure_installed
  [ "$(cfg MODE transparent)" = transparent ] && ut_ensure
  select_strategies "$1" || return 1
  say ""
  if [ "$SEL_SY" -le 0 ] && [ "$SEL_SD" -le 0 ]; then
    err "Ни одна стратегия не помогла."
    say "   Что попробовать: пункт «DNS Google/Cloudflare» и подбор заново; другая сеть; на это время — VPN."
    return 1
  fi
  sel_save
  if [ "$SEL_SY" -gt 0 ]; then report_group YouTube "$(yt_desc)" "$SEL_SY" "$NY"
  else warn "YouTube не открылся ни одним способом — оставил прежний."; fi
  if [ "$SEL_SD" -gt 0 ]; then report_group Discord "$(ds_desc)" "$SEL_SD" "$ND"
  else warn "Discord не открылся ни с одной стратегией — оставил прежнюю."; fi
  if [ "$SEL_UT" = 1 ]; then
    say "   ${D}Звонки Discord идут через utunws.${N}"
  else
    say "   ${D}Звонки Discord идут по UDP, а tpws умеет только TCP. Если голос не подключается — на время звонка включи VPN.${N}"
  fi
  log "Подбор: YouTube — $(yt_desc) ($SEL_SY/$NY), Discord — $(ds_desc) ($SEL_SD/$ND)"
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
  cfg_set S_Y "$(strat_name "$y")"; cfg_set S_D "$(strat_name "$d")"
  if ut_selectable; then cmd_choose_ut || return; fi
  cmd_start
}

# с utunws Discord идёт через него, а YouTube — через tpws или через него
cmd_choose_ut() {
  local i n u yt
  u=$(ut_of); yt=$(yt_engine)
  say ""
  say "Discord идёт через utunws. Его стратегии:"
  for (( i=1; i<=NUT; i++ )); do
    printf '  %2d  %-10s' "$i" "$(ut_strat_name "$i")"
    [ "$i" = "$u" ] && printf '  %s← сейчас%s' "$B" "$N"
    printf '\n'
  done
  printf 'Стратегия utunws для Discord (Enter — оставить %s): ' "$u"
  read -r n
  case $n in
    '') ;;
    *[!0-9]*) err "Нет такой стратегии"; return 1 ;;
    *) { [ "$n" -ge 1 ] && [ "$n" -le "$NUT" ]; } || { err "Нет такой стратегии"; return 1; }; u=$n ;;
  esac
  printf 'YouTube через tpws или utunws? [t/u] (Enter — оставить %s): ' "$yt"
  read -r n
  case $n in
    t|T|т|Т|tpws) yt=tpws ;;
    u|U|г|Г|utunws) yt=utunws ;;
  esac
  cfg_set UT_D "$(ut_strat_name "$u")"; cfg_set YT "$yt"
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
      # что идёт через tpws: всё, а с utunws — только YouTube, и то если он не через utunws
      if ! ut_active || [ "$(yt_engine)" = tpws ]; then
        if start_test cur "$PHYS_IP"; then
          ut_active && { CHECK_ONLY=Y; say "   ${D}YouTube — через tpws:${N}"; }
          run_checks "socks:$TEST_PORT"; CHECK_ONLY=""
          print_checks
        fi
        stop_test
      fi
      if ut_test_on; then
        CHECK_ONLY=D
        if [ "$(yt_engine)" = utunws ]; then CHECK_ONLY=""; say "   ${D}YouTube и Discord — через utunws:${N}"
        else say "   ${D}Discord — через utunws:${N}"; fi
        run_checks utun; CHECK_ONLY=""
        print_checks
        ut_test_off
      fi
      test_env_down
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
  else ok "YouTube и Discord открываются (YouTube — $(yt_desc), Discord — $(ds_desc))."
  fi
}

cmd_status() {
  local mode n v
  mode=$(cfg MODE transparent)
  say ""
  if [ -x "$TPWS" ]; then ok "tpws установлен: $(cat "$DIR/zapret-version" 2>/dev/null) · zapret-mac $ZM_VERSION"; else warn "tpws ещё не установлен"; fi
  say "   Режим: $(mode_name)"
  say "   YouTube — $(yt_desc), Discord — $(ds_desc); остальные сайты из списков — tpws, $(strat_name "$(strat_of D)")"
  if job_loaded "$LBL_TPWS" && tpws_up "$mode"; then ok "tpws работает на 127.0.0.1:$(main_port "$mode")"
  elif job_loaded "$LBL_TPWS"; then warn "tpws запущен, но порт $(main_port "$mode") не отвечает — смотри лог: $LOGS/tpws.log"
  else say "   tpws не запущен"; fi
  if [ "$(cfg UTUNWS 1)" != 1 ]; then say "   utunws для Discord выключен в настройках (пункт 9 → 5)"
  elif [ ! -x "$UTUNWS" ]; then warn "utunws не установлен — Discord идёт через tpws. Установить — пункт 13 «Обновить»"
  elif [ "$mode" != transparent ]; then say "   utunws не используется: он работает только в прозрачном режиме"
  elif ut_up; then ok "utunws работает на $UT_IF ($(cat "$DIR/utunws-version" 2>/dev/null)): Discord — $(ut_strat_name "$(ut_of)")$([ "$(yt_engine)" = utunws ] && printf ', YouTube — тоже через него')"
  elif job_loaded "$LBL_UT"; then warn "utunws запущен, но $UT_IF не поднялся — смотри лог: $LOGS/utunws.log"
  else say "   utunws не запущен"; fi
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
  else say "   Сейчас: выключен — включается в «Настройках» (пункт 9). ${D}Может сломать сайты, которые и так работали.${N}"; fi
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
    say "  5  Discord через utunws (поддельные пакеты, звонки): $([ "$(cfg UTUNWS 1)" = 1 ] && echo "${G}вкл${N}" || echo выкл)"
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
      5) if [ "$(cfg UTUNWS 1)" = 1 ]; then cfg_set UTUNWS 0; else cfg_set UTUNWS 1; ut_ensure; fi
         if [ -f "$PL_TPWS" ]; then
           fw_loaded && fw_on   # выключили — сначала убрать правила utunws, потом его самого
           ut_apply
           fw_loaded && fw_on   # включили — правила добавятся, когда utunws поднялся
           if ut_active; then ok "Discord идёт через utunws"; else ok "Discord идёт через tpws"; fi
         fi ;;
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
  # utunws обновляется вместе со скриптом: версия и контрольные суммы зашиты в него
  if [ "$(cfg UTUNWS 1)" = 1 ]; then
    if ut_files_ok; then ok "utunws $UTUNWS_TAG на месте"
    else install_utunws || warn "utunws не обновлён — Discord пойдёт через tpws."; fi
  fi
  lists_update
  [ -f "$PL_TPWS" ] && cmd_start
  return 0
}

# tpws сам перечитывает изменившиеся списки — перезапускать его не нужно
lists_update() {
  say "Обновляю списки доменов Flowseal…"
  if fetch_list list-google.txt "$LISTS/list-youtube.txt" "$HDR_YT" &&
     fetch_list list-general.txt "$LISTS/list-general.txt" "$HDR_GEN" &&
     fetch_list list-exclude.txt "$LISTS/list-exclude.txt" "$HDR_EX"; then
    ok "Списки обновлены"
  else
    warn "Списки не скачались целиком — оставил прежние"
    return 1
  fi
}

cmd_uninstall() {   # $1 = yes — не спрашивать (из приложения)
  local a=${1:-}
  if [ "$a" != yes ]; then
    printf 'Удалить zapret-mac полностью? [y/N] '
    read -r a
    case $a in y|Y|д|Д|yes|да) ;; *) return ;; esac
  fi
  cmd_stop
  [ -f "$DNS_BACKUP" ] && cmd_dns
  pf_conf_unpatch
  migrate_v1 >/dev/null 2>&1
  rm -rf "$DIR"
  rm -f "$PL_TPWS" "$PL_WD" "$PL_UT" "$SUDOERS"
  if [ -n "$RHOME" ] && [ -f "$(ds_agent)" ]; then
    launchctl bootout "gui/$(id -u "$RUSER")/$LBL_DS" >/dev/null 2>&1
    rm -f "$(ds_agent)"
  fi
  [ -n "$SHORTCUT" ] && grep -qF "$SELF" "$SHORTCUT" 2>/dev/null && rm -f "$SHORTCUT"
  ok "zapret-mac удалён. Сеть вернулась к обычным настройкам."
}

# ─── команды для приложения в строке меню ────────────────────────────
# Приложение Zapret запускает их через sudo -n (правило ставит gui-install) и показывает
# их вывод, пока они работают. Состояние читает командой info — она работает без root.

# Включить. В знакомой сети сначала ставим её стратегии; сохранённые проверяются за
# секунды, полный подбор — только если они не открывают YouTube или Discord
cmd_on() {
  ensure_installed
  rm -f "$PAUSE_F"
  # каждое включение снова пробует прозрачный режим: если он не заработает, cmd_start
  # сам перейдёт на SOCKS-прокси, а из SOCKS иначе не было бы пути назад
  [ "$(cfg MODE transparent)" = socks ] && { cfg_set MODE transparent; cfg_set TP_OK 0; }
  [ "$(cfg MODE transparent)" = transparent ] && ut_ensure
  net_load && say "Сеть «${NET_LABEL}» знакома — начинаю с её стратегий."
  SEL_WHO=gui
  if select_strategies auto; then
    say ""
    if [ "$SEL_PATH" = 1 ]; then
      ok "Сохранённые стратегии работают."
      net_save
    elif [ "$SEL_SY" -le 0 ] && [ "$SEL_SD" -le 0 ]; then
      warn "Ни одна стратегия не помогла — включаю с прежними. Что попробовать: DNS Google/Cloudflare, другая сеть, VPN."
    else
      sel_save
      if [ "$SEL_SY" -gt 0 ]; then report_group YouTube "$(yt_desc)" "$SEL_SY" "$NY"; fi
      if [ "$SEL_SD" -gt 0 ]; then report_group Discord "$(ds_desc)" "$SEL_SD" "$ND"; fi
    fi
    log "Подбор: YouTube — $(yt_desc) ($SEL_SY/$NY), Discord — $(ds_desc) ($SEL_SD/$ND)"
  else
    warn "Подобрать стратегии сейчас не получилось — включаю с сохранёнными, сторож проверит их сам."
  fi
  cmd_start
}

cmd_pause() {   # $1 = на сколько минут, 0 — пока не снимут
  local m=${1:-0} u=0
  case $m in ''|*[!0-9]*) die "Укажи минуты: pause 15 (0 — пока не снимешь)" ;; esac
  [ -f "$PL_WD" ] || die "Обход выключен — ставить на паузу нечего."
  [ "$m" -gt 0 ] && u=$(( $(date +%s) + m * 60 ))
  printf '%s\n' "$u" > "$PAUSE_F" && chmod 644 "$PAUSE_F" || die "Не могу записать $PAUSE_F"
  # снимаем сразу, не дожидаясь сторожа; соединения, завёрнутые в tpws, сбрасываем
  if [ "$(cfg MODE transparent)" = transparent ]; then
    fw_loaded && { fw_off; launchctl kickstart -k "system/$LBL_TPWS" >/dev/null 2>&1; }
  else
    proxy_off
  fi
  wd_status paused "$u"
  if [ "$u" = 0 ]; then ok "Пауза — обход снят, пока не снимешь паузу."; else ok "Пауза до $(date -r "$u" '+%H:%M')."; fi
}

cmd_resume() {
  local v
  [ -f "$PAUSE_F" ] || { ok "Паузы нет."; return 0; }
  rm -f "$PAUSE_F"
  if v=$(vpn_iface); then
    wd_status vpn "$v $(vpn_app)"
    ok "Пауза снята. Сейчас включён VPN — обход вернётся, когда его выключишь."
    return 0
  fi
  if [ "$(cfg MODE transparent)" = transparent ]; then fw_on >/dev/null 2>&1; else proxy_on >/dev/null 2>&1; fi
  wd_status direct
  : > "$RUN/check-soon"
  ok "Пауза снята — обход снова работает."
}

# свои сайты в обходе или нет: список остаётся, меняется только то, получает ли его tpws
cmd_sites() {
  case ${1:-} in on) cfg_set USER_SITES 1 ;; off) cfg_set USER_SITES 0 ;; *) die "sites on|off" ;; esac
  if [ -f "$PL_TPWS" ]; then tpws_apply "$(cfg MODE transparent)" || return 1; fi
  if [ "$1" = on ]; then ok "Свои сайты идут через обход."; else ok "Свои сайты идут напрямую."; fi
  log "Свои сайты: $([ "$1" = on ] && echo включены || echo выключены)"
}

# «https://www.Example.com/path» → «example.com»
dom_norm() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
    sed -E 's|^[a-z][a-z0-9+.-]*://||; s|[/:?#].*$||; s|^www\.||; s|[[:space:]]||g; s|\.$||'
}
dom_ok() {
  case $1 in ''|*[!a-z0-9.-]*|.*|*.|*..*|-*|*.-*|*-.*) return 1 ;; esac
  case $1 in *.*) [ "${#1}" -le 253 ] ;; *) return 1 ;; esac
}

# домены — в list-user.txt; поддомены tpws учитывает сам, перезапуск не нужен
cmd_site_add() {
  local d f="$LISTS/list-user.txt" added=""
  ensure_installed
  [ $# -gt 0 ] || die "Укажи домен: site-add example.com"
  [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ] && printf '\n' >> "$f"
  for d in "$@"; do
    d=$(dom_norm "$d")
    if ! dom_ok "$d"; then err "Это не похоже на домен: $d"; continue; fi
    if grep -qxF "$d" "$f" 2>/dev/null; then ok "$d уже в своих сайтах"; continue; fi
    grep -qxF "$d" "$LISTS/list-exclude.txt" "$LISTS/list-exclude-mac.txt" "$LISTS/list-exclude-user.txt" 2>/dev/null &&
      warn "$d в списке исключений — обход его не тронет, пока он там"
    printf '%s\n' "$d" >> "$f"
    added="$added $d"
    ok "$d добавлен вместе с поддоменами"
  done
  [ -n "$added" ] && log "Свои сайты: добавлены$added"
  return 0
}

cmd_site_del() {
  local d f="$LISTS/list-user.txt" tmp
  for d in "$@"; do
    d=$(dom_norm "$d")
    dom_ok "$d" && grep -qxF "$d" "$f" 2>/dev/null || continue
    tmp=$(mktemp /tmp/zapret-mac-ul.XXXXXX) || return 1
    grep -vxF "$d" "$f" > "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"
    ok "$d убран из своих сайтов"
    log "Свои сайты: убран $d"
  done
  return 0
}

cmd_sites_select() {
  ensure_installed
  SEL_WHO=gui
  if ! sites_select; then
    warn "Ни одна стратегия не открыла свои сайты. Возможно, они закрыты по адресу — тогда поможет только VPN."
    return 1
  fi
  cfg_set S_D "$(strat_name "$SEL_D")"
  net_save
  say ""
  report_group "Свои сайты" "$(us_desc)" "$SEL_SU" "$NU"
  log "Подбор для своих сайтов: $(us_desc), $SEL_SU/$NU"
  [ -f "$PL_TPWS" ] && tpws_apply "$(cfg MODE transparent)"
  return 0
}

cmd_debug() {   # on|off — подробный журнал tpws и utunws (для разбора, потом выключить)
  case ${1:-} in on) cfg_set DEBUG 1 ;; off) cfg_set DEBUG 0 ;; *) die "debug on|off" ;; esac
  if [ -f "$PL_TPWS" ]; then
    tpws_apply "$(cfg MODE transparent)" || return 1
    [ -f "$PL_UT" ] && { ut_apply || return 1; fw_loaded && fw_on >/dev/null 2>&1; }
  fi
  ok "Подробный журнал tpws и utunws: $([ "$1" = on ] && echo включён || echo выключен)"
}

# Провайдер подделывает ответы публичных DNS: с августа 2026 года ТСПУ перехватывает
# UDP-запросы к 8.8.8.8 и 1.1.1.1 и на youtube.com отвечает «такого домена нет».
# С такими DNS YouTube не откроется ни с каким обходом
dns_spoofed() {
  local st
  st=$(/usr/bin/dig +time=2 +tries=1 www.youtube.com A @8.8.8.8 2>/dev/null | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1)
  [ "$st" = NXDOMAIN ]
}

cmd_dns_set() {   # on|off
  case ${1:-} in
    on)  [ -f "$DNS_BACKUP" ] && { ok "DNS уже Google/Cloudflare."; return 0; }
         if dns_spoofed; then
           err "Провайдер подменяет ответы 8.8.8.8 и 1.1.1.1 (YouTube «не существует») — DNS оставил как был."
           return 1
         fi ;;
    off) [ -f "$DNS_BACKUP" ] || { ok "DNS и так как был."; return 0; } ;;
    *)   die "dns on|off" ;;
  esac
  cmd_dns
  rm -f "$RUN/dns-spoof"
  log "DNS: $([ "$1" = on ] && echo Google/Cloudflare || echo как был)"
}

# итог проверки для приложения — $RUN/check; $1 = через что проверяли: bypass|vpn|direct
check_save() {
  local i
  [ -w "$RUN" ] || return 0
  { printf 'check_time=%s\ncheck_via=%s\n' "$(date +%s)" "$1"
    for (( i=0; i<NT; i++ )); do
      [ "${LAST_RC[$i]}" = skip ] || printf 'chk=%s|%s|%s|%s\n' "${LAST_RC[$i]}" "${TARGETS[$i]%%|*}" "$(t_label "${TARGETS[$i]}")" \
        "$([ "${LAST_RC[$i]}" = fail ] && curl_why "${LAST_CODE[$i]}")"
    done
  } > "$RUN/check.new" && chmod 644 "$RUN/check.new" && mv -f "$RUN/check.new" "$RUN/check"
}
check_line() {   # «YouTube 3/3 · Discord 5/5 · свои сайты 1/2 — не открылось: x.com (тайм-аут)»
  local s="YouTube $SCORE_Y/$NY · Discord $SCORE_D/$ND" f="" i
  [ "$NU" -gt 0 ] && s="$s · свои сайты $SCORE_U/$NU"
  for (( i=0; i<NT; i++ )); do
    [ "${LAST_RC[$i]}" = fail ] && f="$f, $(t_label "${TARGETS[$i]}") ($(curl_why "${LAST_CODE[$i]}"))"
  done
  [ -n "$f" ] && s="$s — не открылось: ${f#, }"
  printf '%s' "$s"
}

# проверка в журнал: как сайты открываются у программ прямо сейчас
cmd_check_now() {
  local via=bypass what="через обход"
  if [ ! -f "$PL_TPWS" ] || paused; then via=direct; what="без обхода"
  elif vpn_iface >/dev/null; then via=vpn; what="через VPN"; fi
  if [ "$via" = bypass ] && [ "$(cfg MODE transparent)" = socks ]; then run_checks "socks:$SOCKS_PORT"; else run_checks apps; fi
  print_checks
  check_save "$via"
  log "Проверка $what: $(check_line)"
}

# параметры, с которыми сейчас запущены бы tpws и utunws, — одной строкой
run_args() {
  build_main_args "$(cfg MODE transparent)"
  build_ut_args "$(ut_of)" "$([ "$(yt_engine)" = utunws ] && echo 1)"
  printf '%s\n%s' "${ARGS[*]}" "${UT_ARGS[*]}"
}

# tpws и utunws должны принять каждую стратегию из NEW_TP, NEW_UT, NEW_YT
strat_dry() {
  (
    STRATEGIES=("${NEW_TP[@]}"); UT_STRAT_D=("${NEW_UT[@]}"); UT_YT=$NEW_YT
    NSTRAT=${#STRATEGIES[@]}; NUT=${#UT_STRAT_D[@]}
    for (( i=1; i<=NSTRAT; i++ )); do
      build_test_args "$i" ""
      "$TPWS" "${ARGS[@]}" --dry-run >/dev/null 2>&1 || { err "tpws не принял стратегию $(strat_name "$i")"; exit 1; }
    done
    [ -x "$UTUNWS" ] || exit 0
    for (( i=1; i<=NUT; i++ )); do
      for y in "" 1; do
        build_ut_args "$i" "$y"
        "$UTUNWS" "${UT_ARGS[@]}" --dry-run >/dev/null 2>&1 || { err "utunws не принял стратегию $(ut_strat_name "$i")"; exit 1; }
      done
    done
  )
}

# Свежие стратегии с GitHub и списки Flowseal. Из приложения — кнопка «Обновить
# стратегии», из сторожа — раз в сутки ($1 = auto). tpws и utunws перезапускаются,
# только если поменялись параметры, с которыми они работают
cmd_update_strategies() {
  local tmp before after changed=0 rc res lists=0
  mkdir -p "$RUN"
  mkdir "$RUN/update.lock" 2>/dev/null || { err "Обновление уже идёт."; return 1; }
  [ "${1:-}" = auto ] && say "$(date '+%d.%m %H:%M:%S') обновление раз в сутки"
  say "Скачиваю стратегии с GitHub…"
  tmp=$(mktemp /tmp/zapret-mac-strat.XXXXXX) || { rmdir "$RUN/update.lock"; return 1; }
  curl -fsSL --connect-timeout 10 --max-time 30 -o "$tmp" "$STRAT_URL" 2>/dev/null; rc=$?
  if [ "$rc" = 22 ]; then
    res="на GitHub нет файла стратегий — остались версии $STRAT_VER"
  elif [ "$rc" != 0 ]; then
    res="GitHub не ответил — остались стратегии версии $STRAT_VER"
  elif ! strat_parse "$tmp"; then
    res="файл стратегий с GitHub не прошёл проверку — остались версии $STRAT_VER"
  elif [ "$NEW_VER" -le "$STRAT_VER" ]; then
    res="стратегии актуальны (версия $STRAT_VER)"; changed=-1
  elif ! strat_dry; then
    res="новые стратегии не подошли tpws или utunws — остались версии $STRAT_VER"
  else
    before=$(run_args)
    if install -m 644 -o root -g wheel "$tmp" "$STRAT_FILE"; then
      strat_reload
      changed=1
      res="стратегии обновлены до версии $STRAT_VER"
    else
      res="не смог записать $STRAT_FILE"
    fi
  fi
  rm -f "$tmp"
  lists_update && lists=1
  date +%s > "$RUN/strat-updated" && chmod 644 "$RUN/strat-updated"
  if [ "$changed" = 1 ]; then
    log "Стратегии обновлены до версии $STRAT_VER"
    notify "Стратегии обновлены до версии $STRAT_VER"
    after=$(run_args)
    if [ -f "$PL_TPWS" ] && [ "$before" != "$after" ]; then
      say "Параметры текущих стратегий поменялись — перезапускаю обход."
      tpws_apply "$(cfg MODE transparent)" || log "tpws не запустился с новыми стратегиями"
      if [ -f "$PL_UT" ]; then
        fw_loaded && fw_on >/dev/null 2>&1
        ut_apply || log "utunws не запустился с новыми стратегиями"
        fw_loaded && fw_on >/dev/null 2>&1
      fi
      : > "$RUN/check-soon"   # сторож скоро проверит, открываются ли сайты
    fi
  fi
  rmdir "$RUN/update.lock" 2>/dev/null
  # одна итоговая строка — её приложение показывает как сообщение
  if [ "$lists" = 1 ]; then res="$res, списки обновлены"; else res="$res, списки не скачались"; fi
  if [ "$changed" = 0 ] || [ "$lists" = 0 ]; then warn "$res"; else ok "$res"; fi
  return 0
}

# состояние для приложения строками «ключ=значение»; работает и без root
cmd_info() {
  local st v vi
  printf 'version=%s\n' "$ZM_VERSION"
  if [ ! -f "$PL_TPWS" ]; then st=off
  elif ! pgrep -f "$SELF daemon" >/dev/null 2>&1; then st=nowd
  elif wd_read_state; then st=$WD_ST
  else st=starting; fi
  printf 'state=%s\n' "$st"
  printf 'since=%s\n' "$(stat -f %m "$RUN/status" 2>/dev/null)"
  v=""; [ -f "$RUN/status" ] && read -r _ v < "$RUN/status"
  case $st in
    vpn)    vi=${v%% *}; v=${v#"$vi"}; printf 'vpn=%s\nvpn_app=%s\n' "$vi" "${v# }" ;;
    paused) printf 'pause_until=%s\n' "${v:-0}" ;;
  esac
  printf 'mode=%s\n' "$(cfg MODE transparent)"
  printf 'yt=%s\nds=%s\nus=%s\n' "$(yt_desc)" "$(ds_desc)" "$(us_desc)"
  printf 'user_sites=%s\n' "$(cfg USER_SITES 1)"
  printf 'dns=%s\n' "$([ -f "$DNS_BACKUP" ] && echo 1 || echo 0)"
  [ -f "$DNS_BACKUP" ] && [ -f "$RUN/dns-spoof" ] && printf 'dns_spoof=1\n' 
  printf 'strat_ver=%s\nstrat_updated=%s\n' "$STRAT_VER" "$(cat "$RUN/strat-updated" 2>/dev/null)"
  printf 'tpws_ver=%s\nutunws_ver=%s\nutunws_up=%s\n' "$(cat "$DIR/zapret-version" 2>/dev/null)" \
    "$(cat "$DIR/utunws-version" 2>/dev/null)" "$(ut_up && echo 1 || echo 0)"
  net_id && printf 'net=%s\nnet_known=%s\n' "$NET_LABEL" "$([ -f "$NETS/$NET_ID" ] && echo 1 || echo 0)"
  [ -f "$RUN/progress" ] && printf 'progress=%s\n' "$(cat "$RUN/progress")"
  [ -f "$RUN/check" ] && cat "$RUN/check"
  return 0
}

# Диагностика для разбора, когда «через обход» не открывается ничего: pf, его состояния
# и лимиты, и одни и те же сайты — от пользователя (через перенаправление) и от root
# напрямую через физический интерфейс. Ничего не меняет
cmd_diag() {
  local u url rc t a pu
  say "zapret-mac $ZM_VERSION · режим $(mode_name) · стратегии $STRAT_VER · $(date '+%d.%m %H:%M:%S')"
  say "YouTube — $(yt_desc), Discord — $(ds_desc), свои сайты — $(us_desc)"
  detect_phys; say "Сеть: $PHYS, шлюз $PHYS_GW, адрес $PHYS_IP; VPN: $(vpn_iface || echo нет)"
  say "Состояние сторожа: $(cat "$RUN/status" 2>/dev/null); пауза: $(pause_until || echo нет)"
  say ""; say "── pf"
  pfctl -si 2>/dev/null | grep -E 'Status|current entries|searches|inserts|removals|memory|state-limit|src-limit'
  pfctl -sm 2>/dev/null | grep -E 'states|src-nodes|frags|table-entries'
  say "якоря в основном наборе:"
  { pfctl -sn; pfctl -sr; } 2>/dev/null | grep -E 'anchor' | sed 's/^/   /'
  say "наш якорь $(anchor_main):"
  { pfctl -a "$(anchor_main)" -sn; pfctl -a "$(anchor_main)" -sr; } 2>/dev/null | grep -v '^$' | sed 's/^/   /'
  say "состояний к tpws (127.0.0.1:$TP_PORT): $(pfctl -ss 2>/dev/null | grep -cF "127.0.0.1:$TP_PORT"), всего: $(pfctl -ss 2>/dev/null | grep -c .)"
  if redirect_works; then a=работает; else a="НЕ РАБОТАЕТ"; fi
  say "перехват программ в tpws (своё соединение по своему порту): $a — $REDIR_INFO"
  say "DNS: $(networksetup -getdnsservers Wi-Fi 2>/dev/null | tr '\n' ' ')· 8.8.8.8 на www.youtube.com: $(dns_spoofed && echo 'подделка (NXDOMAIN)' || echo нормально)"
  say ""; say "── процессы"
  say "tpws: $(pgrep -f "$BIN_DIR/tpws" | tr '\n' ' ')· порт $TP_PORT: $(port_bound "$TP_PORT" && echo слушает || echo нет)"
  say "utunws: $(pgrep -f "$UTUNWS" | tr '\n' ' ')· $UT_IF: $(ut_up && echo поднят || echo нет)"
  say ""; say "── сайты: от пользователя (как программы) и от root напрямую через $PHYS"
  pu=$(probe_user)
  # gstatic есть в списке YouTube, но не заблокирован: на нём видно, ломает ли соединения сама нарезка
  for url in "$CONTROL_URL" https://example.com/ https://www.gstatic.com/generate_204 https://www.youtube.com/ https://i.ytimg.com/ https://discord.com/; do
    for a in apps direct; do
      if [ "$a" = apps ]; then
        t=$(sudo -u "$pu" /usr/bin/curl -s -o /dev/null --noproxy '*' --connect-timeout 5 --max-time 8 -A "$UA" \
              -w '%{http_code} %{time_connect}s/%{time_appconnect}s/%{time_total}s %{size_download}B' "$url" 2>/dev/null); rc=$?
      else
        t=$(/usr/bin/curl -s -o /dev/null --noproxy '*' --interface "$PHYS" --connect-timeout 5 --max-time 8 -A "$UA" \
              -w '%{http_code} %{time_connect}s/%{time_appconnect}s/%{time_total}s %{size_download}B' "$url" 2>/dev/null); rc=$?
      fi
      printf '   %-6s %-45s rc=%-3s %s%s\n' "$a" "${url#https://}" "$rc" "$t" "$([ "$rc" != 0 ] && printf ' (%s)' "$(curl_why "$rc")")"
    done
  done
  # транспорт utunws отдельно от DPI: имя example.com провайдер не режет, а адрес — Discord,
  # поэтому запрос уходит в utunws. Открылось напрямую, но не через utunws — utunws не отправляет пакеты
  say ""; say "── utunws: SNI example.com на адрес Discord 162.159.128.233"
  t=$(/usr/bin/curl -s -k -o /dev/null --noproxy '*' --interface "$PHYS" --connect-timeout 5 --max-time 8 \
        --connect-to example.com:443:162.159.128.233:443 -w '%{http_code} %{time_total}s' https://example.com/ 2>/dev/null); rc=$?
  printf '   %-34s rc=%-3s %s\n' "напрямую (root, $PHYS)" "$rc" "$t"
  if ut_active && fw_loaded; then
    t=$(sudo -u "$pu" /usr/bin/curl -s -k -o /dev/null --noproxy '*' --connect-timeout 5 --max-time 8 \
          --connect-to example.com:443:162.159.128.233:443 -w '%{http_code} %{time_total}s' https://example.com/ 2>/dev/null); rc=$?
    printf '   %-34s rc=%-3s %s\n' "через рабочий utunws ($UT_IF)" "$rc" "$t"
  fi
  if ut_files_ok && ! vpn_iface >/dev/null && ut_try_start 1; then
    for u in example.com discord.com; do
      t=$(/usr/bin/curl -s -k -o /dev/null --noproxy '*' --interface "$PHYS" --connect-timeout 5 --max-time 8 \
            --connect-to "$u:443:162.159.128.233:443" -w '%{http_code} %{time_total}s' "https://$u/" 2>/dev/null); rc=$?
      printf '   %-34s rc=%-3s %s\n' "временный utunws, SNI $u" "$rc" "$t"
    done
    ut_try_stop
  fi
  say "состояния pf к сайтам после проверки:"
  pfctl -ss 2>/dev/null | grep -E "127\.0\.0\.1:$TP_PORT|$UT_PEER" | head -12 | sed 's/^/   /'
  say ""; say "── tpws.log"; tail -n 5 "$LOGS/tpws.log" 2>/dev/null | sed 's/^/   /'
  say "── utunws.log"; tail -n 3 "$LOGS/utunws.log" 2>/dev/null | sed 's/^/   /'
}

# Проверка перехвата программ в tpws, которую можно запустить и при включённом VPN: правило
# перехвата не привязано к интерфейсу, поэтому трафик программ, идущий в туннель, проходит тот
# же путь «pf → lo0 → rdr → tpws». Правила грузятся на время проверки в оба якоря по очереди,
# tpws в прозрачном режиме поднимается временный, если основной не такой. Печатает счётчики
# правил pf (сработали ли перехват и rdr) и что увидел tpws. Сторож на это время правила не трогает
cmd_redirect_test() {
  local tp="" log="$LOGS/redirect-test.tpws.log" root ok=""
  mkdir -p "$RUN" "$LOGS"; : > "$RUN/fw-test"
  trap '[ -n "$tp" ] && kill "$tp" 2>/dev/null; rm -f "$RUN/fw-test"; exit 130' INT TERM HUP
  say "VPN: $(vpn_iface || echo нет) · режим: $(mode_name) · PF_ROOT: $(cfg PF_ROOT com.apple)"
  if [ "$(cfg MODE transparent)" = transparent ] && tpws_up transparent; then
    say "tpws: основной, прозрачный, порт $TP_PORT"
  else
    if port_bound "$TP_PORT"; then err "Порт $TP_PORT занят — проверка невозможна"; rm -f "$RUN/fw-test"; return 1; fi
    build_main_args transparent
    "$TPWS" "${ARGS[@]}" --debug=1 > "$log" 2>&1 &
    tp=$!
    if ! wait_bound "$TP_PORT" 60; then err "Временный tpws не запустился:"; tail -n 5 "$log"; kill "$tp" 2>/dev/null; rm -f "$RUN/fw-test"; return 1; fi
    say "tpws: временный, прозрачный, порт $TP_PORT (журнал: $log)"
  fi
  pf_take "$RUN/pf-token-rt"
  for root in zapret-mac com.apple; do
    if [ "$root" = zapret-mac ] && ! pfctl -sn 2>/dev/null | grep -qF 'rdr-anchor "zapret-mac/*"'; then
      say ""; say "── якорь zapret-mac/zapret-mac: точки подключения нет в загруженном наборе pf — пропускаю"; continue
    fi
    FORCE_ROOT=$root
    fw_off
    pf_rules_main | pf_load "$(anchor_main)" || { FORCE_ROOT=""; continue; }
    say ""; say "── якорь $(anchor_main)"
    if redirect_works; then say "   перехват: РАБОТАЕТ"; ok="$ok $root"; else say "   перехват: не работает"; fi
    say "   $REDIR_INFO"
    say "   счётчики (Evaluations/Packets/States):"
    { pfctl -vv -a "$(anchor_main)" -sn; pfctl -vv -a "$(anchor_main)" -sr; } 2>/dev/null |
      awk '/^@/ {r=$0} /Evaluations/ && r ~ /(rdr pass on lo0 inet proto tcp)|(route-to \(lo0 127)/ {print "     " substr(r,1,90); print "       " $0; r=""}'
    fw_off
    FORCE_ROOT=""
  done
  pf_give "$RUN/pf-token-rt"
  if [ -n "$tp" ]; then
    kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
    say ""; say "── временный tpws видел соединений: $(grep -c 'connected from' "$log" 2>/dev/null)"
    grep -E 'connected from|original destination|target|resolv' "$log" 2>/dev/null | head -8 | sed 's/^/   /'
  fi
  # вернуть, как было: в прозрачном режиме без VPN и без паузы правила должны стоять
  if [ -f "$PL_TPWS" ] && [ "$(cfg MODE transparent)" = transparent ] && ! vpn_iface >/dev/null && ! paused; then fw_on >/dev/null 2>&1; fi
  rm -f "$RUN/fw-test"
  trap - INT TERM HUP
  say ""
  if [ -n "$ok" ]; then ok "Перехват работает с якорем:$ok"; else err "Перехват не работает ни с одним якорем"; return 1; fi
}

# Из приложения с правами администратора, один раз: ставит zapret-mac в /opt и правило
# sudo, по которому приложение запускает /opt/zapret-mac/zapret-mac.sh без пароля.
# Скрипт там принадлежит root, так что подменить его, не зная пароля, нельзя. $1 — пользователь
cmd_gui_install() {
  local u=${1:-} tmp
  case $u in ''|root|*[!A-Za-z0-9._-]*) die "Не тот пользователь: $u" ;; esac
  id -u "$u" >/dev/null 2>&1 || die "Нет пользователя $u"
  RUSER=$u; SHORTCUT=""
  RHOME=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  ensure_installed
  [ "$(cfg MODE transparent)" = transparent ] && ut_ensure
  tmp=$(mktemp /tmp/zapret-mac-sudo.XXXXXX) || die "Не могу создать временный файл"
  printf '# zapret-mac: приложение Zapret в строке меню управляет обходом без пароля\n%s ALL=(root) NOPASSWD: %s\n' \
    "$u" "$SELF" > "$tmp"
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; die "visudo не принял правило — sudo не тронут."; fi
  install -m 440 -o root -g wheel "$tmp" "$SUDOERS" || { rm -f "$tmp"; die "Не могу записать $SUDOERS"; }
  rm -f "$tmp"
  grep -qE '^#includedir /(private/)?etc/sudoers\.d' /etc/sudoers 2>/dev/null ||
    warn "В /etc/sudoers нет #includedir — приложению будет нужен пароль."
  log "Установлен из приложения: zapret-mac $ZM_VERSION"
  ok "zapret-mac $ZM_VERSION установлен, приложение управляет им без пароля."
  # обновление снова пробует прозрачный режим, как и «Включить»: SOCKS мог остаться от сбоя
  [ "$(cfg MODE transparent)" = socks ] && { cfg_set MODE transparent; cfg_set TP_OK 0; }
  [ -f "$PL_TPWS" ] && cmd_start   # был включён — перезапускаем с новым кодом
  return 0
}

# ─── сторож (LaunchDaemon от root) ───────────────────────────────────
# Ловит события маршрутизации (route monitor), поэтому VPN замечает сразу:
#   VPN (TUN) включился  → снимает перенаправление, весь трафик идёт в VPN
#   VPN выключился       → возвращает перенаправление, работает обход
#   пауза из приложения  → как при VPN, пока пауза не кончится
#   tpws упал            → снимает перенаправление, чтобы не пропал интернет
#   сменилась сеть       → ставит стратегии, запомненные для этой сети, и скоро проверяет сайты
#   Mac проснулся        → то же, что при смене сети
# Плюс раз в CHECK_EVERY секунд проверяет YouTube и Discord и при сбое сам подбирает
# стратегии в фоне, а раз в сутки скачивает свежие стратегии и списки.
WD_STATE=""; WD_VPN=""; WD_EXTRA=""; WD_APP=""; WD_NET=""; FAILS=0; NEXT_CHECK=0; BACKOFF=$CHECK_EVERY
SEL_PID=""; UPD_PID=""; LAST_FULL=0; LAST_TICK=0; FAIL_NOTIFIED=0; NEXT_UPDATE=0; STRAT_MTIME=""; REDIRECT_NOTIFIED=0

wd_status() { printf '%s %s\n' "$1" "$2" > "$RUN/status.new" && chmod 644 "$RUN/status.new" && mv -f "$RUN/status.new" "$RUN/status"; }

# пауза включена и не кончилась; кончилась — убираем её
pause_until() { local u; [ -f "$PAUSE_F" ] || return 1; read -r u < "$PAUSE_F"; case $u in ''|*[!0-9]*) u=0 ;; esac; printf '%s' "$u"; }
paused() {
  local u
  u=$(pause_until) || return 1
  [ "$u" = 0 ] && return 0
  [ "$(date +%s)" -lt "$u" ] && return 0
  rm -f "$PAUSE_F"
  return 1
}

# какой VPN-клиент держит туннель — для подписи в приложении. Клиенты на Network
# Extension (Happ, V2Box, FoXray, WireGuard) видны в scutil, остальных ищем по процессам
vpn_app() {
  local n
  n=$(scutil --nc list 2>/dev/null | awk -F'"' '/\(Connected\)/ {print $2; exit}')
  [ -z "$n" ] && n=$(ps -axco comm= 2>/dev/null | awk '
    { c = tolower($0) }
    c ~ /^amnezia/  { print "AmneziaVPN"; exit }
    c ~ /incy/      { print "Incy"; exit }
    c ~ /openvpn/   { print "OpenVPN"; exit }
    c ~ /^hiddify/  { print "Hiddify"; exit }
    c ~ /^outline/  { print "Outline"; exit }')
  printf '%s' "${n:-VPN}"
}

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

# событие в $RUN/events («время|текст»): открытое приложение покажет его само,
# а если оно закрыто — уведомление через osascript
notify() {
  local uid
  if [ -w "$RUN" ]; then
    printf '%s|%s\n' "$(date +%s)" "$1" >> "$RUN/events" && chmod 644 "$RUN/events"
    if [ "$(wc -l < "$RUN/events")" -gt 100 ]; then
      tail -n 50 "$RUN/events" > "$RUN/events.tmp" && mv -f "$RUN/events.tmp" "$RUN/events"
    fi
  fi
  uid=$(stat -f %u /dev/console 2>/dev/null)
  [ -n "$uid" ] && [ "$uid" -gt 0 ] || return 0
  pgrep -x -U "$uid" "$APP_PROC" >/dev/null 2>&1 && return 0
  launchctl asuser "$uid" sudo -u "#$uid" /usr/bin/osascript \
    -e "display notification \"$1\" with title \"zapret-mac\"" >/dev/null 2>&1 &
}

reconcile() {   # $1 = full — проверить pf и tpws; без него — только не сменился ли VPN
  local vpn mode st net extra=""
  # идёт redirect-test: правила pf на эти секунды его
  [ -f "$RUN/fw-test" ] && [ $(( $(date +%s) - $(stat -f %m "$RUN/fw-test" 2>/dev/null || echo 0) )) -lt 120 ] && return 0
  vpn=$(vpn_iface)
  [ "$1" = full ] || [ "$vpn" != "$WD_VPN" ] || return 0
  mode=$(cfg MODE transparent)
  if [ -f "$PL_UT" ] && ut_net_changed; then
    log "Сеть сменилась — перезапускаю utunws (он шлёт пакеты на MAC шлюза)"
    launchctl kickstart -k "system/$LBL_UT" >/dev/null 2>&1
  fi
  if paused; then
    st=paused; extra=$(pause_until)
    if [ "$WD_STATE" != paused ]; then
      if [ "$extra" = 0 ]; then log "Пауза — обход снят, пока паузу не снимут"
      else log "Пауза до $(date -r "$extra" '+%H:%M') — обход снят"; fi
      sel_stop
    fi
    if [ "$mode" = transparent ] && fw_loaded; then
      fw_off
      launchctl kickstart -k "system/$LBL_TPWS" >/dev/null 2>&1
    elif [ "$mode" = socks ] && sys_proxy_ours; then
      proxy_off
    fi
  elif [ -n "$vpn" ]; then
    st=vpn
    if [ "$vpn" != "$WD_VPN" ] || [ -z "$WD_APP" ]; then
      WD_APP=$(vpn_app)
      [ "$vpn" != "$WD_VPN" ] && { log "VPN включён ($WD_APP, $vpn) — весь трафик идёт через VPN"; sel_stop; }
    fi
    extra="$vpn $WD_APP"
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
    net=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default" {print $2, $4; exit}')
    if [ "$WD_STATE" != direct ] || [ "$net" != "$WD_NET" ]; then
      [ "$WD_STATE" = direct ] && [ -n "$net" ] && log "Сеть сменилась ($net) — скоро проверю YouTube и Discord"
      [ -n "$net" ] && net_apply
      NEXT_CHECK=$(( SECONDS + 8 )); FAILS=0; BACKOFF=$CHECK_EVERY
    fi
    WD_NET=$net
    if [ "$mode" = transparent ]; then
      if ! fw_loaded || ! pf_on || ! ut_rules_ok; then
        if fw_on >/dev/null 2>&1; then
          if ut_active; then log "Перенаправление pf включено, Discord — через utunws"
          elif ut_wanted; then log "Перенаправление pf включено, utunws не отвечает — Discord пока через tpws"
          else log "Перенаправление pf включено"; fi
        else log "Не удалось включить перенаправление pf"; fi
      fi
    elif ! sys_proxy_ours && ! sys_proxy_other; then
      # VPN-клиент в режиме прокси, выключаясь, сбрасывает и наш прокси — возвращаем
      proxy_on >/dev/null 2>&1 && log "Системный SOCKS-прокси восстановлен"
    fi
  fi
  [ "$st" = vpn ] || WD_APP=""
  if [ "$WD_STATE" = paused ] && [ "$st" != paused ]; then
    if [ "$st" = vpn ]; then log "Пауза кончилась — сейчас включён VPN, обход вернётся без него"
    else log "Пауза кончилась — обход снова работает"; fi
  fi
  { [ "$st" != "$WD_STATE" ] || [ "$extra" != "$WD_EXTRA" ]; } && wd_status "$st" "$extra"
  WD_STATE=$st; WD_VPN=$vpn; WD_EXTRA=$extra
}

# Mac спал: сеть могла смениться, а соединения — оборваться. Как при смене сети:
# стратегии этой сети и скорая проверка
wd_wake() {
  log "Mac проснулся — проверяю сеть и обход"
  WD_NET=""; FAILS=0; BACKOFF=$CHECK_EVERY; NEXT_CHECK=$(( SECONDS + 10 ))
}

sel_start() {
  log "YouTube или Discord не открываются — подбираю стратегии (ход подбора: $LOGS/select.log)"
  rm -f "$RUN/select.result"
  (
    trap 'stop_test; ut_try_stop; prog_done; exit 1' TERM
    SEL_WHO=daemon
    select_strategies auto > "$LOGS/select.log" 2>&1 &&
      printf '%s %s %s %s %s %s %s %s\n' "$SEL_PATH" "$SEL_Y" "$SEL_STY" "$SEL_YT" "$SEL_SY" "$SEL_UT" "$SEL_D" "$SEL_SD" \
        > "$RUN/select.result"
  ) &
  SEL_PID=$!
}

sel_stop() {
  [ -n "$SEL_PID" ] || return 0
  kill "$SEL_PID" 2>/dev/null; wait "$SEL_PID" 2>/dev/null
  SEL_PID=""
  prog_done
  log "Подбор прерван"
}

sel_poll() {
  local r p sy sd old_tp old_ut
  [ -n "$SEL_PID" ] || return 0
  kill -0 "$SEL_PID" 2>/dev/null && return 0
  wait "$SEL_PID" 2>/dev/null; SEL_PID=""
  r=$(cat "$RUN/select.result" 2>/dev/null); rm -f "$RUN/select.result"
  if [ -z "$r" ]; then log "Подбор не удался — подробности в $LOGS/select.log"; return 0; fi
  set -f; set -- $r; set +f
  p=$1; SEL_Y=$2; SEL_STY=$3; SEL_YT=$4; SEL_SY=$5; SEL_UT=$6; SEL_D=$7; SEL_SD=$8
  sy=$SEL_SY; sd=$SEL_SD
  if [ "$p" = 1 ]; then
    log "Стратегии рабочие — перезапускаю tpws, utunws и перенаправление"
    net_save
    fw_off
    launchctl kickstart -k "system/$LBL_TPWS" >/dev/null 2>&1
    [ -f "$PL_UT" ] && launchctl kickstart -k "system/$LBL_UT" >/dev/null 2>&1
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
  old_tp="$(strat_of Y) $(strat_of D)"; old_ut="$(ut_of) $(yt_engine)"
  sel_save   # то, что не открыло ничего, sel_save не сохраняет
  if [ "$old_tp" != "$(strat_of Y) $(strat_of D)" ] || [ "$old_ut" != "$(ut_of) $(yt_engine)" ]; then
    [ "$old_tp" != "$(strat_of Y) $(strat_of D)" ] && { tpws_apply "$(cfg MODE transparent)" >/dev/null 2>&1 || log "tpws не запустился с новыми стратегиями"; }
    if [ "$old_ut" != "$(ut_of) $(yt_engine)" ]; then
      fw_loaded && fw_on >/dev/null 2>&1   # YouTube мог уйти из utunws — сначала правила
      ut_apply >/dev/null 2>&1 || log "utunws не запустился с новыми стратегиями"
      fw_loaded && fw_on >/dev/null 2>&1
    fi
    log "Новые стратегии: YouTube — $(yt_desc) $sy/$NY, Discord — $(ds_desc) $sd/$ND"
    notify "Обход перенастроен: YouTube — $(yt_desc), Discord — $(ds_desc)"
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
  # приложение просит проверить поскорее (сняли паузу, обновились стратегии)
  [ -f "$RUN/check-soon" ] && { rm -f "$RUN/check-soon"; [ "$NEXT_CHECK" -gt $(( SECONDS + 5 )) ] && NEXT_CHECK=$(( SECONDS + 5 )); }
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
  # интернета нет вообще — это не блокировка, подбирать нечего. Сеть после пробуждения
  # поднимается не сразу, поэтому смотрим снова через полминуты
  if ! detect_phys || ! /usr/bin/curl -s -o /dev/null --noproxy '*' --interface "$PHYS" \
       --connect-timeout 5 --max-time 8 "$CONTROL_URL"; then
    NEXT_CHECK=$(( SECONDS + 30 ))
    return 0
  fi
  if [ -f "$DNS_BACKUP" ] && dns_spoofed; then
    if [ ! -f "$RUN/dns-spoof" ]; then
      : > "$RUN/dns-spoof"
      log "Провайдер подменяет DNS Google/Cloudflare — YouTube не откроется, пока их не выключить («Дополнительно»)"
      notify "Провайдер подменяет DNS Google — выключи его в «Дополнительно»"
    fi
  else
    rm -f "$RUN/dns-spoof"
  fi
  # перехват программ в tpws: правила загружены — ещё не значит, что работают (их может
  # перекрыть чужое правило). Не помогла и перезагрузка правил — только сообщаем: SOCKS-прокси
  # выключил бы utunws, а с ним рабочие YouTube и Discord. «Включить» проверит заново и при
  # настоящей поломке сам перейдёт на SOCKS
  if [ "$(cfg MODE transparent)" = transparent ] && ! redirect_works; then
    log "Программы идут мимо tpws ($REDIR_INFO) — перезагружаю правила pf"
    fw_off; fw_on >/dev/null 2>&1
    if redirect_works; then
      log "Перехват в tpws снова работает"
    elif [ "$REDIRECT_NOTIFIED" != 1 ]; then
      REDIRECT_NOTIFIED=1
      log "Перехват в tpws не работает и после перезагрузки правил ($REDIR_INFO) — свои сайты идут напрямую"
      notify "Свои сайты идут мимо обхода — нажми «Выключить» и «Включить»"
    fi
  else
    REDIRECT_NOTIFIED=0
  fi
  if [ "$(cfg MODE transparent)" = socks ]; then run_checks "socks:$SOCKS_PORT"; else run_checks apps; fi
  check_save bypass
  log "Проверка: $(check_line)"
  if [ "$SCORE_Y" -eq "$NY" ] && [ "$SCORE_D" -eq "$ND" ]; then
    FAILS=0; FAIL_NOTIFIED=0; BACKOFF=$CHECK_EVERY
    return 0
  fi
  FAILS=$(( FAILS + 1 ))
  # диагностику — сразу, пока сеть в том же состоянии, и в файл: если перенаправление
  # ломает соединения, посмотреть её можно будет и потом. Отдельным процессом — она идёт с минуту
  if [ "$FAILS" = 1 ] && [ $(( $(date +%s) - $(stat -f %m "$LOGS/diag.log" 2>/dev/null || echo 0) )) -gt 600 ]; then
    ( cmd_diag > "$LOGS/diag.log.new" 2>&1 && mv -f "$LOGS/diag.log.new" "$LOGS/diag.log" ) &
    log "Диагностика — в $LOGS/diag.log"
  fi
  if [ "$FAILS" -lt 2 ]; then NEXT_CHECK=$(( SECONDS + 45 )); return 0; fi   # перепроверить, вдруг случайность
  FAILS=0
  sel_start
}

# раз в сутки — свежие стратегии и списки. Отдельным процессом: скачивание может занять
# минуту, а сторож тем временем должен замечать VPN
upd_tick() {
  local last
  if [ -n "$UPD_PID" ]; then
    kill -0 "$UPD_PID" 2>/dev/null && return 0
    wait "$UPD_PID" 2>/dev/null; UPD_PID=""
  fi
  [ "$SECONDS" -ge "$NEXT_UPDATE" ] || return 0
  NEXT_UPDATE=$(( SECONDS + 3600 ))
  [ -z "$SEL_PID" ] || return 0
  case $WD_STATE in direct|vpn|paused) ;; *) return 0 ;; esac
  last=$(cat "$RUN/strat-updated" 2>/dev/null)
  case $last in ''|*[!0-9]*) last=0 ;; esac
  [ $(( $(date +%s) - last )) -ge "$UPDATE_EVERY" ] || return 0
  /bin/bash "$SELF" update-strategies auto >> "$LOGS/update.log" 2>&1 &
  UPD_PID=$!
}

# strategies.conf поменялся (обновление из приложения или upd_tick) — перечитываем
strat_watch() {
  local m
  m=$(stat -f %m "$STRAT_FILE" 2>/dev/null)
  [ "$m" = "$STRAT_MTIME" ] && return 0
  STRAT_MTIME=$m
  strat_reload
}

log_rotate() {
  local f
  for f in "$LOGS/watchdog.log" "$LOGS/watchdog.err" "$LOGS/tpws.log" "$LOGS/utunws.log" "$LOGS/update.log"; do
    [ -f "$f" ] && [ "$(stat -f %z "$f" 2>/dev/null || echo 0)" -gt 524288 ] || continue
    tail -n 2000 "$f" > "$f.tmp" && cat "$f.tmp" > "$f"; rm -f "$f.tmp"
  done
}

daemon_main() {
  local line t0 ev
  [ "$(id -u)" -eq 0 ] || die "Сторож запускается только из launchd."
  mkdir -p "$LOGS" "$RUN"
  CHECK_LIGHT=1
  log "Сторож запущен (zapret-mac $ZM_VERSION, режим: $(mode_name), стратегии: версия $STRAT_VER)"
  pf_give "$RUN/pf-token"   # токен от прошлого запуска — новый возьмём ниже
  # остатки подбора и обновления, прерванных вместе с терминалом
  pfctl -q -a "$(anchor_test)" -F all >/dev/null 2>&1; pf_give "$RUN/pf-token-test"
  rm -f "$RUN/progress"; rmdir "$RUN/update.lock" 2>/dev/null
  STRAT_MTIME=$(stat -f %m "$STRAT_FILE" 2>/dev/null)
  NEXT_UPDATE=$(( SECONDS + 120 ))   # первое обновление — через пару минут после запуска
  trap 'sel_stop; [ -n "$UPD_PID" ] && kill "$UPD_PID" 2>/dev/null; log "Сторож остановлен"; exit 0' TERM INT
  reconcile full; LAST_FULL=$SECONDS
  exec 3< <(exec route -n monitor 2>/dev/null)
  LAST_TICK=$SECONDS
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
    # read ждёт не дольше 5 секунд; если с прошлого круга прошло больше полуминуты — Mac спал
    if [ $(( SECONDS - LAST_TICK )) -gt 30 ]; then wd_wake; LAST_FULL=0; fi
    [ "$ev" = 1 ] && reconcile
    if [ $(( SECONDS - LAST_FULL )) -ge 5 ]; then
      strat_watch
      reconcile full; LAST_FULL=$SECONDS
      health_tick
      upd_tick
      log_rotate
    fi
    LAST_TICK=$SECONDS
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
  say "Устанавливаю zapret-mac $ZM_VERSION в ${DIR}…"
  sudo -n true 2>/dev/null || say "${D}Нужен пароль от Mac (при вводе символы не видны).${N}"
  sudo /bin/bash "$me" install || die "Установка не удалась."
}

menu_status() {
  local st="" v="" names
  [ -f "$PL_TPWS" ] || { printf '%sвыключен%s' "$D" "$N"; return; }
  [ -f "$RUN/status" ] && read -r st v < "$RUN/status"
  names="YouTube — $(yt_desc), Discord — $(ds_desc)"
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
    say "  9  Настройки: QUIC, автоподбор, режим, utunws"
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
  say "Для приложения: on|off|pause МИНУТ|resume|info|check-now|diag|redirect-test|debug on|off|update-strategies|sites on|off|site-add ДОМЕН…|site-del ДОМЕН…|sites-select|dns on|off|uninstall yes|gui-install ПОЛЬЗОВАТЕЛЬ"
}

# для тестов: ZM_LIB=1 . zapret-mac.sh — подключить функции, ничего не запуская
[ "${ZM_LIB:-}" = 1 ] && { return 0 2>/dev/null || exit 0; }

# долгие команды из приложения пишут ход ещё и в select.log: его видно в журналах приложения
# SIGPIPE не ловим: если приложение закроется на середине, скрипт всё равно уберёт за собой
to_select_log() { trap '' PIPE; mkdir -p "$LOGS" && exec > >(tee "$LOGS/select.log") 2>&1; }

if [ "$(id -u)" -eq 0 ]; then
  case "${1:-}" in
    ""|menu|discord|discord-auto|autostart) die "Меню и Discord запускай без sudo: bash $0 — пароль скрипт спросит сам." ;;
    install)   cmd_install ;;
    auto)      cmd_auto ;;
    start)     cmd_start ;;
    stop|off)  cmd_stop ;;
    restart)   cmd_stop; cmd_start ;;
    test)      cmd_test "${2:-}" ;;
    choose)    cmd_choose ;;
    check)     cmd_check ;;
    status)    cmd_status ;;
    add)       cmd_add ;;
    autolist)  cmd_autolist ;;
    settings)  cmd_settings ;;
    dns)       if [ -n "${2:-}" ]; then cmd_dns_set "$2"; else cmd_dns; fi ;;
    update)    cmd_update ;;
    uninstall) cmd_uninstall "${2:-}" ;;
    on)        to_select_log; cmd_on ;;
    pause)     cmd_pause "${2:-0}" ;;
    resume)    cmd_resume ;;
    info)      cmd_info ;;
    check-now) cmd_check_now ;;
    diag)      cmd_diag ;;
    redirect-test) cmd_redirect_test ;;
    debug)     cmd_debug "${2:-}" ;;
    update-strategies) cmd_update_strategies "${2:-}" ;;
    sites)     cmd_sites "${2:-}" ;;
    site-add)  shift; cmd_site_add "$@" ;;
    site-del)  shift; cmd_site_del "$@" ;;
    sites-select) to_select_log; cmd_sites_select ;;
    gui-install) cmd_gui_install "${2:-}" ;;
    daemon)    daemon_main ;;
    utunws-run) ut_run ;;
    *)         usage ;;
  esac
else
  case "${1:-}" in
    ""|menu)        user_bootstrap; menu ;;
    discord)        cmd_discord ;;
    discord-auto)   cmd_discord_auto ;;
    autostart)      cmd_ds_autostart ;;
    info)           cmd_info ;;
    daemon|utunws-run) die "Это запускает только launchd." ;;
    help|-h|--help) usage ;;
    *)              user_bootstrap; as_root "$@" ;;
  esac
fi
