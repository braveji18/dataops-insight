# 커넥터 단계 프루닝: 어느 쪽도 상대의 상위집합이 아니다

> 비교 축: A-5 커넥터 / 푸시다운 (`plan/01-비교항목-정리.md`)
> 본문: `docs/A-5-02-커넥터-푸시다운.md`
> 선행: `docs/evidence/A-2/20260904-pushdown-scope-probes.md` (옵티마이저 쪽 경계)
> 일자: 2026-09-04

### 주장

`A-2-04` 는 **옵티마이저가 커넥터에게 술어를 넘기는 방식**을 비교했다(협상 유무). 이 실험은 그다음을 본다 — **넘어간 술어로 커넥터가 실제로 파일을 얼마나 걷어내는가.**

1. 파티션 컬럼에 술어가 맨몸으로 걸리면 두 엔진의 프루닝 결과가 같다
2. 술어가 **함수로 감싸이면 갈린다.** 각 엔진은 자기 재작성 규칙이 다루는 함수에서만 프루닝하고, **두 목록은 서로 포함 관계가 아니다**
3. 파티션이 아닌 컬럼에서는 파일 제거 시점이 다르다 — Trino 는 계획 시점, StarRocks 는 리더 안

### 준비

Trino 로 파티션 Iceberg 테이블을 만들고 양쪽에서 읽었다. 두 엔진이 같은 카탈로그·같은 파일을 본다.

```sql
CREATE TABLE bench.o_part WITH (partitioning = ARRAY['month(o_orderdate)']) AS
  SELECT o_orderkey, o_custkey, o_orderdate, o_totalprice, o_orderpriority FROM bench.orders;
-- 15,000행 / 80파일(= 80개월 파티션)
```

### 측정 방법

`count(*)` 는 **쓰면 안 된다.** StarRocks 가 메타데이터만 읽고 끝내므로(`A-2-04` 3-7) 스캔량이 비교되지 않는다. 컬럼을 실제로 읽는 `sum(o_totalprice)` 로 통일했다.

| 엔진 | 읽은 행 | 읽은 파일 |
|---|---|---|
| Trino | `EXPLAIN ANALYZE` 의 `Input: N rows` | `Splits: N` |
| StarRocks | `ANALYZE PROFILE FROM '<id>', 0` 의 `RawRowsRead` | `ScanRanges` |

StarRocks 의 `OutputRows` 는 **필터 통과 후**라 Trino 의 `Input` 과 짝이 아니다. `RawRowsRead`(필터 이전)가 짝이다. 초안에서 이걸 혼동해 15,000 대 255 라는 잘못된 표를 만들 뻔했다.

### 결과

| 술어 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| 없음 (기준선) | 15,000행 / 80파일 | 15,000행 / 80파일 |
| `o_orderdate >= '1995-01-01' AND < '1995-02-01'` | **165행 / 1파일** | **165행 / 1파일** |
| `year(o_orderdate) = 1995` | **2,204행 / 12파일** | 15,000행 / 80파일 ✗ |
| `date_trunc('month', o_orderdate) = '1995-01-01'` | **165행 / 1파일** | 15,000행 / 80파일 ✗ |
| 문자열 포맷 함수 * | 15,000행 / 80파일 ✗ | **165행 / 1파일** |
| `o_orderkey < 1000` (비파티션 컬럼) | 14,269행 / **75파일** | 14,269행 / **80파일** |

\* Trino `format_datetime(CAST(o_orderdate AS timestamp), 'yyyy-MM-dd')`, StarRocks `date_format(o_orderdate, '%Y-%m-%d')`. 두 엔진에서 이름이 다른 같은 성격의 함수다.

모든 행에서 **결과값은 양쪽이 일치했다.** 갈린 것은 읽은 양뿐이다.

### 원인 확정

**StarRocks 가 `year()` 를 못 미는 이유는 두 겹이다.**

`ScalarOperatorToIcebergExpr` 의 컬럼명 추출기는 컬럼 참조·CAST·서브필드만 받고 나머지는 `null` 을 돌려준다(`:465-471`). 함수 호출은 여기서 떨어지고, `visitBinaryPredicate` 는 `columnName == null` 이면 곧장 `return null` 이다(`:189-193`). 즉 **Iceberg 로 넘어가는 표현식 자체가 만들어지지 않는다.**

그런데 이건 구조적 한계가 아니다. **`date_format` 은 완전히 프루닝된다**(165행/1파일 — 맨 컬럼과 동일). `SimplifiedDateColumnPredicateRule` 이 함수를 벗겨 맨 컬럼 범위로 바꿔 놓기 때문이다. 그 규칙이 다루는 함수는 `date_format` / `substr` / `substring` / `replace` 이고 **`year` 와 `date_trunc` 는 없다.**

**Trino 쪽도 같은 구조다.** `year(o_orderdate) = 1995` 의 플랜을 보면 `filterPredicate` 가 아예 없고 `TableScan ... constraint on [o_orderdate]` 만 남는다 — `UnwrapYearInComparison` 규칙이 맨 컬럼 범위로 바꿨기 때문이다. `UnwrapDateTruncInComparison` 도 있어 `date_trunc` 가 된다. 반대로 문자열 포맷 함수는 대응 규칙이 없어 80파일을 전부 읽는다.

**따라서 이 차이는 커넥터의 능력 차이가 아니라 옵티마이저 재작성 규칙의 함수 커버리지 차이다.** 커넥터는 맨 컬럼 술어만 받으면 양쪽 다 똑같이 프루닝한다.

### 비파티션 컬럼 — 제거 시점이 다르다

`o_orderkey < 1000` 에서 두 엔진 모두 Parquet 에서 14,269행을 읽었다(15,000 중 5%만 제거 — 이 컬럼이 파일 안에서 정렬돼 있지 않아 min/max 가 거의 무력하다). 그런데 **파일 수가 다르다.**

- Trino: **75 splits** — Iceberg 매니페스트의 컬럼 통계로 5개 파일을 **계획 시점에** 제외했다
- StarRocks: **80 ScanRanges** — 80개를 전부 스케줄하고 리더 안에서 row group 단위로 걸렀다

읽은 행이 같으므로 **결과는 동등하다.** 다만 Trino 쪽은 스플릿 자체가 생기지 않아 스케줄링 비용이 덜 든다. 이 랩(파일 80개)에서는 무시할 수준이고, 파일이 수만 개인 환경에서 의미가 생길 수 있으나 **여기서 측정하지 않았다.**

### 판정

**대등하다 — 다만 강한 지점이 서로 다르다.**

- 맨 컬럼 술어: **완전히 동등**
- 함수로 감싼 술어: **서로 다른 함수 집합에서만 동작하고, 어느 쪽도 상대를 포함하지 않는다**
- 비파티션 컬럼: 읽는 양은 같고 파일 제거 시점만 다르다

**우열을 말할 수 없다.** 실무 결론은 "어느 엔진이 낫다"가 아니라 **"쓰는 함수가 그 엔진의 목록에 있는지 확인하라"** 이다.

**한정** — Iceberg / Parquet / 단일 파티션 변환(`month`)만 봤다. 다른 변환(`bucket`, `truncate`), 다른 포맷(ORC), 다른 커넥터(Hive, Delta, Paimon, JDBC)는 확인하지 않았다. 실행 시간도 재지 않았다(SF 0.01).

### 조건

profile=functional, TPC-H SF0.01 파생 테이블(orders 15,000행 → 80파티션), Iceberg(HMS 4.0.1 native + MinIO),
Trino 483 / StarRocks 4.0.14, host=linux/amd64 (Linux 6.8, 8 CPU, RAM 15.6GB),
Trino worker 1대 / StarRocks BE 1대, 명시한 세션 변수 외 기본값.
