# License AGPL-3.0 or later (http://www.gnu.org/licenses/agpl.html)
"""Per-tenant addon entitlement enforcement (pooled multi-tenancy).

The pooled image carries the FULL sellable catalog under /mnt/custom-shared/
(one directory per catalog repo, cloned by scripts/prepare_addons.py). Which
of those a tenant may see and install is decided at runtime from the
ODOO_ENTITLEMENTS env var — a JSON map {database: [catalog dirs]} rendered by
terraform/shared from each client's addon_repos in clients.yaml. Selling an
addon is therefore a clients.yaml edit + shared apply (service revision roll),
never an image rebuild.

Enforcement model:
- Trust boundary = the operator context, NOT "is a request bound". The
  provisioning/migration Cloud Run Jobs are the only legitimate install path;
  they set ODOO_ENTITLEMENT_BYPASS=1 (cloud-run-job module) and are exempt.
  Everything else enforces — including tenant ir.cron scheduled actions, which
  run on the shared cron-runner with NO HTTP request bound. Keying off the
  request (as an earlier version did) let a tenant admin create a state=code
  cron and install anything the gate should block; env is not tenant-settable,
  so ODOO_ENTITLEMENT_BYPASS is the correct boundary and its absence fails
  closed (enforce).
- Visibility: uninstalled modules from unentitled catalog dirs are filtered
  out of every search (Apps list, RPC). Installed modules are ALWAYS visible,
  whatever the map says, so an entitlement mistake can never brick a tenant.
  (Visibility is a UX convenience scoped to interactive requests; the hard
  gates below are the actual security control.)
- Hard gate: install/upgrade, module-state writes, and self-uninstall are
  refused for blocked modules in EVERY non-operator context — no sudo exemption
  (server/automated actions run sudo'd) and no interactive-only exemption
  (cron runs without a request).
- base_import_module is blocklisted outright (module-zip sideloading =
  arbitrary code execution on the shared workers).
- This module refuses its own uninstall.
- A daily cron logs ENTITLEMENT_VIOLATION for installed-but-unentitled
  modules; terraform/shared/monitoring.tf turns that into an alert.

Odoo private API touched (re-validate on every major upgrade — the whole
18→19 checklist for entitlements is this one file):
  ir.module.module._search, button_install, button_immediate_install,
  _button_immediate_function, button_uninstall, write
"""

import json
import logging
import os

from odoo import _, api, models
from odoo.exceptions import UserError
from odoo.http import request
from odoo.osv import expression

_logger = logging.getLogger(__name__)

CUSTOM_SHARED_DIR = "/mnt/custom-shared"
# Catalog dirs every tenant is entitled to regardless of plan
ALWAYS_ENTITLED_DIRS = frozenset({"common"})
# Modules no tenant may ever see or install, wherever they live
PLATFORM_BLOCKLIST = frozenset({"base_import_module"})

# Image contents are immutable per process — cache the catalog scan once and
# the per-database blocked set per dbname (env never changes within a revision).
_catalog_cache = None
_blocked_cache = {}         # dbname -> frozenset(blocked module names)
_blocked_sorted_cache = {}  # dbname -> tuple(sorted blocked names), for domains


def _catalog():
    """{catalog dir: frozenset(module names)} from /mnt/custom-shared/."""
    global _catalog_cache
    if _catalog_cache is None:
        catalog = {}
        if os.path.isdir(CUSTOM_SHARED_DIR):
            for slug in os.listdir(CUSTOM_SHARED_DIR):
                repo_dir = os.path.join(CUSTOM_SHARED_DIR, slug)
                if not os.path.isdir(repo_dir):
                    continue
                catalog[slug] = frozenset(
                    mod for mod in os.listdir(repo_dir)
                    if os.path.isfile(os.path.join(repo_dir, mod, "__manifest__.py"))
                )
        _catalog_cache = catalog
    return _catalog_cache


def _always_entitled_module_names():
    """Module names shipped in an always-entitled dir (e.g. `common`)."""
    names = set()
    for slug in ALWAYS_ENTITLED_DIRS:
        names |= _catalog().get(slug, frozenset())
    return names


def _blocked_for(dbname):
    """Module names hidden/blocked for this database (fail-closed)."""
    blocked = _blocked_cache.get(dbname)
    if blocked is None:
        try:
            entitlements = json.loads(os.environ.get("ODOO_ENTITLEMENTS") or "{}")
        except ValueError:
            _logger.error("ODOO_ENTITLEMENTS is not valid JSON — failing closed")
            entitlements = {}
        if not isinstance(entitlements, dict):
            # A valid JSON scalar/list would otherwise make .get() raise
            # AttributeError and crash every module search — fail closed instead.
            _logger.error("ODOO_ENTITLEMENTS is not a JSON object — failing closed")
            entitlements = {}
        entitled_dirs = set(entitlements.get(dbname) or []) | ALWAYS_ENTITLED_DIRS
        restricted, allowed = set(), set()
        for slug, mods in _catalog().items():
            if slug in ALWAYS_ENTITLED_DIRS:
                continue
            restricted |= mods
            if slug in entitled_dirs:
                allowed |= mods
        # A module that ALSO ships in an always-entitled dir is entitled by that
        # copy even if a restricted dir happens to reuse the same technical name.
        allowed |= _always_entitled_module_names()
        blocked = frozenset((restricted - allowed) | PLATFORM_BLOCKLIST)
        _blocked_cache[dbname] = blocked
        _blocked_sorted_cache[dbname] = tuple(sorted(blocked))
    return blocked


def _blocked_sorted(dbname):
    """Sorted tuple of blocked names (memoized alongside _blocked_for)."""
    _blocked_for(dbname)
    return _blocked_sorted_cache[dbname]


def _raise_not_entitled(offenders):
    raise UserError(_(
        "The following apps are not included in your subscription: %s. "
        "Please contact your platform administrator to enable them.",
        ", ".join(offenders),
    ))


def _operator_context():
    """True ONLY in the operator-run provisioning/migration Cloud Run Jobs.

    The trust boundary for the hard install/upgrade/uninstall gates. Those Jobs
    (cloud-run-job module) set ODOO_ENTITLEMENT_BYPASS=1 and are the sole
    legitimate module-install path; the three long-running services never set
    it. Crucially this does NOT key off "no HTTP request bound" — an ir.cron
    scheduled action a tenant admin creates also runs without a request (on the
    shared cron-runner), so a request-based check would let a tenant bypass
    every gate. Tenants cannot set container env, so this is trusted; absence
    means enforce (fail closed).
    """
    return os.environ.get("ODOO_ENTITLEMENT_BYPASS") == "1"


def _interactive():
    """True on HTTP/RPC paths. Used ONLY to scope the visibility filter (a UX
    convenience, not a security control); the hard gates use
    _operator_context() instead."""
    return bool(request)


class IrModuleModule(models.Model):
    _inherit = "ir.module.module"

    @api.model
    def _entitlement_blocked_names(self):
        return _blocked_for(self.env.cr.dbname)

    def _entitlement_offenders(self, records):
        """Blocked module names within `records` (sorted)."""
        blocked = self._entitlement_blocked_names()
        return sorted(m.name for m in records if m.name in blocked)

    # ── Visibility ───────────────────────────────────────────────────────────
    @api.model
    def _search(self, domain, *args, **kwargs):
        # Hide unentitled catalog modules from interactive, non-sudo searches.
        # env.su is exempt so Odoo's own machinery (dependency resolution,
        # upgrade flows) always sees the full picture; the hard gates below do
        # NOT share that exemption. Installed modules stay visible so a bad
        # entitlement map degrades to "cannot install", never "app vanished".
        if _interactive() and not self.env.su:
            blocked = _blocked_sorted(self.env.cr.dbname)
            if blocked:
                domain = expression.AND([
                    domain,
                    ["|",
                     ("name", "not in", list(blocked)),
                     ("state", "not in", ("uninstalled", "uninstallable"))],
                ])
        return super()._search(domain, *args, **kwargs)

    # ── Module discovery (Update Apps List) ─────────────────────────────────
    def update_list(self):
        # update_list() scans addons_path and inserts a state='uninstalled'
        # row for anything not yet known, deciding "already known?" via this
        # very model's _search(). The visibility filter above hides
        # blocked+uninstalled modules from non-sudo interactive searches —
        # without this override, update_list() can't see a blocked module's
        # existing row and repeatedly tries to re-insert it, hitting
        # ir_module_module_name_uniq on every "Update Apps List" click (the
        # full catalog is scanned into every tenant's addons_path regardless
        # of entitlement). Run sudo'd, like the other internal-machinery
        # exemptions in this file, so discovery always sees the full
        # picture; interactive browsing still goes through the non-sudo path
        # above and stays filtered.
        return super(IrModuleModule, self.sudo()).update_list()

    # ── Hard install/upgrade gate ────────────────────────────────────────────
    # Enforced in EVERY context except the operator CLI Jobs — no sudo exemption
    # and, deliberately, no "interactive only" exemption: tenant ir.cron code
    # runs without a request and must still be gated.
    def _entitlement_check_install(self):
        if _operator_context():
            return
        blocked = self._entitlement_blocked_names()
        if not blocked:
            return
        # sudo: the closure must include dependencies our own filter hides
        closure = seen = self.sudo()
        while closure:
            dep_names = closure.mapped("dependencies_id.name")
            closure = self.sudo().search([("name", "in", dep_names)]) - seen
            seen |= closure
        offenders = sorted(m.name for m in seen if m.name in blocked)
        if offenders:
            _raise_not_entitled(offenders)

    def button_install(self):
        self._entitlement_check_install()
        return super().button_install()

    def button_immediate_install(self):
        self._entitlement_check_install()
        return super().button_immediate_install()

    def _button_immediate_function(self, function):
        # Belt-and-suspenders funnel for immediate UI/RPC module operations.
        # NOT the sole gate for anything: direct install goes through
        # button_install/button_immediate_install above, and every install or
        # upgrade must flip `state`, which write() gates — so a core rename that
        # slips past this __name__ match still cannot complete an install.
        if getattr(function, "__name__", "") in ("button_install", "button_upgrade"):
            self._entitlement_check_install()
        return super()._button_immediate_function(function)

    def button_uninstall(self):
        # The gate must not be removable by the gated (covers the immediate
        # path too: button_immediate_uninstall funnels through here). Only the
        # operator Jobs may uninstall it (e.g. deliberate offboarding).
        if not _operator_context() and "addon_entitlement" in self.mapped("name"):
            raise UserError(_(
                "The platform entitlement module cannot be uninstalled."
            ))
        return super().button_uninstall()

    @api.model_create_multi
    def create(self, vals_list):
        # Sibling of the write() smuggle-route guard: creating a module record
        # already in an installing state (a sudo'd tenant ir.cron could try) is
        # gated the same way. update_list() creates records in state
        # 'uninstalled', which is not gated, so normal discovery is unaffected.
        if not _operator_context():
            blocked = _blocked_for(self.env.cr.dbname)
            offenders = sorted(
                vals["name"] for vals in vals_list
                if vals.get("state") in ("to install", "to upgrade", "installed")
                and vals.get("name") in blocked
            )
            if offenders:
                _raise_not_entitled(offenders)
        return super().create(vals_list)

    def write(self, vals):
        # Close the smuggle route: flipping state to 'to install'/'to upgrade'
        # (e.g. from a tenant ir.cron) would get a blocked module processed by
        # the next fleet migration. Gated everywhere but the operator Jobs.
        if (
            not _operator_context()
            and vals.get("state") in ("to install", "to upgrade", "installed")
        ):
            offenders = self._entitlement_offenders(self)
            if offenders:
                _raise_not_entitled(offenders)
        return super().write(vals)

    # ── Detection (daily cron — see data/ir_cron.xml) ────────────────────────
    @api.model
    def _entitlement_audit(self):
        """Log installed-but-unentitled modules; monitoring alerts on the tag."""
        if not self._entitlement_blocked_names():
            return True
        installed = self.sudo().search(
            [("state", "not in", ("uninstalled", "uninstallable"))]
        )
        offenders = self._entitlement_offenders(installed)
        if offenders:
            _logger.warning(
                "ENTITLEMENT_VIOLATION db=%s modules=%s",
                self.env.cr.dbname, ",".join(offenders),
            )
        return True
