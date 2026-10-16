# 파일 리더 호환성: 정상 경로는 완전히 동등하고, 갈리는 곳은 가장자리다

> 비교 축: A-5 커넥터 / 파일 리더 (`plan/01-비교항목-정리.md`)
> 본문: `docs/A-5-03-파일-리더.md`
> 관련: `docs/evidence/A-5/20260820-starrocks-4.0.1-parquet-date-zonemap-crash.md`
> 　　　`docs/evidence/A-1/20260903-parser-dialect-and-type-mapping.md` (판별 3의 UUID)
> 일자: 2026-09-04

### 주장

두 엔진은 같은 Parquet 파일을 각자 독립적으로 구현한 리더로 읽는다(Trino Java / StarRocks C++). **정상 경로에서는 결과가 같아야 하고, 갈린다면 그것은 가장자리 기능일 것이다.**

확인할 것: 복합 타입, 압축 코덱, Iceberg v2 삭제 파일, 지원하지 않는 타입에서의 실패 방식.

### 판별 1 — 복합 타입 왕복

Trino 로 쓰고 양쪽에서 읽었다.

```sql
CREATE TABLE bench.rd (id bigint, arr array(integer), mp map(varchar,integer),
                       st row(a integer, b varchar), ts timestamp(6), dec decimal(30,6));
INSERT INTO bench.rd VALUES
 (1, ARRAY[1,2,3], MAP(ARRAY['x','y'],ARRAY[10,20]), ROW(7,'seven'),
     TIMESTAMP '2026-01-02 03:04:05.123456', DECIMAL '123.456789'),
 (2, ARRAY[], MAP(), ROW(NULL,NULL), NULL, DECIMAL '-0.000001');
```

| 행 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| 1 | `[1, 2, 3]` / `{x=10, y=20}` / `{a=7, b=seven}` / `2026-01-02 03:04:05.123456` / `123.456789` | `[1,2,3]` / `{"x":10,"y":20}` / `{"a":7,"b":"seven"}` / `2026-01-02 03:04:05.123456` / `123.456789` |
| 2 | `[]` / `{}` / `{a=NULL, b=NULL}` / (NULL) / `-0.000001` | `[]` / `{}` / `{"a":null,"b":null}` / `NULL` / `-0.000001` |

**완전히 일치한다.** 빈 배열·빈 맵·NULL 필드를 가진 구조체·음수 소수까지 같다. 표기법만 다르다(Trino 는 `{k=v}`, StarRocks 는 JSON 형태).

`json` 타입은 애초에 만들 수 없었다 — `Type not supported for Iceberg: json`. Iceberg 스펙의 문제이므로 리더 비교에 해당하지 않는다.

### 판별 2 — 압축 코덱

`CREATE TABLE ... WITH (compression_codec='<C>') AS SELECT * FROM nation` 로 코덱별 파일을 만들고 양쪽에서 읽었다.

| 코덱 | 쓰기 | Trino 읽기 | StarRocks 읽기 |
|---|---|---|---|
| ZSTD | OK | 25 | 25 |
| GZIP | OK | 25 | 25 |
| SNAPPY | OK | 25 | 25 |
| NONE | OK | 25 | 25 |
| LZ4 | **Trino 가 거부** — `Compression codec LZ4 not supported for Parquet` | — | — |

**4종 전부 동등하다.** LZ4 는 읽기 문제가 아니라 Trino 의 쓰기 제약이라 판별되지 않았다.

### 판별 3 — Iceberg v2 삭제 파일

Trino 로 `DELETE` 를 실행하면 원본 파일을 다시 쓰지 않고 **삭제 파일**을 남긴다. StarRocks 가 그것을 읽고 같은 행 수를 내는지 본다.

```sql
CREATE TABLE bench.del AS SELECT * FROM bench.orders;   -- 15,000행
DELETE FROM bench.del WHERE o_orderkey % 7 = 0;         -- 2,142행 삭제
```

| 엔진 | `count(*)` |
|---|---|
| Trino 483 | **12,858** |
| StarRocks 4.0.14 | **12,858** |

**일치한다.** StarRocks 프로파일에 `DeleteFilesPerScan` 카운터가 따로 있는 것으로 보아 전용 경로가 있다.

### 판별 4 — 지원하지 않는 타입에서 어떻게 실패하는가

`A-1-02` 에서 확인한 것을 여기 옮겨 적는다. Iceberg `UUID` 컬럼이다.

| 단계 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| 스키마 조회 | `uuid` | `VARBINARY` — **성공한다** |
| 값 조회 | `12151fd2-7586-11e9-8f9e-2a86e4085a59` | **실패** — `parquet column reader: not supported convert from parquet FIXED_LEN_BYTE_ARRAY to VARBINARY` |

같은 `VARBINARY` 라도 `X'0102'` 로 넣은 컬럼은 정상 조회된다. 원인은 VARBINARY 가 아니라 **`FIXED_LEN_BYTE_ARRAY` → VARBINARY 변환 경로의 부재**다.

**주목할 것은 실패 시점이다.** FE 는 타입을 정상적으로 답하고, BE 리더가 값을 읽을 때 거부한다. **스키마만 봐서는 알 수 없다.**

### 판별 5 — 결함의 폭발 반경 (기존 증거 재인용)

`evidence/A-5/20260820-...` 의 4.0.1 크래시다. 스택 최상단이 리더 안이다.

```
starrocks::parquet::Int32ToDateConverter::convert(...)
starrocks::parquet::StatisticsHelper::decode_value_into_column(...)
starrocks::parquet::RawColumnReader::_row_group_zone_map_filter(...)
```

`Int32ToDateConverter` 는 4.0.14 에도 그대로 있다(`be/src/formats/parquet/column_converter.cpp:58`). 결함은 고쳐졌고 클래스는 남았다.

| | 결과 |
|---|---|
| StarRocks 4.0.1 | **BE 프로세스 SIGSEGV(exit 139)** → `ERROR 1064: Failed to find backend to execute` |
| StarRocks 4.0.14 | 정상 |
| Trino 483 | 정상 |

### 판정

**정상 경로는 완전히 동등하다.** 복합 타입·코덱·삭제 파일 어디서도 결과가 갈리지 않았다. 두 리더가 서로 다른 언어로 독립 구현됐음을 감안하면 상호운용성 자체는 잘 지켜지고 있다.

**갈리는 곳은 두 종류다.**

1. **지원 범위의 가장자리** — UUID(`FIXED_LEN_BYTE_ARRAY`). 오류로 드러나지만 **스키마 조회 단계에서는 드러나지 않는다**
2. **결함의 폭발 반경** — 같은 종류의 버그가 Trino 에서는 쿼리 실패로 끝나고 StarRocks 에서는 프로세스 사망으로 이어진다. 이는 구현 언어와 프로세스 경계에서 오는 구조적 차이다

**한정** — Parquet 만 봤다. ORC / Avro / CSV 는 확인하지 않았다. 파일을 인위적으로 손상시켜 보지 않았고, 4.0.1 크래시는 재현하지 않았다(디스크 부족 — `plan/02` 6-1절). 등가 삭제 파일(equality delete)은 Trino 가 만들지 않아 판별하지 못했다.

### 조건

profile=functional, TPC-H SF0.01, Iceberg(HMS 4.0.1 native + MinIO), Trino 483 / StarRocks 4.0.14,
host=linux/amd64 (Linux 6.8, 8 CPU, RAM 15.6GB), Trino worker 1대 / StarRocks BE 1대, Parquet 기본값.
