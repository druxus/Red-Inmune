# SOC Dashboard Reference

The Grafana dashboard (`La Red Inmune · SOC Dashboard`) provides real-time visibility over all security incidents detected and handled by the platform.

---

## Panels

### Incidentes Totales
- **Type:** Stat
- **Query:** `SELECT COUNT(*) FROM incidentes`
- Turns red when count exceeds 5.

### En Cuarentena
- **Type:** Stat
- **Query:** `SELECT COUNT(*) FROM incidentes WHERE estado = 'En cuarentena'`
- Turns orange at 1, red at 3.

### Actividad — Últimas 24 horas
- **Type:** Time series
- Groups incidents by hour using Grafana's `$__timeFilter` macro.
- Useful for spotting attack bursts or sustained campaigns.

### Top 10 Reglas Disparadas
- **Type:** Horizontal bar chart
- Shows which Falco rules are triggering most often.
- Helps tune `REGLAS_IGNORADAS` if a noisy rule is generating false positives.

### Distribución por Estado
- **Type:** Donut pie chart
- Breaks down incidents by their `estado` field (`Detectado`, `En cuarentena`, etc.).

### Últimos Pods en Cuarentena
- **Type:** Table
- Shows the five most recently quarantined pods (one row per unique pod name).

### Registro de Incidentes
- **Type:** Table
- Full incident log, last 100 rows, ordered by most recent first.
- Columns: ID, Fecha, Regla, Pod, Estado.

---

## Refresh and time range

- **Auto-refresh:** every 10 seconds
- **Default time range:** last 24 hours

Both can be changed from the Grafana toolbar at the top right.

---

## Importing the dashboard

The dashboard is imported via the Grafana REST API using `deploy/Crear-Dashboard-SOC.sh`. The script:

1. Authenticates with Basic Auth
2. Fetches the datasource UID for `grafana-postgresql-datasource`
3. Injects the UID into all panel targets
4. POSTs the dashboard JSON to `/api/dashboards/db`

If you need to re-import (e.g. after changing the datasource name), simply re-run the script — `"overwrite": true` ensures it replaces the existing dashboard.
