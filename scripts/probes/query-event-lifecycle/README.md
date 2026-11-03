# 쿼리 이벤트 생애주기 판별 도구

`docs/evidence/B/20261103-trino-query-event-lifecycle.md` 의 측정을 재현한다.

판별하는 질문은 **Trino 가 `query_created` 를 발행하고도 `query_completed` 를 발행하지 않는 조건이 무엇인가**이다.
표준 랩(`scripts/testenv/`)을 쓰지 않는다. Iceberg 카탈로그가 필요 없고, 대신 **이벤트 수신 지점**이 필요하기 때문이다.

## 구성

| 파일 | 역할 |
|---|---|
| `etc/` | Trino 483 코디네이터 설정. 번들 플러그인 `http-event-listener` 를 생성·완료 이벤트 모두 켜고 수집기로 보낸다 |
| `collector.py` | 이벤트 수신 서버. 수신한 JSON 에 `statistics` 필드가 있으면 `query_completed`, 없으면 `query_created` 로 분류해 한 줄씩 기록한다 |
| `client.py` | 클라이언트 프로토콜을 직접 호출한다. **폴링을 임의 시점에 중단하고, 취소 요청을 보낼지 여부를 선택할 수 있다** |
| `fails.py` | Prepared Statement 의 실패 경로 네 가지를 한 번에 실행한다 |

JDBC 드라이버를 쓰지 않고 프로토콜을 직접 호출하는 이유는, **클라이언트가 결과를 중간에 버리는 상황을 재현 가능한 형태로 만들어야** 하기 때문이다.
드라이버는 결과 집합을 닫을 때 취소 요청을 보내 버리므로 그 상황이 만들어지지 않는다.

## 실행

호스트 네트워크를 사용하므로 **18080(Trino)과 18123(수집기)이 비어 있어야 한다.**

```bash
cd scripts/probes/query-event-lifecycle

# 1) 이벤트 수집기
EVENTS_LOG=events.log python3 -I collector.py 18123 &

# 2) Trino 코디네이터
docker run -d --name trino-evt --network host \
  -v "$PWD/etc:/etc/trino:ro" trinodb/trino:483

# 준비 완료까지 대기
until curl -s http://127.0.0.1:18080/v1/info | grep -q '"starting":false'; do sleep 3; done

# 3) 시나리오 실행
python3 -I client.py plain            # 일반 SELECT, 결과 전량 수신
python3 -I client.py exec_immediate   # EXECUTE IMMEDIATE (JDBC 기본 경로)
python3 -I client.py prepare_execute  # PREPARE + EXECUTE (explicitPrepare=true 경로)
python3 -I client.py abandon          # 폴링 중단, 취소 요청 미전송 ← 누락이 재현되는 조건
python3 -I client.py abandon_cancel   # 폴링 중단, 취소 요청 전송
python3 -I client.py post_only        # 제출만 하고 결과를 조회하지 않음
python3 -I fails.py                   # Prepared Statement 실패 경로 4종

# 4) 결과 확인
awk -F'\t' '{print $1"\t"$2"\t"$3}' events.log
```

`abandon` 시나리오의 쿼리는 **`query.client.timeout`(기본 5분)이 지난 뒤** `ABANDONED_QUERY` 로 강제 종료되면서
완료 이벤트를 뒤늦게 발행한다. 그 지연을 확인하려면 5분 넘게 기다려야 한다.

## 정리

```bash
docker rm -f trino-evt
kill "$(pgrep -f 'collector.py')"
```
