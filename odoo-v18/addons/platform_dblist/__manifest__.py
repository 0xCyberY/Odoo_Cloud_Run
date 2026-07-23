# License AGPL-3.0 or later (http://www.gnu.org/licenses/agpl.html)
{
    "name": "Platform Database List (env-driven)",
    "summary": "Serve the tenant database list from ODOO_DATABASES instead of "
    "pg_database ownership (required for pooled multi-tenancy with "
    "least-privilege per-tenant DB owners). Load server-wide.",
    "version": "18.0.1.0.0",
    "author": "Nomowsoft",
    "website": "https://github.com/0xCyberY",
    "license": "AGPL-3",
    "category": "Technical",
    "depends": ["base"],
    "installable": True,
}
