# StarRocks: DROP 시 S3 데이터는 유지하고 메타데이터만 삭제하는 방법

가능 여부는 **테이블 종류에 따라 다릅니다.**

| 대상 | metadata만 삭제 가능? | 방법 |
|---|---|---|
| **Iceberg catalog 테이블** | ✅ 가능 (기본 동작) | `DROP TABLE` (FORCE 없이) |
| **Hive catalog 테이블** | ❌ StarRocks에서는 불가 | Hive/Spark 쪽에서 EXTERNAL 테이블로 바꾼 뒤 DROP |
| **External catalog 자체** | ✅ 가능 | `DROP CATALOG` |
| **내부 테이블 (shared-data, S3 저장)** | ❌ 불가 | 데이터를 미리 export·backup하는 수밖에 없음 |

---

## 1. Iceberg catalog: 기본이 metadata만 삭제

Iceberg 테이블을 drop하면 기본적으로 원격 스토리지의 파일 경로와 데이터는 삭제되지 않습니다(v3.1부터 지원). `FORCE`를 붙이면 원격 스토리지의 테이블 데이터가 삭제되고 파일 경로만 남습니다.

```sql
SET CATALOG iceberg_catalog;
DROP TABLE iceberg_db.sales_data;          -- metadata만 삭제, S3 데이터는 유지
-- DROP TABLE iceberg_db.sales_data FORCE; -- ⚠ S3 데이터까지 삭제
```

참고로 metadata 삭제는 Iceberg catalog 백엔드(Glue, REST, HMS 등)에서 테이블 등록을 해제하는 것입니다. 나중에 S3에 남은 `metadata.json`으로 테이블을 다시 등록할 수 있습니다(Spark의 `register_table` 등).

## 2. Hive catalog: StarRocks에서는 metadata만 지울 수 없음

StarRocks에서 Hive 테이블을 DROP하는 기능에는 제약이 있습니다.

- v3.2 이상이 필요합니다.
- Managed Table만 삭제할 수 있습니다.
- `FORCE` 키워드가 필수입니다.
- 이 작업은 HDFS/오브젝트 스토리지의 테이블 데이터를 삭제하고 파일 경로만 남깁니다.

따라서 S3 데이터를 보존하려면 **StarRocks에서 DROP하지 말고 Hive(또는 Spark) 쪽에서 처리**해야 합니다.

```sql
-- Hive / Spark SQL에서 실행
ALTER TABLE db.tbl SET TBLPROPERTIES ('EXTERNAL'='TRUE');  -- managed → external
DROP TABLE db.tbl;   -- external 테이블은 metadata만 삭제됨
```

그 후 StarRocks에서 `REFRESH EXTERNAL TABLE`을 실행하거나 metadata 캐시가 만료되면 테이블이 보이지 않게 됩니다.

DB 단위 삭제(`DROP DATABASE`)는 빈 DB만 가능하고, HDFS나 오브젝트 스토리지의 해당 경로는 삭제되지 않습니다.

## 3. External catalog 삭제: 데이터에 영향 없음

```sql
DROP CATALOG hive_catalog;
```

이 명령은 StarRocks에 등록된 catalog 정의만 지웁니다. Hive Metastore나 Glue의 metadata, S3 데이터는 그대로 남습니다.

## 4. 내부 테이블 (shared-data 모드): metadata만 지우는 옵션 없음

shared-data 클러스터의 내부 테이블은 StarRocks가 S3 데이터를 직접 관리합니다. 그래서 DROP하면 결국 데이터도 지워집니다.

- **일반 `DROP TABLE`:** 휴지통으로 이동하며, 일정 시간(기본 1일) 안에는 `RECOVER`로 복구할 수 있습니다. 이 시간은 FE 설정 `catalog_trash_expire_second`로 정해지며, 지나면 S3 데이터도 정리됩니다.
- **`DROP TABLE ... FORCE`:** 바로 삭제되며 복구할 수 없습니다.

```sql
DROP TABLE my_table;
RECOVER TABLE my_table;   -- 보존 기간 안에서만 가능
```

데이터를 남기고 싶다면 DROP 전에 따로 빼 두어야 합니다.

```sql
-- 예: Parquet로 S3에 export
INSERT INTO FILES(
  "path" = "s3://bucket/backup/my_table/",
  "format" = "parquet",
  "aws.s3.region" = "ap-northeast-2"
  -- 인증 관련 속성 추가
)
SELECT * FROM my_table;
```

`BACKUP SNAPSHOT`으로 S3 repository에 백업해 두는 방법도 있습니다.

---

## 권장 구조

S3 데이터를 StarRocks와 무관하게 오래 보존하는 것이 목적이라면, 처음부터 **Iceberg 테이블로 만들어 external catalog로 읽는 구조**가 가장 깔끔합니다. 이렇게 하면 DROP과 데이터 보존을 분리해서 관리할 수 있습니다.

---

## 참고 자료

- [StarRocks — Iceberg DDL operations](https://docs.starrocks.io/docs/data_source/catalog/iceberg/DDL/)
- [StarRocks — DROP TABLE](https://docs.starrocks.io/docs/sql-reference/sql-statements/table_bucket_part_index/DROP_TABLE/)
- [StarRocks — DROP CATALOG](https://docs.starrocks.io/docs/sql-reference/sql-statements/Catalog/DROP_CATALOG/)
- [Alibaba Cloud EMR Serverless StarRocks — Hive Catalog](https://help.aliyun.com/en/emr/emr-serverless-starrocks/hive-catalog)
