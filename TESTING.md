# Тестирование UsageTimeController

## Быстрый старт (безопасно на своем компе)

### 1. Запустить API сервер

```bash
cd api
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python -m uvicorn app.main:app --reload
```

Сервер стартует на `http://localhost:8000`. Swagger UI: `http://localhost:8000/docs`.

### 2. Запустить API тесты

```bash
cd api
source venv/bin/activate
python -m pytest tests/ -v
```

Все 60 тестов должны проходить.

### 3. Запустить macOS агент в DEV MODE

```bash
cd macos-agent
./dev-test.sh
```

Скрипт автоматически:
- Проверит что API сервер запущен
- Создаст тестового пользователя и устройство
- Установит тестовую политику (5 минут экранного времени)
- Соберет приложение в Debug
- Запустит с DEV MODE

### 4. Запустить веб-дашборд

```bash
cd web-dashboard
npm install
npm run dev
```

Откроется на `http://localhost:5173`. Логин: `dev-test@usagetime.local` / `devtest123`.

---

## Dev Mode — защита от самоблокировки

Когда агент запущен в dev mode (`UTC_DEV_MODE=1`), активны следующие защиты:

| Защита | Описание |
|--------|----------|
| **Auto-unlock** | Лок-скрин автоматически уходит через 10 секунд |
| **Emergency hotkey** | `Ctrl+Opt+Cmd+U` — мгновенно снимает лок-скрин |
| **Floating window** | Лок-скрин на уровне `.floating`, можно переключиться через `Cmd+Tab` |
| **Quit доступен** | В меню бара есть пункт "Quit (Dev Mode)", `Cmd+Q` работает |
| **Нет self-protection** | Процесс можно свободно убить через Activity Monitor или `pkill` |
| **Нет watchdog** | Не устанавливается LaunchDaemon, процесс не воскресает |
| **Быстрые таймеры** | Tick каждые 5с (вместо 30), sync каждые 10с (вместо 60) |
| **DEV метка** | Метка "DEV MODE" в меню баре и на лок-скрине |

### Как остановить агент в dev mode

Любой способ работает:
```bash
# Через меню бар → "Quit (Dev Mode)"
# Cmd+Q
# Из терминала:
pkill -f UsageTimeAgent
# Activity Monitor → UsageTimeAgent → Force Quit
```

### Конфигурация dev mode

Через переменные окружения:
```bash
export UTC_DEV_MODE=1              # включить dev mode
export UTC_DEV_AUTO_UNLOCK=10      # авто-разблокировка через N секунд
export UTC_SERVER_URL=http://localhost:8000
export UTC_API_TOKEN=your-token
export UTC_POLL_INTERVAL=10        # sync каждые N секунд
```

Или через plist (`/etc/usagetime/config.plist`):
```xml
<key>DevMode</key>
<true/>
<key>DevAutoUnlockSeconds</key>
<integer>10</integer>
```

Или через UserDefaults:
```bash
defaults write com.usagetime.agent DevMode -bool true
defaults write com.usagetime.agent DevAutoUnlockSeconds -int 10
```

---

## Что тестировать

### Сценарий 1: Экранное время
1. Запустить агент в dev mode
2. В веб-дашборде установить лимит 1 минута
3. Подождать — через ~1 минуту должен появиться лок-скрин
4. Лок-скрин автоматически уйдет через 10с (dev mode)
5. В меню баре должно показываться оставшееся время

### Сценарий 2: Даунтайм
1. Установить downtime: текущее время → +2 минуты
2. Лок-скрин должен появиться немедленно (следующий sync)
3. Проверить что показывается "Время отдыха"

### Сценарий 3: Добавление времени
1. Довести до лимита (лок-скрин появится)
2. В дашборде увеличить лимит
3. На следующем sync (10с в dev mode) лок-скрин должен уйти
4. Предупреждения должны сброситься

### Сценарий 4: Выходные/будни
1. Установить разные лимиты для weekday/weekend
2. Проверить что применяется правильный лимит

### Сценарий 5: Parent App (iOS/macOS)
1. Открыть ParentApp в Xcode, запустить на симуляторе или устройстве
2. Залогиниться с тестовыми кредами
3. Проверить что устройства и политики видны
4. Изменить политику — проверить что агент подхватывает

---

## Production установка (НЕ для тестирования на своем компе!)

```bash
cd macos-agent
sudo ./install.sh
```

Это установит агент с полной защитой:
- Лок-скрин на максимальном уровне (нельзя переключиться)
- Cmd+Q заблокирован
- Watchdog воскрешает процесс каждые 15 секунд
- Приложение принадлежит root (нельзя удалить без sudo)

**НИКОГДА не запускайте production установку на своем рабочем компе без настроенного удаленного доступа!**

---

## Архитектура тестирования

```
┌─────────────────┐     HTTP      ┌──────────────┐
│  macOS Agent    │◄────────────►│  API Server  │
│  (dev mode)     │               │  (localhost)  │
└─────────────────┘               └──────┬───────┘
                                         │
┌─────────────────┐     HTTP      ┌──────┴───────┐
│  Parent App     │◄────────────►│   SQLite DB  │
│  (Xcode sim)    │               └──────────────┘
└─────────────────┘
         │
┌────────┴────────┐
│  Web Dashboard  │
│  (localhost)     │
└─────────────────┘
```

Все компоненты работают локально, никакого внешнего сервера не нужно.
