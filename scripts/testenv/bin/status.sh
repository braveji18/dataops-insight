#!/usr/bin/env bash
#
# 랩 상태 점검. exit 0 = 비교 실험을 시작해도 되는 상태.
#
# ★ 이 스크립트의 존재 이유: "컨테이너가 떴다"와 "비교가 가능하다"는 다르다.
#   docker ps 가 green 이어도 카탈로그가 안 붙었거나 한쪽 엔진만 데이터를 못 보는 상태가
#   흔하다. 그래서 판정 기준을 문장이 아니라 실제 쿼리로 못 박는다.
#   AI 든 사람이든 "잘 뜬 것 같다"고 판단할 여지를 남기지 않기 위한 장치다.

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
lab_load_env

Q="$LAB_ROOT/bin/q.sh"
FAILED=0

check() { # check <이름> <명령...>
  local name="$1"; shift
  printf '  %-38s ' "$name"
  if out="$("$@" 2>&1)"; then
    printf '\033[0;32mOK\033[0m\n'
  else
    printf '\033[0;31mFAIL\033[0m\n'
    printf '%s\n' "$out" | sed 's/^/      /' | head -5
    FAILED=1
  fi
}

t_worker_registered() {
  [ "$("$Q" trino --no-prelude --raw "SELECT count(*) FROM system.runtime.nodes WHERE coordinator = false AND state = 'active'")" = "1" ]
}
s_be_alive() {
  "$Q" sr --no-prelude --raw "SHOW BACKENDS" | grep -q "true"
}
t_iceberg_visible() { "$Q" trino --no-prelude --raw "SHOW SCHEMAS FROM iceberg" >/dev/null; }
s_iceberg_visible() { "$Q" sr    --no-prelude --raw "SHOW DATABASES FROM iceberg" >/dev/null; }

echo "lakehouse-lab / profile=$LAB_PROFILE / trino=$TRINO_VERSION / starrocks=$STARROCKS_VERSION / hive=$HIVE_VERSION($HMS_PLATFORM)"
echo
echo "[1] 컨테이너"
for c in lab-minio lab-hms-postgres lab-hive-metastore lab-trino-coordinator lab-trino-worker lab-starrocks-fe lab-starrocks-be; do
  st="$(lab_container_health "$c")"
  case "$st" in
    healthy|running) printf '  %-38s \033[0;32m%s\033[0m\n' "$c" "$st" ;;
    *)               printf '  %-38s \033[0;31m%s\033[0m\n' "$c" "$st"; FAILED=1 ;;
  esac
done

echo
echo "[2] 클러스터 구성 (coordinator+worker / FE+BE)"
check "trino: active worker 1대" t_worker_registered
check "starrocks: BE alive"      s_be_alive

echo
echo "[3] 동일 Iceberg 카탈로그 접속 (실제 쿼리로 확인)"
check "trino: SHOW SCHEMAS FROM iceberg"     t_iceberg_visible
check "starrocks: SHOW DATABASES FROM iceberg" s_iceberg_visible

echo
echo "[4] 시드 데이터 정합성 (양쪽이 같은 행 수를 보는가)"
T_CNT="$("$Q" trino --raw "SELECT count(*) FROM iceberg.bench.lineitem" 2>/dev/null | tail -1 || echo -)"
S_CNT="$("$Q" sr    --raw "SELECT count(*) FROM iceberg.bench.lineitem" 2>/dev/null | tail -1 || echo -)"
printf '  %-38s trino=%s starrocks=%s ' "bench.lineitem 행 수" "${T_CNT:--}" "${S_CNT:--}"
if [ -n "$T_CNT" ] && [ "$T_CNT" = "$S_CNT" ] && [ "$T_CNT" != "-" ] && [ "$T_CNT" != "0" ]; then
  printf '\033[0;32mMATCH\033[0m\n'
else
  printf '\033[0;31mMISMATCH\033[0m  (bin/seed.sh 가 필요한가?)\n'
  FAILED=1
fi

echo
if [ "$FAILED" -eq 0 ]; then
  lab_ok "GREEN — 비교 실험 가능"
  echo
  echo "  Trino UI      http://localhost:8080"
  echo "  StarRocks FE  http://localhost:8030   mysql -h127.0.0.1 -P9030 -uroot"
  echo "  MinIO 콘솔    http://localhost:9001   ($S3_ACCESS_KEY / $S3_SECRET_KEY)"
  exit 0
else
  lab_fail "RED — 위 실패 항목 해결 필요. .claude/skills/lakehouse-lab/references/troubleshooting.md 참조"
  exit 1
fi
