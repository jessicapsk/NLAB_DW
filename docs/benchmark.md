# Benchmark OLTP x OLAP

Mesmo servidor MariaDB. Mediana de 3 execuções no DW e de 1 no OLTP (timeout de 300s por consulta).

| Consulta | OLTP (s) | DW (s) | Speedup |
|---|---:|---:|---:|
| B1 - Revisões por ano/mês | 1.24 | 1.07 | 1.2x |
| B2 - Revisões por categoria | > 300 (timeout) | 1.82 | > 165x |
| B3 - Revisões por autor | 2.05 | 1.03 | 2.0x |

## Planos de execução (tabela:tipo/chave/linhas estimadas)

**B1 - Revisões por ano/mês**
- OLTP: `revisions:ALL/-/~1196842`
- DW: `f:ALL/-/~1354156; t:eq_ref/PRIMARY/~1`

**B2 - Revisões por categoria**
- OLTP: `r:ALL/-/~1196842; w:ALL/-/~4853207; c:eq_ref/PRIMARY/~1`
- DW: `f:ALL/-/~1354156; p:eq_ref/PRIMARY/~1`

**B3 - Revisões por autor**
- OLTP: `r:ALL/-/~1196842; u:eq_ref/PRIMARY/~1`
- DW: `f:ALL/-/~1354156; a:ALL/-/~4`

