# 같은 Iceberg 테이블에 대한 쓰기 능력: StarRocks 는 추가만, Trino 는 전부

> 비교 축: A-5 커넥터 / 쓰기와 테이블 포맷 트랜잭션 (`plan/01-비교항목-정리.md`)
> 본문: `docs/A-5-04-쓰기와-테이블-포맷-트랜잭션.md`
> 일자: 2026-09-04

### 주장

두 엔진이 같은 Iceberg 카탈로그를 붙이고 있으므로, **쓰기 능력을 같은 테이블에 같은 문장으로 물어볼 수 있다.**

읽기(`A-5-02`·`A-5-03`)에서는 거의 동등했다. 쓰기에서도 그런지 본다.

### 방법

Trino 로 만든 Iceberg 테이블 하나(`bench.w1`, nation 25행)에 양쪽에서 번갈아 문장을 던졌다. 성공 여부와 오류 메시지를 그대로 기록한다.

### 결과 — DML

| 문장 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| `INSERT INTO ... SELECT` | **성공** (1행) | **성공** |
| `CREATE TABLE ... AS SELECT` | **성공** (25행) | **성공** (25행) |
| `UPDATE ... SET ... WHERE` | **성공** (1행) | ✗ `table w1 does not support update` |
| `DELETE FROM ... WHERE` | **성공** (1행) | ✗ `Table of iceberg catalog doesn't support [DELETE]` |
| `MERGE INTO ...` | **성공** (2행) | ✗ 구문 오류 (문법에 없음) |

### 결과 — DDL / 스키마 진화

| 문장 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| `ALTER TABLE ADD COLUMN` | 성공 | **성공** |
| `ALTER TABLE DROP COLUMN` | 성공 | **성공** |
| `ALTER TABLE RENAME COLUMN` | 성공 | **성공** |

**상호운용도 확인했다.** StarRocks 로 `n_name` → `n_nm`, Trino 로 `n_comment` → `n_cmt` 로 각각 바꾼 뒤 양쪽에서 조회하니 **둘 다 같은 스키마**를 보았다.

| | Trino `DESCRIBE` | StarRocks `DESC` |
|---|---|---|
| | `n_nationkey, n_nm, n_regionkey, n_cmt` | `n_nationkey, n_nm, n_regionkey, n_cmt` |

### 결과 — 스냅샷 / 시간 여행 / 유지보수

| 기능 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| `FOR VERSION AS OF <snapshot_id>` | **25** | **25** |
| 메타데이터 테이블 (`$snapshots`) | **7** | **7** |
| 파일 병합 (`OPTIMIZE` / `COMPACT`) | 성공 — `ALTER TABLE ... EXECUTE optimize` | ✗ `This connector does not support ...` |

시간 여행과 메타데이터 테이블은 **완전히 동등**하다. 스냅샷 7개를 양쪽이 똑같이 보고, 첫 스냅샷 지정 조회도 양쪽 25행으로 일치했다.

### 원인 확정

StarRocks 의 거부는 **커넥터 능력 판단이 아니라 분석기의 하드코딩된 게이트**다.

```java
if (!operation.equals("ALTER") && catalog.getType().equalsIgnoreCase("iceberg")) {
    throw new SemanticException("Table of iceberg catalog doesn't support [%s]", operation);
}
```
— `sql/common/MetaUtils.java:91-93`

**`ALTER` 만 통과시키고 나머지는 카탈로그 타입 이름만 보고 거부한다.** `DeleteAnalyzer.java:201` 이 `"DELETE"` 로 이것을 호출한다.

`UPDATE` 는 다른 경로다 — 테이블 객체에 물어본다.

```java
if (!table.supportsUpdate()) {
    throw unsupportedException("table " + table.getName() + " does not support update");
}
```
— `sql/analyzer/UpdateAnalyzer.java:89-91`

**즉 두 문장이 서로 다른 방식으로 막혀 있다.** 하나는 카탈로그 이름, 하나는 테이블 능력 질의다.

한편 `IcebergMetadata` 안에는 삭제 파일을 다루는 코드가 이미 있다 — `deleteFile(DeleteFile)`, `addAppliedDeleteFiles(...)`(`:1817`, `:1850`). **기계는 있는데 문장이 연결돼 있지 않다.**

### 판정

**동등하지 않다 — 쓰기에서 격차가 크다.**

- **추가(INSERT/CTAS)와 스키마 진화는 동등하다.** 상호운용도 확인됐다
- **행 수정(UPDATE/DELETE/MERGE)은 StarRocks 가 하지 못한다.** 세 문장 모두 서로 다른 이유로 막힌다
- **유지보수(파일 병합, 스냅샷 정리)도 StarRocks 에는 없다**
- **읽기(시간 여행, 메타데이터 테이블)는 완전히 동등하다**

**한정** — Iceberg 만 봤다. Delta Lake / Hudi / Paimon 은 랩에 없다. 동시 쓰기 충돌, 트랜잭션 격리, 커밋 재시도는 확인하지 않았다(단일 세션 도구). StarRocks 네이티브 테이블의 쓰기 능력은 이 문서 범위 밖이다(`C-1-04`).

### 조건

profile=functional, TPC-H SF0.01 파생, Iceberg(HMS 4.0.1 native + MinIO), Trino 483 / StarRocks 4.0.14,
host=linux/amd64 (Linux 6.8, 8 CPU, RAM 15.6GB), Trino worker 1대 / StarRocks BE 1대, Parquet 기본값.
