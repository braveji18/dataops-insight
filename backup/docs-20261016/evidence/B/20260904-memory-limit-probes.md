# 메모리 한도: 유효 바닥은 비슷하고, spill 은 이 규모에서 판별되지 않는다

> 비교 축: B-1 메모리 관리와 spill (`plan/01-비교항목-정리.md`)
> 본문: `docs/B-1-01-메모리-관리와-spill.md`
> 선행: `docs/A-3-03-연산자-알고리즘.md` (spill 가능 연산자 범위)
> 일자: 2026-09-04

### 주장

`A-3-03` 은 **어떤 연산자가 spill 할 수 있는가**를 코드로 비교했다(Trino 4계열 vs StarRocks 12계열). 이 실험은 그다음을 본다 — **한도를 좁히면 실제로 무엇이 일어나는가.**

1. 쿼리당 메모리 한도를 좁히면 양쪽 다 실패한다. **오류 메시지가 진단에 쓸 만한가**
2. **spill 을 켜면 살아나는가**

### 판별 쿼리

해시 집계가 메모리를 잡아먹도록 고카디널리티 복합 키로 중복 제거한다.

```sql
SELECT count(*) FROM (
  SELECT DISTINCT l_orderkey, l_partkey, l_suppkey, l_comment, l_shipdate FROM lineitem
) t
```

기준선은 양쪽 모두 **60,175** 로 일치한다.

한도는 각 엔진의 쿼리 단위 노브만 움직였다 — Trino `query_max_memory_per_node`, StarRocks `query_mem_limit`.

### 결과 — 한도 스윕

| 한도 | Trino 483 (spill off / on) | StarRocks 4.0.14 (spill off / on) |
|---|---|---|
| 2MB | 실패 / 실패 | 실패 / 실패 |
| 4MB | 실패 / 실패 | — |
| 8MB | 실패 / 실패 | — |
| 16MB | **60175** / 60175 | 실패 / 실패 |
| 18MB | — | **60175** / 60175 |
| 20 · 24 · 28 · 32MB | 60175 / 60175 | 60175 / 60175 |

**유효 바닥이 비슷하다** — Trino 16MB, StarRocks 18MB. 이 쿼리·이 데이터에서 두 엔진이 요구하는 최소 메모리가 같은 자릿수라는 뜻이다.

**spill 은 어느 쪽에서도 결과를 바꾸지 못했다.** 켜나 끄나 같은 한도에서 실패하고 같은 한도에서 성공한다.

### 오류 메시지 — 진단 정보가 다르다

**Trino (2MB)**

```
Query exceeded per-node memory limit of 2MB
[Allocated: 856B, Delta: 2MB, Top Consumers: {PagePartitioner=856B}]
```

**`Top Consumers`** 가 붙는다 — **어느 연산자가 먹고 있었는지**를 오류가 직접 알려 준다.

**StarRocks (2MB)**

```
Memory of Query01a06c84-... exceed limit. Pipeline Backend: starrocks-be,
fragment: 01a06c84-... Used: 2232112, Limit: 2097152.
Mem usage has exceed the limit of single query,
You can change the limit by set session variable query_mem_limit.
```

**어느 BE 와 어느 fragment 인지**, 그리고 **어떤 세션 변수를 바꾸면 되는지**를 알려 준다. 소비 연산자는 알려주지 않는다.

낮은 한도(2MB)에서 StarRocks 오류는 Parquet 파일 경로까지 붙었다 — **스캔 단계에서 이미 실패**했다는 뜻이고, 그 아래 한도에서는 집계가 판별되지 않음을 확인해 준다.

### spill 이 걸렸는지 확인

`enable_spill=true`, `spill_mem_limit_threshold=0.1`(기본 0.8)로 낮추고 프로파일을 봤다.

- 플랜에 **`SPILL_PROCESS` 노드가 등장한다** — spill 기계가 실제로 연결된다
- 그러나 **spill 바이트 카운터는 나타나지 않았다** — 실제로 흘린 데이터가 없다

즉 **기계는 붙지만 이 데이터 규모(SF 0.01, 60,175행)에서는 발동하지 않는다.**

### 판정

**한도 동작은 대등하다. spill 은 판별하지 못했다.**

- 유효 바닥(16MB vs 18MB)이 같은 자릿수다. 어느 쪽이 메모리를 아낀다고 말할 수 없다
- 오류 메시지는 **성격이 다르다** — Trino 는 *무엇이* 먹었는지, StarRocks 는 *어디서* 터졌고 *무엇을 바꾸면* 되는지. 둘 다 유용하고 서로 보완적이다
- **spill 은 이 랩에서 판별 불가다.** 실패하는 한도(≤16MB)에서는 spill 을 켜도 실패하고, 성공하는 한도(≥18MB)에서는 spill 이 필요 없다. 그 사이 창이 없다

### 한정

SF 0.01 / worker 1대 / BE 1대. spill 의 실효를 재려면 **집계 대상이 메모리를 확실히 넘는 데이터**가 필요하다 — `perf` 프로파일(`plan/02` 6-2절)이거나 더 큰 SF 다. 다중 노드 한도(Trino `query.max-memory`)와 클러스터 단위 kill 정책도 확인하지 못했다.

### 조건

profile=functional, TPC-H SF0.01, Iceberg(HMS 4.0.1 native + MinIO), Trino 483 / StarRocks 4.0.14,
host=linux/amd64 (Linux 6.8, 8 CPU, RAM 15.6GB), Trino worker 1대 / StarRocks BE 1대,
명시한 세션 변수 외 기본값.
