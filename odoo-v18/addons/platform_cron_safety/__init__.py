# License AGPL-3.0 or later (http://www.gnu.org/licenses/agpl.html)
"""Thread-safety patch for Odoo's cron dispatch loop (server-wide module).

odoo.service.server.ThreadedServer.cron_thread reaches into
Registry.registries.d (the raw internal OrderedDict of the process-wide LRU
registry cache) and iterates it directly:

    for db_name, registry in registries.d.items():

Registry.registries is an LRU whose own accessor methods (__getitem__,
__setitem__, ...) ARE lock-guarded (odoo/tools/lru.py wraps them with a
@locked decorator around self._lock) -- but this direct `.d.items()` access
bypasses that lock entirely. Any concurrent registry load/eviction on
another thread (which DOES go through the locked LRU.__setitem__/
__delitem__) mutates `.d` mid-iteration here and raises "RuntimeError:
OrderedDict mutated during iteration". ThreadedServer.cron_thread has no
surrounding try/except around this, so an uncaught RuntimeError doesn't just
log a warning -- it kills that cron thread permanently (its `while True:`
loop never gets a chance to retry), silently shrinking this container's
cron capacity over time until a restart.

This surfaces specifically on the shared Cron Runner (entrypoint.sh
ODOO_MODE=cron), which runs cron threads for EVERY tenant database in one
process (v2 Fix #8) -- multiple concurrent cron threads polling different
tenant registries is exactly the condition that triggers it. A single-
tenant Odoo deployment would rarely hit this.

Fix: monkeypatch cron_thread with an otherwise-identical copy that takes a
lock-guarded snapshot of the registries dict (registries._lock is the same
RLock the LRU's own @locked methods use) before iterating, instead of
iterating the live dict directly. A registry evicted immediately after the
snapshot is caught by the existing per-db try/except; one added immediately
after is simply picked up on the next SLEEP_INTERVAL poll -- both harmless,
unlike the crash.

Odoo private API touched (re-validate on every major upgrade -- diff this
file's _patched_cron_thread body against odoo/service/server.py's
ThreadedServer.cron_thread on every Odoo version bump):
  odoo.service.server.ThreadedServer.cron_thread (full method body copied
  from Odoo 18.0's odoo/service/server.py; SLEEP_INTERVAL=60 there)
"""

import contextlib
import logging
import select
import threading
import time

import odoo
from odoo.service import server as odoo_server
from odoo.tools import config

_logger = logging.getLogger(__name__)

SLEEP_INTERVAL = odoo_server.SLEEP_INTERVAL


def _patched_cron_thread(self, number):
    from odoo.addons.base.models.ir_cron import ir_cron

    def _run_cron(cr):
        pg_conn = cr._cnx
        # LISTEN / NOTIFY doesn't work in recovery mode
        cr.execute("SELECT pg_is_in_recovery()")
        in_recovery = cr.fetchone()[0]
        if not in_recovery:
            cr.execute("LISTEN cron_trigger")
        else:
            _logger.warning("PG cluster in recovery mode, cron trigger not activated")
        cr.commit()
        alive_time = time.monotonic()
        while config['limit_time_worker_cron'] <= 0 or (time.monotonic() - alive_time) <= config['limit_time_worker_cron']:
            select.select([pg_conn], [], [], SLEEP_INTERVAL + number)
            time.sleep(number / 100)
            pg_conn.poll()

            registries = odoo.modules.registry.Registry.registries
            _logger.debug('cron%d polling for jobs', number)
            # Snapshot under the LRU's own lock instead of iterating the
            # live dict directly -- see module docstring.
            with registries._lock:
                items = list(registries.d.items())
            for db_name, registry in items:
                if registry.ready:
                    thread = threading.current_thread()
                    thread.start_time = time.time()
                    try:
                        ir_cron._process_jobs(db_name)
                    except Exception:
                        _logger.warning('cron%d encountered an Exception:', number, exc_info=True)
                    thread.start_time = None
    while True:
        conn = odoo.sql_db.db_connect('postgres')
        with contextlib.closing(conn.cursor()) as cr:
            _run_cron(cr)
            cr._cnx.close()
        _logger.info('cron%d max age (%ss) reached, releasing connection.', number, config['limit_time_worker_cron'])


odoo_server.ThreadedServer.cron_thread = _patched_cron_thread
_logger.info("platform_cron_safety: patched ThreadedServer.cron_thread for safe registries iteration")
