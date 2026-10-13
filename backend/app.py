import logging
import os

import psycopg
from flask import Flask, jsonify


app = Flask(__name__)


def database_time():
    required = ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD")
    missing = [name for name in required if not os.getenv(name)]
    if missing:
        raise RuntimeError("Faltan variables de base de datos: " + ", ".join(missing))

    with psycopg.connect(
        host=os.environ["DB_HOST"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        port=int(os.getenv("DB_PORT", "5432")),
        sslmode=os.getenv("DB_SSLMODE", "require"),
        connect_timeout=5,
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT CURRENT_TIMESTAMP")
            return cursor.fetchone()[0].isoformat()


@app.get("/live")
def live():
    return jsonify(status="ok", service="backend")


@app.get("/ready")
def ready():
    try:
        database_time()
    except Exception:
        logging.exception("No fue posible conectar con PostgreSQL")
        return jsonify(status="error", database="unavailable"), 503
    return jsonify(status="ok", database="connected")


@app.get("/saludo")
def saludo():
    try:
        timestamp = database_time()
    except Exception:
        logging.exception("No fue posible consultar PostgreSQL")
        return jsonify(error="No se pudo consultar la base de datos"), 503
    return jsonify(mensaje="Hola desde Azure", database_time=timestamp)
