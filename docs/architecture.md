# Как устроен zapret-mac

Весь проект — один файл `zapret-mac.sh`. Меню и команда `discord` работают от имени пользователя, всё остальное скрипт перезапускает через `sudo` из установленной копии `/opt/zapret-mac/zapret-mac.sh`. Папка принадлежит root: её запускают системные демоны, и править её может только администратор.

## Компоненты

| Компонент | Как запущен | Что делает |
|---|---|---|
| tpws | LaunchDaemon `com.zapret-mac.tpws`, от root | прозрачный прокси на `127.0.0.1:988` (или SOCKS на `127.0.0.1:1080` в запасном режиме) |
| utunws | LaunchDaemon `com.zapret-mac.utunws` (`zapret-mac.sh utunws-run`), после запуска от `nobody` | Discord: получает пакеты из `utun50`, добавляет поддельные, отправляет через BPF |
| сторож | LaunchDaemon `com.zapret-mac.watchdog` (`zapret-mac.sh daemon`) | следит за VPN и tpws, включает и снимает правила pf, проверяет сайты |
| правила pf | якорь `com.apple/zapret-mac` или `zapret-mac/zapret-mac` | заворачивают TCP 80/443 в tpws, Discord — в utunws, глушат QUIC к Google и Discord |

## Профили tpws

Основной tpws получает два-три профиля, разделённых `--new`:

1. `list-youtube.txt` со стратегией YouTube (`S_Y` в настройках);
2. `list-general.txt` и `list-user.txt` со стратегией Discord (`S_D`);
3. `--hostlist-auto` — только если автосписок включён (`AUTOLIST=1`).

Во всех профилях действуют исключения: `list-exclude.txt` (Flowseal), `list-exclude-mac.txt` (службы Apple) и `list-exclude-user.txt`. Сайты не из списков проходят через tpws без изменений.

На macOS tpws не принимает `--oob` вместе с `--disorder` для одного протокола (это работает только в Linux), поэтому OOB-стратегии здесь без disorder. `tests/dry-run.sh` проверяет, что tpws принимает все стратегии.

## utunws

utunws — nfqws из zapret v72.13 с macOS-входом и выходом из [Flowseal/zapret-mac-discord-youtube](https://github.com/Flowseal/zapret-mac-discord-youtube). Скрипт скачивает релиз Flowseal (`UTUNWS_TAG`) и сверяет SHA-256 четырёх файлов: `utunws`, `tls_clienthello_www_google_com.bin`, `tls_clienthello_4pda_to.bin`, `ACTIVE_DISCORD_UDP.bin`.

`zapret-mac.sh utunws-run`:

1. ждёт сеть и узнаёт физический интерфейс, шлюз и его MAC (`ping`, затем `arp`);
2. запускает utunws с `ZAPRET_IFACE`, `ZAPRET_GATEWAY_MAC` и `ZAPRET_UTUN_UNIT=51` — он открывает `utun50` и `/dev/bpf*`, потом сбрасывает права до `nobody`;
3. назначает `utun50` адреса `10.77.0.1 → 10.77.0.2`;
4. записывает интерфейс, шлюз и MAC в `/opt/zapret-mac/run/utunws.net` и ждёт, пока utunws работает. Упал — выходит, launchd запускает снова.

### Профили

Каждый профиль привязан к адресам через `--ipset-ip`:

1. **Discord** — TCP 443, 2053, 2083, 2087, 2096, 8443 к адресам Discord (`<zm_ds4>`), стратегия из настройки `UT_D`:

   | № | Название | Параметры (Flowseal) |
   |---|---|---|
   | 1 | SEQOVL | `--dpi-desync=multisplit --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern=tls_clienthello_4pda_to.bin` |
   | 2 | FAKE | `--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fake-tls=tls_clienthello_www_google_com.bin` |
   | 3 | FAKESEQOVL | `--dpi-desync=fake,multisplit --dpi-desync-split-seqovl=681 --dpi-desync-fooling=badseq …` |

2. **YouTube** — только если `YT=utunws`: TCP 443 к адресам Google (`<zm_g4>`), `--ip-id=zero --dpi-desync=hostfakesplit --dpi-desync-fooling=ts --dpi-desync-hostfakesplit-mod=host=www.google.com`.
3. **Голос** — UDP 19294–19344 и 50000–50100, `--filter-l7=discord,stun --dpi-desync=fake` с `ACTIVE_DISCORD_UDP.bin`.

Пропускать через utunws что-то без обработки нельзя. macOS отдаёт пакеты в `utun` не по порядку и с перекрытием, utunws отправляет их так же, и провайдер, не прочитав имя сайта, может оборвать соединение. Поэтому pf отдаёт utunws только адреса Discord (и Google, если через него идёт YouTube), а профили обрабатывают всё, что пришло.

### Замеры

Октябрь 2026 года, macOS 26.4. Проверялись главная `discord.com`, JS-файл приложения Discord (1,5–12 МБ), YouTube и `i.ytimg.com`.

| Стратегия | Домашний провайдер | МегаФон, раздача с iPhone |
|---|---|---|
| tpws, 16 стратегий, YouTube | открывается | почти везде 0 из 3 |
| utunws `FAKE` | Discord открывается | Discord не открывается |
| utunws `SEQOVL` | Discord открывается | Discord открывается |
| utunws `hostfakesplit`, YouTube | — | YouTube открывается |

utunws работает только в прозрачном режиме. Без него (`UTUNWS=0`, не скачался, не поднялся) Discord идёт через tpws, как в 2.1.

## Правила pf

Правила взяты из [docs/bsd.md](https://github.com/bol-van/zapret/blob/master/docs/bsd.md) zapret, раздел MacOS. Исходящий трафик уводится на lo0 через `route-to`, там `rdr` отдаёт его tpws:

```
rdr pass on lo0 inet proto tcp from !127.0.0.0/8 to !<zm_skip4> port { 80, 443 } -> 127.0.0.1 port 988
block return out quick inet proto udp from any to <zm_quic4> port 443 user { >root }
pass out route-to (lo0 127.0.0.1) inet proto tcp from !127.0.0.0/8 to !<zm_skip4> port { 80, 443 } user { >root }
```

Такие же правила есть для IPv6 (через `fe80::1` на lo0).

Когда utunws работает, перед правилами tpws добавляются:

```
pass out quick on utun50 all no state
pass out quick on en0 route-to (utun50 10.77.0.2) inet proto tcp from any to <zm_ds4> port { 443, 2053, 2083, 2087, 2096, 8443 } user { >root } no state
pass out quick on en0 route-to (utun50 10.77.0.2) inet proto udp from any to !<zm_skip4> port { 19294:19344, 50000:50100 } user { >root } no state
block return out quick on en0 inet proto udp from any to <zm_ds4> port 443 user { >root }
block return out quick on en0 inet6 proto { tcp, udp } from any to <zm_ds6> user { >root }
```

Если YouTube тоже идёт через utunws (`YT=utunws`), добавляются ещё:

```
pass out quick on en0 route-to (utun50 10.77.0.2) inet proto tcp from any to <zm_g4> port 443 user { >root } no state
block return out quick on en0 inet proto udp from any to <zm_g4> port 443 user { >root }
block return out quick on en0 inet6 proto { tcp, udp } from any to <zm_g6> port 443 user { >root }
```

- `<zm_ds4>` — адреса Discord: на Cloudflare `162.159.128.0/21` и `162.159.136.0/22` (`discord.com`, `gateway.discord.gg`, `cdn.discordapp.com`, `media.discordapp.net`, `discord.media`) и сервер обновлений `stable.dl2.discordapp.net` в Google Cloud.
- `<zm_g4>`, `<zm_g6>` — сервисы Google без Google Cloud, та же таблица, что для QUIC.
- Первое правило нужно потому, что пакет, отправленный через `route-to` в другой интерфейс, pf проверяет ещё раз уже на нём, и без него пакет перехватило бы правило tpws, у которого нет привязки к интерфейсу.
- QUIC к Discord и Discord по IPv6 сразу получают отказ, и приложение уходит на TCP по IPv4 — то есть в utunws.
- Пакеты, которые utunws пишет через BPF, через pf не проходят.

Сторож держит эти правила загруженными ровно тогда, когда на `utun50` есть адрес `10.77.0.1`: иначе Discord уходил бы в интерфейс, где его никто не ждёт.

- `user { >root }` — трафик root не трогается. От root работает сам tpws, иначе он завернул бы собственные соединения.
- `<zm_skip4>` — локальные сети: 10/8, 172.16/12, 192.168/16, 100.64/10 и служебные диапазоны.
- `<zm_quic4>` — сервисы Google без Google Cloud. `block return` сразу отвечает браузеру отказом, и он без задержки переходит с HTTP/3 на TCP.

Сначала правила грузятся в дочерний якорь `com.apple/zapret-mac`, и `/etc/pf.conf` не меняется. Скрипт проверяет, что перенаправление правда работает: открывает сайт от имени пользователя и ищет в таблице состояний pf соединение на `127.0.0.1:988`. Если его нет, скрипт, как установщик zapret, вписывает в `/etc/pf.conf` строки `rdr-anchor "zapret-mac/*"` и `anchor "zapret-mac/*"` (копия оригинала сохраняется в `/opt/zapret-mac/pf.conf.orig`) и использует якорь `zapret-mac/zapret-mac`. Если не помогает и это, включается режим SOCKS-прокси.

pf включается через `pfctl -E` с токеном, а не `pfctl -e`, чтобы не выключить его для других программ.

## Сторож

Сторож читает `route -n monitor` и на каждое событие RTM_ADD, RTM_DELETE, RTM_CHANGE, RTM_IFINFO, RTM_NEWADDR, RTM_DELADDR проверяет, не сменился ли VPN. Раз в 5 секунд он делает полную сверку.

| Состояние | Условие | Что делает |
|---|---|---|
| `vpn` | маршрут до 8.8.8.8 идёт через `utun*`, `ipsec*`, `ppp*`, `tun*` или `wg*` | снимает правила pf, перезапускает tpws, чтобы оборвать завёрнутые в него соединения |
| `down` | tpws не слушает порт | снимает правила pf, чтобы не пропал интернет |
| `direct` | VPN нет, tpws работает | ставит правила pf, если их нет, pf выключен или правила utunws не совпадают с тем, работает ли он |

При каждой полной сверке сторож сравнивает интерфейс, шлюз и MAC шлюза с теми, что utunws получил при запуске. Сменились — перезапускает utunws: его кадры адресованы старому шлюзу.

VPN-клиент в режиме системного прокси (без TUN) маршрут не меняет, поэтому обход остаётся включённым: программы, которые прокси не слушают, всё равно идут через tpws.

Проверка YouTube и Discord идёт через 8 секунд после перехода в `direct`, после смены сети и потом раз в 30 минут. Сторож качает сжатые страницы, чтобы не тратить лишний трафик. Если два раза подряд что-то не открылось, он запускает подбор в фоне:

1. сначала проверяет текущие стратегии через отдельные tpws и utunws — если они рабочие, значит, сломалось перенаправление, и сторож перезапускает tpws, utunws и pf;
2. иначе перебирает все стратегии и оставляет лучшие для YouTube и для Discord;
3. если полностью рабочих нет, присылает уведомление и откладывает следующий подбор: 30 минут, час, два и так далее до 4 часов.


## Подбор стратегий

Каждая стратегия проверяется отдельным tpws в режиме SOCKS на `127.0.0.1:1090` от root: трафик root pf не перенаправляет, поэтому основной tpws в проверку не вмешивается. curl открывает восемь адресов параллельно с тайм-аутом 8 секунд. Главная YouTube при ручном подборе качается целиком (~1 МБ), так видно и замедление, а не только блокировку.

Если включён VPN, временный tpws шлёт с адреса Wi-Fi (`--connect-bind-addr`), а правило в якоре `zapret-mac-test`

```
pass out quick on utunN route-to (en0 <шлюз>) inet proto tcp from <адрес en0> to any
```

выпускает такие пакеты прямо в Wi‑Fi мимо туннеля. Обычные программы шлют с адреса VPN, и правило их не задевает. Перед подбором скрипт сравнивает внешний IP через временный tpws и через `curl --interface en0`: если они не совпали, подбор отменяется с просьбой выключить VPN.

Стратегии utunws проверяет временный utunws на `utun51` (`ZAPRET_UTUN_UNIT=52`, адреса `10.77.1.1 → 10.77.1.2`), рабочий на `utun50` при этом не трогается. curl открывает адреса от root через `--interface en0`. Правила основного якоря трафик root не трогают, а правила в `zapret-mac-test` отдают его временному utunws:

```
pass out quick on utun51 all no state
pass out quick on en0 route-to (utun51 10.77.1.2) inet proto tcp from any to <zm_t4> port { 443, … } user root no state
```

Порядок подбора с utunws:

1. стратегии tpws — только для YouTube;
2. стратегии utunws для Discord, по порядку, пока одна не откроет всё;
3. если tpws открывает YouTube не полностью — YouTube через utunws с лучшей стратегией для Discord. Открывает больше — YouTube переходит на utunws (`YT=utunws`).

Без utunws обе группы подбираются через tpws, как раньше.

«Проверить» при включённом VPN показывает и utunws: в якорь `zapret-mac-test` добавляются правила для рабочего utunws, а curl открывает адреса от имени пользователя через `--interface en0`, мимо туннеля.

## Настройки

Файл `/opt/zapret-mac/config`, строки `КЛЮЧ=значение`:

| Ключ | По умолчанию | Значение |
|---|---|---|
| `MODE` | `transparent` | `transparent` или `socks` |
| `S_Y`, `S_D` | `1` | номера стратегий для YouTube и Discord |
| `QUIC` | `1` | глушить QUIC к Google |
| `AUTOFIX` | `1` | сторож сам подбирает стратегии |
| `AUTOLIST` | `0` | профиль автосписка tpws |
| `PF_ROOT` | `com.apple` | `com.apple` или `zapret-mac` — куда подключены правила pf |
| `UTUNWS` | `1` | Discord через utunws |
| `UT_D` | `1` | стратегия utunws для Discord |
| `YT` | `tpws` | `tpws` или `utunws` — чем обходить YouTube |
| `TP_OK` | — | `1`, когда прозрачный режим проверен на этом Mac |
