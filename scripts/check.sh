#!/usr/bin/env bash
# Останавливаться при любой ошибке
set -Eeuo pipefail

# Работаем из корня репозитория, откуда бы ни запустили скрипт
cd "$(dirname "$0")/.."

# Уникальное имя тестового проекта, чтобы не задеть основной стек
PROJECT="hwcheck_$$"
# Порт 0 = Docker сам выберет свободный порт
export HOST_PORT=0
export GREETING="check"
STAGE="подготовка"
PORT=""
BACKUP_DIR="$PWD/backups"
BACKUP_FILE="redis-data-$(date +%Y%m%d-%H%M%S).tar"
REDIS_IMAGE="redis:7.4-alpine"

# "dc ..." = "docker compose -p <наш проект> ..."
dc() { docker compose -p "$PROJECT" "$@"; }

# Выполняется при любом выходе из скрипта (успех или ошибка)
on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ОШИБКА на этапе: $STAGE (код $rc)" >&2
    dc logs --tail=30 >&2 || true
  fi
  # убираем только свои тестовые ресурсы
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  exit "$rc"
}
trap on_exit EXIT

fail() { echo "ОШИБКА: $*" >&2; exit 1; }

# Узнать, на какой порт Docker опубликовал приложение
refresh_port() {
  local out
  out="$(dc port app 8000 | head -n1)"
  PORT="${out##*:}"
  [ -n "$PORT" ] || fail "не удалось определить порт приложения"
}

url() { echo "http://127.0.0.1:${PORT}$1"; }

# Вернуть HTTP-код ответа: http_code GET /readyz
http_code() {
  curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -X "$1" "$(url "$2")" 2>/dev/null || true
}

# Вытащить число count из JSON
get_count() {
  curl -fsS --max-time 5 "$(url /)" \
    | sed -n 's/.*"count"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

# Ждать до 60 секунд, пока /readyz не вернёт 200
wait_ready() {
  local i
  for i in $(seq 1 60); do
    if [ "$(http_code GET /readyz)" = "200" ]; then return 0; fi
    sleep 1
  done
  fail "сервис не стал готов за 60 секунд"
}

# Сравнить: expect_eq "что проверяем" ожидалось получено
expect_eq() {
  [ "$2" = "$3" ] || fail "$1: ожидалось '$2', получено '$3'"
  echo "OK: $1 = $3"
}

STAGE="1. запуск проекта и ожидание готовности"
dc up -d --build --wait --wait-timeout 120
refresh_port
wait_ready

STAGE="2. начальный счётчик и POST /increment"
expect_eq "начальный счётчик" 0 "$(get_count)"
N=5
for _ in $(seq 1 "$N"); do
  [ "$(http_code POST /increment)" = "200" ] || fail "POST /increment вернул не 200"
done
expect_eq "счётчик после $N инкрементов" "$N" "$(get_count)"

STAGE="3. пересоздание только контейнера app"
dc up -d --force-recreate --no-deps --wait --wait-timeout 60 app
refresh_port
wait_ready
expect_eq "счётчик после пересоздания app" "$N" "$(get_count)"

STAGE="4. остановка и запуск Redis"
dc stop redis
expect_eq "healthz при остановленном Redis" 200 "$(http_code GET /healthz)"
expect_eq "readyz при остановленном Redis" 503 "$(http_code GET /readyz)"
expect_eq "POST /increment при остановленном Redis" 503 "$(http_code POST /increment)"
dc start redis
wait_ready
expect_eq "счётчик после возвращения Redis" "$N" "$(get_count)"
expect_eq "POST после восстановления" 200 "$(http_code POST /increment)"
expect_eq "счётчик N+1" "$((N + 1))" "$(get_count)"

STAGE="5. резервная копия данных Redis"
# Останавливаем app и Redis, чтобы копия была согласованной
dc stop app redis
mkdir -p "$BACKUP_DIR"
VOLUME="${PROJECT}_redis-data"
# Временный контейнер: монтирует volume и папку backups, пакует /data в tar
docker run --rm \
  -v "${VOLUME}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  --entrypoint sh "$REDIS_IMAGE" \
  -c "tar -C /data -cpf /backup/${BACKUP_FILE} . && chown $(id -u):$(id -g) /backup/${BACKUP_FILE}"
[ -s "${BACKUP_DIR}/${BACKUP_FILE}" ] || fail "файл резервной копии пустой"
# Проверяем, что в архиве есть данные Redis
docker run --rm -v "${BACKUP_DIR}:/backup:ro" --entrypoint sh "$REDIS_IMAGE" \
  -c "tar -tf /backup/${BACKUP_FILE} | grep -q appendonlydir" \
  || fail "в архиве нет данных Redis (appendonlydir)"
echo "OK: резервная копия ${BACKUP_DIR}/${BACKUP_FILE}"

STAGE="6. удаление тестового проекта вместе с volumes"
dc down -v --remove-orphans
[ -z "$(docker volume ls -q --filter "name=^${PROJECT}_")" ] || fail "остались volumes проекта"
echo "OK: проект удалён"

STAGE="готово"
echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
