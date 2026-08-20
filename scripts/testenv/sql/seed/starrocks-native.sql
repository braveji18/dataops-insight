-- 선택 시드(seed.sh --with-native): 동일 데이터를 StarRocks 네이티브 테이블로도 적재한다.
--
-- 목적은 Trino 와의 직접 비교가 아니다. plan/01 C-1(StarRocks 전용 스토리지 계층)에서
-- "같은 데이터를 레이크(Iceberg)로 읽을 때 vs 네이티브 스토리지로 읽을 때" 차이를 재는 것.
-- 이 축은 Trino 에 대응물이 없으므로 "비교"가 아니라 "부재 및 대체 수단"으로 기술한다.

CREATE DATABASE IF NOT EXISTS default_catalog.native_bench;

CREATE TABLE IF NOT EXISTS default_catalog.native_bench.lineitem
DISTRIBUTED BY HASH(l_orderkey) BUCKETS 4
PROPERTIES ("replication_num" = "1")
AS SELECT * FROM iceberg.bench.lineitem;

CREATE TABLE IF NOT EXISTS default_catalog.native_bench.orders
DISTRIBUTED BY HASH(o_orderkey) BUCKETS 4
PROPERTIES ("replication_num" = "1")
AS SELECT * FROM iceberg.bench.orders;

CREATE TABLE IF NOT EXISTS default_catalog.native_bench.customer
DISTRIBUTED BY HASH(c_custkey) BUCKETS 4
PROPERTIES ("replication_num" = "1")
AS SELECT * FROM iceberg.bench.customer;

ANALYZE TABLE default_catalog.native_bench.lineitem;
ANALYZE TABLE default_catalog.native_bench.orders;
ANALYZE TABLE default_catalog.native_bench.customer;
