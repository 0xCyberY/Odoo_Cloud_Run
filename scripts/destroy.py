#!/usr/bin/env python3
"""
scripts/destroy.py
Tears down a tenant's Terraform workspace (Cloud Run services/jobs, GCS
attachment bucket, per-domain cert resources once Phase 1.5 lands). Mirrors
CloudRunProvisioner in provision.py so CI and local share one implementation
instead of duplicating terraform steps inline in destroy-client.yml.

Does NOT drop the tenant database — README §13 offboarding step 3 documents
the separate DROP-as-odoo_shared procedure (tenant-owned databases can't be
dropped via the Cloud SQL API a workspace destroy uses).
"""

import os
import sys
import argparse
import subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import validate_clients  # noqa: E402

import yaml


class Colors:
    OKBLUE = '\033[94m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'


def log_info(msg):
    print(f"{Colors.OKBLUE}[INFO]{Colors.ENDC} {msg}")


def log_success(msg):
    print(f"{Colors.OKGREEN}[SUCCESS]{Colors.ENDC} {Colors.BOLD}{msg}{Colors.ENDC}")


def log_warn(msg):
    print(f"{Colors.WARNING}[WARN]{Colors.ENDC} {msg}")


def log_error(msg):
    print(f"{Colors.FAIL}[ERROR]{Colors.ENDC} {msg}", file=sys.stderr)


def run_cmd(args, capture_output=True, text=True, check=True, cwd=None):
    use_shell = os.name == 'nt'
    try:
        return subprocess.run(
            args, capture_output=capture_output, text=text,
            check=check, shell=use_shell, cwd=cwd,
        )
    except subprocess.CalledProcessError as e:
        log_error(f"Command {' '.join(args)} failed with exit code {e.returncode}")
        if e.stdout:
            print(f"Stdout:\n{e.stdout}", file=sys.stderr)
        if e.stderr:
            print(f"Stderr:\n{e.stderr}", file=sys.stderr)
        raise e


class CloudRunDestroyer:
    def __init__(self, client_name, dry_run=False):
        self.client_name = client_name
        self.dry_run = dry_run

        self.config_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "clients", "clients.yaml"
        )
        if not os.path.exists(self.config_path):
            raise FileNotFoundError(f"Configuration file not found at {self.config_path}")

        with open(self.config_path, 'r') as f:
            raw_config = f.read()
        self.full_config = yaml.safe_load(raw_config)

        errors = validate_clients.validate(self.full_config, raw_text=raw_config)
        if errors:
            raise ValueError("clients.yaml validation failed:\n  " + "\n  ".join(errors))

        if "clients" not in self.full_config or self.client_name not in self.full_config["clients"]:
            raise ValueError(f"Client '{self.client_name}' not defined in clients.yaml")

        self.client_config = self.full_config["clients"][self.client_name]
        if not self.client_config.get("gcp_project"):
            raise ValueError(f"Client '{self.client_name}' has no gcp_project set in clients.yaml")
        self.gcp_project = self.client_config["gcp_project"]
        self.tf_state_bucket = f"{self.gcp_project}-tf-state"

    def _sync_adc_quota_project(self):
        # Skipped under Workload Identity Federation (CI) — see the matching
        # docstring in provision.py's _sync_adc_quota_project for why.
        if os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
            return
        run_cmd(
            ["gcloud", "auth", "application-default", "set-quota-project", self.gcp_project],
            capture_output=False,
        )

    def destroy_terraform(self):
        """Destroys the tenant's Terraform-managed infrastructure."""
        log_info(f"--- Destroying Terraform workspace '{self.client_name}' ---")

        tf_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "terraform"
        )
        tf_vars_file = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "clients", f"{self.client_name}.tfvars"
        )

        if self.dry_run:
            log_info(f"[DRY-RUN] Would terraform init/destroy workspace '{self.client_name}' in {tf_dir}")
            return

        self._sync_adc_quota_project()
        run_cmd(
            ["terraform", "init", "-reconfigure", f"-backend-config=bucket={self.tf_state_bucket}"],
            cwd=tf_dir, capture_output=False,
        )
        run_cmd(["terraform", "workspace", "select", self.client_name], cwd=tf_dir, capture_output=False)
        run_cmd(
            ["terraform", "destroy", "-auto-approve", f"-var-file={tf_vars_file}"],
            cwd=tf_dir, capture_output=False,
        )
        log_success(f"Terraform destroy complete for workspace '{self.client_name}'.")

    def cleanup_workspace(self):
        """Switches back to default and deletes the now-empty client workspace."""
        log_info(f"--- Removing Terraform workspace '{self.client_name}' ---")

        tf_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "terraform"
        )

        if self.dry_run:
            log_info(f"[DRY-RUN] Would switch to 'default' and delete workspace '{self.client_name}'")
            return

        run_cmd(["terraform", "workspace", "select", "default"], cwd=tf_dir, capture_output=False)
        run_cmd(["terraform", "workspace", "delete", self.client_name], cwd=tf_dir, capture_output=False)
        log_success(f"Workspace '{self.client_name}' removed.")

    def run(self):
        log_info(f"Starting destroy workflow for Cloud Run client '{self.client_name}'...")
        self.destroy_terraform()
        self.cleanup_workspace()
        log_warn(
            f"Terraform-managed infra for '{self.client_name}' is gone. The tenant "
            "database itself was NOT dropped (README §13 step 3 — DROP as odoo_shared "
            "is a separate, deliberate manual step)."
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Destroy an Odoo client's Terraform-managed Cloud Run infrastructure.")
    parser.add_argument("--client", required=True, help="Client slug defined in clients.yaml (e.g. acme-corp)")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without modifying state")

    args = parser.parse_args()

    try:
        d = CloudRunDestroyer(args.client, dry_run=args.dry_run)
        d.run()
    except Exception as e:
        log_error(f"Destroy failed: {e}")
        sys.exit(1)
