-- TPC-H Q1 (양쪽 방언에서 그대로 도는 형태로 조정)
-- 원본의 `date '1998-12-01' - interval '90' day` 는 두 엔진의 날짜 산술 문법이 달라서
-- 계산 결과 리터럴로 고정했다. 비교 대상은 날짜 함수가 아니라 집계 성능이므로 무해하다.
SELECT
    l_returnflag,
    l_linestatus,
    sum(l_quantity)                                       AS sum_qty,
    sum(l_extendedprice)                                  AS sum_base_price,
    sum(l_extendedprice * (1 - l_discount))               AS sum_disc_price,
    sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) AS sum_charge,
    avg(l_quantity)                                       AS avg_qty,
    avg(l_extendedprice)                                  AS avg_price,
    avg(l_discount)                                       AS avg_disc,
    count(*)                                              AS count_order
FROM iceberg.bench.lineitem
WHERE l_shipdate <= DATE '1998-09-02'
GROUP BY l_returnflag, l_linestatus
ORDER BY l_returnflag, l_linestatus
