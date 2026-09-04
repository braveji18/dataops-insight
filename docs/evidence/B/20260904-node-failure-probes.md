# 노드 사망: Trino 는 62초 기다리고, StarRocks 는 즉시 포기한다

> 비교 축: B-4 고가용성과 장애 복구 (`plan/01-비교항목-정리.md`)
> 본문: `docs/B-4-01-고가용성과-장애-복구.md`
> 관련: `docs/A-4-01-셔플-전송-계층.md` (재시도 한도), `docs/A-5-03-파일-리더.md` (BE 블랙리스트)
> 일자: 2026-09-04

### 주장

노드가 죽으면 두 엔진이 어떻게 반응하는가. 코드로는 "Trino 는 FTE 가 없으면 쿼리 실패, StarRocks 는 쿼리 재실행"까지 알 수 있었다. **실제로 무엇이 보이고 얼마나 걸리는지**를 잰다.

### 방법

랩의 실행 노드를 실제로 정지시켰다(`docker compose stop`). 워커/BE 가 1대뿐이므로 **"한 대가 죽었을 때 나머지로 계속하는가"는 판별할 수 없고**, 확인할 수 있는 것은 **실패 방식과 복구 방식**이다.

### 결과 1 — Trino: 62초 재시도 후 실패

`trino-worker` 를 정지시키고 곧바로 쿼리를 던졌다.

```
Query 20260904_131658_00417_78vfk failed: Encountered too many errors talking to a
worker node. The node may have crashed or be under too much load. This is probably
a transient issue, so please retry your query in a few minutes.
(http://172.20.0.7:8080/v1/task/.../results/0/0 - 15 failures,
 failure duration 62.25s, total failed request time 67.25s)
```

**62.25초 동안 15번 재시도한 뒤 포기했다.**

이 숫자는 코드와 정확히 맞는다 — `A-4-01` 3-2 에서 본 교환 클라이언트의 재시도 한도다.

```java
private Duration maxErrorDuration = new Duration(1, TimeUnit.MINUTES);
```
— `core/trino-main/.../operator/DirectExchangeClientConfig.java:35`

**오류 메시지가 판단까지 담고 있다** — *"This is probably a transient issue, so please retry your query in a few minutes."* 즉 Trino 는 노드 사망을 **일시적 장애로 가정하고 오래 기다린다.**

워커를 다시 띄우자 자동으로 클러스터에 복귀했다(`system.runtime.nodes` 의 active 가 2로 회복).

### 결과 2 — StarRocks: 즉시 실패

`starrocks-be` 를 정지시키고 같은 성격의 쿼리를 던졌다.

```
ERROR 1064 (HY000) at line 1: Failed to find backend to execute
```

**기다리지 않는다.** FE 가 실행 가능한 BE 목록을 항상 들고 있으므로, 목록이 비면 계획 단계에서 곧장 거부한다.

`A-5-03` 3-2 에서 인용한 4.0.1 크래시의 사용자 측 증상(`Failed to find backend to execute`)과 **완전히 같은 메시지**다. 즉 **BE 가 죽은 원인이 무엇이든 사용자에게는 같은 오류로 보인다.**

BE 를 다시 띄우자 **19초 만에** 쿼리가 정상 처리됐다. `SHOW BACKEND BLACKLIST` 는 비어 있었다 — 정상 종료였고 블랙리스트에 올라가지 않았다.

### 결과 3 — 대조

| | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| 실패까지 | **62.25초** (15회 재시도) | **즉시** |
| 오류 메시지 | 노드 주소, 실패 횟수, 총 시간, **재시도 권고** | `Failed to find backend to execute` |
| 사망 감지 주체 | 태스크와 통신하는 **교환 클라이언트** | **FE 의 노드 목록** |
| 복구 | 워커 재기동 후 자동 복귀 | **19초** 후 정상 |
| 블랙리스트 | 해당 없음 | 정상 종료라 등록되지 않음 |

### 판정

**어느 쪽이 낫다고 말할 수 없다 — 가정이 다르다.**

- **Trino 는 "잠깐 느린 것일 수 있다"고 가정한다.** GC 정지나 일시적 네트워크 문제로 워커가 잠깐 응답하지 않는 상황을 재시도로 넘긴다. 대가는 **정말 죽었을 때 62초를 버리는 것**이다
- **StarRocks 는 "없으면 없는 것"이라고 가정한다.** FE 가 하트비트로 노드 상태를 관리하므로 즉시 판단할 수 있다. 대가는 **일시적 장애에도 즉시 실패하는 것**이다

**실무적으로는 Trino 쪽 62초가 문제가 될 수 있다.** 대화형 쿼리에서 1분간 멈춰 있다가 실패하면 사용자 경험이 나쁘다. `exchange.max-error-duration` 을 줄이는 것이 조정 수단이다.

**한정 — 이 실험의 판별력은 여기까지다.** 워커/BE 가 1대뿐이라 **"한 대가 죽어도 나머지로 계속하는가"라는 이 축의 진짜 질문은 확인하지 못했다.** Trino FTE 의 태스크 단위 재시도도 마찬가지다. 다중 노드 랩이 필요하다(`plan/02` 6-3절).

### 조건

profile=functional, TPC-H SF0.01, Iceberg(HMS 4.0.1 native + MinIO), Trino 483 / StarRocks 4.0.14,
host=linux/amd64 (Linux 6.8, 8 CPU, RAM 15.6GB), Trino coordinator 1 + worker 1 / StarRocks FE 1 + BE 1,
`retry-policy` 기본값(NONE), 노드 정지는 `docker compose stop`(정상 종료).
실험 후 `bin/status.sh` GREEN 복구 확인.
