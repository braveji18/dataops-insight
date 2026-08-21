#!/usr/bin/env bash
#
# lakehouse-lab 기동.
#
#   bin/up.sh                 # functional 프로파일 + Hive 4 (기본)
#   bin/up.sh perf            # perf 프로파일 (Docker 16GB 이상 필요)
#   bin/up.sh --hive 3        # Hive Metastore 3.1.3 변형
#   bin/up.sh --no-seed       # 시드 없이 인프라만
#
# 멱등하다. 이미 떠 있으면 부족한 것만 채우고 green 을 확인한 뒤 끝난다.
# 단, hive 변형 전환은 멱등하지 않다 — HMS 스키마가 호환되지 않으므로 reset 을 요구한다.

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

PROFILE="functional"
HIVE=""
DO_SEED=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-seed) DO_SEED=0; shift ;;
    --hive)    HIVE="${2:-}"; shift 2 ;;
    --hive=*)  HIVE="${1#--hive=}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*)        lab_die "알 수 없는 옵션: $1" ;;
    *)         PROFILE="$1"; shift ;;
  esac
done

# 기본 hive 변형은 versions.env 가 들고 있다(LAB_HIVE_DEFAULT).
if [ -z "$HIVE" ]; then
  HIVE="$(sed -n 's/^LAB_HIVE_DEFAULT=//p' "$LAB_ROOT/versions.env" | tail -1)"
  HIVE="${HIVE:-4}"
fi

# --- 사전 점검 ----------------------------------------------------------------
docker info >/dev/null 2>&1 || lab_die "Docker 데몬이 응답하지 않는다. 먼저 Docker 를 켤 것."

# hive 변형 전환 가드.
#   Hive 3 은 metastore 스키마 3.1.0, Hive 4 는 4.0.0 을 쓴다. 같은 hms-pg-data 볼륨
#   위에서 변형만 바꾸면 schematool 이 버전 불일치로 죽거나, 최악의 경우 조용히
#   반쯤 동작한다. 사고를 나중에 발견하는 것보다 여기서 멈추는 편이 싸다.
PREV_HIVE="$(lab_current_hive)"
if [ -n "$PREV_HIVE" ] && [ "$PREV_HIVE" != "$HIVE" ] && [ "${LAB_FORCE_HIVE_SWITCH:-0}" != "1" ]; then
  lab_fail "hive 변형이 바뀌었다 (현재 .env=$PREV_HIVE → 요청=$HIVE)."
  lab_die "HMS 스키마가 호환되지 않는다. 볼륨째 갈아야 한다:  bin/reset.sh $PROFILE --hive $HIVE"
fi

lab_render_env "$PROFILE" "$HIVE"
lab_load_env
lab_info "프로파일=$LAB_PROFILE  Trino=$TRINO_VERSION  StarRocks=$STARROCKS_VERSION  Hive=$HIVE_VERSION($HMS_PLATFORM)  데이터=TPC-H $TPCH_SCHEMA"

DOCKER_MEM="$(docker info --format '{{.MemTotal}}')"
if [ "$DOCKER_MEM" -lt "$LAB_MIN_DOCKER_MEM_BYTES" ]; then
  lab_fail "Docker 메모리 부족: 할당 $((DOCKER_MEM/1000/1000))MB < 필요 $((LAB_MIN_DOCKER_MEM_BYTES/1000/1000))MB"
  if lab_is_darwin; then
    lab_die "Docker Desktop > Settings > Resources 에서 메모리를 올리거나, 더 작은 프로파일을 쓸 것."
  else
    # 리눅스 네이티브 도커에서 MemTotal 은 "호스트 총 RAM"이다(=VM 할당량이 아니다).
    # 다른 프로세스가 쓰는 몫은 빠지지 않으므로 이 검사는 상한만 걸러낸다.
    lab_die "호스트 RAM 이 부족하다. 여유를 확보하거나 더 작은 프로파일을 쓸 것."
  fi
fi

# --- 기동 --------------------------------------------------------------------
lab_info "Hive Metastore 이미지 빌드 (hive $HIVE_VERSION + hadoop-aws $HADOOP_AWS_VERSION)"
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
