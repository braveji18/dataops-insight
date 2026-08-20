#!/usr/bin/env bash
# lakehouse-lab 공통 함수. 직접 실행하지 말고 source 할 것.
# macOS 기본 bash 3.2 에서도 동작해야 하므로 연관배열/${var,,} 등은 쓰지 않는다.

set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_ENV_FILE="$LAB_ROOT/.env"

# --- 출력 ---------------------------------------------------------------------
lab_info()  { printf '\033[0;36m[lab]\033[0m %s\n' "$*" >&2; }
lab_ok()    { printf '\033[0;32m[ ok]\033[0m %s\n' "$*" >&2; }
lab_warn()  { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
lab_fail()  { printf '\033[0;31m[fail]\033[0m %s\n' "$*" >&2; }
lab_die()   { lab_fail "$*"; exit 1; }

# --- .env 합성 ----------------------------------------------------------------
# versions.env(버전 기준선) + profiles/<p>.env(자원·데이터 규모) → .env
# .env 는 생성물이므로 gitignore 대상. 원본은 항상 위 두 파일뿐이다.
lab_render_env() {
  local profile="$1"
  local pfile="$LAB_ROOT/profiles/${profile}.env"
  [ -f "$pfile" ] || lab_die "알 수 없는 프로파일: $profile (사용 가능: $(ls "$LAB_ROOT/profiles" | sed 's/\.env//' | tr '\n' ' '))"
  {
    echo "# 이 파일은 bin/up.sh 가 생성한다. 직접 수정하지 말 것."
    echo "# 원본: versions.env + profiles/${profile}.env"
    cat "$LAB_ROOT/versions.env"
    echo
    cat "$pfile"
  } > "$LAB_ENV_FILE"
}

lab_load_env() {
  [ -f "$LAB_ENV_FILE" ] || lab_die ".env 가 없다. 먼저 bin/up.sh 를 실행할 것."
  set -a
  # shellcheck disable=SC1090
  . "$LAB_ENV_FILE"
  set +a
}

# --- docker compose 래퍼 ------------------------------------------------------
dc() {
  docker compose \
    --project-directory "$LAB_ROOT" \
    --env-file "$LAB_ENV_FILE" \
    -f "$LAB_ROOT/docker-compose.yml" "$@"
}

# --- 시간 측정 (macOS date 는 %N 미지원이라 perl 사용) --------------------------
lab_now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1000'; }

# --- 헬스 대기 ----------------------------------------------------------------
lab_container_health() {
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo "absent"
}

lab_wait_healthy() {
  local container="$1" timeout="${2:-180}" waited=0 st
  while [ "$waited" -lt "$timeout" ]; do
    st="$(lab_container_health "$container")"
    case "$st" in
      healthy|running) echo "$st"; return 0 ;;
      exited|dead)     lab_fail "$container 가 죽었다 (status=$st)"; return 1 ;;
    esac
    sleep 3
    waited=$((waited + 3))
  done
  lab_fail "$container 헬스 대기 시간 초과 (${timeout}s, 마지막 상태=$st)"
  return 1
}

# --- 엔진 실행기 --------------------------------------------------------------
# 두 엔진 모두 "TSV + 헤더" 로 표준화한다. 출력 포맷이 같아야 결과 diff 가 가능하다.
lab_trino_exec() {
  dc exec -T trino-coordinator \
    trino --server localhost:8080 --output-format "${LAB_TRINO_FORMAT:-TSV_HEADER}" \
    ${LAB_TRINO_CATALOG:+--catalog "$LAB_TRINO_CATALOG"} \
    ${LAB_TRINO_SCHEMA:+--schema "$LAB_TRINO_SCHEMA"} \
    --execute "$1"
}

lab_sr_exec() {
  dc exec -T starrocks-fe \
    mysql -h127.0.0.1 -P9030 -uroot --batch ${LAB_SR_RAW:+--raw} -e "$1"
}
