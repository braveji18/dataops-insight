#!/usr/bin/env bash
#
# 완전 초기화 후 재기동. 상태가 꼬였을 때의 최종 수단.
#   bin/reset.sh [profile]
#
# 버전을 올린 뒤(versions.env 수정)에도 반드시 이걸 돌려야 한다.
# StarRocks FE 메타와 HMS DB 가 이전 버전 상태로 남아 있으면 조용히 이상 동작한다.

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

PROFILE="${1:-functional}"
lab_warn "볼륨 포함 전체 초기화 후 profile=$PROFILE 로 재기동한다."
"$LAB_ROOT/bin/down.sh" --purge || true
exec "$LAB_ROOT/bin/up.sh" "$PROFILE"
