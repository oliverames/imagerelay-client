from __future__ import annotations

import logging
from logging.handlers import RotatingFileHandler

from .appdirs import ensure_app_dirs, log_path


def configure_logging(verbose: bool = False) -> logging.Logger:
    ensure_app_dirs()

    logger = logging.getLogger("imagerelay_client")
    logger.setLevel(logging.DEBUG)

    if logger.handlers:
        if verbose:
            for handler in logger.handlers:
                handler.setLevel(logging.DEBUG)
        return logger

    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s [pid=%(process)d %(name)s] %(message)s",
        "%Y-%m-%d %H:%M:%S",
    )

    file_handler = RotatingFileHandler(log_path(), maxBytes=1_000_000, backupCount=3)
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(formatter)

    stream_handler = logging.StreamHandler()
    stream_handler.setLevel(logging.DEBUG if verbose else logging.INFO)
    stream_handler.setFormatter(formatter)

    logger.addHandler(file_handler)
    logger.addHandler(stream_handler)
    logger.propagate = False

    return logger
