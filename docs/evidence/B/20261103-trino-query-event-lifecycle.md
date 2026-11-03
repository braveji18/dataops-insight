# 쿼리 이벤트 생애주기: `query_completed` 는 클라이언트가 결과를 다 받아가야 발행된다

> 비교 축: B-6 관측성 (`plan/01-비교항목-정리.md`)
> 본문: `docs/B-6-01-관측성.md`
> 일자: 2026-11-03
> 범위: **Trino 483 단독 검증이다.** StarRocks 쪽 대응 동작은 확인하지 않았다

### 주장

`B-6-01` 2-1 절은 Trino 의 `EventListener` SPI 를 **"쿼리 밖에서 보는 것"의 강점**으로 서술했다. 그 서술은 **이벤트가 빠짐없이 도착한다는 전제**에 의존한다. 이 실험은 그 전제를 직접 흔들어 본다.

출발점은 다음 관찰이었다 — **Prepared Statement 로 쿼리를 실행했을 때 `query_created` 는 발생하는데 `query_completed` 가 발생하지 않는 경우가 있다.**

판별해야 할 질문은 세 가지다.

1. Prepared Statement 경로(`EXECUTE IMMEDIATE`, `PREPARE` + `EXECUTE`)에 이벤트 누락 결함이 있는가
2. 누락이 재현된다면 그 조건은 무엇인가
3. 누락은 영구적인가, 아니면 지연인가

### 판별 설계

표준 랩(`scripts/testenv/`)을 쓰지 않았다. 이 판별에는 Iceberg 카탈로그가 필요 없고, 대신 **이벤트 수신 지점**이 필요하기 때문이다.

| 구성 요소 | 내용 |
|---|---|
| 엔진 | `trinodb/trino:483` 단일 컨테이너 (coordinator 겸 worker, `--network host`) |
| 카탈로그 | `tpch` 커넥터 (`sf1.lineitem`, 6백만 행) |
| 이벤트 리스너 | 번들 플러그인 `http-event-listener`, `log-created=true`, `log-completed=true` |
| 수집기 | 로컬 HTTP 서버. 수신한 JSON 에 `statistics` 필드가 있으면 `query_completed`, 없으면 `query_created` 로 분류한다 |
| 클라이언트 | 클라이언트 프로토콜을 직접 호출하는 스크립트. **폴링을 임의 시점에 중단하고 취소 요청을 보낼지 여부를 선택할 수 있다** |

JDBC 드라이버를 쓰지 않고 프로토콜을 직접 호출한 이유는, **클라이언트가 결과를 중간에 버리는 상황을 재현 가능한 형태로 만들어야** 했기 때문이다.

판별 대상 구문은 다음 두 가지이고, 이는 JDBC 드라이버가 실제로 전송하는 구문과 같다.

| 드라이버 설정 | 전송 구문 | 근거 |
|---|---|---|
| 기본값 | `EXECUTE IMMEDIATE '<sql>' USING ...` | `works/trino/client/trino-jdbc/src/main/java/io/trino/jdbc/TrinoPreparedStatement.java:1016-1026` |
| `explicitPrepare=true` | `PREPARE <name> FROM <sql>` 를 별도 쿼리로 실행한 뒤 `EXECUTE <name> USING ...` | 같은 파일 `:131`, `:1028-1037` |

### 결과 1 — 정상 경로는 양쪽 이벤트가 모두 발행된다

| 시나리오 | `query_created` | `query_completed` | 종료 상태 |
|---|---|---|---|
| 일반 SELECT, 결과 전량 수신 | 발생 | 발생 | `FINISHED` |
| `EXECUTE IMMEDIATE ... USING ...`, 결과 전량 수신 | 발생 | 발생 | `FINISHED` |
| `PREPARE` 구문 자체 | 발생 | 발생 | `FINISHED` |
| `EXECUTE <name> USING ...`, 결과 전량 수신 | 발생 | 발생 | `FINISHED` |

`EXECUTE` 쿼리의 이벤트에는 `preparedQuery` 필드에 원본 SQL 이 함께 실려 왔다.

### 결과 2 — 실패 경로도 양쪽 이벤트가 모두 발행된다

Prepared Statement 가 깨지는 네 가지 경로를 모두 시험했다.

| 시나리오 | 오류 코드 | `query_created` | `query_completed` |
|---|---|---|---|
| `EXECUTE nosuch USING 'SHIP'` (등록되지 않은 이름) | `NOT_FOUND` | 발생 | 발생 |
| 파라미터 개수 불일치 | `INVALID_PARAMETER_USAGE` | 발생 | 발생 |
| `EXECUTE IMMEDIATE` 내부 구문의 분석 실패 | `COLUMN_NOT_FOUND` | 발생 | 발생 |
| `EXECUTE IMMEDIATE` 내부 구문의 구문 오류 | `SYNTAX_ERROR` | 발생 | 발생 |

**따라서 "준비 단계 실패 때문에 완료 이벤트가 누락된다"는 가설은 폐기한다.** 디스패치 과정에서 발생한 모든 예외는 실패 디스패치 쿼리를 만들어 생성 이벤트와 즉시 실패 이벤트를 순서대로 발행하기 때문이다 — `works/trino/core/trino-main/src/main/java/io/trino/dispatcher/DispatchManager.java:271-281`.

```java
// maintain proper order of calls such that EventListener has access to QueryInfo
// - add query to tracker
// - fire query created event
// - fire query completed event
queryMonitor.queryImmediateFailureEvent(failedDispatchQuery.getBasicQueryInfo(), toFailure(throwable));
```

### 결과 3 — 누락은 "클라이언트가 결과를 버리고 취소도 하지 않은" 경우에만 재현된다

| 시나리오 | `query_created` | `query_completed` | 서버 측 상태 |
|---|---|---|---|
| **폴링을 3회만 하고 중단, 취소 요청 미전송** | **발생** | **발생하지 않음** | `RUNNING` 으로 잔존 |
| 폴링을 3회만 하고 중단, 취소 요청(DELETE) 전송 | 발생 | 발생 | `FAILED` (`USER_CANCELED`) |
| POST 만 하고 `nextUri` 를 한 번도 호출하지 않음 | 발생하지 않음 | 발생하지 않음 | 등록되지 않음 |

세 번째 행은 별도로 기록할 가치가 있다. **쿼리를 제출하기만 하면 아무 이벤트도 발행되지 않는다.** 제출 게이트가 첫 `nextUri` 조회 시점에 비로소 열리기 때문이다 — `works/trino/core/trino-main/src/main/java/io/trino/dispatcher/QueuedStatementResource.java:384-390`.

```java
private void submitIfNeeded()
{
    if (submissionGate.compareAndSet(NOT_SUBMITTED, SUBMITTED)) {
        querySpan.addEvent("submit");
        creationFuture.setFuture(dispatchManager.createQuery(queryId, querySpan, slug, sessionContext, query));
    }
}
```

### 결과 4 — 누락은 영구적이지 않고, 기본값 5분만큼 지연된다

첫 번째 행의 쿼리를 그대로 두고 관찰했다.

```
01:08:41  query_created    20261103_010841_00010_ryy2k  QUEUED
          (클라이언트 폴링 중단, 취소 요청 미전송)
01:13:41  Failing abandoned query 20261103_010841_00010_ryy2k
          TIMELINE: FAILED (ABANDONED_QUERY) :: elapsed 300144ms
01:13:43  query_completed  20261103_010841_00010_ryy2k  FAILED
```

경과 시간 300,144ms 는 `query.client.timeout` 의 기본값 5분과 일치한다 — `works/trino/core/trino-main/src/main/java/io/trino/execution/QueryManagerConfig.java:88`. 추적기가 주기적으로 심박이 끊긴 쿼리를 찾아 `ABANDONED_QUERY` 로 강제 종료시키고, 그 종료가 완료 이벤트를 유발한다 — `works/trino/core/trino-main/src/main/java/io/trino/execution/QueryTracker.java:266-277`.

### 코드 근거 — 두 이벤트가 서로 다른 조건에 묶여 있다

**생성 이벤트는 조건 없이 발행된다.** 디스패치 쿼리를 만드는 시점에 동기적으로 호출하며, 소스에도 이 위치를 옮기면 안 된다는 주석이 붙어 있다 — `works/trino/core/trino-main/src/main/java/io/trino/dispatcher/LocalDispatchQueryFactory.java:147-154`.

**완료 이벤트는 `finalQueryInfo` 가 채워질 때에만 발행된다** — `works/trino/core/trino-main/src/main/java/io/trino/dispatcher/LocalDispatchQuery.java:145-156`.

```java
querySubmitter.accept(queryExecution);
if (notificationSentOrGuaranteed.compareAndSet(false, true)) {
    queryExecution.addFinalQueryInfoListener(queryMonitor::queryCompletedEvent);
}
```

그리고 `finalQueryInfo` 가 채워지는 경로는 종료 상태에 도달하는 것뿐인데, **성공 종료(`FINISHED`)에는 관문이 두 개 있다** — `works/trino/core/trino-main/src/main/java/io/trino/execution/QueryStateMachine.java:1298-1310`.

```java
private void transitionToFinishedIfReady()
{
    if (queryState.get().isDone()) { return; }
    if (!committed.get() || !consumed.get()) { return; }
    queryStateTimer.endQuery();
    queryState.setIf(FINISHED, currentState -> !currentState.isDone());
}
```

`committed` 는 실행이 끝나면 엔진이 설정한다. 그러나 **`consumed` 는 클라이언트가 결과 페이지를 모두 받아갔을 때에만 설정된다** — `works/trino/core/trino-main/src/main/java/io/trino/server/protocol/Query.java:473-479`.

```java
if (isStarted && (queryInfo.stages().isEmpty() || exchangeDataSource.isFinished())) {
    queryManager.resultsConsumed(queryId);
    resultsConsumed = true;
    ...
}
```

즉 **쿼리의 종료 여부가 클라이언트의 수신 행위에 의존한다.** 클라이언트가 중간에 사라지면 쿼리는 `RUNNING` 또는 `FINISHING` 에 머물고, 종료 상태에 도달하지 못하므로 완료 이벤트도 발행되지 않는다.

실패 종료는 반대로 보장된다. 실패 상태 전이는 별도의 즉시 실패 이벤트 경로를 타고, 두 경로가 한 번만 발행되도록 원자적 플래그로 조율한다 — `works/trino/core/trino-main/src/main/java/io/trino/dispatcher/LocalDispatchQuery.java:93-105`. DDL 계열은 실행기 생성 시점에 종료 시 `finalQueryInfo` 를 채우는 청취자를 직접 등록해 둔다 — `works/trino/core/trino-main/src/main/java/io/trino/execution/DataDefinitionExecution.java:73-78`.

### 왜 이 조건이 운영 환경에서 성립하는가

JDBC 드라이버는 결과 집합을 닫을 때 취소 요청을 보내지만, **그 전송 실패를 조용히 무시한다** — `works/trino/client/trino-client/src/main/java/io/trino/client/StatementClientV1.java:663-676`.

```java
private void httpDelete(URI uri)
{
    ...
    catch (IOException ignored) {
        // callers expect this method not to throw
    }
}
```

따라서 다음 상황에서 코디네이터는 클라이언트의 이탈을 알 수 없다.

- 애플리케이션이 결과 집합을 닫지 않고 버린 경우
- 조회 중에 애플리케이션 프로세스나 파드가 종료된 경우
- 중간 프록시가 연결을 끊고, 이어지는 취소 요청도 같은 경로에서 실패한 경우

Prepared Statement 에서 이 현상이 더 자주 관측되는 이유는 **구문 자체의 결함이 아니라 호출자의 성격**이다. Prepared Statement 는 BI 도구와 애플리케이션 커넥션 풀을 통해 실행되는 비중이 높고, 그런 호출자는 결과를 일부만 읽고 떠나거나 프록시 타임아웃에 걸리는 빈도가 높다.

### 판정

**Prepared Statement 고유의 이벤트 누락 결함은 없다.** 일반 쿼리도 동일한 조건에서 같은 현상을 보인다.

`query_created` 만 발행되는 경우는 단 하나로 수렴한다 — **클라이언트가 결과를 끝까지 받지 않은 상태에서 취소 요청도 보내지 않고 사라진 경우**다. 이때 완료 이벤트는 누락이 아니라 **`query.client.timeout` 만큼 지연**되며, 기본값에서는 5분이다. 다만 그 유예 기간 안에 코디네이터가 재시작되면 **그 쿼리의 완료 이벤트는 영구히 유실된다.** 이벤트 리스너는 코디네이터 메모리의 상태 머신에만 연결되어 있고 영속화 장치가 없기 때문이다.

관측 체계에 주는 함의는 세 가지다.

1. `query_created` 와 `query_completed` 를 즉시 짝지어 미완료를 판정하면 **오탐이 발생한다.** 최소 `query.client.timeout` 만큼의 유예를 두어야 한다
2. 지연 발행된 완료 이벤트의 오류 코드는 `ABANDONED_QUERY` 다. 이 코드를 따로 집계하면 **클라이언트 이탈 규모를 직접 측정할 수 있다**
3. 제출만 하고 결과를 조회하지 않은 요청은 **어떤 이벤트도 남기지 않는다.** 감사 목적으로 이벤트 리스너만 사용한다면 이 구간이 사각지대로 남는다

### 조건

profile=functional(표준 랩 미사용), 엔진=`trinodb/trino:483` 단독 컨테이너, 카탈로그=`tpch` 커넥터 `sf1`, 이벤트 리스너=번들 `http-event-listener`(생성·완료 모두 활성), `query.client.timeout`=기본값 5분, 클라이언트=클라이언트 프로토콜 직접 호출 스크립트

### 확인하지 못한 것

- **StarRocks 의 대응 동작을 검증하지 않았다.** StarRocks 는 감사 로그 플러그인이 쿼리 종료 시점에 기록을 남기는 구조이므로(`B-6-01` 3-1 절), 클라이언트가 결과를 버린 경우 어떤 시점에 어떤 상태로 기록되는지는 별도 판별이 필요하다
- **코디네이터 재시작 중 유실을 실측하지 않았다.** 위 3절 판정의 마지막 문장은 코드 구조에서 도출한 추론이며, 재시작을 끼운 실험으로 확인하지는 않았다
- **다중 코디네이터 구성은 검증 범위에서 제외했다.** 단일 코디네이터로만 측정했다
