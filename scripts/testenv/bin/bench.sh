#!/usr/bin/env bash
#
# 두 엔진에 동일 쿼리를 돌려 시간을 비교한다.
#
#   bin/bench.sh --label q1 --sql "SELECT count(*) FROM iceberg.bench.lineitem"
#   bin/bench.sh --label q1 -f queries/q1.sql --repeat 5 --warmup 2
#   bin/bench.sh --label q1 -f q1.sql --engines trino     # 한쪽만
#
# 측정 규칙(비교 공정성) — 바꾸려면 이 파일을 고치고, 결과 파일에 남는 값도 함께 바뀐다:
#   * warmup 1회 + 측정 3회, 중앙값 사용 (기본값)
#   * 두 엔진 각각에 대해 SELECT 1 왕복시간을 측정해 CLI/접속 오버헤드를 함께 기록
#   * 결과는 벽시계 시간이다. CLI 기동 + 접속 오버헤드가 포함되므로 짧은 쿼리일수록
#     overhead_ms 대비 비율을 함께 봐야 한다
#   * 호스트 지문(arch/cpu/mem)과 이미지 digest 를 매 결과에 박는다 —
#     다른 머신의 숫자를 무심코 비교하는 사고를 막기 위해서다
#
# ★ arm64(Apple Silicon) 주의: StarRocks BE 는 x86 에서 AVX2/AVX512, arm 에서 NEON 경로를
#   탄다. arm64 랩의 절대값을 x86 운영 판단 근거로 쓰지 말 것.

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
lab_load_env

LABEL="bench"
SQL=""
SQL_FILE=""
REPEAT=3
WARMUP=1
ENGINES="trino sr"
OUT_DIR="$LAB_ROOT/results"

while [ $# -gt 0 ]; do
  case "$1" in
    --label)   LABEL="$2"; shift 2 ;;
    --sql)     SQL="$2"; shift 2 ;;
    -f)        SQL_FILE="$2"; shift 2 ;;
    --repeat)  REPEAT="$2"; shift 2 ;;
    --warmup)  WARMUP="$2"; shift 2 ;;
    --engines) ENGINES="$(printf '%s' "$2" | tr ',' ' ')"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *)         lab_die "알 수 없는 옵션: $1" ;;
  esac
done

if [ -n "$SQL_FILE" ]; then
  if [ "$SQL_FILE" = "-" ]; then SQL="$(cat)"; else SQL="$(cat "$SQL_FILE")"; fi
fi
[ -n "$SQL" ] || lab_die "--sql 또는 -f 로 쿼리를 줄 것"

mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/${STAMP}-${LABEL}.json"

# --- 호스트 지문 --------------------------------------------------------------
HOST_ARCH="$(uname -m)"
HOST_OS="$(uname -s)"
DOCKER_CPUS="$(docker info --format '{{.NCPU}}')"
DOCKER_MEM="$(docker info --format '{{.MemTotal}}')"

run_once() { # run_once <engine> ; 소요 ms 를 stdout 으로
  local engine="$1" s e
  s="$(lab_now_ms)"
  "$LAB_ROOT/bin/q.sh" "$engine" --no-prelude --raw "$SQL" >/dev/null 2>&1 || return 1
  e="$(lab_now_ms)"
  echo $((e - s))
}

overhead_ms() { # 접속/CLI 왕복 기준선 — 짧은 쿼리의 수치를 해석하려면 반드시 필요하다
  local engine="$1" s e
  s="$(lab_now_ms)"
  "$LAB_ROOT/bin/q.sh" "$engine" --no-prelude --raw "SELECT 1" >/dev/null 2>&1 || true
  e="$(lab_now_ms)"
  echo $((e - s))
}

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2==1)? a[(NR+1)/2] : int((a[NR/2]+a[NR/2+1])/2)}'; }

printf '{\n' > "$OUT"
printf '  "label": "%s",\n  "timestamp_utc": "%s",\n' "$LABEL" "$STAMP" >> "$OUT"
printf '  "profile": "%s",\n  "tpch_scale": "%s",\n' "$LAB_PROFILE" "$TPCH_SCHEMA" >> "$OUT"
printf '  "warmup": %s,\n  "repeat": %s,\n' "$WARMUP" "$REPEAT" >> "$OUT"
printf '  "host": {"os": "%s", "arch": "%s", "docker_cpus": %s, "docker_mem_bytes": %s},\n' \
  "$HOST_OS" "$HOST_ARCH" "$DOCKER_CPUS" "$DOCKER_MEM" >> "$OUT"
printf '  "images": {"trino": "%s", "starrocks_fe": "%s", "starrocks_be": "%s"},\n' \
  "$TRINO_IMAGE" "$STARROCKS_FE_IMAGE" "$STARROCKS_BE_IMAGE" >> "$OUT"
printf '  "sql": %s,\n' "$(printf '%s' "$SQL" | awk 'BEGIN{printf "\""} {gsub(/"/,"\\\""); printf "%s ", $0} END{printf "\""}')" >> "$OUT"
printf '  "results": {\n' >> "$OUT"

echo
printf '%-10s %-12s %-12s %-10s %s\n' "engine" "median_ms" "overhead_ms" "runs" "label=$LABEL profile=$LAB_PROFILE"
printf '%-10s %-12s %-12s %-10s %s\n' "------" "---------" "-----------" "----" "----------------------"

FIRST=1
for engine in $ENGINES; do
  ov="$(overhead_ms "$engine")"

  i=0
  while [ "$i" -lt "$WARMUP" ]; do run_once "$engine" >/dev/null || lab_die "$engine warmup 실패 — bin/q.sh 로 직접 확인할 것"; i=$((i+1)); done

  RUNS=""
  i=0
  while [ "$i" -lt "$REPEAT" ]; do
    ms="$(run_once "$engine")" || lab_die "$engine 실행 실패"
    RUNS="$RUNS $ms"
    i=$((i+1))
  done
  # shellcheck disable=SC2086
  MED="$(median $RUNS)"

  printf '%-10s %-12s %-12s %-10s\n' "$engine" "$MED" "$ov" "$(printf '%s' "$RUNS" | sed 's/^ //;s/ /,/g')"

  [ "$FIRST" -eq 1 ] || printf ',\n' >> "$OUT"
  FIRST=0
  printf '    "%s": {"median_ms": %s, "overhead_ms": %s, "runs_ms": [%s]}' \
    "$engine" "$MED" "$ov" "$(printf '%s' "$RUNS" | sed 's/^ //;s/ /,/g')" >> "$OUT"
done

printf '\n  }\n}\n' >> "$OUT"
echo
lab_ok "결과 저장: ${OUT#"$LAB_ROOT"/}"
lab_warn "이 수치는 $HOST_ARCH / Docker ${DOCKER_CPUS}cpu 기준의 상대 비교값이다. 운영 환경 절대값으로 인용하지 말 것."
