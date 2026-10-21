<div align="center">

# zapret-mac

**YouTube и Discord на macOS без VPN — на движке [zapret](https://github.com/bol-van/zapret).**
Один bash-скрипт с меню. Сам переключается, когда включаешь и выключаешь VPN.

[![CI](https://github.com/getpaintoo/zapret-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/getpaintoo/zapret-mac/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon%20%7C%20Intel-black?logo=apple)
![bash](https://img.shields.io/badge/bash-3.2-4EAA25?logo=gnubash&logoColor=white)

[Установка](#установка) · [Как это работает](#как-это-работает) · [Discord и обрыв на 16 КБ](#discord-и-обрыв-на-16-кб) · [Если пропал интернет](#если-пропал-интернет)

</div>

---

На Windows есть готовая сборка [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube). WinDivert не запускается на macOS, а локальный tpws не отправляет поддельные пакеты. Для провайдеров, которые обрывают Discord на 16 КБ, можно дополнительно запустить Linux VM в режиме Bridged с обычным zapret/nfqws и подключить Discord через SSH SOCKS-туннель.

## Возможности

- **Прозрачный режим, как в оригинальном zapret.** pf перенаправляет исходящий TCP на порты 80 и 443 в tpws, поэтому обход видят все программы. В том числе апдейтер Discord: он написан на Rust и системный SOCKS-прокси игнорирует.
- **Отдельные стратегии для YouTube и для Discord.** Подбор перебирает 16 стратегий tpws и для каждой группы сайтов выбирает свою.
- **Автопереключение с VPN.** Сторож ловит события маршрутизации. VPN в режиме TUN включился — перенаправление снимается, весь трафик идёт в VPN. Выключился — обход возвращается.
- **Самопроверка.** Раз в 30 минут и после смены сети сторож открывает YouTube и Discord. Если перестали открываться, подбирает стратегии в фоне и присылает уведомление.
- **Подбор при включённом VPN.** Тестовый трафик уходит к провайдеру напрямую через Wi‑Fi, мимо туннеля. Перед подбором скрипт сверяет внешний IP, чтобы проверка правда шла мимо VPN.
- **QUIC к Google блокируется.** Браузер сразу идёт по TCP, то есть через обход. Адреса Google Cloud не трогаются: на них бывают VPN-серверы.
- **Безопасные отказы.** Если якорь pf внутри `com.apple` не срабатывает, скрипт прописывает свой в `/etc/pf.conf`, как установщик zapret. Если прозрачный режим не работает совсем, переходит на SOCKS-прокси. Если tpws упал, перенаправление снимается, чтобы не пропал интернет.
- **Проверенный tpws.** Скачивается из релиза bol-van/zapret, контрольная сумма SHA-256 сверяется с зашитой в скрипт.
- **Linux nfqws для Discord.** В настройках можно указать Linux VM. Только Discord запускается через SSH SOCKS-туннель к её nfqws; остальные приложения и маршруты Mac не меняются. [Инструкция](docs/linux-vm-discord.md).

## Что работает

| | Через обход | Через VPN |
|---|:---:|:---:|
| YouTube в браузере | ✓ | ✓ |
| Обновления Discord | ✓ | ✓ |
| Приложение Discord | зависит от провайдера, [Linux nfqws VM](docs/linux-vm-discord.md) или VPN | ✓ |
| Звонки в Discord (UDP) | ✗ | ✓ |

tpws работает только с TCP, поэтому голос в Discord через обход не идёт.

## Установка

Нужны macOS и пароль администратора. Остальное (bash 3.2, curl, pfctl, launchd) уже есть в системе. tpws собран для Intel и Apple Silicon; проверено на macOS 26.4 с Apple Silicon.

```bash
curl -fLO https://raw.githubusercontent.com/getpaintoo/zapret-mac/main/zapret-mac.sh
bash zapret-mac.sh
```

В меню выбери **1 — Подобрать стратегии и включить**. Запускать через `sudo` не нужно: пароль скрипт спросит сам. При первом запуске он ставит себя в `/opt/zapret-mac` и кладёт на рабочий стол ярлык `Zapret.command`.

## Меню

| № | Что делает |
|---|---|
| 1 | Подобрать стратегии и включить |
| 2 | Включить с сохранёнными стратегиями |
| 3 | Выбрать стратегии вручную (отдельно для YouTube и Discord) |
| 4 | Выключить |
| 5 | Проверить, что открывается: напрямую и через обход |
| 6 | Перезапустить Discord |
| 7 | Добавить свой сайт в обход |
| 8 | Автосписок сайтов |
| 9 | Настройки: QUIC, автоподбор, режим, автосписок |
| 10 | DNS Google/Cloudflare: вкл/выкл |
| 11 | Подробный статус и журнал сторожа |
| 12 | Перебрать все стратегии |
| 13 | Обновить tpws и списки доменов |
| 14 | Удалить всё |
| 15 | Отключить SSH-туннель Linux VM |

Без меню:

```bash
bash zapret-mac.sh auto        # подобрать и включить
bash zapret-mac.sh check       # что открывается
bash zapret-mac.sh status      # подробный статус
bash zapret-mac.sh stop        # выключить
```

Также есть `start`, `restart`, `test [all]`, `discord`, `add`, `dns`, `update`, `uninstall`.

Параметры Linux VM для Discord задаются в **9 → 5**. После настройки VM используй пункт **6** для запуска Discord через nfqws.

## Как это работает

```
 программа ── TCP 80/443 ──▶ pf: route-to lo0 → rdr ──▶ tpws :988 ──▶ провайдер
                                                      │
                                    стратегия только для доменов из списков,
                                    остальные сайты проходят без изменений

 VPN (TUN) включён ──▶ сторож снимает правила pf ──▶ весь трафик идёт в VPN
```

- **tpws** работает от root как LaunchDaemon `com.zapret-mac.tpws`. На macOS адрес назначения из pf отдают только root, это ограничение описано в [docs/bsd.md](https://github.com/bol-van/zapret/blob/master/docs/bsd.md) zapret.
- **Правила pf** — из той же документации. Трафик root не перенаправляется, иначе tpws завернул бы сам себя. Локальные сети не трогаются.
- **Сторож** — LaunchDaemon `com.zapret-mac.watchdog`, тот же скрипт с командой `daemon`. Читает `route -n monitor` и раз в 5 секунд сверяет, что pf и tpws в порядке.
- **Списки доменов** — из Flowseal: `list-youtube.txt` (у Flowseal это `list-google`) и `list-general.txt`. Свои сайты — в `list-user.txt`.

Подробно: [docs/architecture.md](docs/architecture.md).

## Discord и обрыв на 16 КБ

У части провайдеров обход приложению Discord не помогает, и стратегия тут ни при чём. Провайдер делает две вещи:

1. блокирует соединение, если в начале TLS видно имя `discord.com`;
2. обрывает после ~16 КБ любое соединение с адресами Cloudflare, в котором имя прочитать не смог.

tpws обходит первое правило тем, что прячет имя, и этим включает второе. Приложение Discord живёт на Cloudflare, поэтому грузится обрывками. Обновления Discord это не задевает: они качаются с Google Cloud. YouTube тоже. Для этого случая можно пустить только TCP Discord через Linux VM с nfqws по [этой инструкции](docs/linux-vm-discord.md); TUN VPN остаётся вторым вариантом.

Как это было проверено и что с этим делать: [docs/discord-16kb.md](docs/discord-16kb.md). zapret-mac распознаёт такой обрыв: в проверке он показан как `! Discord — оборвалось на 12 КБ`, и сторож не тратит время на бесполезный подбор стратегий.

## Если пропал интернет

```bash
sudo bash /opt/zapret-mac/zapret-mac.sh stop
```

Команда снимает правила pf, останавливает tpws и сторожа, выключает системный прокси, если его ставил скрипт. Если и скрипта под рукой нет, правила можно снять вручную (смотря куда они загружены):

```bash
sudo pfctl -a com.apple/zapret-mac -F all
sudo pfctl -a zapret-mac/zapret-mac -F all
```

## Удаление

Пункт 14 в меню или `bash zapret-mac.sh uninstall`. Убирается всё: `/opt/zapret-mac`, оба LaunchDaemon, правки `/etc/pf.conf`, ярлык. DNS возвращается к прежнему, если его менял скрипт.

## Где что лежит

| Путь | Что там |
|---|---|
| `/opt/zapret-mac/zapret-mac.sh` | установленная копия скрипта |
| `/opt/zapret-mac/bin/tpws` | tpws из релиза zapret |
| `/opt/zapret-mac/lists/` | списки доменов; свои сайты — `list-user.txt`, исключения — `list-exclude-user.txt` |
| `/opt/zapret-mac/config` | настройки: режим, стратегии, QUIC, автоподбор, автосписок |
| `/opt/zapret-mac/log/` | `watchdog.log` — журнал сторожа, `tpws.log`, `select.log` — ход последнего автоподбора |
| `/Library/LaunchDaemons/com.zapret-mac.*.plist` | автозапуск tpws и сторожа |

## Обновление со старой версии

Первая версия жила в `~/.zapret-mac` и работала как SOCKS-прокси. Новая при установке сама её останавливает, снимает прокси и переносит свои сайты, выбранную стратегию и сохранённые настройки DNS. История изменений — в [CHANGELOG.md](CHANGELOG.md).

## Участие

Ошибки и предложения — в [Issues](https://github.com/getpaintoo/zapret-mac/issues). Перед pull request прочитай [CONTRIBUTING.md](CONTRIBUTING.md): скрипт должен работать на системном bash 3.2.

## Благодарности

- [bol-van/zapret](https://github.com/bol-van/zapret) — tpws и правила pf для macOS.
- [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) — списки доменов и сама идея набора стратегий.

## Лицензия

[MIT](LICENSE). Лицензии использованных проектов — в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Скрипт меняет сетевые настройки macOS (pf, launchd, системный прокси) и предоставляется как есть, без гарантий.

---

<details>
<summary><b>English</b></summary>

zapret-mac brings [zapret](https://github.com/bol-van/zapret) DPI circumvention for YouTube and Discord to macOS. It runs tpws as a transparent proxy behind pf, picks separate strategies for YouTube and Discord, starts on boot via launchd, and can optionally launch Discord through a bridged Linux VM running zapret/nfqws.

Install: `curl -fLO https://raw.githubusercontent.com/getpaintoo/zapret-mac/main/zapret-mac.sh && bash zapret-mac.sh`, then choose 1 in the menu.

Known limitation: some ISPs cut connections to Cloudflare after ~16 KB when they cannot read the SNI, which is exactly what tpws hides. For those networks, use the optional Linux nfqws VM or a TUN VPN. Discord calls still require a path that carries UDP. See [docs/discord-16kb.md](docs/discord-16kb.md) (in Russian).

</details>
