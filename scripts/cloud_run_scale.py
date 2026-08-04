#!/usr/bin/env python3
"""
scripts/cloud_run_scale.py
Updates the minimum instance count (min-instances) for Odoo Cloud Run services.
Used to toggle between warm standby (min=1) and scale-to-zero (min=0) settings.
"""

import argparse
import os
import sys
import subprocess

def run_cmd(args):
    try:
        res = subprocess.run(args, capture_output=True, text=True, check=True)
        return res
    except subprocess.CalledProcessError as e:
        print(f"Error: Command {' '.join(args)} failed with code {e.returncode}")
        if e.stderr:
            print(f"Details:\n{e.stderr}")
        raise e

def scale_service(client, min_instances, region, project):
    # All clients are pooled. Always target the shared pooled Odoo service.
    service_name = "pooled-odoo"
    print(f"All clients are hosted on the pooled tier. Scaling the shared service '{service_name}' (min-instances={min_instances})...")
    
    cmd = [
        "gcloud", "run", "services", "update", service_name,
        f"--min-instances={min_instances}",
        f"--region={region}",
        f"--project={project}"
    ]
    
    run_cmd(cmd)
    print(f"Successfully scaled '{service_name}' min-instances to {min_instances}.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Scale Cloud Run Odoo service min-instances.")
    parser.add_argument("--client", required=False, help="Ignored: all clients share the pooled service (pooled-odoo)")
    parser.add_argument("--min-instances", type=int, required=True, choices=[0, 1, 2, 3], help="Target minimum instances")
    parser.add_argument("--region", default=os.environ.get("GCP_REGION", "europe-west1"), help="GCP Region (or set GCP_REGION env var)")
    parser.add_argument("--project", default=os.environ.get("GCP_PROJECT"), help="GCP Project ID (or set GCP_PROJECT env var) — required, no hardcoded default")

    args = parser.parse_args()
    if not args.project:
        parser.error("--project or GCP_PROJECT env var is required")

    try:
        scale_service(args.client, args.min_instances, args.region, args.project)
    except Exception as e:
        print(f"Failed to scale service: {e}")
        sys.exit(1)
