#!/bin/bash
# Проверяет, что tpws принимает все стратегии zapret-mac: основной процесс
# в обоих режимах (с автосписком и без) и временный процесс для подбора.
# Если указан utunws — что он принимает все его стратегии, с YouTube и без
# (поддельные пакеты должны лежать рядом с ним). Работает без root и ничего в системе не меняет.
#
#   ZM_TPWS=/путь/к/tpws [ZM_UTUNWS=/путь/к/utunws] bash tests/dry-run.sh

here=$(cd "$(dirname "$0")/.." && pwd)
[ -x "${ZM_TPWS:-}" ] || { echo "Укажи tpws: ZM_TPWS=/путь/к/tpws bash $0" >&2; exit 2; }

ZM_LIB=1 . "$here/zapret-mac.sh"

tmp=$(mktemp -d /tmp/zapret-mac-test.XXXXXX) || exit 1
trap 'rm -rf "$tmp"' EXIT
LISTS="$tmp/lists"; CONF="$tmp/config"
: > "$CONF"
write_lists

# --user=root и --user=nobody без root не проверить — убираем только их
dry() {
  local a out
  local -a A=()
  for a in "${ARGS[@]}"; do case $a in --user=*) ;; *) A+=("$a") ;; esac; done
  out=$("$TPWS" "${A[@]}" --dry-run 2>&1) && return 0
  printf '%s\n' "$out" | tail -n 2
  return 1
}

fails=0 runs=0
for mode in transparent socks; do
  for auto in 0 1; do
    cfg_set AUTOLIST "$auto"
    for (( y=1; y<=NSTRAT; y++ )); do
      cfg_set S_Y "$y"; cfg_set S_D $(( y % NSTRAT + 1 ))
      build_main_args "$mode"
      runs=$(( runs + 1 ))
      dry || { echo "FAIL: основной tpws, $mode, автосписок=$auto, YouTube=$y"; fails=$(( fails + 1 )); }
    done
  done
done
for s in $(seq 1 "$NSTRAT") cur; do
  build_test_args "$s" 192.168.0.10
  runs=$(( runs + 1 ))
  dry || { echo "FAIL: tpws для подбора, стратегия $s"; fails=$(( fails + 1 )); }
done

if [ -x "${ZM_UTUNWS:-}" ]; then
  for (( u=1; u<=NUT; u++ )); do
    for yt in "" 1; do
      build_ut_args "$u" "$yt"
      A=()
      for a in "${UT_ARGS[@]}"; do case $a in --user=*) ;; *) A+=("$a") ;; esac; done
      runs=$(( runs + 1 ))
      if ! out=$("$UTUNWS" "${A[@]}" --dry-run 2>&1); then
        printf '%s\n' "$out" | tail -n 2
        echo "FAIL: utunws, стратегия $u ($(ut_strat_name "$u")), YouTube=${yt:-0}"; fails=$(( fails + 1 ))
      fi
    done
  done
else
  echo "utunws не указан (ZM_UTUNWS) — его параметры не проверены"
fi

echo "Проверено наборов параметров: $runs, ошибок: $fails"
[ "$fails" -eq 0 ]
