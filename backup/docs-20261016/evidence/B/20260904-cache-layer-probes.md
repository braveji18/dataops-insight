# 캐시 계층: Trino 에도 파일 캐시가 있다. 갈리는 것은 기본값과 결과 캐시다

> 비교 축: B-3 캐시 계층 (`plan/01-비교항목-정리.md`)
> 본문: `docs/B-3-01-캐시-계층.md`
> 일자: 2026-09-04

### 주장

`plan/01` 은 이 축을 **"StarRocks Data Cache / Query Cache vs Trino의 부재와 대체 수단"** 으로 적었다. "부재"를 확인해야 한다.

1. Trino 483 에 파일 캐시가 정말 없는가
2. StarRocks 의 캐시는 랩에서 실제로 동작하는가
3. Query Cache 는 외부 테이블에도 적용되는가

### 판별 1 — Trino 에는 파일 시스템 캐시가 있다

`plan/01` 의 전제가 **틀렸다.**

| 모듈 | 내용 |
|---|---|
| `lib/trino-filesystem/.../cache/` | `TrinoFileSystemCache`, `CacheFileSystem`, `CacheInputFile`, `CacheSplitAffinityProvider` 등 |
| `lib/trino-filesystem-cache-alluxio/` | Alluxio 기반 구현 (9개 파일) |
| `docs/.../object-storage/file-system-cache.md` | 사용자 문서 |

문서가 지원 커넥터를 명시한다.

```
Trino includes support for caching these files with the help of the open
source [Alluxio](https://github.com/Alluxio/alluxio) libraries with catalogs
using the following connectors:

* [](/connector/delta-lake)
* [](/connector/hive)
* [](/connector/iceberg)
```

그리고 **분산 캐시**임을 밝힌다 — *"with preference for using a fixed set of nodes for a given file"*. 즉 같은 파일은 같은 노드로 보내 캐시 적중률을 높인다(`CacheSplitAffinityProvider`).

**따라서 "Trino 에 캐시가 없다"는 서술은 폐기해야 한다.**

### 판별 2 — 그러나 기본값이 정반대다

| | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| 파일/데이터 캐시 기본 | **꺼짐** — `fs.cache.directories` 가 빈 목록 | **켜짐** — `datacache_enable = true` |
| 크기 기본 | 지정해야 함 (`fs.cache.max-sizes`) | 메모리 **20%** + 디스크 **100%** |
| TTL | **7일** | 없음(용량 기반 축출) |
| 블록/페이지 단위 | 1MB | 256KB |

Trino:
```java
private List<String> cacheDirectories = ImmutableList.of();
private List<DataSize> maxCacheSizes = ImmutableList.of();
private Optional<Duration> cacheTTL = Optional.of(Duration.valueOf("7d"));
private List<Integer> maxCacheDiskUsagePercentages = ImmutableList.of();
private DataSize cachePageSize = DataSize.valueOf("1MB");
```
— `lib/trino-filesystem-cache-alluxio/.../AlluxioFileSystemCacheConfig.java:37-41`

StarRocks:
```cpp
CONF_Bool(datacache_enable, "true");
CONF_mString(datacache_mem_size, "20%");
CONF_mString(datacache_disk_size, "100%");
CONF_Int64(datacache_block_size, "262144"); // 256K
```
— `be/src/common/config.h:1372-1375`

**랩에서 확인**: BE 의 `/varz` 가 `datacache_enable=true` 를 보고한다. **아무 설정도 하지 않은 기본 상태다.**

### 판별 3 — StarRocks 캐시가 실제로 적중한다

같은 쿼리를 두 번 돌리고 두 번째의 프로파일을 봤다.

```sql
SELECT sum(l_quantity) FROM iceberg.bench.lineitem
```

```
FooterCacheReadCount: 1
FooterCacheReadTimer: 3.125us
FooterCacheWriteCount: 0
PageCacheReadCounter: 1
PageCacheReadDecompressedCounter: 1
PageCacheWriteCounter: 0
```

**읽기 카운터는 1, 쓰기 카운터는 0** — 두 번째 실행에서 Parquet footer 와 페이지를 **캐시에서 가져왔고 새로 채우지 않았다.**

### 판별 4 — Query Cache 는 외부 테이블에 적용되지 않는다

```sql
SET enable_query_cache=true;
SELECT l_returnflag, sum(l_quantity) FROM iceberg.bench.lineitem GROUP BY l_returnflag;
```

결과는 정상(`R 381449`, `A 380456`)이고 세션 변수도 `false -> true` 로 바뀌었다. 그러나 **프로파일에 캐시 연산자가 나타나지 않는다.**

코드가 이유를 말해 준다. `planner/` 아래 스캔 노드 중 query cache 를 다루는 것은 **`OlapScanNode.java` 하나뿐**이다.

```java
int pkHotNum = connectContext.getSessionVariable().getQueryCacheHotPartitionNum();
```
— `fe/fe-core/.../planner/OlapScanNode.java:1314`

`IcebergScanNode.java` 에는 `QueryCache` 언급이 **0건**이다.

**즉 Query Cache 는 StarRocks 네이티브 테이블 전용이다.** 기본값도 꺼져 있다(`enableQueryCache = false`, `SessionVariable.java:2568`).

### 판별 5 — Trino 에는 쿼리 결과 캐시가 없다

`trino/core/` 와 `trino/lib/` 전체에서 `resultcache` / `querycache` 를 대소문자 무시로 검색해 **0건**이다. 문서에도 없다.

**이 부분은 `plan/01` 의 "부재"가 맞다.** 대체 수단은 Materialized View 인데, `A-2-06` 에서 확인한 대로 **Trino 는 MV 자동 재작성 규칙이 0개**라 사용자가 직접 MV 를 조회해야 한다.

### 판정

**`plan/01` 의 "Trino 의 부재"는 절반만 맞다.**

| 계층 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| 파일/블록 캐시 | **있음** (Alluxio 기반, 분산, 캐시 친화 스플릿 배정) — **기본 꺼짐** | **있음** (Data Cache) — **기본 켜짐** |
| 쿼리 결과 캐시 | **없음** | **있음** — 단 **네이티브 테이블 전용**, 기본 꺼짐 |
| 대체 수단 | MV (자동 재작성 없음 — `A-2-06`) | MV (자동 재작성 있음) |

**실무적으로 갈리는 것은 "있느냐"가 아니라 "켜져 있느냐"다.** 아무 설정 없이 붙이면 StarRocks 는 캐시가 돌고 Trino 는 돌지 않는다.

**한정** — Trino 파일 캐시는 랩에 구성돼 있지 않아 **실측하지 못했다.** 적중률·성능 이득도 재지 않았다(SF 0.01). StarRocks Query Cache 를 네이티브 테이블에서 시험하지 않았다.

### 조건

profile=functional, TPC-H SF0.01, Iceberg(HMS 4.0.1 native + MinIO), Trino 483 / StarRocks 4.0.14,
host=linux/amd64 (Linux 6.8, 8 CPU, RAM 15.6GB), Trino worker 1대 / StarRocks BE 1대, 캐시 설정 기본값.
