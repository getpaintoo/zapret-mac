#!/bin/bash
# Проверяет разбор strategies.conf: файл из репозитория принимается целиком и совпадает
# со встроенными стратегиями скрипта, а строки, которые могли бы навредить (стратегия
# без списка доменов, пути к файлам, чужие опции), отклоняются. Работает без root.
#
#   bash tests/strategies.sh

here=$(cd "$(dirname "$0")/.." && pwd)
ZM_STRAT=/nonexistent ZM_LIB=1 . "$here/zapret-mac.sh"

fails=0
t() {   # $1 = ожидание (ok|bad), $2 = описание, дальше — строки файла
  local want=$1 what=$2 f got
  shift 2
  f=$(mktemp /tmp/zapret-mac-strat-test.XXXXXX) || exit 1
  printf '%s\n' "$@" > "$f"
  if strat_parse "$f"; then got=ok; else got=bad; fi
  rm -f "$f"
  [ "$got" = "$want" ] && return 0
  echo "FAIL: $what — ждал $want, вышло $got"
  fails=$(( fails + 1 ))
}

V="version|2026102301"
UT="ut|X|--dpi-desync=fake"
YT="utyt|Y|--dpi-desync=hostfakesplit"
TP="tpws|A|@HL --split-pos=1 --disorder"

# файл из репозитория — те же стратегии, что встроены в скрипт
if strat_parse "$here/strategies.conf"; then
  [ "${NEW_TP[*]}" = "${BUILTIN_TP[*]}" ] || { echo "FAIL: tpws в strategies.conf не совпадают со встроенными"; fails=$(( fails + 1 )); }
  [ "${NEW_UT[*]}" = "${BUILTIN_UT[*]}" ] || { echo "FAIL: utunws в strategies.conf не совпадают со встроенными"; fails=$(( fails + 1 )); }
  [ "$NEW_YT" = "$UT_YT" ] || { echo "FAIL: utyt в strategies.conf не совпадает со встроенной"; fails=$(( fails + 1 )); }
  [ "$NEW_VER" = "$STRAT_VER" ] || { echo "FAIL: версия strategies.conf ($NEW_VER) не равна встроенной ($STRAT_VER)"; fails=$(( fails + 1 )); }
else
  echo "FAIL: strategies.conf из репозитория не прошёл разбор"; fails=$(( fails + 1 ))
fi

t ok  "минимальный файл"                 "$V" "$TP" "$UT" "$YT"
t ok  "комментарии и пустые строки"      "# x" "" "$V" "$TP" "$UT" "$YT"
t ok  "два блока tpws"                   "$V" "tpws|B|@HL --filter-l7=tls --split-pos=1 --new @HL --hostcase" "$UT" "$YT"
t ok  "поддельный пакет из папки utunws" "$V" "$TP" "ut|S|--dpi-desync=fake --dpi-desync-fake-tls=@F/tls_clienthello_www_google_com.bin" "$YT"
t bad "нет версии"                       "$TP" "$UT" "$YT"
t bad "нет стратегий utunws"             "$V" "$TP" "$YT"
t bad "нет utyt"                         "$V" "$TP" "$UT"
t bad "tpws без @HL — трогал бы все сайты" "$V" "tpws|A|--split-pos=1 --disorder" "$UT" "$YT"
t bad "второй блок tpws без @HL"         "$V" "tpws|A|@HL --split-pos=1 --new --disorder" "$UT" "$YT"
t bad "свой список доменов"              "$V" "tpws|A|@HL --hostlist=/etc/passwd" "$UT" "$YT"
t bad "чужой пользователь"               "$V" "tpws|A|@HL --user=root" "$UT" "$YT"
t bad "отладка в файл"                   "$V" "$TP" "ut|X|--dpi-desync=fake --debug=@/tmp/x" "$YT"
t bad "поддельный пакет по своему пути"  "$V" "$TP" "ut|X|--dpi-desync=fake --dpi-desync-fake-tls=/etc/hosts" "$YT"
t bad "выход из папки utunws"            "$V" "$TP" "ut|X|--dpi-desync-fake-tls=@F/../../etc/hosts" "$YT"
t bad "ipset у utunws"                   "$V" "$TP" "ut|X|--dpi-desync=fake --ipset=/tmp/x" "$YT"
t bad "команда оболочки"                 "$V" "tpws|A|@HL ;rm -rf /" "$UT" "$YT"
t bad "подстановка"                      "$V" "tpws|A|@HL --split-pos=\$(id)" "$UT" "$YT"
t bad "кавычки"                          "$V" "tpws|A|@HL --split-pos='1'" "$UT" "$YT"
t bad "название с пробелом"              "$V" "tpws|A B|@HL --split-pos=1" "$UT" "$YT"
t bad "неизвестный вид"                  "$V" "$TP" "$UT" "$YT" "nfqws|Z|--dpi-desync=fake"
t bad "версия не числом"                 "version|v2" "$TP" "$UT" "$YT"
t bad "строка без параметров"            "$V" "tpws|A" "$UT" "$YT"

# bash 3.2 под UTF-8 считает русские буквы, «» и … частью имени переменной: в "«$x»" подставится
# пустая переменная x». Такие места пишутся как ${x}
bad=$(perl -ne 'print "$ARGV:$.: $&\n" if !/^\s*#/ && /\$[A-Za-z_]\w*(?=[\x80-\xff])/; close ARGV if eof' \
        "$here/zapret-mac.sh" "$here/app/build.sh" "$here"/tests/*.sh)
[ -z "$bad" ] || { echo "FAIL: переменная вплотную к не-ASCII символу, нужны фигурные скобки:"; echo "$bad"; fails=$(( fails + 1 )); }

echo "Ошибок: $fails"
[ "$fails" -eq 0 ]
