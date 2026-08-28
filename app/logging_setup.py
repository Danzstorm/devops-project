"""Logs estructurados en JSON a stdout.

12-factor, factor XI: **la app no gestiona sus logs**. No abre archivos, no los
rota, no los comprime. Escribe a stdout y se desentiende. Recoger, agregar y
almacenar es trabajo de la plataforma (Docker, Kubernetes, Loki).

El motivo es concreto: dentro de un contenedor, un archivo de log vive en un
sistema de ficheros efimero. Cuando el pod muere -- y los pods mueren
constantemente, es normal -- el archivo se va con el. Justo el log que
necesitabas para entender por que murio.

JSON y no texto plano porque quien lo lee es una maquina. Poder filtrar por
`level` o por `slug` sin escribir expresiones regulares es la diferencia entre
buscar y adivinar.
"""

import json
import logging
import sys

# Atributos que trae de serie cualquier LogRecord. Todo lo que NO este aqui es
# un extra={...} que puso el codigo llamante, y queremos que llegue al JSON.
# `color_message` lo mete uvicorn: es el mismo mensaje con codigos ANSI de color
# dentro. En una terminal se ve bonito; en un JSON destinado a un agregador es
# basura duplicada.
_BUILTIN = frozenset(vars(logging.LogRecord("", 0, "", 0, "", (), None))) | {
    "taskName",
    "color_message",
}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        payload.update({k: v for k, v in record.__dict__.items() if k not in _BUILTIN})
        return json.dumps(payload, ensure_ascii=False, default=str)


def setup_logging(level: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level.upper())

    # uvicorn instala sus propios handlers con formato de texto de colores.
    # Se los quitamos: si no, la mitad de los logs sale en JSON y la otra mitad
    # en texto, y el agregador solo entiende una de las dos.
    for name in ("uvicorn", "uvicorn.access", "uvicorn.error"):
        logger = logging.getLogger(name)
        logger.handlers = []
        logger.propagate = True
