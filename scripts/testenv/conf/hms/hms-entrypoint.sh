#!/bin/bash
#
# apache/hive 이미지의 /entrypoint.sh 앞에 끼우는 얇은 래퍼.
#
# 목적은 단 하나 — Hive 3 과 Hive 4 의 기동 차이를 여기서만 흡수하는 것.
# compose 파일과 metastore-site.xml 은 두 변형에서 완전히 동일하게 유지된다.
# (버전별 분기가 여러 파일로 번지면 "동일 조건 비교"라는 전제가 깨진다)
#
# HIVE_MAJOR 는 Dockerfile 이 이미지에 구워 넣는다. 3.1.3 이미지에는 HIVE_VER
# 환경변수 자체가 없어서 이미지에서 버전을 읽을 수 없기 때문이다.

set -uo pipefail

HIVE_HOME="${HIVE_HOME:-/opt/hive}"
CONF="${HIVE_HOME}/conf"

# 원래 /entrypoint.sh 도 같은 일을 하지만, 아래 schema 판정에 설정이 먼저 필요하다.
# ln -sfn 이라 나중에 다시 걸려도 무해하다.
if [ -d "${HIVE_CUSTOM_CONF_DIR:-}" ]; then
  find "${HIVE_CUSTOM_CONF_DIR}" -type f -exec ln -sfn {} "${CONF}"/ \;
fi

if [ "${HIVE_MAJOR:-4}" -lt 4 ]; then

  # (1) Hive 3 의 schematool 은 HiveSchemaTool → HiveConf → hive-site.xml 만 읽는다.
  #     metastore-site.xml 만 주면 JDBC 설정을 못 찾아 derby 로 초기화하려 든다.
  #     심볼릭 링크가 아니라 실체 복사여야 한다(원본은 read-only 마운트).
  if [ -e "${CONF}/metastore-site.xml" ]; then
    rm -f "${CONF}/hive-site.xml"
    cp -L "${CONF}/metastore-site.xml" "${CONF}/hive-site.xml"
  fi

  # (2) Hive 3 entrypoint 는 IS_RESUME 이 false 면 매 기동 -initSchema 를 돌리고,
  #     이미 초기화된 DB 에서는 실패해 exit 1 한다(4.x 는 -initOrUpgradeSchema 라 멱등).
  #     볼륨을 유지한 재기동에서 죽지 않도록, 스키마가 이미 있으면 건너뛰게 한다.
  if "${HIVE_HOME}/bin/schematool" -dbType "${DB_DRIVER:-derby}" -info >/dev/null 2>&1; then
    echo "[hms-entrypoint] 기존 스키마 감지 → schema init 건너뜀 (IS_RESUME=true)"
    export IS_RESUME=true
  else
    echo "[hms-entrypoint] 스키마 없음 → 최초 초기화 진행"
  fi
fi

exec /entrypoint.sh
