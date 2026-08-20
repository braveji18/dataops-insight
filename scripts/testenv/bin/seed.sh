#!/usr/bin/env bash
#
# 시드 데이터 적재.
#
#   bin/seed.sh                 # 프로파일에 맞는 TPC-H 를 Iceberg 로 적재
#   bin/seed.sh --with-native   # StarRocks 네이티브 테이블 사본까지 (plan/01 C-1 용)
#   bin/seed.sh --force         # 기존 bench 스키마를 지우고 다시
#
# 데이터 생성은 Trino 의 tpch 커넥터로 일원화한다. 두 엔진이 "같은 파일"을 읽어야
# 비교가 성립하므로, 적재 경로는 반드시 하나여야 한다.

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
lab_load_env

WITH_NATIVE=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --with-native) WITH_NATIVE=1 ;;
    --force)       FORCE=1 ;;
    -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
    *)             lab_die "알 수 없는 옵션: $arg" ;;
  esac
done

TABLES="nation region supplier part partsupp customer orders lineitem"

if [ "$FORCE" -eq 1 ]; then
  lab_warn "기존 iceberg.bench 를 삭제한다"
  for t in $TABLES; do
    "$LAB_ROOT/bin/q.sh" trino --no-prelude --raw "DROP TABLE IF EXISTS iceberg.bench.$t" >/dev/null 2>&1 || true
  done
  "$LAB_ROOT/bin/q.sh" trino --no-prelude --raw "DROP SCHEMA IF EXISTS iceberg.bench" >/dev/null 2>&1 || true
fi

lab_info "TPC-H $TPCH_SCHEMA → iceberg.bench 적재 (Trino tpch 커넥터 경유)"
SQL="$(sed "s/@TPCH@/${TPCH_SCHEMA}/g" "$LAB_ROOT/sql/seed/tpch-iceberg.sql.tmpl")"

# Trino CLI 는 --execute 로 여러 구문을 받지만, 실패 지점을 알려면 한 줄씩 돌리는 편이 낫다.
# (파이프 대신 파일 리다이렉션 — 파이프의 while 은 서브셸이라 실패 시 exit 가 먹지 않는다)
TMP_SQL="$(mktemp -t lab-seed)"
trap 'rm -f "$TMP_SQL"' EXIT
printf '%s\n' "$SQL" | grep -E '^(CREATE|ANALYZE)' > "$TMP_SQL"
while IFS= read -r stmt; do
  [ -n "$stmt" ] || continue
  printf '  %s\n' "$(printf '%s' "$stmt" | cut -c1-72)" >&2
  "$LAB_ROOT/bin/q.sh" trino --no-prelude --raw "$stmt" >/dev/null \
    || lab_die "적재 실패: $stmt"
done < "$TMP_SQL"
lab_ok "Iceberg 시드 완료"

# StarRocks 쪽 통계. 외부 카탈로그 통계는 엔진이 직접 수집한다(plan/01 A-2 비교 소재).
lab_info "StarRocks 외부 테이블 통계 수집"
for t in $TABLES; do
  "$LAB_ROOT/bin/q.sh" sr --no-prelude --raw "ANALYZE TABLE iceberg.bench.$t" >/dev/null 2>&1 \
    || lab_warn "ANALYZE iceberg.bench.$t 실패 (통계 없이도 쿼리는 가능)"
done

if [ "$WITH_NATIVE" -eq 1 ]; then
  lab_info "StarRocks 네이티브 테이블 사본 적재 (C-1 비교용)"
  "$LAB_ROOT/bin/q.sh" sr --no-prelude --raw "$(cat "$LAB_ROOT/sql/seed/starrocks-native.sql")" >/dev/null \
    || lab_die "네이티브 적재 실패"
  lab_ok "native_bench 적재 완료"
fi

lab_ok "시드 완료 — bin/status.sh 로 양쪽 행 수 일치 확인 권장"
