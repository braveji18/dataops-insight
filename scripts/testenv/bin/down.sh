#!/usr/bin/env bash
#
#   bin/down.sh          # 컨테이너만 정리 (데이터 볼륨 유지 — 다음 up 이 빠르다)
#   bin/down.sh --purge  # 볼륨까지 삭제 (MinIO 데이터, HMS DB, SR 메타/스토리지 전부)

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

if [ ! -f "$LAB_ENV_FILE" ]; then
  lab_warn ".env 가 없다. 랩이 기동된 적이 없거나 이미 정리됨."
  exit 0
fi
lab_load_env

case "${1:-}" in
  --purge)
    lab_warn "볼륨까지 삭제한다. 시드 데이터가 전부 사라진다."
    dc down --volumes --remove-orphans
    lab_ok "정리 완료 (볼륨 포함)"
    ;;
  "")
    dc down --remove-orphans
    lab_ok "정리 완료 (볼륨 유지)"
    ;;
  *) lab_die "사용법: down.sh [--purge]" ;;
esac
