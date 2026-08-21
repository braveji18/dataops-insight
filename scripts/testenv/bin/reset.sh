#!/usr/bin/env bash
#
# 완전 초기화 후 재기동. 상태가 꼬였을 때의 최종 수단.
#   bin/reset.sh [profile] [--hive 3|4]
#
# 버전을 올린 뒤(versions.env 수정)에도 반드시 이걸 돌려야 한다.
# StarRocks FE 메타와 HMS DB 가 이전 버전 상태로 남아 있으면 조용히 이상 동작한다.
# hive 변형(3↔4) 전환도 마찬가지다 — metastore 스키마 버전이 다르다.

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

lab_warn "볼륨 포함 전체 초기화 후 재기동한다: $*"
"$LAB_ROOT/bin/down.sh" --purge || true

# up.sh 의 hive 전환 가드를 여기서만 푼다. 볼륨을 이미 지웠으므로 스키마 충돌이 없다.
export LAB_FORCE_HIVE_SWITCH=1
exec "$LAB_ROOT/bin/up.sh" "$@"
