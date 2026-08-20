#!/usr/bin/env bash
#
# lakehouse-lab 기동.
#
#   bin/up.sh                 # functional 프로파일(기본)
#   bin/up.sh perf            # perf 프로파일 (Docker 16GB 이상 필요)
#   bin/up.sh --no-seed       # 시드 없이 인프라만
#
# 멱등하다. 이미 떠 있으면 부족한 것만 채우고 green 을 확인한 뒤 끝난다.

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

PROFILE="functional"
DO_SEED=1
for arg in "$@"; do
  case "$arg" in
    --no-seed) DO_SEED=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) lab_die "알 수 없는 옵션: $arg" ;;
    *)  PROFILE="$arg" ;;
  esac
done

# --- 사전 점검 ----------------------------------------------------------------
docker info >/dev/null 2>&1 || lab_die "Docker 데몬이 응답하지 않는다. Docker Desktop 을 먼저 켤 것."

lab_render_env "$PROFILE"
lab_load_env
lab_info "프로파일=$LAB_PROFILE  Trino=$TRINO_VERSION  StarRocks=$STARROCKS_VERSION  데이터=TPC-H $TPCH_SCHEMA"

DOCKER_MEM="$(docker info --format '{{.MemTotal}}')"
if [ "$DOCKER_MEM" -lt "$LAB_MIN_DOCKER_MEM_BYTES" ]; then
  lab_fail "Docker 메모리 부족: 할당 $((DOCKER_MEM/1000/1000))MB < 필요 $((LAB_MIN_DOCKER_MEM_BYTES/1000/1000))MB"
  lab_die "Docker Desktop > Settings > Resources 에서 메모리를 올리거나, 더 작은 프로파일을 쓸 것."
fi

# --- 기동 --------------------------------------------------------------------
lab_info "Hive Metastore 이미지 빌드 (hadoop-aws $HADOOP_AWS_VERSION 주입)"
dc build hive-metastore

lab_info "컨테이너 기동"
dc up -d

lab_info "헬스 대기 (최초 기동은 이미지 pull 포함 수 분 걸릴 수 있음)"
for c in lab-minio lab-hms-postgres lab-hive-metastore lab-trino-coordinator lab-starrocks-fe lab-starrocks-be; do
  printf '  %-26s ' "$c" >&2
  lab_wait_healthy "$c" 300
done

# --- StarRocks 카탈로그 등록 ---------------------------------------------------
# Trino 는 파일(iceberg.properties)로 카탈로그가 선언되지만 StarRocks 는 DDL 이라
# 기동 후 한 번 실행해줘야 한다. 이 비대칭 자체가 plan/01 A-5 의 비교 소재이기도 하다.
lab_info "StarRocks 에 Iceberg 카탈로그 등록"
lab_sr_exec "$(cat "$LAB_ROOT/sql/00-starrocks-catalog.sql")" >/dev/null
lab_ok "카탈로그 등록 완료"

if [ "$DO_SEED" -eq 1 ]; then
  "$LAB_ROOT/bin/seed.sh"
fi

exec "$LAB_ROOT/bin/status.sh"
