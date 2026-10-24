# Участие в проекте

## Сообщить о проблеме

Открой [issue](https://github.com/getpaintoo/zapret-mac/issues/new/choose) и приложи вывод пунктов 5 («Проверить») и 11 («Подробный статус») из меню. Перед отправкой убери из него свои IP-адреса.

## Изменения в коде

- Скрипт должен работать на системном `/bin/bash` версии 3.2. Нельзя: ассоциативные массивы, `mapfile`, `${var,,}`, `|&`, дробный `read -t`.
- Обход — в `zapret-mac.sh`, стратегии — в `strategies.conf`, приложение — в `app/`. Комментарии и сообщения — по-русски, в стиле уже существующих.
- Всё, что меняет сеть, должно уметь откатиться: `stop` и `uninstall` возвращают систему в исходное состояние.

Перед pull request:

```bash
/bin/bash -n zapret-mac.sh
ZM_TPWS=/opt/zapret-mac/bin/tpws ZM_UTUNWS=/opt/zapret-mac/bin/utunws bash tests/dry-run.sh
bash tests/strategies.sh
bash app/build.sh          # приложение: Command Line Tools, Xcode не нужен
```

Новые стратегии добавляй в `strategies.conf` и во встроенные массивы `STRATEGIES` и `UT_STRAT_D` скрипта (они должны совпадать — это проверяет `tests/strategies.sh`), увеличь номер в строке `version` и `STRAT_VER`. Затем прогони `tests/dry-run.sh`: если tpws или utunws не примет параметры, тест упадёт. После слияния в main служба у пользователей скачает новый файл сама, в течение суток. Если стратегия помогла у твоего провайдера, напиши в описании, что именно стало открываться.
