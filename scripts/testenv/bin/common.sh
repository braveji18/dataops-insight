#!/usr/bin/env bash
# lakehouse-lab 공통 함수. 직접 실행하지 말고 source 할 것.
#
# 이식성 규칙 (macOS / 리눅스 양쪽에서 돌아야 한다):
#   - macOS 기본 bash 는 3.2 다. 연관배열, ${var,,}, mapfile 등 4.x 문법은 쓰지 않는다.
#   - BSD(macOS)와 GNU(리눅스)가 갈리는 명령은 쓰기 전에 판별한다. 현재 해당하는 것은
#     date 뿐이고 lab_now_ms 가 처리한다. sed/grep 은 양쪽 공통 문법만 쓴다.
#   - 검증 현황: macOS arm64 는 hive 3 / hive 4 모두 실행 확인. 리눅스는 미검증.

set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_ENV_FILE="$LAB_ROOT/.env"

# --- 출력 ---------------------------------------------------------------------
lab_info()  { printf '\033[0;36m[lab]\033[0m %s\n' "$*" >&2; }
lab_ok()    { printf '\033[0;32m[ ok]\033[0m %s\n' "$*" >&2; }
lab_warn()  { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
lab_fail()  { printf '\033[0;31m[fail]\033[0m %s\n' "$*" >&2; }
lab_die()   { lab_fail "$*"; exit 1; }

# --- 호스트 ------------------------------------------------------------------
lab_is_darwin() { [ "$(uname -s)" = "Darwin" ]; }

# 호스트 아키텍처를 docker 의 platform 문자열로. 멀티아치 이미지에 아키텍처를
# 명시적으로 박아, compose 가 무엇을 고를지 추측하지 않게 만든다.
lab_host_platform() {
  case "$(uname -m)" in
    arm64|aarch64) echo "linux/arm64" ;;
    x86_64|amd64)  echo "linux/amd64" ;;
    *)             echo "linux/$(uname -m)" ;;
  esac
}

# q.sh 가 perl 로 SQL 말미 세미콜론 제거와 EXPLAIN 개행 복원을 한다.
# 최소 설치 리눅스에는 perl 이 없을 수 있어, 조용히 틀리는 대신 미리 알린다.
command -v perl >/dev/null 2>&1 || \
  lab_warn "perl 이 없다. bin/q.sh 의 세미콜론 처리와 EXPLAIN 개행 복원이 동작하지 않는다."

# --- 메모리 표기 --------------------------------------------------------------
# docker mem_limit 표기("768m", "1g")를 다루는 두 함수.

# "768m" → 768, "1g" → 1024. 단위를 MB 정수로 통일해 비교 가능하게 만든다.
lab_mem_mb() {
  local num unit
  num="$(printf '%s' "$1" | sed 's/[^0-9]*$//')"
  unit="$(printf '%s' "$1" | sed 's/^[0-9]*//' | tr 'A-Z' 'a-z')"
  case "$unit" in
    g) echo $((num * 1024)) ;;
    *) echo "$num" ;;
  esac
}

# "768m" → "1536m", "1g" → "2g". 단위 표기는 그대로 유지한다.
lab_double_mem() {
  local num unit
  num="$(printf '%s' "$1" | sed 's/[^0-9]*$//')"
  unit="$(printf '%s' "$1" | sed 's/^[0-9]*//')"
  echo "$((num * 2))${unit}"
}

# --- .env 합성 ----------------------------------------------------------------
# 원본 3개를 합쳐 .env 를 만든다. .env 는 생성물이라 gitignore 대상이고,
# 손으로 고쳐도 다음 up.sh 에서 덮어써진다. 값을 바꾸려면 원본을 고칠 것.
#
#   versions.env        버전 기준선 (이미지 digest, 랩 고정 상수)
#   hive/hive<N>.env    HMS 변형 (Hive 3 / 4 — 이미지, hadoop-aws, 아키텍처가 한 세트)
#   profiles/<p>.env    자원·데이터 규모 (functional / perf)
#                                                              → .env
lab_render_env() {
  local profile="$1" hive="${2:-4}"
  local pfile="$LAB_ROOT/profiles/${profile}.env"
  local hfile="$LAB_ROOT/hive/hive${hive}.env"
  [ -f "$pfile" ] || lab_die "알 수 없는 프로파일: $profile (사용 가능: $(ls "$LAB_ROOT/profiles" | sed 's/\.env//' | tr '\n' ' '))"
  [ -f "$hfile" ] || lab_die "알 수 없는 hive 변형: $hive (사용 가능: $(ls "$LAB_ROOT/hive" | sed 's/^hive//;s/\.env//' | tr '\n' ' '))"

  local hms_platform host_platform
  host_platform="$(lab_host_platform)"
  hms_platform="$(lab_effective_hms_platform "$hfile")"

  {
    echo "# 이 파일은 bin/up.sh 가 생성한다. 직접 수정하지 말 것 (다음 up.sh 가 덮어쓴다)."
    echo "# 원본: versions.env + hive/hive${hive}.env + profiles/${profile}.env"
    cat "$LAB_ROOT/versions.env"
    echo
    cat "$hfile"

    # 변형이 플랫폼을 고정하지 않았다면(=멀티아치 이미지) 호스트 아키텍처를 채운다.
    if ! grep -qE '^HMS_PLATFORM=' "$hfile"; then
      echo
      echo "# up.sh 가 호스트 아키텍처로 채운 값 (hive${hive}.env 가 고정하지 않음)"
      echo "HMS_PLATFORM=${host_platform}"
    fi
    echo

    if [ "$hms_platform" = "$host_platform" ]; then
      cat "$pfile"
    else
      # 에뮬레이션 보정. HMS_MEM 은 프로파일 원본 줄을 빼고 보정값으로 대체한다
      # — 같은 키를 두 번 쓰면 last-wins 로 동작은 하지만 .env 를 읽는 사람이 헷갈린다.
      grep -v '^HMS_MEM=' "$pfile"
      echo
      echo "# 에뮬레이션 보정 (HMS_PLATFORM=${hms_platform} != 호스트=${host_platform})"
      echo "# 다른 아키텍처로 돌리면 QEMU 변환 캐시와 JIT 오버헤드로 RSS 가 네이티브보다"
      echo "# 크게 뜬다. 실측: hive 3.1.3(amd64) on arm64 는 768m 한도에서 ObjectStore"
      echo "# 초기화 도중 SIGKILL(137). 프로파일 값의 2배를 준다."
      echo "HMS_MEM=$(lab_double_mem "$(sed -n 's/^HMS_MEM=//p' "$pfile" | tail -1)")"
    fi
  } > "$LAB_ENV_FILE"

  lab_check_hms_mem
}

# 변형이 플랫폼을 고정했으면 그 값, 아니면 호스트 플랫폼.
lab_effective_hms_platform() {
  local p
  p="$(sed -n 's/^HMS_PLATFORM=//p' "$1" | tail -1)"
  [ -n "$p" ] && echo "$p" || lab_host_platform
}

# 불변식: HMS_MEM > HMS_HEAP.
#
# 이 규칙이 코드로 들어와 있는 이유 — 양쪽으로 다 틀려봤기 때문이다.
#   한도 < 힙:  이미지 entrypoint 가 -Xmx 를 강제하는데 컨테이너 한도가 그보다 작으면,
#               JVM 은 한도를 모른 채 힙을 늘리다 SIGKILL(137) 로 죽는다.
#   힙을 줄임:  한도에 맞춰 힙을 512m 로 낮췄더니 GC 스래싱으로 schematool 이 6분 넘게
#               진행하지 못했다(CPU 200% 고정, 로그 정지). 힙을 줄이는 방향이 아니라
#               한도를 키우는 방향이 맞다.
lab_check_hms_mem() {
  local mem heap
  mem="$(sed -n 's/^HMS_MEM=//p'  "$LAB_ENV_FILE" | tail -1)"
  heap="$(sed -n 's/^HMS_HEAP=//p' "$LAB_ENV_FILE" | tail -1)"
  [ -n "$mem" ] && [ -n "$heap" ] || lab_die "HMS_MEM / HMS_HEAP 이 프로파일에 없다."
  [ "$(lab_mem_mb "$mem")" -gt "$(lab_mem_mb "$heap")" ] || \
    lab_die "HMS_MEM($mem) 은 HMS_HEAP($heap) 보다 커야 한다. 프로파일의 HMS_MEM 을 올릴 것 (힙을 줄이면 GC 스래싱으로 더 나빠진다)."
}

lab_load_env() {
  [ -f "$LAB_ENV_FILE" ] || lab_die ".env 가 없다. 먼저 bin/up.sh 를 실행할 것."
  set -a
  # shellcheck disable=SC1090
  . "$LAB_ENV_FILE"
  set +a
}

# 지금 떠 있는 랩이 어떤 hive 변형으로 렌더링됐는지. .env 가 없으면 빈 문자열.
lab_current_hive() {
  [ -f "$LAB_ENV_FILE" ] || { echo ""; return 0; }
  sed -n 's/^HIVE_VARIANT=//p' "$LAB_ENV_FILE" | tail -1
}

# --- docker compose 래퍼 ------------------------------------------------------
dc() {
  docker compose \
    --project-directory "$LAB_ROOT" \
    --env-file "$LAB_ENV_FILE" \
    -f "$LAB_ROOT/docker-compose.yml" "$@"
}

# --- 시간 측정 ----------------------------------------------------------------
# GNU date 는 %N(나노초)을 지원하지만 BSD(macOS) date 는 %N 을 문자 그대로 뱉는다.
# 한 번 판별해 두고 함수를 확정한다. perl 도 없으면 초 단위로 떨어진다.
if date +%s%3N 2>/dev/null | grep -qE '^[0-9]+$'; then
  lab_now_ms() { date +%s%3N; }
elif command -v perl >/dev/null 2>&1; then
  lab_now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1000'; }
else
  lab_now_ms() { echo $(( $(date +%s) * 1000 )); }
fi

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

# --- StarRocks DDL 실행기 -----------------------------------------------------
# 기동 직후 카탈로그를 등록하는 up.sh 전용. 일반 쿼리는 전부 bin/q.sh 를 쓴다.
# (Trino 는 카탈로그가 파일로 선언되므로 대응하는 함수가 필요 없다)
#
# ★ stdin 을 반드시 /dev/null 로 끊는다.
#   docker compose exec -T 는 stdin 을 컨테이너로 스트리밍하고 EOF 를 기다린다.
#   터미널에서 직접 치면 드러나지 않지만, stdin 이 열린 채 EOF 가 오지 않는 실행
#   (nohup/백그라운드 잡, CI, 에이전트)에서는 SQL 이 끝났는데도 반환하지 않는다.
#   실측: up.sh 의 카탈로그 등록이 4분 넘게 정지 — 카탈로그는 이미 생성돼 있었다.
#   SQL 은 인자로 받으므로 stdin 이 애초에 필요 없다. bin/q.sh 도 같은 이유로 끊는다.
lab_sr_exec() {
  dc exec -T starrocks-fe \
    mysql -h127.0.0.1 -P9030 -uroot --batch -e "$1" < /dev/null
}
