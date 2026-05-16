#!/usr/bin/env bash
# ============================================================
#  Crear-Dashboard-SOC.sh
#  Crea el dashboard SOC completo en Grafana via API REST
#  Requisito: kubectl port-forward svc/grafana-svc 3000:3000
#
#  Traducido de PowerShell a Bash (lógica idéntica).
# ============================================================

GRAFANA_URL="http://YOUR_GRAFANA_LB_URL"  # SVC-GRAFANA
GRAFANA_USER="admin"
GRAFANA_PASS="YOUR_GRAFANA_PASSWORD"
DS_NAME="grafana-postgresql-datasource"   # Nombre exacto del datasource

# ── Auth header (Basic base64) ───────────────────────────────
B64=$(printf '%s:%s' "$GRAFANA_USER" "$GRAFANA_PASS" | base64)

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║    La Red Inmune · Importing SOC Dashboard          ║"
echo "╚══════════════════════════════════════════════════════╝"

# ── Verificar conexión ───────────────────────────────────────
health_json=$(curl -s -f \
    -H "Authorization: Basic $B64" \
    -H "Content-Type: application/json" \
    "$GRAFANA_URL/api/health" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo ""
    echo "[✗] Error: No se detecta Grafana en $GRAFANA_URL"
    exit 1
fi
version=$(echo "$health_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null)
echo ""
echo "[✓] Grafana conectado (v${version})"

# ── Obtener UID del datasource ───────────────────────────────
datasources_json=$(curl -s \
    -H "Authorization: Basic $B64" \
    -H "Content-Type: application/json" \
    "$GRAFANA_URL/api/datasources")

DS_UID=$(echo "$datasources_json" | python3 -c "
import sys, json
ds_list = json.load(sys.stdin)
name = '$DS_NAME'
for ds in ds_list:
    if ds.get('name') == name:
        print(ds.get('uid',''))
        break
" 2>/dev/null)

if [ -z "$DS_UID" ]; then
    echo "[✗] Datasource '$DS_NAME' no encontrado."
    exit 1
fi

# ── JSON del dashboard ───────────────────────────────────────
# Nota: $__timeFilter es una macro de Grafana, se escapa con \$
dashboard_json=$(cat <<EOF
{
  "dashboard": {
    "id": null,
    "uid": null,
    "title": "La Red Inmune \u00b7 SOC Dashboard",
    "tags": ["soc", "security"],
    "style": "dark",
    "timezone": "browser",
    "refresh": "10s",
    "schemaVersion": 38,
    "time": { "from": "now-24h", "to": "now" },
    "panels": [
      {
        "id": 1,
        "type": "stat",
        "title": "Incidentes Totales",
        "gridPos": { "x": 0, "y": 0, "w": 6, "h": 4 },
        "transparent": true,
        "options": {
          "reduceOptions": { "calcs": ["lastNotNull"] },
          "colorMode": "background",
          "textMode": "value",
          "graphMode": "none"
        },
        "fieldConfig": {
          "defaults": {
            "thresholds": {
              "mode": "absolute",
              "steps": [{ "color": "green", "value": null }, { "color": "red", "value": 5 }]
            },
            "noValue": "0"
          }
        },
        "targets": [{
          "datasource": { "type": "postgres", "uid": "${DS_UID}" },
          "rawSql": "SELECT COUNT(*) AS \"value\"\nFROM incidentes",
          "format": "table",
          "refId": "A"
        }]
      },
      {
        "id": 2,
        "type": "stat",
        "title": "En Cuarentena",
        "gridPos": { "x": 6, "y": 0, "w": 6, "h": 4 },
        "transparent": true,
        "options": {
          "reduceOptions": { "calcs": ["lastNotNull"] },
          "colorMode": "background",
          "textMode": "value",
          "graphMode": "none"
        },
        "fieldConfig": {
          "defaults": {
            "thresholds": {
              "mode": "absolute",
              "steps": [{ "color": "green", "value": null }, { "color": "orange", "value": 1 }, { "color": "red", "value": 3 }]
            },
            "noValue": "0"
          }
        },
        "targets": [{
          "datasource": { "type": "postgres", "uid": "${DS_UID}" },
          "rawSql": "SELECT COUNT(*) AS \"value\"\nFROM incidentes\nWHERE estado = 'En cuarentena'",
          "format": "table",
          "refId": "A"
        }]
      },
      {
        "id": 4,
        "type": "timeseries",
        "title": "Actividad \u2014 \u00daltimas 24 horas",
        "gridPos": { "x": 12, "y": 0, "w": 12, "h": 8 },
        "transparent": true,
        "fieldConfig": {
          "defaults": {
            "color": { "mode": "fixed", "fixedColor": "#d7191c" },
            "custom": { "lineWidth": 2, "fillOpacity": 15, "gradientMode": "opacity" }
          }
        },
        "targets": [{
          "datasource": { "type": "postgres", "uid": "${DS_UID}" },
          "rawSql": "SELECT\n  date_trunc('hour', fecha) AS \"time\",\n  COUNT(*) AS \"Incidentes\"\nFROM incidentes\nWHERE \$__timeFilter(fecha)\nGROUP BY 1\nORDER BY 1",
          "format": "time_series",
          "refId": "A"
        }]
      },
      {
        "id": 5,
        "type": "barchart",
        "title": "Top 10 Reglas Disparadas",
        "gridPos": { "x": 0, "y": 4, "w": 12, "h": 8 },
        "transparent": true,
        "options": { "orientation": "horizontal", "xField": "Regla" },
        "targets": [{
          "datasource": { "type": "postgres", "uid": "${DS_UID}" },
          "rawSql": "SELECT\n  regla AS \"Regla\",\n  COUNT(*) AS \"Total\"\nFROM incidentes\nGROUP BY regla\nORDER BY 2 DESC\nLIMIT 10",
          "format": "table",
          "refId": "A"
        }]
      },
      {
        "id": 6,
        "type": "piechart",
        "title": "Distribuci\u00f3n por Estado",
        "gridPos": { "x": 12, "y": 8, "w": 6, "h": 8 },
        "transparent": true,
        "options": { "pieType": "donut", "legend": { "displayMode": "table", "placement": "right", "values": ["value"] } },
        "targets": [{
          "datasource": { "type": "postgres", "uid": "${DS_UID}" },
          "rawSql": "SELECT\n  estado AS \"metric\",\n  COUNT(*) AS \"value\"\nFROM incidentes\nGROUP BY estado",
          "format": "table",
          "refId": "A"
        }],
        "transformations": [{ "id": "prepareTimeSeries", "options": { "valueFieldName": "value" } }]
      },
      {
        "id": 7,
        "type": "table",
        "title": "\u00daltimos Pods en Cuarentena",
        "gridPos": { "x": 18, "y": 8, "w": 6, "h": 8 },
        "transparent": true,
        "fieldConfig": {
            "defaults": { "color": { "mode": "fixed", "fixedColor": "#d7191c" } }
        },
        "targets": [{
          "datasource": { "type": "postgres", "uid": "${DS_UID}" },
          "rawSql": "SELECT DISTINCT ON (pod)\n  pod AS \"Pod\",\n  fecha AS \"Fecha\"\nFROM incidentes\nWHERE estado = 'En cuarentena'\nORDER BY pod, fecha DESC\nLIMIT 5",
          "format": "table",
          "refId": "A"
        }]
      },
      {
        "id": 8,
        "type": "table",
        "title": "Registro de Incidentes",
        "gridPos": { "x": 0, "y": 16, "w": 24, "h": 10 },
        "transparent": true,
        "targets": [{
          "datasource": { "type": "postgres", "uid": "${DS_UID}" },
          "rawSql": "SELECT\n  id AS \"ID\",\n  fecha AS \"Fecha\",\n  regla AS \"Regla\",\n  pod AS \"Pod\",\n  estado AS \"Estado\"\nFROM incidentes\nORDER BY id DESC\nLIMIT 100",
          "format": "table",
          "refId": "A"
        }]
      }
    ]
  },
  "overwrite": true
}
EOF
)

# ── Ejecutar Importación ─────────────────────────────────────
echo "[►] Enviando a Grafana..."

response=$(curl -s \
    -X POST \
    -H "Authorization: Basic $B64" \
    -H "Content-Type: application/json" \
    -d "$dashboard_json" \
    "$GRAFANA_URL/api/dashboards/db")

status=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
url=$(echo "$response"    | python3 -c "import sys,json; print(json.load(sys.stdin).get('url',''))"    2>/dev/null)

if [ "$status" = "success" ]; then
    echo ""
    echo "    [✓] Dashboard SOC ready."
    echo "    URL: ${GRAFANA_URL}${url}"
    # Intentar abrir en el navegador (equivalente a Start-Process)
    xdg-open "${GRAFANA_URL}${url}" 2>/dev/null || \
    open     "${GRAFANA_URL}${url}" 2>/dev/null || true
else
    err=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message', d))" 2>/dev/null)
    echo "[✗] Error en la API: $err"
fi
