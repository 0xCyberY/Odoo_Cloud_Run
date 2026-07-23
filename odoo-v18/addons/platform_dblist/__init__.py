import logging
import os

import odoo
from odoo.service import db as db_service

_logger = logging.getLogger(__name__)

_original_list_dbs = db_service.list_dbs


def _env_list_dbs(force=False):
    """Database discovery override for pooled multi-tenancy (v2 Fix #4).

    Core ``list_dbs()`` only returns databases OWNED by the connecting role.
    Our tenant databases are owned by per-tenant least-privilege users, so
    ownership-based discovery (as the platform user) returns nothing and every
    request falls through to the database selector. The tenant catalog is
    already known — clients.yaml renders it into the ODOO_DATABASES env var —
    so serve the list from there. Falls back to core behavior when unset.
    """
    dbs = os.environ.get("ODOO_DATABASES")
    if not dbs:
        return _original_list_dbs(force)
    if not odoo.tools.config["list_db"] and not force:
        raise odoo.exceptions.AccessDenied()
    return sorted(d.strip() for d in dbs.split(",") if d.strip())


db_service.list_dbs = _env_list_dbs
_logger.info("platform_dblist active: list_dbs() served from ODOO_DATABASES")
