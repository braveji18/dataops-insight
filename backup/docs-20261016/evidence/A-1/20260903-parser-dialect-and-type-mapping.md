# 파싱·타입 계층 판별 4종: `||` 의미, 예약어, Iceberg 타입 매핑, Trino 방언 모드

> 비교 축: A-1 SQL 파싱 & 분석 계층 (`plan/01-비교항목-정리.md`)
> 본문: `docs/A-1-01-문법-정의와-방언-커버리지.md`, `docs/A-1-02-타입-체계.md`
> 일자: 2026-09-03

### 주장

A-1의 소스코드 비교에서 나온 네 가지 주장을 실행으로 확인한다.

1. StarRocks는 `||` 를 **논리 OR** 로 해석한다. Trino는 항상 문자열 결합이다. StarRocks 렉서가 `sql_mode` 를 읽어 토큰 타입을 바꾸기 때문이고, 기본 `sql_mode` 에는 `PIPES_AS_CONCAT` 이 없다
2. StarRocks의 예약어 집합이 Trino보다 넓다. 소스 기준 155개 vs 83개
3. 같은 Iceberg 테이블에서 Trino는 `timestamp` 와 `timestamptz` 를 서로 다른 타입으로 보고, StarRocks는 둘 다 `DATETIME` 으로 본다
4. StarRocks는 `sql_dialect='trino'` 로 Trino 파서(trino-parser 385)를 태울 수 있고, 실패하면 자기 파서로 되돌린다

### 판별 1 — `||`

```sql
SELECT 'a' || 'b';
SELECT 1 || 0, 0 || 0;
```

| 엔진 / 설정 | `'a' \|\| 'b'` | `1 \|\| 0` | `0 \|\| 0` |
|---|---|---|---|
| Trino 483 | `ab` | **파싱 오류** | — |
| StarRocks 4.0.14 (기본) | **`NULL`** | `1` | `0` |
| StarRocks (`sql_mode='PIPES_AS_CONCAT'`) | `ab` | — | — |

`1 || 0 = 1`, `0 || 0 = 0` 이므로 논리 OR 로 확정된다. `'a' || 'b'` 는 문자열을 boolean 으로 캐스트하지 못해 `NULL` 이 되는데, **오류가 아니라 조용히 NULL 이 나온다.** Trino 에서 옮겨온 SQL 이 실패하지 않고 틀린 값을 반환하는 경로다.

`sql_mode` 를 바꾸면 같은 SQL 이 `ab` 가 된다 — 원인이 렉서의 `sqlMode` 분기임이 확정된다.

### 판별 2 — 예약어를 컬럼 별칭으로

```sql
SELECT 1 AS <word>
```

| 단어 | Trino | StarRocks |
|---|---|---|
| `text` | OK | 오류 |
| `key` | OK | 오류 |
| `json` | OK | 오류 |
| `range` | OK | 오류 |
| `partition` | OK | 오류 |

5개 모두 갈렸다. 소스에서 계산한 차집합(StarRocks에만 예약된 99개)의 표본이다.

### 판별 3 — 같은 Iceberg 테이블, 다른 타입 표면

Trino로 테이블을 만들고 양쪽에서 스키마와 값을 읽었다. 두 엔진이 **같은 카탈로그·같은 파일**을 본다.

```sql
CREATE TABLE bench.typeprobe (
  ts_ntz timestamp(6),
  ts_tz  timestamp(6) with time zone,
  d      decimal(38,4),
  u      uuid,
  b      varbinary
);
INSERT INTO bench.typeprobe VALUES (
  TIMESTAMP '2026-01-02 03:04:05.123456',
  TIMESTAMP '2026-01-02 03:04:05.123456 Asia/Seoul',
  DECIMAL '12345.6789',
  UUID '12151fd2-7586-11e9-8f9e-2a86e4085a59',
  X'0102');
```

| 컬럼 | Trino `DESCRIBE` | StarRocks `DESC` |
|---|---|---|
| `ts_ntz` | `timestamp(6)` | `DATETIME` |
| `ts_tz` | `timestamp(6) with time zone` | **`DATETIME`** (구분 불가) |
| `d` | `decimal(38,4)` | `DECIMAL(38,4)` |
| `u` | `uuid` | `VARBINARY` |
| `b` | `varbinary` | `VARBINARY` |

**시간대 의미는 StarRocks도 지킨다.** 세션 `time_zone` 만 바꿔 같은 행을 다시 읽었다.

| `time_zone` | `ts_ntz` | `ts_tz` |
|---|---|---|
| `Etc/UTC` | 2026-01-02 03:04:05.123456 | 2026-01-01 18:04:05.123456 |
| `Asia/Seoul` | 2026-01-02 03:04:05.123456 | **2026-01-02 03:04:05.123456** |

`ts_tz` 만 +9시간 이동했고 `ts_ntz` 는 고정이다. 즉 StarRocks는 Iceberg 의 `adjust-to-UTC` 플래그를 **읽기 경로에서는 반영한다.** 무너지는 것은 **타입 표면**이다 — 스키마만 보고 두 컬럼을 구분할 수 없다.

**UUID 는 읽기가 실패한다.** FE 는 `VARBINARY` 로 매핑하지만 BE 리더가 거부한다.

```
ERROR 1064 (HY000): parquet column reader: not supported convert from parquet
`FIXED_LEN_BYTE_ARRAY` to `VARBINARY`: ... BE:10001
```

같은 `VARBINARY` 라도 `X'0102'` 로 넣은 `b` 컬럼은 `hex(b) = 0102` 로 정상 조회된다. 따라서 원인은 VARBINARY 자체가 아니라 **Parquet `FIXED_LEN_BYTE_ARRAY` → VARBINARY 경로의 부재**다. FE 의 타입 매핑과 BE 리더의 지원 범위가 어긋나 있고, 이 불일치는 **조회 시점에야 드러난다**(`DESC` 는 성공한다).

### 판별 4 — `sql_dialect='trino'`

```sql
SELECT approx_distinct(l_orderkey) FROM lineitem;   -- Trino 전용 이름
```

| 설정 | 결과 |
|---|---|
| Trino 483 | `15432` |
| StarRocks 기본 | 오류 — `No matching function with signature: approx_distinct(bigint(20))` |
| StarRocks `sql_dialect='trino'` | **`15022`** — 출력 컬럼명이 `approx_count_distinct(l_orderkey)` 로 바뀌어 나온다 |

방언 계층은 **함수 이름을 치환할 뿐 알고리즘을 옮기지 않는다.** 두 엔진의 근사 distinct 구현이 달라 값이 다르다(15432 vs 15022, 약 2.7% 차이).

되돌림도 확인했다. `sql_dialect='trino'` 상태에서 Trino 문법에 없는 `SHOW DATABASES FROM iceberg` 를 실행하면 그대로 동작한다 — `enable_dialect_downgrade` 가 기본 `true` 라 StarRocks 파서로 재시도한다.

### 판정

**네 주장 모두 확인됐다.** 실무 관점의 무게는 서로 다르다.

- 판별 1은 **조용한 오답**이라 가장 위험하다. 판별 2·4는 오류로 즉시 드러난다
- 판별 3의 `timestamptz` 는 값이 맞으므로 즉시 사고가 나지 않는다. 문제는 **스키마만으로 판단할 수 없다**는 것, 그리고 StarRocks 에서 테이블을 만들 때 그 구분을 표현할 수단이 없다는 것이다
- 판별 3의 UUID 는 FE/BE 이원 구조에서 나오는 종류의 결함이다. A-5-03(파일 리더)과 같은 뿌리다

**한정** — 랩 1노드 구성이지만 이 네 항목은 노드 수와 무관하다. Iceberg 파일 포맷은 Parquet 기본값이며, ORC/Avro 는 확인하지 않았다.

### 조건

profile=functional, TPC-H SF0.01, Iceberg(HMS 4.0.1 native + MinIO), Trino 483 / StarRocks 4.0.14,
host=linux/amd64 (Linux 6.8, 8 CPU, RAM 15.6GB), Trino worker 1대 / StarRocks BE 1대,
명시한 세션 변수 외 기본값.
