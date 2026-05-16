# ============================================================
#  Crear-Dashboard-SOC.ps1
#  Crea el dashboard SOC completo en Grafana via API REST
#  Requisito: kubectl port-forward svc/grafana-svc 3000:3000
# ============================================================

$GRAFANA_URL  = "http://YOUR_GRAFANA_LB_URL" #SVC-GRAFANA
$GRAFANA_USER = "admin"
$GRAFANA_PASS = "YOUR_GRAFANA_PASSWORD"
$DS_NAME      = "grafana-postgresql-datasource"   # Nombre exacto del datasource

# ── Auth header ─────────────────────────────────────────────
$bytes   = [System.Text.Encoding]::ASCII.GetBytes("${GRAFANA_USER}:${GRAFANA_PASS}")
$b64     = [Convert]::ToBase64String($bytes)
$headers = @{ Authorization = "Basic $b64"; "Content-Type" = "application/json" }

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║    La Red Inmune · Importing SOC Dashboard          ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── Verificar conexión ──────────────────────────────────────
try {
    $health = Invoke-RestMethod -Uri "$GRAFANA_URL/api/health" -Headers $headers -Method GET
    Write-Host "`n[✓] Grafana conectado (v$($health.version))" -ForegroundColor Green
} catch {
    Write-Host "`n[✗] Error: No se detecta Grafana en $GRAFANA_URL" -ForegroundColor Red
    exit 1
}

# ── Obtener UID del datasource ───────────────────────────────
$datasources = Invoke-RestMethod -Uri "$GRAFANA_URL/api/datasources" -Headers $headers -Method GET
$ds = $datasources | Where-Object { $_.name -eq $DS_NAME }
if (-not $ds) {
    Write-Host "[✗] Datasource '$DS_NAME' no encontrado." -ForegroundColor Red
    exit 1
}
$DS_UID = $ds.uid

# ── JSON del dashboard ───────────────────────────────────────
$dashboardJson = @"
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
          "datasource": { "type": "postgres", "uid": "$DS_UID" },
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
          "datasource": { "type": "postgres", "uid": "$DS_UID" },
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
          "datasource": { "type": "postgres", "uid": "$DS_UID" },
          "rawSql": "SELECT\n  date_trunc('hour', fecha) AS \"time\",\n  COUNT(*) AS \"Incidentes\"\nFROM incidentes\nWHERE `$__timeFilter(fecha)\nGROUP BY 1\nORDER BY 1",
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
          "datasource": { "type": "postgres", "uid": "$DS_UID" },
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
          "datasource": { "type": "postgres", "uid": "$DS_UID" },
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
          "datasource": { "type": "postgres", "uid": "$DS_UID" },
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
          "datasource": { "type": "postgres", "uid": "$DS_UID" },
          "rawSql": "SELECT\n  id AS \"ID\",\n  fecha AS \"Fecha\",\n  regla AS \"Regla\",\n  pod AS \"Pod\",\n  estado AS \"Estado\"\nFROM incidentes\nORDER BY id DESC\nLIMIT 100",
          "format": "table",
          "refId": "A"
        }]
      }
    ]
  },
  "overwrite": true
}
"@

# ── Ejecutar Importación ─────────────────────────────────────
Write-Host "[►] Enviando a Grafana..." -ForegroundColor Cyan
try {
    $response = Invoke-RestMethod -Uri "$GRAFANA_URL/api/dashboards/db" -Headers $headers -Method POST -Body $dashboardJson
    if ($response.status -eq "success") {
        Write-Host "`n    [✓] Dashboard SOC ready." -ForegroundColor Green
        Write-Host "    URL: $GRAFANA_URL$($response.url)" -ForegroundColor Yellow
        Start-Process "$GRAFANA_URL$($response.url)" 2>$null
    }
} catch {
    Write-Host "[✗] Error en la API: $($_.Exception.Message)" -ForegroundColor Red
}
