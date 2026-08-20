-- StarRocks 에 Trino 와 "동일한" Iceberg 카탈로그를 등록한다.
-- conf/trino/catalog/iceberg.properties 와 항상 짝을 이뤄야 한다.
-- 카탈로그 이름을 양쪽 모두 iceberg 로 맞췄기 때문에, 같은 SQL 문자열
--   SELECT ... FROM iceberg.bench.lineitem
-- 이 두 엔진에서 그대로 동작한다. 비교 쿼리를 한 벌만 관리하기 위한 선택.

DROP CATALOG IF EXISTS iceberg;

CREATE EXTERNAL CATALOG iceberg
PROPERTIES (
    "type" = "iceberg",
    "iceberg.catalog.type" = "hive",
    "hive.metastore.uris" = "thrift://hive-metastore:9083",
    "aws.s3.endpoint" = "http://minio:9000",
    "aws.s3.region" = "us-east-1",
    "aws.s3.enable_ssl" = "false",
    -- MinIO 필수. 빠뜨리면 bucket.host 형태로 접근하다 DNS 에서 실패한다.
    "aws.s3.enable_path_style_access" = "true",
    "aws.s3.access_key" = "minio",
    "aws.s3.secret_key" = "minio123"
);
