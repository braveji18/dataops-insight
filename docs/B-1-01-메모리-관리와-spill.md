# B-1 운영 (1) — 메모리 관리와 spill

> 비교 축: `plan/01-비교항목-정리.md` B-1 "한도 계층 구조, OOM 시 kill 정책, spill 대상 연산자 범위"
> 기준 버전: **Trino 483** / **StarRocks 4.0.14**
> 런타임 증거: `docs/evidence/B/20260904-memory-limit-probes.md`
> 선행 문서: `docs/A-3-03-연산자-알고리즘.md` (spill 가능 연산자 범위)
> 일자: 2026-09-04

---

## 1. 비교 관점

`A-3-03` 은 "어떤 연산자가 spill 할 수 있는가"를 셌다(Trino 4계열 / StarRocks 12계열). 이 문서는 그 위층을 본다.

1. **한도가 어떻게 층을 이루는가** — 무엇을 무엇으로 제한하는가
2. **한도에 닿으면 무엇이 죽는가** — 쿼리인가, 태스크인가, 프로세스인가
3. **한도 밖의 소비자** — 쿼리 말고 무엇이 메모리를 쓰는가

세 번째가 이 축의 숨은 핵심이다. **Trino 의 메모리 소비자는 사실상 쿼리뿐이다.** StarRocks 의 BE 는 쿼리와 함께 **적재·compaction·스키마 변경·복제**를 같은 프로세스에서 돌린다. 한도 설계가 같을 수 없다.

결론부터: **Trino 는 쿼리를 골라 죽이는 데 공을 들였고, StarRocks 는 무엇이 먹고 있는지 나누어 세는 데 공을 들였다.** 실측에서 쿼리 하나의 유효 바닥은 대등했다.

---

## 2. Trino 구현

### 2-1. 한도는 3층이다

```java
private DataSize maxQueryMemoryPerNode = HeapSizeParser.DEFAULT.parse("30%");
private DataSize heapHeadroom = HeapSizeParser.DEFAULT.parse("30%");
```
— `core/trino-main/.../memory/NodeMemoryConfig.java:33-34`

```java
private DataSize maxQueryMemory = DataSize.of(20, GIGABYTE);
```
— `core/trino-main/.../memory/MemoryManagerConfig.java:38`

| 층 | 설정 | 기본값 | 뜻 |
|---|---|---|---|
| 클러스터 × 쿼리 | `query.max-memory` | **20GB** | 쿼리 하나가 전 노드에서 쓸 수 있는 합 |
| 노드 × 쿼리 | `query.max-memory-per-node` | **힙의 30%** | 쿼리 하나가 한 노드에서 |
| 노드 | `memory.heap-headroom-per-node` | **힙의 30%** | 쿼리에 주지 않고 남겨 두는 몫 |

**힙의 30% 를 아예 떼어 둔다**는 점이 중요하다. JVM 이 GC 를 돌리고 커넥터·HTTP 버퍼가 쓸 자리다. 즉 **Trino 는 "쿼리가 쓰는 메모리"만 회계하고, 나머지는 넉넉히 비워 두는 것으로 대응한다.**

### 2-2. 넘치면 쿼리를 골라 죽인다

`core/trino-main/src/main/java/io/trino/memory/` 에 킬러 구현이 **5종** 있다.

| 클래스 | 정책 |
|---|---|
| `NoneLowMemoryKiller` | 죽이지 않음 |
| `TotalReservationLowMemoryKiller` | 가장 많이 쓰는 쿼리 |
| `TotalReservationOnBlockedNodesQueryLowMemoryKiller` | **막힌 노드에서** 가장 많이 쓰는 쿼리 |
| `TotalReservationOnBlockedNodesTaskLowMemoryKiller` | 같은 기준으로 **태스크만** |
| `LeastWastedEffortTaskLowMemoryKiller` | **버리는 작업량이 가장 적은** 태스크 |

기본값은 둘 다 "막힌 노드 기준"이다.

```java
private LowMemoryQueryKillerPolicy lowMemoryQueryKillerPolicy = LowMemoryQueryKillerPolicy.TOTAL_RESERVATION_ON_BLOCKED_NODES;
private LowMemoryTaskKillerPolicy lowMemoryTaskKillerPolicy = LowMemoryTaskKillerPolicy.TOTAL_RESERVATION_ON_BLOCKED_NODES;
```
— `MemoryManagerConfig.java:48-49`

**`LeastWastedEffortTaskLowMemoryKiller` 가 이 목록에서 가장 흥미롭다.** "가장 많이 먹는 놈"이 아니라 **"죽여도 손해가 가장 적은 놈"** 을 고른다. 이는 FTE(`A-4-02` 3-1)를 전제로 한 정책이다 — 태스크 단위 재시도가 가능하니 *다시 만드는 비용*으로 희생자를 고르는 것이 합리적이다.

즉 **Trino 의 메모리 관리는 "누구를 죽일까"에 설계 노력이 집중돼 있다.**

---

## 3. StarRocks 구현

### 3-1. 프로세스 한도 하나에서 갈라 나간다

```
CONF_String(mem_limit, "90%");
```
— `be/src/common/config.h:105`

**시스템 메모리의 90%** 를 BE 프로세스 전체 한도로 잡는다. Trino 가 30% 를 비워 두는 것과 정반대다 — C++ 이라 GC 여유가 필요 없고, **메모리를 직접 회계하기 때문에 90% 까지 밀어붙일 수 있다.**

그 90% 를 무엇이 나눠 쓰는지가 `MemTracker::Type` 이다.

```cpp
PROCESS,
QUERY,
QUERY_POOL,
LOAD,
CONSISTENCY,
COMPACTION_TASK,
COMPACTION,
SCHEMA_CHANGE_TASK,
SCHEMA_CHANGE,
```
— `be/src/runtime/mem_tracker.h:83-91` 발췌 (이어서 `RESOURCE_GROUP_BIG_QUERY`, `CLONE`, `COMPACTION_STATE` 등)

**이 목록이 이 문서의 핵심이다.** `LOAD`, `COMPACTION`, `SCHEMA_CHANGE`, `CLONE` — 전부 **쿼리가 아니다.** StarRocks BE 는 스토리지를 소유하므로(`C-1`) 적재·병합·스키마 변경·복제를 같은 프로세스에서 돌리고, **그것들이 쿼리와 메모리를 다툰다.**

Trino 에는 이 항목들이 아예 없다. 스토리지가 없으니 compaction 도 clone 도 없다.

### 3-2. 쿼리 한도는 세션 변수다

```java
@VariableMgr.VarAttr(name = QUERY_MEM_LIMIT)
private long queryMemLimit = 0L;
```
— `fe/fe-core/.../qe/SessionVariable.java:1263-1264`

**기본값 0 은 "제한 없음"** 이다. 즉 기본 상태에서 쿼리 하나는 프로세스 한도(90%)까지 쓸 수 있다. Trino 가 기본적으로 "힙의 30%" 로 묶는 것과 대비된다.

한도를 넘으면 상태를 세운다.

```cpp
str << "Memory of " << label() << " exceed limit. " << msg << " ";
```
— `be/src/runtime/mem_tracker.cpp:246`

`Status::MemoryLimitExceeded` 로 올라가고(`mem_tracker.cpp:220`, `runtime_state.cpp:255`), **해당 쿼리가 실패한다.** Trino 처럼 "여러 쿼리 중 하나를 골라 죽이는" 클러스터 단위 킬러는 이 계층에 없다 — 그 역할은 리소스 그룹(`B-2-01`)이 맡는다.

### 3-3. spill 은 비율로 발동한다

```java
@VarAttr(name = SPILL_MEM_LIMIT_THRESHOLD, flag = VariableMgr.INVISIBLE)
private double spillMemLimitThreshold = 0.8;
@VarAttr(name = SPILL_OPERATOR_MIN_BYTES, flag = VariableMgr.INVISIBLE)
private long spillOperatorMinBytes = 1024L * 1024 * 50;
```
— `SessionVariable.java:1632-1635`

**한도의 80% 에 닿으면 흘리기 시작하고, 50MB 미만인 연산자는 흘리지 않는다.** 후자가 실무적으로 중요하다 — 작은 연산자를 흘려봐야 I/O 비용만 든다.

spill 자체는 기본 꺼져 있다.

```java
@VariableMgr.VarAttr(name = ENABLE_SPILL)
private boolean enableSpill = false;
```
— `SessionVariable.java:1600-1601`

---

## 4. 실측

전문은 `docs/evidence/B/20260904-memory-limit-probes.md`.

고카디널리티 복합 키 중복 제거로 해시 집계에 부담을 주고, 쿼리 단위 한도만 좁혔다. 기준선은 양쪽 **60,175** 로 일치한다.

### 4-1. 유효 바닥이 비슷하다

| 한도 | Trino 483 (spill off / on) | StarRocks 4.0.14 (spill off / on) |
|---|---|---|
| 2 · 4 · 8MB | 실패 / 실패 | 실패 / 실패 |
| 16MB | **60175** / 60175 | 실패 / 실패 |
| 18MB 이상 | 60175 / 60175 | **60175** / 60175 |

**Trino 16MB, StarRocks 18MB.** 같은 자릿수다 — 이 쿼리에서 어느 쪽이 메모리를 아낀다고 말할 수 없다.

### 4-2. spill 은 판별되지 않았다

**켜나 끄나 결과가 같다.** 실패하는 한도에서는 spill 을 켜도 실패하고, 성공하는 한도에서는 spill 이 필요 없다. **그 사이의 창이 이 데이터 규모에는 없다.**

`enable_spill=true` + `spill_mem_limit_threshold=0.1` 로 낮추면 StarRocks 플랜에 **`SPILL_PROCESS` 노드가 등장한다** — 기계는 실제로 연결된다. 그러나 **spill 바이트 카운터는 나타나지 않았다.** 흘릴 만큼 쌓이지 않았다는 뜻이다.

### 4-3. 오류 메시지의 성격이 다르다

**Trino**

```
Query exceeded per-node memory limit of 2MB
[Allocated: 856B, Delta: 2MB, Top Consumers: {PagePartitioner=856B}]
```

**`Top Consumers`** — 어느 연산자가 먹고 있었는지를 오류가 직접 말해 준다.

**StarRocks**

```
Memory of Query01a06c84-... exceed limit. Pipeline Backend: starrocks-be,
fragment: 01a06c84-... Used: 2232112, Limit: 2097152.
Mem usage has exceed the limit of single query,
You can change the limit by set session variable query_mem_limit.
```

**어느 BE 의 어느 fragment 인지**와 **무엇을 바꾸면 되는지**를 말해 준다. 소비 연산자는 알려주지 않는다.

**둘 다 유용하고 서로 보완적이다.** Trino 는 "무엇이 먹었나", StarRocks 는 "어디서 터졌고 무엇을 바꾸나".

---

## 5. 설계 차이와 그 원인

### 5-1. 요약

| 관점 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| 프로세스 한도 | 없음 — JVM 힙이 상한 | **`mem_limit = 90%`** |
| 예약 여유분 | **힙의 30%** 를 쿼리에 주지 않음 | 없음(10%) |
| 쿼리 기본 한도 | 노드당 **힙의 30%**, 클러스터 **20GB** | **0 = 무제한** |
| 회계 대상 | 쿼리만 | **쿼리 + 적재 + compaction + 스키마 변경 + 복제** |
| 한도 초과 시 | 킬러가 **희생자 선택**(5종 정책) | 해당 쿼리 실패 |
| 태스크 단위 kill | **있음**(FTE 전제) | 없음 |
| spill 발동 | 연산자별 | **한도의 80%**, 50MB 미만 연산자는 제외 |
| spill 기본 | 꺼짐 | 꺼짐 |

### 5-2. 30% 를 비우는가, 90% 를 쓰는가

이 대비가 두 엔진의 성격을 압축한다.

**Trino 는 힙의 30% 를 통째로 비워 둔다.** JVM 이므로 회계되지 않는 할당(GC 작업 공간, 커넥터 라이브러리 내부 버퍼, HTTP 클라이언트)이 존재하고, 그것을 정확히 세는 대신 **넉넉히 남기는 쪽**을 택했다.

**StarRocks 는 90% 까지 쓴다.** C++ 이라 할당을 직접 가로챌 수 있고, `MemTracker` 계층으로 **누가 얼마나 쓰는지 다 센다.** 대신 세지 못한 할당이 있으면 그대로 OOM 이다.

`A-3-01`·`A-5-03` 에서 반복된 구도와 같다 — **정확함과 여유 중 무엇을 택했는가.**

### 5-3. 쿼리 말고 무엇이 메모리를 쓰는가

이것이 운영에서 가장 크게 갈리는 지점이다.

Trino 워커의 메모리 소비자는 **사실상 쿼리뿐**이다. 쿼리가 없으면 놀고, 쿼리 부하만 보면 용량 계획이 선다.

StarRocks BE 는 다르다. `MemTracker::Type` 에 `LOAD`, `COMPACTION`, `SCHEMA_CHANGE`, `CLONE` 이 있다는 것은 **쿼리가 없어도 메모리를 쓰는 작업이 상시 돈다**는 뜻이다. 특히 compaction 은 적재량에 비례해 자동으로 돌므로(`C-1-03`), **적재가 몰리는 시간대에 쿼리 메모리가 줄어든다.**

**따라서 StarRocks 의 용량 계획은 쿼리만 봐서는 안 된다.** 이 점은 `B-2-01`(리소스 격리)·`C-1-03`(compaction)과 이어진다.

### 5-4. 킬러 정책의 정교함이 어디서 왔는가

Trino 의 킬러 5종, 특히 `LeastWastedEffortTaskLowMemoryKiller` 는 **FTE 없이는 의미가 약한 정책**이다. 태스크를 죽여도 다시 만들 수 있어야 "버리는 작업량"을 기준으로 고르는 것이 성립한다(`A-4-02` 3-1).

StarRocks 에 대응물이 없는 것도 같은 이유로 읽힌다 — 중간 결과가 남지 않으니 태스크만 죽여봐야 쿼리 전체를 다시 돌려야 한다. 그래서 **kill 정책 대신 리소스 그룹으로 애초에 격리하는 방향**을 택했다(`B-2-01`).

### 5-5. 기본값의 방향이 반대다

**Trino 는 좁게 시작해서 넓힌다** — 쿼리당 힙의 30%. 한 쿼리가 노드를 독차지하지 못한다.

**StarRocks 는 넓게 시작해서 좁힌다** — `query_mem_limit = 0`(무제한). 한 쿼리가 프로세스 한도까지 쓸 수 있다.

**운영 관점에서 이 차이는 크다.** StarRocks 기본 설정에서는 무거운 쿼리 하나가 BE 의 메모리를 다 먹고 다른 쿼리를 밀어낼 수 있다. 막으려면 `query_mem_limit` 을 명시적으로 걸거나 리소스 그룹을 써야 한다.

---

## 6. 결론

**동등하지 않다 — 회계의 정밀함과 kill 의 정교함이 서로 반대편에 있다.**

- **Trino**: 쿼리만 회계하고 30% 를 비워 둔다. 대신 **넘쳤을 때 누구를 죽일지**에 5종 정책을 두었다
- **StarRocks**: 90% 까지 쓰고 **쿼리·적재·compaction·복제를 모두 나눠 센다.** 대신 킬러 정책은 없고, 넘친 쿼리가 실패한다
- **실측**: 쿼리 하나의 유효 바닥은 16MB vs 18MB 로 대등하다. **spill 은 이 규모에서 판별되지 않았다**
- **오류 메시지**: Trino 는 소비 연산자를, StarRocks 는 위치와 해결 방법을 알려 준다

**실무 결론**

1. **StarRocks 를 쓰면 `query_mem_limit` 을 기본값(무제한)으로 두지 말 것.** 무거운 쿼리 하나가 BE 를 독차지할 수 있다
2. **StarRocks 의 용량 계획에는 적재·compaction 몫을 반드시 포함해야 한다.** 쿼리 부하만 보면 적재가 몰리는 시간대에 터진다
3. **Trino 에서 메모리 오류가 나면 `Top Consumers` 를 먼저 볼 것.** 어느 연산자를 손봐야 할지 오류가 직접 알려 준다
4. **긴 쿼리가 많고 메모리가 빠듯하면 Trino 의 `LEAST_WASTE` 태스크 킬러 + FTE 조합이 유일한 답에 가깝다.** 진행된 작업을 최대한 살린다

### 아직 답하지 않은 것

- **spill 의 실효** — 판별하지 못했다. 집계 대상이 메모리를 확실히 넘는 데이터가 필요하다(`perf` 프로파일, `plan/02` 6-2절)
- **클러스터 단위 kill** — Trino 의 킬러는 여러 노드·여러 쿼리가 경합해야 동작한다. 1노드 랩에서 확인 불가
- **StarRocks 의 compaction 이 실제로 쿼리 메모리를 얼마나 잠식하는가** — 적재 부하를 만들지 않았다. `C-1-03`
- **GC 정지 시간** — Trino 가 30% 를 비워도 GC 는 돈다. 그 지연이 실행 시간에 미치는 영향을 재지 않았다
- **리소스 그룹을 통한 격리** — `B-2-01`
- **`spill_operator_min_bytes = 50MB` 의 타당성** — 이 임계값이 실제로 적절한지 판단할 근거가 없다
