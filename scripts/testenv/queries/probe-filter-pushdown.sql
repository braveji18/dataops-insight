-- 판별 목적: 술어가 Iceberg 스캔 단계까지 내려가는가 (plan/01 A-2 / A-5)
--
-- 이 SQL 자체가 아니라 EXPLAIN 결과를 봐야 한다:
--   bin/q.sh trino --explain -f queries/probe-filter-pushdown.sql
--   bin/q.sh sr    --explain -f queries/probe-filter-pushdown.sql
--
-- 볼 것: 스캔 노드에 술어가 붙는가, 예상 스캔 행 수가 필터 후 값으로 줄어드는가,
--        아니면 전체를 읽고 상위 Filter 노드에서 거르는가.
SELECT count(*)
FROM iceberg.bench.lineitem
WHERE l_shipdate >= DATE '1995-01-01'
  AND l_shipdate <  DATE '1995-04-01'
  AND l_discount BETWEEN 0.05 AND 0.07
  AND l_quantity < 24
