"""
inmune-agente.py - La Red Inmune
Diego Bermudo
"""

import json
import os
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from http.server import BaseHTTPRequestHandler, HTTPServer

import boto3
import psycopg2

# =========================================================
# CONFIGURACIÓN
# =========================================================

CUARENTENA_NS = 'inmune-cuarentena'
PRODUCTION_NS = 'default'
PORT          = 8080

# Solo estas reglas disparan acción
REGLAS_CRITICAS = {
    'Terminal shell in container',
    'Read sensitive file untrusted',
    'Netcat Remote Code Execution in Container',
    'Create Symlink Over Sensitive Files',
    'Search Private Keys or Passwords',
}

# Estas reglas se descartan en silencio — sin log, sin DB, sin cuarentena
REGLAS_IGNORADAS = {
    'Contact K8S API Server From Container',
}

EXCLUIDOS_NS  = {'kube-system', 'falco', 'monitoring'}
EXCLUIDOS_POD = {'inmune-agente'}

PG_DSN  = ''
SNS_ARN = ''

# Lock para evitar procesar el mismo pod dos veces en paralelo
_pods_en_proceso: set = set()
_lock_pods = threading.Lock()

# =========================================================
# LOGGING — solo lo que importa
# =========================================================

R  = '\033[0m'
B  = '\033[1m'
DM = '\033[2m'
RJ = '\033[91m'
AM = '\033[93m'
VD = '\033[92m'
AZ = '\033[94m'
MG = '\033[95m'
LN = '─' * 60

def _ts():
    return datetime.now(ZoneInfo('Europe/Madrid')).strftime('%H:%M:%S')

def log_ataque(regla, pod, ns):
    print(
        f'\n{LN}\n'
        f'{B}{RJ}  ATAQUE DETECTADO{R}\n'
        f'  {DM}Hora   {R}{_ts()}\n'
        f'  {DM}Regla  {R}{B}{regla}{R}\n'
        f'  {DM}Pod    {R}{pod}\n'
        f'  {DM}NS     {R}{ns}',
        flush=True
    )

def log_accion(msg):
    print(f'  {AM}▶ {msg}{R}', flush=True)

def log_ok(msg):
    print(f'  {VD}✔ {msg}{R}\n{LN}', flush=True)

def log_error(origen, msg):
    print(f'  {MG}✘ [{origen}] {msg}{R}', flush=True)

def log_info(msg):
    print(f'{DM}[{_ts()}] {msg}{R}', flush=True)

# =========================================================
# AWS SECRETS
# =========================================================

def leer_secreto(nombre):
    cliente = boto3.client('secretsmanager', region_name='us-east-1')
    secreto = cliente.get_secret_value(SecretId=nombre)
    return json.loads(secreto['SecretString'])

# =========================================================
# BASE DE DATOS
# =========================================================

def guardar_incidente(regla, pod, ns, detalles, estado):
    try:
        with psycopg2.connect(PG_DSN) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    'INSERT INTO incidentes '
                    '(regla, pod, namespace, detalles, estado) '
                    'VALUES (%s,%s,%s,%s,%s)',
                    (regla, pod, ns, detalles[:4000], estado)
                )
    except Exception as e:
        log_error('DB', str(e))

# =========================================================
# SNS
# =========================================================

def enviar_email(regla, pod, ns, estado):
    if not SNS_ARN:
        return
    try:
        boto3.client('sns', region_name='us-east-1').publish(
            TopicArn=SNS_ARN,
            Subject=f'[Red Inmune] {estado}: {regla[:60]}',
            Message=(
                f'Regla: {regla}\n'
                f'Pod: {pod}\n'
                f'Namespace: {ns}\n'
                f'Estado: {estado}\n'
                f'Fecha: {datetime.utcnow().isoformat()}'
            )
        )
    except Exception as e:
        log_error('SNS', str(e))

# =========================================================
# KUBECTL
# =========================================================

def kubectl(args):
    try:
        r = subprocess.run(
            ['kubectl'] + args,
            capture_output=True,
            text=True,
            timeout=30
        )
        return r.returncode == 0, r.stdout.strip()
    except Exception as e:
        log_error('KUBECTL', str(e))
        return False, ''

# =========================================================
# RESPUESTA AUTOMÁTICA
# =========================================================

def responder(datos):
    try:
        regla   = datos.get('rule', 'desconocida')
        campos  = datos.get('output_fields') or {}
        pod     = (campos.get('k8s.pod.name') or 'unknown').strip('"')
        ns      = (campos.get('k8s.ns.name')  or PRODUCTION_NS).strip('"')
        detalle = datos.get('output', '')

        # ── Filtros tempranos — silencio total ─────────────
        if regla in REGLAS_IGNORADAS:
            return
        if ns in EXCLUIDOS_NS or any(e in pod for e in EXCLUIDOS_POD):
            return
        if regla not in REGLAS_CRITICAS:
            return
        if pod == 'unknown':
            return

        # ── Deduplicación en memoria ───────────────────────
        # Evita doble procesamiento cuando Falco envía dos alertas
        # críticas distintas del mismo pod casi a la vez
        with _lock_pods:
            if pod in _pods_en_proceso:
                return
            _pods_en_proceso.add(pod)

        try:
            # ── Verificar cuarentena en cluster ───────────
            ok, label = kubectl([
                'get', 'pod', pod, '-n', ns,
                '-o', 'jsonpath={.metadata.labels.cuarentena}'
            ])
            if ok and label == 'true':
                return

            # ── Log de ataque ──────────────────────────────
            log_ataque(regla, pod, ns)

            # ── Aislamiento ────────────────────────────────
            log_accion(f'Aislando {pod}...')
            kubectl(['label', 'pod', pod, 'app-', 'tier-', '-n', ns, '--overwrite'])
            kubectl(['label', 'pod', pod, 'cuarentena=true', '-n', ns, '--overwrite'])

            # ── Clon forense ───────────────────────────────
            log_accion('Clonando pod para análisis forense...')
            ok, manifiesto = kubectl(['get', 'pod', pod, '-n', ns, '-o', 'json'])
            if ok:
                datos_pod = json.loads(manifiesto)
                meta      = datos_pod['metadata']

                for campo in (
                    'resourceVersion', 'uid', 'creationTimestamp',
                    'managedFields', 'ownerReferences', 'selfLink',
                    'finalizers', 'generation'
                ):
                    meta.pop(campo, None)

                datos_pod.pop('status', None)
                datos_pod['spec'].pop('nodeName', None)

                meta['namespace'] = CUARENTENA_NS
                meta['name']      = pod[:40] + '-cuarentena'
                meta['labels']    = {'cuarentena': 'true', 'origen': pod[:30]}

                with tempfile.NamedTemporaryFile(
                    mode='w', suffix='.json', delete=False, dir='/tmp'
                ) as f:
                    json.dump(datos_pod, f)
                    tmp = f.name

                kubectl(['apply', '-f', tmp, '-n', CUARENTENA_NS])
                os.unlink(tmp)

            # ── Persistencia y notificación ────────────────
            guardar_incidente(regla, pod, ns, detalle, 'En cuarentena')
            enviar_email(regla, pod, ns, 'En cuarentena')

            log_ok(f'Pod {pod} aislado · Notificación enviada')

        finally:
            # Liberar tras 10s para permitir re-alertas legítimas futuras
            def _liberar():
                time.sleep(10)
                with _lock_pods:
                    _pods_en_proceso.discard(pod)
            threading.Thread(target=_liberar, daemon=True).start()

    except Exception as e:
        log_error('RESPONDER', str(e))

# =========================================================
# HTTP SERVER
# =========================================================

class ManejadorAlertas(BaseHTTPRequestHandler):

    def log_message(self, *args):
        pass  # Sin logs HTTP

    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != '/alert':
            self.send_response(404)
            self.end_headers()
            return
        try:
            length  = int(self.headers.get('Content-Length', 0))
            raw     = self.rfile.read(length).decode('utf-8').strip()

            if not raw:
                self.send_response(400)
                self.end_headers()
                return

            payload = json.loads(raw.split('\n')[0])

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

            threading.Thread(
                target=responder,
                args=(payload,),
                daemon=True
            ).start()

        except Exception as e:
            log_error('HTTP', str(e))
            self.send_response(500)
            self.end_headers()

# =========================================================
# MAIN
# =========================================================

if __name__ == '__main__':

    print(
        f'\n{B}{"━" * 60}{R}\n'
        f'{B}  RED INMUNE · Agente de Respuesta Automática{R}\n'
        f'{"━" * 60}',
        flush=True
    )

    log_info('Cargando secretos AWS...')
    try:
        secretos_db  = leer_secreto('inmune/postgres')
        secretos_sns = leer_secreto('inmune/sns')
        PG_DSN  = secretos_db['dsn']
        SNS_ARN = secretos_sns['topic_arn']
        log_info('Secretos cargados.')
    except Exception as e:
        log_error('FATAL', f'Error AWS: {e}')
        exit(1)

    log_info('Verificando base de datos...')
    conectado = False
    for i in range(5):
        try:
            psycopg2.connect(PG_DSN).close()
            conectado = True
            log_info('Base de datos OK.')
            break
        except Exception:
            log_info(f'Reintentando ({i + 1}/5)...')
            time.sleep(5)

    if not conectado:
        log_error('FATAL', 'No se pudo conectar a RDS.')
        exit(1)

    print(
        f'\n{B}{"━" * 60}{R}\n'
        f'  Escuchando en :{PORT} · Esperando alertas de Falco\n'
        f'{"━" * 60}\n',
        flush=True
    )

    HTTPServer.allow_reuse_address = True
    HTTPServer(('0.0.0.0', PORT), ManejadorAlertas).serve_forever()
