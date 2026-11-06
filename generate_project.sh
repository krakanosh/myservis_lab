#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/opt/myservis"
CALLER_USER="${SUDO_USER:-${USER:-$(id -un)}}"
CALLER_GROUP="$(id -gn "$CALLER_USER" 2>/dev/null || true)"

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
fail() { printf '[x] %s\n' "$*" >&2; exit 1; }

if [[ ! -d "$(dirname "$PROJECT_DIR")" ]]; then
  sudo mkdir -p "$(dirname "$PROJECT_DIR")"
fi

if [[ ! -w "$(dirname "$PROJECT_DIR")" ]]; then
  command -v sudo >/dev/null 2>&1 || fail "Нет прав на /opt и не найден sudo."
  log "Для создания $PROJECT_DIR потребуются права администратора."
  sudo mkdir -p "$PROJECT_DIR"
  sudo chown "$CALLER_USER":"${CALLER_GROUP:-$CALLER_USER}" "$PROJECT_DIR"
else
  mkdir -p "$PROJECT_DIR"
fi

if [[ ! -w "$PROJECT_DIR" ]]; then
  sudo chown "$CALLER_USER":"${CALLER_GROUP:-$CALLER_USER}" "$PROJECT_DIR"
fi

cd "$PROJECT_DIR"
mkdir -p app scripts data logs

cat > app/main.py <<'PYEOF'
import atexit
import logging
import os
import signal
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path

import yaml
from flask import Flask, jsonify, render_template_string

BASE_DIR = Path(__file__).resolve().parent
CONFIG = yaml.safe_load((BASE_DIR / "config.yaml").read_text(encoding="utf-8"))
DB_PATH = Path(CONFIG.get("db_path", "/app/data/metrics.db"))
LOG_PATH = Path(CONFIG.get("log_path", "/app/logs/myservis.log"))
INTERVAL_SEC = max(1, int(CONFIG.get("interval_sec", 10)))
THRESHOLD = float(CONFIG.get("threshold_percent", 85))

DB_PATH.parent.mkdir(parents=True, exist_ok=True)
LOG_PATH.parent.mkdir(parents=True, exist_ok=True)

logger = logging.getLogger("myservis")
logger.setLevel(logging.INFO)
handler = logging.FileHandler(LOG_PATH, encoding="utf-8")
handler.setFormatter(logging.Formatter(
    "[%(asctime)s] [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
))
logger.addHandler(handler)

app = Flask(__name__)
stop_event = threading.Event()
worker_thread = None


def connect_db():
    connection = sqlite3.connect(DB_PATH, timeout=10)
    connection.row_factory = sqlite3.Row
    return connection


def init_db():
    with connect_db() as connection:
        connection.execute("""
            CREATE TABLE IF NOT EXISTS disk_stats (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts TEXT NOT NULL,
                total INTEGER NOT NULL,
                used INTEGER NOT NULL,
                free INTEGER NOT NULL,
                percent REAL NOT NULL
            )
        """)


def collect_metric():
    import shutil

    usage = shutil.disk_usage("/")
    percent = round((usage.used / usage.total) * 100, 2) if usage.total else 0.0
    timestamp = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    with connect_db() as connection:
        connection.execute(
            "INSERT INTO disk_stats (ts, total, used, free, percent) VALUES (?, ?, ?, ?, ?)",
            (timestamp, usage.total, usage.used, usage.free, percent),
        )
    logger.info(
        "Disk usage collected: total=%s used=%s free=%s percent=%.2f",
        usage.total, usage.used, usage.free, percent,
    )
    if percent > THRESHOLD:
        logger.warning("Disk usage %.2f%% exceeds threshold %.2f%%", percent, THRESHOLD)


def collector():
    while not stop_event.is_set():
        try:
            collect_metric()
        except Exception:
            logger.exception("Failed to collect disk metrics")
        stop_event.wait(INTERVAL_SEC)


def shutdown_handler(signum, _frame):
    logger.info("Received signal %s; stopping collector", signum)
    stop_event.set()


def get_current():
    with connect_db() as connection:
        row = connection.execute(
            "SELECT id, ts, total, used, free, percent FROM disk_stats ORDER BY id DESC LIMIT 1"
        ).fetchone()
    return dict(row) if row else None


def get_history(limit=20):
    with connect_db() as connection:
        rows = connection.execute(
            "SELECT id, ts, total, used, free, percent FROM disk_stats ORDER BY id DESC LIMIT ?",
            (limit,),
        ).fetchall()
    return [dict(row) for row in rows]


@app.get("/")
def index():
    current = get_current()
    history = get_history(20)
    return render_template_string("""
    <!doctype html>
    <html lang="ru"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Мониторинг диска</title>
    <style>
      body{font:16px/1.5 system-ui,sans-serif;max-width:1000px;margin:40px auto;padding:0 18px;color:#222}
      .metric{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px}
      .card{background:#f2f4f7;border-radius:10px;padding:16px}
      table{width:100%;border-collapse:collapse;margin-top:20px}
      th,td{text-align:left;padding:9px;border-bottom:1px solid #ddd}
      code{overflow-wrap:anywhere}
    </style></head><body>
    <h1>Мониторинг дискового пространства</h1>
    {% if current %}
      <p>Последнее обновление: {{ current.ts }}</p>
      <section class="metric">
        <div class="card"><b>Всего</b><br>{{ current.total|filesizeformat }}</div>
        <div class="card"><b>Занято</b><br>{{ current.used|filesizeformat }}</div>
        <div class="card"><b>Свободно</b><br>{{ current.free|filesizeformat }}</div>
        <div class="card"><b>Использовано</b><br>{{ current.percent }}%</div>
      </section>
    {% else %}<p>Ожидание первой метрики…</p>{% endif %}
    <h2>История (последние 20 записей)</h2>
    <table><thead><tr><th>Время</th><th>Всего, байт</th><th>Занято, байт</th>
    <th>Свободно, байт</th><th>%</th></tr></thead><tbody>
    {% for row in history %}<tr><td>{{ row.ts }}</td><td>{{ row.total }}</td>
    <td>{{ row.used }}</td><td>{{ row.free }}</td><td>{{ row.percent }}</td></tr>
    {% else %}<tr><td colspan="5">Записей пока нет</td></tr>{% endfor %}
    </tbody></table>
    <p>API: <a href="/api/current">/api/current</a> · <a href="/api/history">/api/history</a></p>
    </body></html>
    """, current=current, history=history)


@app.get("/api/current")
def api_current():
    current = get_current()
    return jsonify(current) if current else (jsonify({"message": "metrics not collected yet"}), 404)


@app.get("/api/history")
def api_history():
    return jsonify(get_history(100))


def start_worker():
    global worker_thread
    init_db()
    worker_thread = threading.Thread(target=collector, name="disk-collector", daemon=True)
    worker_thread.start()


def stop_worker():
    stop_event.set()
    if worker_thread and worker_thread.is_alive():
        worker_thread.join(timeout=INTERVAL_SEC + 2)


signal.signal(signal.SIGTERM, shutdown_handler)
signal.signal(signal.SIGINT, shutdown_handler)
atexit.register(stop_worker)
start_worker()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(CONFIG.get("port", 8080)), use_reloader=False)
PYEOF

cat > app/config.yaml <<'YAMLEOF'
interval_sec: 10
threshold_percent: 85
db_path: /app/data/metrics.db
log_path: /app/logs/myservis.log
port: 8080
YAMLEOF

cat > app/requirements.txt <<'REQEOF'
Flask==3.1.1
PyYAML==6.0.2
REQEOF

cat > app/Dockerfile <<'DOCKEREOF'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py config.yaml ./
RUN mkdir -p /app/data /app/logs

EXPOSE 8080
CMD ["python", "main.py"]
DOCKEREOF

cat > docker-compose.yml <<'COMPOSEEOF'
services:
  myservis:
    build:
      context: ./app
    container_name: myservis
    ports:
      - "8080:8080"
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    restart: unless-stopped
COMPOSEEOF

cat > scripts/01_prepare.sh <<'PREPAREEOF'
#!/usr/bin/env bash
set -euo pipefail
log(){ printf '[+] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
fail(){ printf '[x] %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || fail "Скрипт предназначен для Linux в WSL2."
if ! grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  warn "WSL2 не обнаружен. Продолжаю проверку, но целевая среда задания — Ubuntu в WSL2."
fi
command -v curl >/dev/null 2>&1 || fail "Не найден curl. Установите: sudo apt update && sudo apt install -y curl"
command -v docker >/dev/null 2>&1 || fail "Не найден docker CLI. Установите Docker Desktop в Windows и включите Settings → Resources → WSL Integration для Ubuntu."
docker info >/dev/null 2>&1 || fail "Docker daemon недоступен. Запустите Docker Desktop в Windows и включите WSL Integration для используемого дистрибутива Ubuntu."
docker compose version >/dev/null 2>&1 || fail "Не найден Docker Compose v2. Обновите Docker Desktop и проверьте интеграцию WSL."
log "Linux/WSL, curl, Docker CLI, Docker daemon и Compose v2 доступны."
log "Docker Engine внутри WSL не устанавливался: используется Docker Desktop."
PREPAREEOF

cat > scripts/02_create_structure.sh <<'STRUCTEOF'
#!/usr/bin/env bash
set -euo pipefail
log(){ printf '[+] %s\n' "$*"; }
fail(){ printf '[x] %s\n' "$*" >&2; exit 1; }
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
for file in app/main.py app/config.yaml app/requirements.txt app/Dockerfile docker-compose.yml; do
  [[ -f "$file" ]] || fail "Отсутствует обязательный файл: $file. Повторно запустите generate_project.sh."
done
mkdir -p data logs
touch .project-write-test && rm .project-write-test
log "Структура проверена; каталоги data/ и logs/ готовы."
STRUCTEOF

cat > scripts/03_build_and_up.sh <<'BUILDEOF'
#!/usr/bin/env bash
set -euo pipefail
log(){ printf '[+] %s\n' "$*"; }
fail(){ printf '[x] %s\n' "$*" >&2; exit 1; }
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
command -v docker >/dev/null 2>&1 || fail "Docker CLI не найден. Сначала выполните scripts/01_prepare.sh."
docker info >/dev/null 2>&1 || fail "Docker daemon недоступен. Запустите Docker Desktop."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 недоступен."
mkdir -p data logs
log "Сборка образа и запуск сервиса..."
docker compose up -d --build
log "Команда docker compose завершилась успешно."
BUILDEOF

cat > scripts/04_info.sh <<'INFOEOF'
#!/usr/bin/env bash
set -euo pipefail
log(){ printf '[+] %s\n' "$*"; }
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
log "Каталог проекта: $PROJECT_DIR"
printf '\n--- docker compose ps ---\n'
docker compose ps
printf '\n--- Последние 10 строк логов контейнера ---\n'
docker compose logs --tail=10 myservis || true
printf '\n--- Количество записей SQLite ---\n'
if [[ -f data/metrics.db ]]; then
  docker compose exec -T myservis python -c "import sqlite3; c=sqlite3.connect('/app/data/metrics.db'); print(c.execute('SELECT COUNT(*) FROM disk_stats').fetchone()[0])" 2>/dev/null || \
    python3 -c "import sqlite3; c=sqlite3.connect('data/metrics.db'); print(c.execute('SELECT COUNT(*) FROM disk_stats').fetchone()[0])" 2>/dev/null || \
    printf '[!] Не удалось прочитать БД (возможно, контейнер ещё не запущен).\n'
else
  printf '[!] Файл data/metrics.db пока не создан.\n'
fi
printf '\nURL: http://localhost:8080\n'
INFOEOF

cat > scripts/05_check.sh <<'CHECKEOF'
#!/usr/bin/env bash
set -euo pipefail
log(){ printf '[+] %s\n' "$*"; }
fail(){ printf '[x] %s\n' "$*" >&2; exit 1; }
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

log "Ожидание HTTP-сервиса (до 30 секунд)..."
HTTP_OK=0
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null -w '%{http_code}' http://localhost:8080/ 2>/dev/null | grep -qx '200'; then
    HTTP_OK=1
    break
  fi
  sleep 1
done
[[ "$HTTP_OK" -eq 1 ]] || { docker compose ps; docker compose logs --tail=30 myservis || true; fail "HTTP GET / не вернул 200 за 30 секунд."; }

RUNNING="$(docker compose ps --status running --services)"
grep -qx 'myservis' <<<"$RUNNING" || fail "Сервис myservis не находится в состоянии running."

[[ -s logs/myservis.log ]] || fail "Лог logs/myservis.log отсутствует или пуст."
[[ -s data/metrics.db ]] || fail "База data/metrics.db отсутствует или пуста."

COUNT="$(docker compose exec -T myservis python -c "import sqlite3; c=sqlite3.connect('/app/data/metrics.db'); print(c.execute('SELECT COUNT(*) FROM disk_stats').fetchone()[0])")"
[[ "$COUNT" =~ ^[0-9]+$ ]] || fail "Не удалось получить количество записей SQLite."
(( COUNT >= 1 )) || fail "В SQLite нет ни одной метрики."

log "HTTP GET /: 200"
log "Контейнер myservis: running"
log "SQLite: $COUNT записей"
log "Лог: непустой"
log "OK — все проверки пройдены."
CHECKEOF

cat > README.md <<'READMEEOF'
# myservis — мониторинг дискового пространства

Flask-сервис периодически собирает статистику корневой файловой системы контейнера, сохраняет её в SQLite и предоставляет HTML-страницу и JSON API.

## Среда

- Ubuntu 22.04+ в WSL2.
- Docker Desktop в Windows, включена интеграция для Ubuntu: **Settings → Resources → WSL Integration**.
- Docker Compose v2.
- Порт: `8080`.

> В этой конфигурации Docker Engine отдельно в WSL не устанавливается. Используется демон Docker Desktop.

## Создание проекта

Генератор лабораторной работы создаёт этот каталог и все файлы:

```bash
sudo bash generate_project.sh
```

Если генератор расположен вне `/opt/myservis`, запустите его из каталога, где он сохранён. После генерации перейдите в проект:

```bash
cd /opt/myservis
```

## Запуск

```bash
bash scripts/01_prepare.sh
bash scripts/02_create_structure.sh
bash scripts/03_build_and_up.sh
bash scripts/04_info.sh
bash scripts/05_check.sh
```

Откройте в браузере Windows: <http://localhost:8080>.

## API

- `GET /api/current` — последняя метрика.
- `GET /api/history` — последние 100 метрик.

Примеры:

```bash
curl -i http://localhost:8080/
curl http://localhost:8080/api/current
curl http://localhost:8080/api/history
```

## Данные и логи

- `data/metrics.db` — SQLite, таблица `disk_stats`.
- `logs/myservis.log` — журнал приложения.
- Каталоги подключены как bind mounts, поэтому данные сохраняются при пересоздании контейнера.

## Управление

```bash
docker compose ps
docker compose logs -f myservis
docker compose restart myservis
docker compose down
```

`docker compose down` останавливает и удаляет контейнер, но не удаляет `data/` и `logs/`.

## Конфигурация

Параметры находятся в `app/config.yaml`:

- `interval_sec` — период сбора данных в секундах.
- `threshold_percent` — порог заполнения для WARNING.
- `db_path` — путь к SQLite внутри контейнера.
- `log_path` — путь к журналу внутри контейнера.
- `port` — порт Flask внутри контейнера.

После изменения конфигурации пересоздайте контейнер:

```bash
docker compose up -d --build
```

## Важное замечание о метрике

Сервис измеряет файловую систему, видимую контейнеру по пути `/`. В Docker Desktop это не обязательно совпадает с диском Windows целиком или файловой системой WSL-дистрибутива. Это именно статистика корневой файловой системы контейнера.
READMEEOF

chmod +x scripts/*.sh
chown -R "$CALLER_USER":"${CALLER_GROUP:-$CALLER_USER}" "$PROJECT_DIR" 2>/dev/null || true

log "Проект создан в $PROJECT_DIR"
log "Следующий шаг: cd $PROJECT_DIR && bash scripts/01_prepare.sh"
log "Генератор не запускает контейнеры и не заявляет об успешном тестировании."
