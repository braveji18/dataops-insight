# A-3 데이터 표현 — 배치 단위 판별 probe 4종

> 대상 문서: `docs/A-3-01-데이터-표현과-벡터화.md`
> 형식: `.claude/skills/lakehouse-lab/references/protocol.md` 4절
> 일자: 2026-09-04

**공통 조건**: profile=functional, TPC-H SF0.01, Trino 483 (worker 1) / StarRocks 4.0.14 (BE 1),
host=linux/x86_64 (8 CPU / 16GB), hive=4, 캐시=기본값.

**이 축은 원래 런타임으로 확인할 수 있는 범위가 좁다.** 데이터 표현(블록/컬럼의 메모리 배치, SIMD 사용)은
플랜이나 프로파일에 드러나지 않는다. 여기서 확인할 수 있는 것은 **배치 단위의 노브와 그 효과**까지다.

---

## probe 1 — 배치 크기를 무엇으로 정하는가

### 주장

StarRocks 는 **행 수**로, Trino 는 **바이트와 행 수 두 축**으로 배치 크기를 정한다.

### 판별

```sql
-- StarRocks
SELECT @@chunk_size;

-- Trino
SHOW SESSION LIKE '%page%';
```

### 결과

| 엔진 | 노출된 노브 | 값 |
|---|---|---|
| StarRocks 4.0.14 | `chunk_size` | **4096** (행 수) |
| Trino 483 | `filter_and_project_min_output_page_row_count` | **256** (행 수) |
| Trino 483 | `filter_and_project_min_output_page_size` | **500kB** (바이트) |

`SHOW SESSION LIKE '%page%'` 에 나온 나머지 둘(`iceberg.parquet_writer_page_size`,
`iceberg.parquet_writer_page_value_count`)은 Parquet 파일 쓰기용이지 실행 배치와 무관하다.

**성격이 다르다.** StarRocks 의 `chunk_size` 는 **실행 전체의 기본 배치 크기**다(BE 코드에서
`state->chunk_size()` 또는 `config::vector_chunk_size` 를 참조하는 지점이 246곳). Trino 의 두 값은
**filter/project 연산자 출력의 하한**일 뿐이고, 전체 배치 크기를 정하는 노브는 세션에 노출돼 있지 않다.

### 판정

**노브의 축과 적용 범위가 다르다.** StarRocks 는 행 수 하나로 전역, Trino 는 행 수와 바이트 두 축으로 특정 연산자에만.

---

## probe 2 — `chunk_size` 는 실제로 실행에 영향을 주는가 (★)

### 주장

청크는 이름뿐인 개념이 아니라 **실제로 물질화되는 메모리 단위**다. 크기를 바꾸면 할당량이 바뀌어야 한다.

### 판별 쿼리

```sql
SET chunk_size = <64 | 4096 | 32768>;
EXPLAIN ANALYZE SELECT l_returnflag, count(*) FROM iceberg.bench.lineitem GROUP BY l_returnflag;
```

프로파일 요약의 `QueryAllocatedMemoryUsage` 를 읽는다. **시간이 아니라 할당량**을 신호로 쓴다 —
이 랩에서는 실행 시간으로 결론을 내지 않기 때문이다(`plan/02` 6-2절).

### 결과 (각 2회)

| `chunk_size` | 시도 1 | 시도 2 |
|---|---|---|
| **64** | 3.745 MB | 3.733 MB |
| **4096** (기본) | 3.172 MB | 3.169 MB |
| **32768** | 7.076 MB | 7.077 MB |

- 기본값 대비 8배(32768)로 키우면 할당량이 **2.2배**로 늘었다
- 64로 줄이면 오히려 조금 **늘었다**(3.17 → 3.74MB). 청크 하나당 고정 비용이 있고 청크 수가 64배가 되기 때문으로 읽힌다
- 재현성이 높다 — 두 시도의 편차가 0.5% 미만

### 결과 정합성

같은 쿼리를 세 설정으로 실행한 결과가 서로 같고, Trino 와도 같다.

| 설정 | A | N | R |
|---|---|---|---|
| SR `chunk_size=64` | 14876 / 532348211.65 | 30397 / 1085247103.47 | 14902 / 534594445.35 |
| SR `chunk_size=4096` | (동일) | (동일) | (동일) |
| SR `chunk_size=32768` | (동일) | (동일) | (동일) |
| Trino 483 | 14876 / 5.3234821165E8 | 30397 / 1.08524710347E9 | 14902 / 5.3459444535E8 |

### 판정

**청크는 실제 메모리 단위이고 노브는 살아 있다.** 다만 **어느 값이 빠른지는 판정하지 않는다** — 시간을 재지 않았다.

---

## probe 3 — Trino 에 대응하는 노브가 없다

### 판별

Trino 에서 배치 크기를 바꾸려 해도 세션 속성이 없다. 소스에서 값은 **코드 상수**다.

| 상수 | 값 | 위치 |
|---|---|---|
| `PageProcessor.MAX_BATCH_SIZE` | 8192 행 | `operator/project/PageProcessor.java:55` |
| `PageProcessor.MAX_PAGE_SIZE_IN_BYTES` | 16 MB | `:56` |
| `PageProcessor.MIN_PAGE_SIZE_IN_BYTES` | 4 MB | `:57` |
| `PageBuilderStatus.DEFAULT_MAX_PAGE_SIZE_IN_BYTES` | 1 MB | `spi/block/PageBuilderStatus.java:22` |

그리고 배치 크기는 **런타임에 스스로 조정된다** — `PageProcessor.java:220-231`:

```java
private void updateBatchSize(int positionCount, long pageSize)
{
    // if we produced a large page, halve the batch size for the next call
    if (positionCount > 1 && pageSize > MAX_PAGE_SIZE_IN_BYTES) {
        projectBatchSize = projectBatchSize / 2;
    }

    // if we produced a small page, double the batch size for the next call
    if (pageSize < MIN_PAGE_SIZE_IN_BYTES && projectBatchSize < MAX_BATCH_SIZE) {
        projectBatchSize = projectBatchSize * 2;
    }
}
```

StarRocks 쪽에는 이런 적응 로직이 없다. BE 에서 `adaptive` 라는 이름이 붙은 것은
`AdaptiveNullableColumn`(NULL 표현 적응)이지 청크 크기가 아니다.

### 판정

**Trino 는 바이트 예산을 목표로 행 수를 런타임에 조절하고, StarRocks 는 행 수를 고정한다.**

---

## probe 4 — 프로파일이 노출하는 단위

### 판별

같은 쿼리를 양쪽 `EXPLAIN ANALYZE` 로 실행해 어떤 단위가 보이는지 본다.

### 결과

| 엔진 | 연산자별로 보이는 것 |
|---|---|
| Trino 483 | `Input: 60175 rows (587.64kB)`, `Output: 3 rows (45B)`, `Input avg./std.dev.` — **행과 바이트를 함께** |
| StarRocks 4.0.14 | `OutputRows: 60.175K`, `TotalTime/CPUTime/ScanTime`, `InstanceAllocatedMemoryUsage` — **행과 시간, 메모리** |

**청크·페이지 개수를 직접 보여주는 카운터는 어느 쪽에도 없다.** StarRocks 프로파일의 `GroupChunkRead` 는
Parquet row group 읽기 타이머이지 실행 청크와 무관하다(`pipeline_profile_level=2` 로 올려도 같다).

### 판정

**둘 다 배치 단위 자체를 관측 지표로 노출하지 않는다.** 행 단위로만 볼 수 있다.

---

## 정리

| probe | 판정 |
|---|---|
| 1 배치 크기 노브 | SR = 행 수 1축·전역 / Trino = 행 수+바이트 2축·연산자 한정 |
| 2 `chunk_size` 효과 | **살아 있다** — 8배 키우면 할당량 2.2배. 결과는 불변 |
| 3 Trino 의 배치 크기 | 코드 상수 + **런타임 적응**(바이트 예산 기준 배증/반감) |
| 4 프로파일 단위 | 양쪽 다 배치 개수는 노출하지 않는다 |

### 이 probe 로 판별하지 못한 것

- **실행 시간** — `chunk_size` 를 바꿨을 때 어느 값이 빠른지 재지 않았다. 할당 메모리만 신호로 썼다(`perf` 프로파일 필요, `plan/02` 6-2절)
- **블록/컬럼의 내부 메모리 배치** — NULL 마스크, 딕셔너리, 상수 표현이 실제로 어떻게 잡히는지는 플랜·프로파일에 드러나지 않는다. 코드 비교로만 확인했다
- **SIMD 가 실제로 도는지** — CPU 카운터 수집이 필요하다. 이 랩에서는 불가
- **StarRocks 네이티브 테이블** — 전부 Iceberg 외부 테이블로만 쟀다. 네이티브 스캔은 청크 생성 경로가 다르다
- **다중 노드** — worker/BE 1대. 셔플 구간의 배치 단위는 A-4 의 주제다
