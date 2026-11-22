# ДЗ по Docker: счётчик

Веб-приложение со счётчиком в Docker. Код в `app/` не менялся.

## Запуск

```bash
cp .env.example .env
docker compose up -d --build --wait
curl http://127.0.0.1:8080/
curl -X POST http://127.0.0.1:8080/increment
docker compose logs app
docker compose down        # без -v: данные Redis сохраняются
```

## Настройки (файл `.env`)

| Переменная | По умолчанию | Значение |
| --- | --- | --- |
| `GREETING` | `Hello, Docker!` | текст приветствия |
| `HOST_PORT` | `8080` | порт приложения на компьютере (внутри контейнера всегда 8000) |

## Состав Compose

- `app`: образ из `Dockerfile`, `STORAGE=redis`, `REDIS_URL=redis://redis:6379/0`, healthcheck по `/readyz`. Работает от UID 10001, файловая система только для чтения, лимиты 256 MiB RAM и 1 CPU. Единственный опубликованный порт.
- `redis`: `redis:7.4-alpine` с `--appendonly yes`, volume `redis-data` на `/data`, healthcheck `redis-cli ping`.

## Автоматическая проверка (10 баллов)

```bash
./scripts/check.sh
```

Скрипт создаёт отдельный тестовый проект, проверяет счётчик, пересоздание `app`, отключение Redis, делает резервную копию данных в `backups/` и удаляет проект вместе с volumes.

## Отчёт

Файлы в папке `report/`:

- `level4_logs.txt`: логи одного контейнера (4 балла)
- `level6.txt`: Compose и volume, счётчик сохраняется (6 баллов)
- `level8.txt`: проверки с Redis: `down`/`up`, остановка и запуск Redis (8 баллов)
- `level10_limits.txt`: UID, read-only, лимиты памяти и CPU
- `level10_run1.txt`, `level10_run2.txt`: два успешных запуска `scripts/check.sh` подряд
