# Discord через Linux zapret на Mac

Этот режим обходит обрыв Cloudflare после ~16 КБ без VPN и без изменения маршрута остальных приложений Mac. Он запускает Linux `nfqws` из zapret внутри VM и подаёт TCP трафик Discord через локальный SOCKS-туннель OpenSSH.

```
Discord.app
  └─ SOCKS5 localhost:1081
       └─ SSH к Linux VM по локальной сети
            └─ sshd открывает TCP к Discord
                 └─ nfqws меняет пакеты
                      └─ bridged-интерфейс VM → провайдер
```

## 1. Создай Linux VM с мостом

В UTM создай Debian или Ubuntu VM и в настройках сети выбери **Bridged (Advanced)**, затем физический Wi-Fi или Ethernet интерфейс Mac. VM должна получить собственный IP из той же локальной сети, что и Mac. Закрепи этот IP за VM в настройках DHCP роутера.

Не используй **Shared Network/NAT**: документация zapret предупреждает, что виртуальный NAT может менять или отбрасывать поддельные пакеты nfqws. В UTM для Wi-Fi-моста иногда требуется дополнительная настройка macOS; если VM не получает обычный LAN IP, проверь настройки моста или используй проводной Ethernet. [UTM: режимы сети](https://docs.getutm.app/settings-apple/devices/network/) · [zapret: виртуальные машины](https://github.com/bol-van/zapret/blob/master/docs/readme.en.md)

## 2. Установи Linux zapret и SSH

В терминале VM:

```bash
sudo apt update
sudo apt install -y git openssh-server
sudo systemctl enable --now ssh
git clone https://github.com/bol-van/zapret.git /tmp/zapret
cd /tmp/zapret
sudo ./install_bin.sh
sudo ./install_prereq.sh
sudo ./blockcheck.sh
sudo ./install_easy.sh
```

В `blockcheck.sh` введи `discord.com` и сохрани рабочий результат. В `install_easy.sh` выбери **nfqws**, согласись на редактирование параметров и внеси найденную стратегию. Если используешь фильтрацию по hostlist, добавь туда `discord.com` и `discord.gg`. Стратегии различаются у провайдеров; универсальное значение здесь задавать нельзя. [zapret: быстрая настройка](https://github.com/bol-van/zapret/blob/master/docs/quick_start.md)

После установки проверь службу командой `sudo systemctl status zapret`. Она должна быть запущена до подключения Discord.

Проверь, что обычный пользователь VM может подключиться к Discord и что SSH доступен по локальной сети. Не открывай SSH или SOCKS наружу в интернет.

## 3. Подключи Mac

В меню zapret-mac открой **9 → 5** и введи SSH-цель VM, например `myuser@192.168.1.50`. Для нестандартного SSH-порта создай алиас в `~/.ssh/config` и укажи этот алиас. Пароль или подтверждение нового SSH-ключа вводятся в терминале при первом запуске.

Затем выбери **6 — Перезапустить Discord**. Приложение будет использовать SOCKS5 через SSH и Linux `nfqws`; остальной трафик Mac останется на прежнем маршруте. Когда закончишь, выбери **15 — Отключить SSH-туннель Linux VM**. Настройку VM можно отключить через **9 → 5**, оставив поле пустым.

## Ограничения

- SOCKS5 в Chromium проксирует TCP-запросы, но не UDP. Сообщения и загрузка приложения идут через Linux zapret; голосовые звонки Discord этим способом не туннелируются, для них включи VPN. [Chromium: SOCKSv5](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md)
- VM должна быть включена, подключена к той же сети и иметь рабочий SSH. Если провайдер блокирует и SSH-соединение внутри локальной сети, проверь изоляцию клиентов Wi-Fi на роутере.
- При обновлении или смене провайдера заново проверь стратегию через `blockcheck.sh`.
