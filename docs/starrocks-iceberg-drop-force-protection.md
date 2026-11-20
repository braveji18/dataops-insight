# StarRocks: 외부 Iceberg 테이블 `DROP TABLE ... FORCE` 시 원본 데이터 삭제 방지

## 결론

- **StarRocks 자체에는 `DROP TABLE ... FORCE`의 데이터 삭제를 막는 설정이 없습니다.**
- 대신 **Iceberg 테이블 속성 `gc.enabled = false`**를 주면 데이터 파일 삭제를 막을 수 있습니다. 단, catalog 종류에 따라 결과가 다릅니다.
- 가장 안전한 방법은 **DROP 권한 제한과 S3 버저닝 또는 DeleteObject 거부를 함께 쓰는 구성**입니다.

> 확인 기준: StarRocks 최신 소스(main 브랜치, 2026-11-20 기준, Iceberg 1.12.0 사용)와 Apache Iceberg 1.12.0 소스

---

## 1. StarRocks에는 막는 설정이 없음

`IcebergMetadata.dropTable()`은 FORCE 여부를 그대로 Iceberg 라이브러리에 넘깁니다.

```java
icebergCatalog.dropTable(context, stmt.getDbName(), stmt.getTableName(), stmt.isForceDrop());
```

이 경로에 FE 설정이나 catalog 속성으로 purge를 끄는 분기는 없습니다. 그래서 실제 동작은 **Iceberg 쪽 로직**이 결정합니다.

## 2. Iceberg 속성 `gc.enabled = false`

FORCE(purge)일 때 Iceberg의 `CatalogUtil.dropTableData()`는 다음처럼 동작합니다.

```java
boolean gcEnabled = PropertyUtil.propertyAsBoolean(metadata.properties(), GC_ENABLED, GC_ENABLED_DEFAULT);
if (gcEnabled) {
  // delete data files only if we are sure this won't corrupt other tables
  deleteFiles(io, manifestsToDelete);
}
// 이후 manifest, manifest list, metadata.json 등은 무조건 삭제
```

즉 `gc.enabled=false`이면 **데이터 파일(parquet 등)은 남고, 메타데이터 파일(manifest, metadata.json 등)은 삭제**됩니다.

설정은 Spark 등에서 할 수 있습니다.

```sql
-- Spark SQL
ALTER TABLE iceberg_catalog.db.tbl SET TBLPROPERTIES ('gc.enabled' = 'false');
```

StarRocks에서 테이블을 만들 때 `PROPERTIES ("gc.enabled" = "false")`로 지정할 수도 있습니다. 기존 테이블의 속성을 StarRocks에서 바꾸는 기능은 버전에 따라 다르므로, Spark에서 설정하는 것이 확실합니다.

## 3. Catalog 종류별 FORCE 동작

| Iceberg catalog 종류 | `DROP TABLE ... FORCE` 동작 | `gc.enabled=false` 효과 |
|---|---|---|
| **Hive Metastore** | HMS 항목 삭제 → `dropTableData()` 실행 | ✅ 데이터 파일 유지 (메타데이터 파일은 삭제) |
| **Glue** | Glue 항목 삭제 → `dropTableData()` 실행 | ✅ 위와 같음 |
| **JDBC** | 위와 같은 방식 | ✅ 위와 같음 |
| **REST** | StarRocks가 purge 플래그를 넘기지 않음 (`dropTable(context, identifier)` 호출) | 해당 없음. **FORCE를 붙여도 StarRocks는 purge를 요청하지 않으며**, 삭제 여부는 REST 서버 정책에 따름 |
| **Hadoop (파일 경로 기반)** | purge 처리 후 **테이블 디렉터리 전체를 재귀 삭제**(`fs.delete(tablePath, true)`). **FORCE가 없어도 삭제됨** | ❌ 효과 없음. 테이블 경로 아래에 있는 데이터는 지워짐 |

Hadoop catalog는 테이블이 곧 디렉터리라서, 일반 DROP으로도 데이터가 삭제됩니다. 이 경우는 5번의 권한·스토리지 보호가 유일한 방법입니다.

## 4. `gc.enabled=false`의 부작용

- **메타데이터는 삭제됩니다.** FORCE 후 데이터 파일은 남지만 metadata.json과 manifest가 없어서, `register_table`로 바로 다시 등록할 수 없습니다. 복구하려면 새 테이블을 만들고 Spark의 `add_files` 프로시저 등으로 파일을 다시 붙여야 합니다.
- **테이블 유지보수가 막힙니다.** Iceberg는 GC가 꺼진 테이블에서 `expire_snapshots`나 `remove_orphan_files`를 거부합니다. 오래된 스냅샷과 파일이 계속 쌓이므로 스토리지 비용이 늘어납니다.

## 5. 더 확실한 보호 방법 (함께 쓰는 것을 권장)

1. **DROP 권한 차단**
   - 일반 사용자에게는 Iceberg 테이블에 대한 DROP 권한을 주지 않습니다. Ranger를 쓴다면 Ranger 정책에서 막습니다.
   - FORCE 실수 자체를 원천 차단하는 방법입니다.
2. **S3 레벨 보호**
   - **버킷 버저닝**을 켜 두면 삭제되어도 이전 버전으로 복구할 수 있습니다(메타데이터 포함).
   - StarRocks가 쓰는 IAM 자격 증명에서 `s3:DeleteObject`를 **거부**하는 버킷 정책을 둡니다. Iceberg의 일반 INSERT나 OVERWRITE는 파일을 물리적으로 지우지 않으므로 쓰기에는 영향이 거의 없습니다. 다만 StarRocks에서 스냅샷 정리 같은 유지보수 작업은 할 수 없게 됩니다.
   - 규정상 필요하다면 **Object Lock**(보존 모드)을 씁니다.
3. **REST catalog를 쓴다면**
   - 서버 쪽 purge 정책을 확인하세요. Polaris, Unity, Nessie 등 서버마다 동작이 다릅니다.

---

## 정리

"실수로 FORCE를 해도 데이터는 남게" 하려면 `gc.enabled=false`만으로는 반쪽짜리 보호입니다(데이터만 남고 메타데이터는 사라짐). **DROP 권한 제한과 S3 버저닝 또는 DeleteObject 거부를 함께 쓰는 구성**이 가장 안전합니다.

---

## 참고 자료

- [StarRocks 소스: `IcebergMetadata.java`](https://github.com/StarRocks/starrocks/blob/main/fe/fe-core/src/main/java/com/starrocks/connector/iceberg/IcebergMetadata.java)
- [StarRocks 소스: `IcebergRESTCatalog.java`](https://github.com/StarRocks/starrocks/blob/main/fe/fe-core/src/main/java/com/starrocks/connector/iceberg/rest/IcebergRESTCatalog.java)
- [Apache Iceberg 소스: `CatalogUtil.java` (1.12.0)](https://github.com/apache/iceberg/blob/apache-iceberg-1.12.0/core/src/main/java/org/apache/iceberg/CatalogUtil.java)
- [Apache Iceberg 소스: `HadoopCatalog.java` (1.12.0)](https://github.com/apache/iceberg/blob/apache-iceberg-1.12.0/core/src/main/java/org/apache/iceberg/hadoop/HadoopCatalog.java)
- [StarRocks — Iceberg DDL operations](https://docs.starrocks.io/docs/data_source/catalog/iceberg/DDL/)
