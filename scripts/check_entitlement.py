#!/usr/bin/env python3
"""scripts/check_entitlement.py

CI-side entitlement guard (used by .github/workflows/update-addon.yml): refuse a
targeted module update for a client whose plan does not include the module's
catalog repo. This mirrors the runtime rule in the addon_entitlement Odoo module
so the CI gate and runtime enforcement cannot drift — a module is allowed iff it
is a platform module (odoo-v18/addons), a core/OCA module owned by no catalog
repo, or owned by a catalog repo the client is entitled to via clients.yaml
addon_repos (plus the always-entitled `common`).

Run scripts/prepare_addons.py first so odoo-v18/build-addons/ is populated.

Usage: python3 scripts/check_entitlement.py --client <slug> --module <name>
Exit 1 with a ::error:: line if the module is not entitled for the client.
"""

import argparse
import os
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIENTS_YAML = os.path.join(ROOT, "clients", "clients.yaml")
PLATFORM_ADDONS = os.path.join(ROOT, "odoo-v18", "addons")
BUILD_ADDONS = os.path.join(ROOT, "odoo-v18", "build-addons")
ALWAYS_ENTITLED = {"common"}


def _has_module(root, module):
    return os.path.isfile(os.path.join(root, module, "__manifest__.py"))


def owning_catalog_dirs(module):
    """Catalog build dirs that ship `module` (empty for core/OCA modules)."""
    if not os.path.isdir(BUILD_ADDONS):
        return []
    return sorted(
        d for d in os.listdir(BUILD_ADDONS)
        if os.path.isdir(os.path.join(BUILD_ADDONS, d))
        and _has_module(os.path.join(BUILD_ADDONS, d), module)
    )


def entitled_dirs(config, client_slug):
    return set(config["clients"][client_slug].get("addon_repos") or []) | ALWAYS_ENTITLED


def is_entitled(config, client_slug, module):
    """Returns (allowed: bool, owning_dirs: list)."""
    if _has_module(PLATFORM_ADDONS, module):
        return True, []          # platform module — always allowed
    owners = owning_catalog_dirs(module)
    if not owners:
        return True, []          # core/OCA module — not entitlement-gated
    return bool(set(owners) & entitled_dirs(config, client_slug)), owners


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", required=True)
    parser.add_argument("--module", required=True)
    args = parser.parse_args()

    with open(CLIENTS_YAML) as f:
        config = yaml.safe_load(f)
    if args.client not in (config.get("clients") or {}):
        print(f"::error::unknown client '{args.client}'")
        sys.exit(1)

    allowed, owners = is_entitled(config, args.client, args.module)
    if not allowed:
        entitled = sorted(entitled_dirs(config, args.client))
        print(f"::error::module '{args.module}' belongs to catalog repo(s) {owners}, "
              f"but '{args.client}' is only entitled to {entitled} — add the repo to "
              "its addon_repos in clients/clients.yaml (and apply terraform/shared) first")
        sys.exit(1)


if __name__ == "__main__":
    main()
