# License AGPL-3.0 or later (http://www.gnu.org/licenses/agpl.html)
{
    "name": "Addon Entitlement (per-tenant catalog gating)",
    "summary": "Hide and block catalog addons a tenant's plan does not include. "
    "Entitlements come from the ODOO_ENTITLEMENTS env var "
    "(db → catalog repo dirs, rendered by terraform/shared from "
    "clients.yaml); the full catalog stays baked in the shared image.",
    "version": "18.0.1.0.0",
    "author": "Nomowsoft",
    "website": "https://github.com/0xCyberY",
    "license": "AGPL-3",
    "category": "Technical",
    "depends": ["base"],
    "data": ["data/ir_cron.xml"],
    "installable": True,
}
