#!/usr/bin/env python3
"""
scripts/provision.py
Automates the provisioning of Odoo SaaS clients on GCP Cloud Run.
Provisions per-tenant infrastructure via Terraform (including dedicated databases,
storage buckets, and Cloud Run services), and executes database initialization
jobs on Cloud Run. Secrets are managed entirely by Terraform.
"""

import os
import sys
import argparse
import subprocess
import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import validate_clients  # noqa: E402

# Color output helper
class Colors:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'

def log_info(msg):
    print(f"{Colors.OKBLUE}[INFO]{Colors.ENDC} {msg}")

def log_success(msg):
    print(f"{Colors.OKGREEN}[SUCCESS]{Colors.ENDC} {Colors.BOLD}{msg}{Colors.ENDC}")

def log_warn(msg):
    print(f"{Colors.WARNING}[WARN]{Colors.ENDC} {msg}")

def log_error(msg):
    print(f"{Colors.FAIL}[ERROR]{Colors.ENDC} {msg}", file=sys.stderr)

def run_cmd(args, capture_output=True, text=True, input_str=None, check=True, cwd=None):
    """Helper to run a shell command securely."""
    use_shell = os.name == 'nt'
    try:
        res = subprocess.run(
            args,
            capture_output=capture_output,
            text=text,
            input=input_str,
            check=check,
            shell=use_shell,
            cwd=cwd
        )
        return res
    except subprocess.CalledProcessError as e:
        log_error(f"Command {' '.join(args)} failed with exit code {e.returncode}")
        if e.stdout:
            print(f"Stdout:\n{e.stdout}", file=sys.stderr)
        if e.stderr:
            print(f"Stderr:\n{e.stderr}", file=sys.stderr)
        raise e

class CloudRunProvisioner:
    def __init__(self, client_name, init_db=False, dry_run=False):
        self.client_name = client_name
        self.init_db = init_db
        self.dry_run = dry_run
        
        # Load clients configuration
        self.config_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "clients", "clients.yaml"
        )
        
        if not os.path.exists(self.config_path):
            raise FileNotFoundError(f"Configuration file not found at {self.config_path}")
            
        with open(self.config_path, 'r') as f:
            raw_config = f.read()
        self.full_config = yaml.safe_load(raw_config)

        # Reject duplicate/ambiguous registrations before touching any infra
        # (duplicate slugs/domains/databases, hosts that don't resolve to
        # exactly one database under dbfilter = ^(%d|%h)$).
        errors = validate_clients.validate(self.full_config, raw_text=raw_config)
        if errors:
            raise ValueError("clients.yaml validation failed:\n  " + "\n  ".join(errors))

        if "clients" not in self.full_config or self.client_name not in self.full_config["clients"]:
            raise ValueError(f"Client '{self.client_name}' not defined in clients.yaml")
            
        self.client_config = self.full_config["clients"][self.client_name]
        self.gcp_project = self.client_config.get("gcp_project", "nomowsoft-poc")
        self.region = self.client_config.get("region", "europe-west1")
        self.domain = self.client_config.get("domain")
        self.database_name = self.client_config.get("database")
        
    def execute_shared_terraform(self):
        """Applies terraform/shared first: tenant SQL user + password secret,
        pgbouncer credential map, SSL certificate domains, and uptime checks all
        derive from clients.yaml and must exist before the tenant workspace."""
        log_info("--- Step 1: Applying shared infrastructure (clients.yaml driven) ---")

        shared_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "terraform", "shared"
        )

        if self.dry_run:
            log_info(f"[DRY-RUN] Would run: terraform init && terraform apply -auto-approve in {shared_dir}")
            return

        run_cmd(["terraform", "init"], cwd=shared_dir, capture_output=False)
        run_cmd(["terraform", "apply", "-auto-approve"], cwd=shared_dir, capture_output=False)
        log_success("Shared infrastructure is up to date (tenant DB user, pgbouncer map, SSL cert, monitoring).")

    def execute_terraform(self):
        """Runs Terraform to provision databases, buckets, and Cloud Run service."""
        log_info("--- Step 2: Running Terraform Provisioning ---")
        
        tf_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "terraform"
        )
        
        # Select or create Terraform Workspace
        log_info(f"Initializing Terraform and selecting workspace '{self.client_name}'...")
        if not self.dry_run:
            run_cmd(["terraform", "init"], cwd=tf_dir, capture_output=False)
            
            # Check if workspace exists
            ws_list_res = run_cmd(["terraform", "workspace", "list"], cwd=tf_dir)
            workspaces = [w.strip().replace("*", "").strip() for w in ws_list_res.stdout.split("\n") if w.strip()]
            
            if self.client_name in workspaces:
                run_cmd(["terraform", "workspace", "select", self.client_name], cwd=tf_dir, capture_output=False)
            else:
                run_cmd(["terraform", "workspace", "new", self.client_name], cwd=tf_dir, capture_output=False)
        
        # Assemble terraform apply arguments
        tf_vars_file = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "clients", f"{self.client_name}.tfvars"
        )
        
        tf_apply_cmd = [
            "terraform", "apply", "-auto-approve",
            f"-var-file={tf_vars_file}"
        ]

        if self.dry_run:
            log_info(f"[DRY-RUN] Would execute Terraform command in {tf_dir}:\n{' '.join(tf_apply_cmd)}")
            return

        log_info("Applying Terraform changes...")
        try:
            run_cmd(tf_apply_cmd, cwd=tf_dir, capture_output=False)
        except subprocess.CalledProcessError:
            # The tenant jobs reference secrets whose IAM grants are created by
            # the shared stack moments earlier; Secret Manager IAM is eventually
            # consistent, so a brand-new tenant can race propagation. One retry
            # after a grace period is safe: terraform apply is idempotent.
            log_warn("Tenant apply failed — likely IAM propagation lag on freshly "
                     "granted secrets. Retrying once in 30s...")
            import time
            time.sleep(30)
            run_cmd(tf_apply_cmd, cwd=tf_dir, capture_output=False)
        log_success(f"Terraform successfully applied for workspace '{self.client_name}'.")

    def execute_job(self, job_name):
        """Executes a Cloud Run Job and waits for completion."""
        run_job_cmd = [
            "gcloud", "run", "jobs", "execute", job_name,
            f"--region={self.region}",
            f"--project={self.gcp_project}",
            "--wait"
        ]

        if self.dry_run:
            log_info(f"[DRY-RUN] Would run Cloud Run Job:\n{' '.join(run_job_cmd)}")
            return

        log_info(f"Executing Cloud Run Job '{job_name}' and waiting for completion...")
        run_cmd(run_job_cmd, capture_output=False)
        log_success(f"Cloud Run Job '{job_name}' completed successfully.")

    def run_db_setup_job(self):
        """Hardens the tenant database (v2 Fixes #2 & #4): restricts CONNECT to
        the tenant's least-privilege user, transfers ownership, and applies
        statement_timeout / connection limits. Idempotent — safe to re-run."""
        log_info("--- Step 3: Tenant database hardening (least-privilege user) ---")
        self.execute_job(f"{self.client_name}-odoo-job-db-setup")

    def run_init_job(self):
        """Executes the Cloud Run Job to initialize the database, then re-runs
        db-setup to sync the Odoo admin credentials (the init leaves admin/admin,
        which must never reach a public URL)."""
        if not self.init_db:
            log_info("Database initialization not requested. Skipping job execution.")
            return

        log_info("--- Step 4: Triggering Cloud Run DB Init Job ---")
        self.execute_job(f"{self.client_name}-odoo-job-init")

        log_info("--- Step 4b: Syncing Odoo admin credentials (db-setup re-run) ---")
        self.execute_job(f"{self.client_name}-odoo-job-db-setup")

    def output_routing_info(self):
        """Prints details required for DNS and Load Balancer registration."""
        log_info("--- Step 5: Routing & DNS Registration details ---")

        log_info(f"Tenant domain '{self.domain}' points to the Shared ALB IP.")
        log_info("Routing is automatically handled in Terraform by the pooled Load Balancer NEG backend.")
        log_info("The pooled service revision now includes this tenant in its pgbouncer credential map.")
        log_success("Provisioning flow complete!")

    def run(self):
        log_info(f"Starting provisioning workflow for Cloud Run client '{self.client_name}'...")
        self.execute_shared_terraform()
        self.execute_terraform()
        self.run_db_setup_job()
        self.run_init_job()
        self.output_routing_info()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Provision an Odoo client on Cloud Run with Private DB + Secret Manager.")
    parser.add_argument("--client", required=True, help="Name of the client defined in clients.yaml (e.g. acme-corp)")
    parser.add_argument("--init-db", action="store_true", help="Trigger the Odoo DB initialization Cloud Run job")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without modifying state")
    
    args = parser.parse_args()
    
    try:
        p = CloudRunProvisioner(args.client, init_db=args.init_db, dry_run=args.dry_run)
        p.run()
    except Exception as e:
        log_error(f"Provisioning failed: {e}")
        sys.exit(1)
