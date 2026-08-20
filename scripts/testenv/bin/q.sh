#!/usr/bin/env bash
#
# 두 엔진에 대한 단일 쿼리 진입점.
#
#   bin/q.sh trino "SELECT count(*) FROM iceberg.bench.lineitem"
#   bin/q.sh sr    "SELECT count(*) FROM iceberg.bench.lineitem"
#   bin/q.sh trino --explain "SELECT ..."
#   bin/q.sh sr -f probe.sql
#   echo "SELECT 1" | bin/q.sh trino -f -
#
# 설계 의도:
#   1) Trino(HTTP/CLI)와 StarRocks(MySQL 프로토콜)의 접속 방식 차이를 숨긴다.
#   2) 출력을 TSV+헤더로 통일한다 → 두 엔진 결과를 그대로 diff 할 수 있다.
#   3) 호출 형태가 하나뿐이라 .claude/settings.json 에 한 줄로 허용된다(퍼미션 프롬프트 제거).
#
# 옵션:
#   -f FILE           파일에서 SQL 읽기 ('-' 면 stdin)
#   --explain         EXPLAIN 을 붙여 실행
#   --explain-analyze EXPLAIN ANALYZE 를 붙여 실행
#   --catalog NAME    기본 iceberg
#   --schema NAME     기본 bench
#   --no-prelude      카탈로그/스키마 지정 없이 원문 그대로 (system.*, SHOW BACKENDS 등)
#   --raw             헤더 없이 값만
#   --timing          실행 시간(ms)을 stderr 에 출력

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
lab_load_env

ENGINE="${1:-}"; shift || true
[ "$ENGINE" = "trino" ] || [ "$ENGINE" = "sr" ] || lab_die "사용법: q.sh <trino|sr> [옵션] \"SQL\""

CATALOG="$ICEBERG_CATALOG"
SCHEMA="$BENCH_SCHEMA"
PRELUDE=1
RAW=0
TIMING=0
PREFIX=""
SQL=""
SQL_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -f)                SQL_FILE="$2"; shift 2 ;;
    --explain)         PREFIX="EXPLAIN "; shift ;;
    --explain-analyze) PREFIX="EXPLAIN ANALYZE "; shift ;;
    --catalog)         CATALOG="$2"; shift 2 ;;
    --schema)          SCHEMA="$2"; shift 2 ;;
    --no-prelude)      PRELUDE=0; shift ;;
    --raw)             RAW=1; shift ;;
    --timing)          TIMING=1; shift ;;
    -h|--help)         sed -n '2,30p' "$0"; exit 0 ;;
    --)                shift; SQL="$*"; break ;;
    -*)
      # SQL 이 주석(`-- ...`)으로 시작하면 옵션처럼 보인다. 공백/개행이 있으면 SQL 로 본다.
      if printf '%s' "$1" | grep -q '[[:space:]]'; then SQL="$1"; shift
      else lab_die "알 수 없는 옵션: $1"; fi ;;
    *)                 SQL="$1"; shift ;;
  esac
done

if [ -n "$SQL_FILE" ]; then
  if [ "$SQL_FILE" = "-" ]; then SQL="$(cat)"; else SQL="$(cat "$SQL_FILE")"; fi
fi
[ -n "$SQL" ] || lab_die "실행할 SQL 이 없다."

# 입력 "전체"의 맨 끝 세미콜론만 제거한다 (EXPLAIN 접두, SR prelude 조합 때 걸린다).
# sed 로 하면 줄마다 지워져서 다중 구문 파일이 한 덩어리로 합쳐진다 — perl 로 전체를 한 번에.
SQL="$(printf '%s' "$SQL" | perl -0pe 's/\s*;\s*\z//')"
SQL="${PREFIX}${SQL}"

START="$(lab_now_ms)"
set +e
# ★ stdin 을 반드시 끊는다. docker compose exec -T 는 stdin 을 통째로 삼키기 때문에,
#   호출부가 while read 루프 안이면 나머지 입력이 사라져 한 줄만 실행되고 조용히 끝난다.
#   (SQL 은 이미 위에서 변수로 읽어둔 상태라 stdin 이 필요 없다)
exec 0</dev/null
if [ "$ENGINE" = "trino" ]; then
  fmt="TSV_HEADER"; [ "$RAW" -eq 1 ] && fmt="TSV"
  # EXPLAIN 결과는 TSV 한 칸에 담기면서 개행이 \n 으로 이스케이프된다. 되돌려 준다.
  unescape() { if [ -n "$PREFIX" ]; then perl -pe 's/\\n/\n/g'; else cat; fi; }
  if [ "$PRELUDE" -eq 1 ]; then
    dc exec -T trino-coordinator trino --server localhost:8080 \
      --catalog "$CATALOG" --schema "$SCHEMA" --output-format "$fmt" --execute "$SQL" | unescape
  else
    dc exec -T trino-coordinator trino --server localhost:8080 \
      --output-format "$fmt" --execute "$SQL" | unescape
  fi
else
  # StarRocks: --batch 가 TSV 를 만든다. --skip-column-names 로 헤더 제거.
  hdr=""; [ "$RAW" -eq 1 ] && hdr="--skip-column-names"
  if [ "$PRELUDE" -eq 1 ]; then
    STMT="SET CATALOG ${CATALOG}; USE ${SCHEMA}; ${SQL}"
  else
    STMT="$SQL"
  fi
  dc exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot --batch --raw $hdr -e "$STMT"
fi
RC=$?
set -e
END="$(lab_now_ms)"

[ "$TIMING" -eq 1 ] && printf 'elapsed_ms=%s engine=%s rc=%s\n' "$((END - START))" "$ENGINE" "$RC" >&2
exit "$RC"
