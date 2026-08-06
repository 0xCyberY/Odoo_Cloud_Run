#!/usr/bin/env python3
"""
scripts/onboard_client.py

Single consolidated script for the automated client-onboarding flow, fired by
`repository_dispatch` (types: client-onboarding) against provision-client.yml.
Takes a signup payload from "request" to "admin creds ready for handover,
selected addons installed, DNS self-managed for platform subdomains" with no
manual infrastructure step:

  1. validate the payload (reuses validate_clients.py — R1-R10, plus a live
     DNS collision check for subdomain_slug clients)
  2. append the clients.yaml entry (raw-text append — preserves the file's
     hand-written schema comments, unlike a yaml.safe_load/dump round-trip)
  3. apply terraform/shared (tenant SQL user, pgbouncer map, cert domain —
     imports CloudRunProvisioner from provision.py as a class, reused in this
     one process rather than shelling out to a second script)
  4. self-manage DNS for subdomain_slug clients (A record + Certificate
     Manager dns_authorization CNAME via `gcloud dns`); surface both records
     for domain clients to add manually instead (unchanged from today's flow)
  5. apply the tenant Terraform workspace, run db-setup, then run the init
     job with a combined -i list: the fixed platform base
     (terraform/main.tf's cloud_run_init_job args) + DEFAULT_AUTO_INSTALL
     (addon_entitlement/models/ir_module.py) + this client's own
     selected_addons, resolved to real module technical names
  6. fetch the generated admin credentials from Secret Manager, mask the
     password (`::add-mask::`) and write both to $GITHUB_OUTPUT — this
     script does NOT send email itself; a subsequent step in
     provision-client.yml (dawidd6/action-send-mail@v3) does, reading these
     outputs, to the DevOps/Product distribution list — never the client.

Requires the Certificate Manager migration (Phase 1.5,
terraform/shared: var.enable_certificate_manager) to be applied before a
subdomain_slug client's DNS step can complete — until then, step 4 fails
with a clear error for subdomain_slug clients specifically; domain clients
are unaffected (they never depended on it).
"""

import argparse
import ast
import json
import os
import sys
import tempfile

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import prepare_addons  # noqa: E402
import validate_clients  # noqa: E402
from provision import (  # noqa: E402
    CloudRunProvisioner, log_info, log_success, log_warn, log_error, run_cmd,
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIENTS_YAML_PATH = os.path.join(REPO_ROOT, "clients", "clients.yaml")
IR_MODULE_PATH = os.path.join(
    REPO_ROOT, "odoo-v18", "addons", "addon_entitlement", "models", "ir_module.py"
)
# Mirrors terraform/main.tf's cloud_run_init_job args — the platform baseline
# every tenant gets regardless of plan. Keep both copies in sync if that
# changes (separate Terraform state, no cross-stack variable sharing, same
# constraint noted in terraform/shared/main.tf's server_env_config comment).
FIXED_BASE_MODULES = ["base", "web", "gcs_attachment_default", "addon_entitlement"]


def _extract_frozenset_constant(py_path, name):
    """Reads a top-level `NAME = frozenset({...})` constant from a .py file via
    ast, without importing it — ir_module.py does `from odoo import ...`,
    which isn't installed in this script's environment. ast.literal_eval alone
    can't evaluate a bare `frozenset(...)` call, so unwrap that one layer
    ourselves."""
    with open(py_path) as f:
        tree = ast.parse(f.read())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
            getattr(t, "id", None) == name for t in node.targets
        ):
            value = node.value
            if isinstance(value, ast.Call) and getattr(value.func, "id", None) in ("frozenset", "set"):
                if not value.args:
                    return set()
                return set(ast.literal_eval(value.args[0]))
            return set(ast.literal_eval(value))
    raise ValueError(f"Constant '{name}' not found in {py_path}")


class ClientOnboarder:
    def __init__(self, *, client_slug, domain=None, use_subdomain=False, contact_email=None,
                 addon_repos=None, selected_addons=None, region="europe-west1",
                 gcp_project=None, db_user=None, dry_run=False):
        self.client_slug = client_slug
        self.domain = domain or None
        # subdomain_slug is never a separately supplied value — a
        # platform-subdomain client's subdomain IS its client_slug
        # (newco-corp -> newco-corp.nomowsoft.com), so there's nothing to
        # collide or typo between the two.
        self.subdomain_slug = client_slug if use_subdomain else None
        self.contact_email = contact_email or None
        self.addon_repos = list(addon_repos or [])
        self.selected_addons = list(selected_addons or [])
        self.region = region
        self.gcp_project = gcp_project or os.environ.get("GCP_PROJECT")
        self.dry_run = dry_run
        self._config = None
        self._pre_write_raw = None

        if not self.gcp_project:
            raise ValueError("--gcp-project or GCP_PROJECT env var is required")
        if bool(self.domain) == bool(self.subdomain_slug):
            raise ValueError("Exactly one of --domain or --use-subdomain is required")

        self.database = self.subdomain_slug or self._first_label(self.domain)
        self.db_user = db_user or f"{self.client_slug.replace('-', '_')}_production"

    @staticmethod
    def _first_label(domain):
        host = domain[4:] if domain.startswith("www.") else domain
        return host.split(".")[0]

    # ── Step 1: validate ─────────────────────────────────────────────────────
    def _client_entry(self):
        entry = {
            "region": self.region,
            "database": self.database,
            "db_user": self.db_user,
            "gcp_project": self.gcp_project,
            "addon_repos": list(self.addon_repos),
        }
        if self.domain:
            entry["domain"] = self.domain
        else:
            entry["subdomain_slug"] = self.subdomain_slug
        if self.selected_addons:
            entry["selected_addons"] = list(self.selected_addons)
        if self.contact_email:
            entry["contact_email"] = self.contact_email
        return entry

    def validate_payload(self):
        log_info(f"--- Step 1: Validating onboarding payload for '{self.client_slug}' ---")
        with open(CLIENTS_YAML_PATH) as f:
            raw = f.read()
        config = yaml.safe_load(raw)

        if self.client_slug in (config.get("clients") or {}):
            raise ValueError(f"Client '{self.client_slug}' already exists in clients.yaml")

        catalog = config.get("catalog") or {}
        for entry in self.addon_repos:
            if entry not in catalog:
                raise ValueError(f"addon_repos entry '{entry}' is not a known catalog key (known: {sorted(catalog)})")

        # Re-validate the WHOLE file with the candidate entry merged in —
        # reuses every rule (R1-R10) instead of duplicating them here.
        candidate = dict(config)
        candidate["clients"] = dict(candidate.get("clients") or {})
        candidate["clients"][self.client_slug] = self._client_entry()
        errors = validate_clients.validate(candidate)
        if errors:
            raise ValueError("Onboarding payload rejected:\n  " + "\n  ".join(errors))

        if self.subdomain_slug and not self.dry_run:
            if not validate_clients.check_subdomain_dns(self.subdomain_slug):
                raise ValueError(
                    f"'{self.subdomain_slug}.{validate_clients.PLATFORM_APEX_DOMAIN}' already "
                    "resolves in DNS (stale/orphaned record?) — refusing to provision a "
                    "colliding subdomain before touching Terraform or DNS"
                )

        log_success("Payload valid — no collisions, no policy violations.")
        self._config = config
        return config, raw

    # ── Step 2: clients.yaml ─────────────────────────────────────────────────
    def _render_entry_block(self):
        lines = [f"  {self.client_slug}:"]
        if self.domain:
            lines.append(f"    domain:      {self.domain}")
        else:
            lines.append(f"    subdomain_slug: {self.subdomain_slug}")
        lines.append(f"    region:      {self.region}")
        lines.append(f"    database:    {self.database}")
        lines.append(f"    db_user:     {self.db_user}")
        lines.append(f"    gcp_project: {self.gcp_project}")
        addons = ", ".join(self.addon_repos)
        lines.append(f"    addon_repos: [{addons}]")
        if self.selected_addons:
            lines.append(f"    selected_addons: [{', '.join(self.selected_addons)}]")
        if self.contact_email:
            lines.append(f"    contact_email: '{self.contact_email}'")
        return "\n".join(lines) + "\n"

    def write_clients_yaml(self):
        log_info(f"--- Step 2: Adding '{self.client_slug}' to clients.yaml ---")
        with open(CLIENTS_YAML_PATH) as f:
            raw = f.read()
        new_raw = raw.rstrip("\n") + "\n\n" + self._render_entry_block()

        # Confirm the appended text is still valid YAML and passes every rule
        # before writing it to disk — a malformed append must never land.
        parsed = yaml.safe_load(new_raw)
        errors = validate_clients.validate(parsed, raw_text=new_raw)
        if errors:
            raise ValueError(
                "Generated clients.yaml entry failed validation post-append:\n  "
                + "\n  ".join(errors)
            )

        if self.dry_run:
            log_info(f"[DRY-RUN] Would append to clients.yaml:\n{self._render_entry_block()}")
            return
        # Recorded so a later-step failure (DNS, terraform, ...) can revert
        # this write — otherwise a retry hits "already exists" at step 1
        # forever, with no automatic way back to a clean state.
        self._pre_write_raw = raw
        with open(CLIENTS_YAML_PATH, "w") as f:
            f.write(new_raw)
        self._config = parsed
        log_success(f"clients.yaml updated with '{self.client_slug}'.")

    def _tfvars_path(self):
        return os.path.join(REPO_ROOT, "clients", f"{self.client_slug}.tfvars")

    def write_tfvars(self):
        """terraform/main.tf's tenant workspace apply requires
        clients/<slug>.tfvars (-var-file, provision.py's execute_terraform) —
        without this, the automated flow would apply cleanly against
        terraform/shared and then abort on the tenant apply for every single
        onboarding. Mirrors the format of the existing hand-written
        clients/*.tfvars files."""
        log_info(f"--- Step 3: Writing clients/{self.client_slug}.tfvars ---")
        image_url = f"{self.region}-docker.pkg.dev/{self.gcp_project}/odoo-v18-repo/odoo-pooled:latest"
        effective_domain = self.domain or f"{self.subdomain_slug}.{validate_clients.PLATFORM_APEX_DOMAIN}"
        lines = [
            f'gcp_project   = "{self.gcp_project}"',
            f'region        = "{self.region}"',
            f'client_slug   = "{self.client_slug}"',
            f'domain        = "{effective_domain}"',
            f'database_name = "{self.database}"',
            f'admin_user    = "admin@{self.client_slug}.com"',
            f'image_url     = "{image_url}"',
        ]
        if self.subdomain_slug:
            # terraform/main.tf's own google_dns_record_set.client_dns
            # (var.manage_dns) creates the A record — the ONLY DNS record
            # this script creates imperatively itself is the Certificate
            # Manager dns_authorization CNAME (handle_dns), which has no
            # terraform-managed equivalent yet.
            lines.append("manage_dns    = true")
            lines.append(f'dns_managed_zone = "{self._dns_zone()}"')
        content = "\n".join(lines) + "\n"

        if self.dry_run:
            log_info(f"[DRY-RUN] Would write clients/{self.client_slug}.tfvars:\n{content}")
            return
        with open(self._tfvars_path(), "w") as f:
            f.write(content)
        log_success(f"Wrote clients/{self.client_slug}.tfvars")

    def _rollback(self):
        """Best-effort cleanup after a failure downstream of write_clients_yaml/
        write_tfvars: revert clients.yaml to its pre-onboarding content and
        remove the tfvars file, so a retry starts clean instead of
        permanently failing validate_payload()'s 'already exists' check.
        Does NOT touch Terraform state — terraform/shared's apply (if it ran)
        is idempotent, so a retry's next apply reconciles it safely once the
        clients.yaml entry exists again."""
        pre_write_raw = getattr(self, "_pre_write_raw", None)
        if pre_write_raw is not None:
            with open(CLIENTS_YAML_PATH, "w") as f:
                f.write(pre_write_raw)
            log_warn(f"Rolled back clients.yaml entry for '{self.client_slug}' after a failure.")
        tfvars_path = self._tfvars_path()
        if os.path.exists(tfvars_path):
            os.remove(tfvars_path)
            log_warn(f"Removed clients/{self.client_slug}.tfvars after a failure.")

    # ── Step 4: DNS ──────────────────────────────────────────────────────────
    def _alb_ip(self):
        shared_dir = os.path.join(REPO_ROOT, "terraform", "shared")
        res = run_cmd(["terraform", "output", "-raw", "alb_ip"], cwd=shared_dir)
        return res.stdout.strip()

    def _read_dns_authorization_records(self):
        shared_dir = os.path.join(REPO_ROOT, "terraform", "shared")
        res = run_cmd(["terraform", "output", "-json", "dns_authorization_records"], cwd=shared_dir)
        return json.loads(res.stdout)

    def _dns_zone(self):
        zone = os.environ.get("PLATFORM_DNS_ZONE")
        if not zone:
            raise ValueError(
                "PLATFORM_DNS_ZONE env var is required to self-manage DNS for a "
                "subdomain_slug client — the Cloud DNS managed zone name for "
                "nomowsoft.com in this GCP project. See README's onboarding "
                "prerequisites (this zone + its registrar NS delegation is a "
                "one-time manual setup step, not something this script creates)."
            )
        return zone

    def handle_dns(self):
        log_info("--- Step 4: DNS ---")
        dns_auth_records = self._read_dns_authorization_records()
        auth = dns_auth_records.get(self.client_slug)

        if not self.subdomain_slug:
            alb_ip = self._alb_ip()
            log_info(f"'{self.domain}' is a client-owned domain — add these records "
                      "manually at the client's DNS registrar (unchanged from today's flow):")
            log_info(f"  A record:  {self.domain} -> {alb_ip}")
            if auth:
                log_info(f"  CNAME:     {auth['name']} -> {auth['data']} (cert activation proof)")
            else:
                log_warn("No dns_authorization output for this client yet — Certificate Manager "
                         "migration (Phase 1.5) may not be applied. The A record above still "
                         "routes traffic; HTTPS activation depends on that migration landing.")
            return

        if not auth:
            raise ValueError(
                f"No dns_authorization output for '{self.client_slug}' — the Certificate "
                "Manager migration (terraform/shared var.enable_certificate_manager) must be "
                "applied before a subdomain_slug client can be onboarded. Domain clients don't "
                "have this dependency; only self-managed platform subdomains do."
            )

        zone = self._dns_zone()
        fqdn = f"{self.subdomain_slug}.{validate_clients.PLATFORM_APEX_DOMAIN}"
        # The A record is NOT created here — write_tfvars() sets manage_dns=true
        # + dns_managed_zone, so terraform/main.tf's own google_dns_record_set
        # creates it as part of execute_terraform() below (state-tracked,
        # instead of an untracked imperative gcloud call that would also
        # collide with that resource on every re-apply). Only the Certificate
        # Manager dns_authorization CNAME has no terraform-managed equivalent,
        # so it's the one record this script creates itself.

        if self.dry_run:
            log_info(f"[DRY-RUN] Would create CNAME {auth['name']} -> {auth['data']} "
                      f"(A record for {fqdn} is terraform-managed, see write_tfvars)")
            return

        run_cmd([
            "gcloud", "dns", "record-sets", "create", auth["name"],
            f"--type={auth['type']}", "--ttl=300", f"--zone={zone}", f"--project={self.gcp_project}",
            f"--rrdatas={auth['data']}",
        ], capture_output=False)
        log_success(f"Cert CNAME self-managed for '{fqdn}' — no manual client step.")

    # ── Step 5: init job with combined -i list ──────────────────────────────
    def _resolve_selected_modules(self, tmp_dir):
        """Resolves each selected_addons catalog key to the Odoo module
        technical names it actually ships — mirrors ir_module.py's _catalog()
        scan (any subdir with __manifest__.py is a module) and
        prepare_addons.py's clone() convention."""
        if not self.selected_addons:
            return []
        token = os.environ.get("GITHUB_TOKEN", "")
        catalog = (self._config or {}).get("catalog") or {}
        modules = []
        for key in self.selected_addons:
            spec = catalog[key]
            dest = os.path.join(tmp_dir, key)
            prepare_addons.clone(spec["repo"], spec.get("branch", "18.0"), dest, token)
            for entry in sorted(os.listdir(dest)):
                if os.path.isfile(os.path.join(dest, entry, "__manifest__.py")):
                    modules.append(entry)
        return modules

    def _auto_install_list(self):
        default_auto_install = sorted(_extract_frozenset_constant(IR_MODULE_PATH, "DEFAULT_AUTO_INSTALL"))
        with tempfile.TemporaryDirectory() as tmp:
            selected_modules = self._resolve_selected_modules(tmp)
        return list(dict.fromkeys(FIXED_BASE_MODULES + default_auto_install + selected_modules))

    def run_init_job(self, provisioner):
        log_info("--- Step 5: Init job (combined -i list) ---")
        modules = self._auto_install_list()
        log_info(f"Auto-install list: {','.join(modules)}")
        if self.dry_run:
            log_info("[DRY-RUN] Would execute init job with the above -i list")
            return
        job_name = f"{self.client_slug}-odoo-job-init"
        run_cmd([
            "gcloud", "run", "jobs", "execute", job_name,
            f"--region={self.region}", f"--project={self.gcp_project}",
            f"--args=-d,{self.database},-i,{','.join(modules)},--without-demo=all,--stop-after-init",
            "--wait",
        ], capture_output=False)
        log_success("Init job completed with combined auto-install list.")
        # Re-run db-setup to sync real admin credentials (init leaves admin/admin).
        provisioner.run_db_setup_job()

    # ── Step 6: credentials ──────────────────────────────────────────────────
    def fetch_and_mask_credentials(self):
        log_info("--- Step 6: Fetching and masking admin credentials ---")
        if self.dry_run:
            log_info("[DRY-RUN] Would fetch and mask admin credentials")
            return
        user_res = run_cmd([
            "gcloud", "secrets", "versions", "access", "latest",
            f"--secret={self.client_slug}-admin-user", f"--project={self.gcp_project}",
        ])
        pass_res = run_cmd([
            "gcloud", "secrets", "versions", "access", "latest",
            f"--secret={self.client_slug}-admin-password", f"--project={self.gcp_project}",
        ])
        admin_user = user_res.stdout.strip()
        admin_password = pass_res.stdout.strip()

        # GitHub Actions workflow command: redacts this value from all
        # subsequent log output, even if a later step echoes it.
        print(f"::add-mask::{admin_password}")

        github_output = os.environ.get("GITHUB_OUTPUT")
        if github_output:
            with open(github_output, "a") as f:
                f.write(f"admin_user={admin_user}\n")
                f.write(f"admin_password={admin_password}\n")
        else:
            log_warn("GITHUB_OUTPUT not set (not running in Actions?) — credentials fetched "
                     "but not exposed as step outputs.")
        log_success("Credentials fetched and masked.")

    # ── Orchestration ────────────────────────────────────────────────────────
    def run(self):
        log_info(f"=== Onboarding '{self.client_slug}' ===")
        self.validate_payload()
        self.write_clients_yaml()
        self.write_tfvars()

        if self.dry_run:
            # Every step from here on (CloudRunProvisioner included) requires
            # the client to actually exist in clients.yaml on disk — which a
            # dry-run deliberately never writes. Validation + the entry/tfvars
            # preview above is the full extent of what a dry-run can safely
            # simulate for a client that doesn't exist yet.
            log_info("[DRY-RUN] Stopping here — Terraform/DNS/init-job/credential "
                      "steps all require the clients.yaml + tfvars writes above to be real.")
            return

        # Everything from here on can fail partway through (DNS prerequisite
        # missing, terraform error, ...) after the writes above already
        # landed and terraform/shared may already have applied. Roll the
        # clients.yaml/tfvars writes back on any failure so a retry starts
        # clean instead of permanently tripping validate_payload()'s
        # "already exists" check (see _rollback's docstring for what this
        # does and doesn't undo).
        try:
            provisioner = CloudRunProvisioner(self.client_slug, init_db=False, dry_run=self.dry_run)
            provisioner.execute_shared_terraform()

            self.handle_dns()

            provisioner.execute_terraform()
            provisioner.run_db_setup_job()
            self.run_init_job(provisioner)

            self.fetch_and_mask_credentials()
        except Exception:
            self._rollback()
            raise

        log_success(f"Onboarding complete for '{self.client_slug}'.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Onboard a new Odoo SaaS client end-to-end.")
    parser.add_argument("--client-slug", required=True)
    domain_group = parser.add_mutually_exclusive_group(required=True)
    domain_group.add_argument("--domain", help="Client-owned domain (manual CNAME step)")
    domain_group.add_argument(
        "--use-subdomain", action="store_true",
        help="Platform-issued '{client-slug}.nomowsoft.com' (self-managed DNS) — the "
             "subdomain is always the client slug itself, never a separate value",
    )
    parser.add_argument("--contact-email", default=None)
    parser.add_argument("--addon-repos", default="", help="Comma-separated catalog keys this client is entitled to")
    parser.add_argument("--selected-addons", default="", help="Comma-separated subset of --addon-repos to auto-install")
    parser.add_argument("--region", default="europe-west1")
    parser.add_argument("--gcp-project", default=os.environ.get("GCP_PROJECT"))
    parser.add_argument("--db-user", default=None)
    parser.add_argument("--dry-run", action="store_true")

    args = parser.parse_args()

    try:
        onboarder = ClientOnboarder(
            client_slug=args.client_slug,
            domain=args.domain,
            use_subdomain=args.use_subdomain,
            contact_email=args.contact_email,
            addon_repos=[a.strip() for a in args.addon_repos.split(",") if a.strip()],
            selected_addons=[a.strip() for a in args.selected_addons.split(",") if a.strip()],
            region=args.region,
            gcp_project=args.gcp_project,
            db_user=args.db_user,
            dry_run=args.dry_run,
        )
        onboarder.run()
    except Exception as e:
        log_error(f"Onboarding failed: {e}")
        sys.exit(1)
