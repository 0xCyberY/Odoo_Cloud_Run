#!/usr/bin/env python3
"""
scripts/prepare_addons.py

Populates odoo-v18/build-addons/ with the FULL addon catalog before the pooled
image build: the common addon repo plus every repo in the top-level `catalog:`
section of clients/clients.yaml — independent of which clients currently
subscribe. Baking the whole catalog means selling an addon never needs an
image rebuild: per-client visibility/install is enforced at runtime by the
addon_entitlement module from ODOO_ENTITLEMENTS (rendered by terraform/shared
from each client's addon_repos catalog references).

Repos are cloned with GITHUB_TOKEN (env) for private access; .git dirs are
stripped so no credentials or history leak into the build context.

Usage: GITHUB_TOKEN=... python3 scripts/prepare_addons.py [--clean]
"""

import argparse
import os
import shutil
import subprocess
import sys

import yaml

import validate_clients

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIENTS_YAML = os.path.join(ROOT, "clients", "clients.yaml")
BUILD_ADDONS = os.path.join(ROOT, "odoo-v18", "build-addons")


def clone(repo, branch, dest, token):
    if os.path.isdir(dest):
        print(f"[skip] {dest} already present")
        return
    url = f"https://{token}@{repo}" if token else f"https://{repo}"
    print(f"[clone] {repo} ({branch}) -> {os.path.relpath(dest, ROOT)}")
    subprocess.run(
        ["git", "clone", "--depth", "1", "-b", branch, url, dest],
        check=True,
        # Never echo the URL (contains the token) on failure
        stdout=subprocess.DEVNULL,
    )
    shutil.rmtree(os.path.join(dest, ".git"), ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clean", action="store_true", help="Remove build-addons/ first")
    args = parser.parse_args()

    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        print("[warn] GITHUB_TOKEN not set; private repos will fail to clone", file=sys.stderr)

    with open(CLIENTS_YAML) as f:
        raw = f.read()
    config = yaml.safe_load(raw)

    # Fail fast on tenant-resolution problems (duplicate domains/DBs, hosts
    # that would not match — or ambiguously match — a database).
    errors = validate_clients.validate(config, raw_text=raw)
    if errors:
        for e in errors:
            print(f"[error] {e}", file=sys.stderr)
        sys.exit(1)

    if args.clean and os.path.isdir(BUILD_ADDONS):
        shutil.rmtree(BUILD_ADDONS)
    os.makedirs(BUILD_ADDONS, exist_ok=True)

    # Common shared addons (always entitled for every tenant)
    common = config.get("common_addon_repo")
    if common:
        clone(common, "18.0", os.path.join(BUILD_ADDONS, "common"), token)

    # Full sellable catalog — every repo, whether or not a client subscribes
    # today. The directory name (catalog key) is the entitlement unit that
    # clients' addon_repos and ODOO_ENTITLEMENTS refer to.
    for key, spec in (config.get("catalog") or {}).items():
        clone(spec["repo"], spec.get("branch", "18.0"), os.path.join(BUILD_ADDONS, key), token)

    dirs = sorted(
        d for d in os.listdir(BUILD_ADDONS)
        if os.path.isdir(os.path.join(BUILD_ADDONS, d))
    )
    print(f"[done] build-addons/ contains: {', '.join(dirs) if dirs else '(nothing)'}")

    check_duplicate_module_names(BUILD_ADDONS, dirs)


def check_duplicate_module_names(build_addons, top_level_dirs):
    """Odoo enforces a unique technical name across the whole addons_path
    (ir_module_module.name_uniq). Two catalog repos shipping a module with
    the same folder name silently loses one at runtime (logged only as
    "WARNING ... The name of the module must be unique!", with no mention
    of which module or which repos). Catch it here, at build time, with
    both repo names attached.
    """
    seen = {}  # module name -> repo dir it was first found in
    collisions = []
    for repo_dir in top_level_dirs:
        repo_path = os.path.join(build_addons, repo_dir)
        for entry in sorted(os.listdir(repo_path)):
            entry_path = os.path.join(repo_path, entry)
            if not os.path.isfile(os.path.join(entry_path, "__manifest__.py")):
                continue
            if entry in seen:
                collisions.append((entry, seen[entry], repo_dir))
            else:
                seen[entry] = repo_dir

    if collisions:
        print("[error] duplicate module technical name(s) across catalog repos:", file=sys.stderr)
        for name, repo_a, repo_b in collisions:
            print(f"  - '{name}' exists in both '{repo_a}' and '{repo_b}'", file=sys.stderr)
        print(
            "Odoo requires unique module names across the whole addons_path; "
            "rename or remove one copy in the offending repo.",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
