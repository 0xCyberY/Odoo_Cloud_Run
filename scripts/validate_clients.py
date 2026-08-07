#!/usr/bin/env python3
"""
scripts/validate_clients.py

Validates clients/clients.yaml against the platform's tenant-resolution rules.
Called by prepare_addons.py and provision.py (and importable); terraform/shared
enforces the same rules as apply-time preconditions on the SSL certificate.

Rules (dbfilter = ^(%d|%h)$ — Option A hybrid):
  R1  client slugs are unique (YAML would silently drop dupes — we re-scan raw text)
  R2  domains are unique across clients
  R3  database names are unique across clients
  R4  db_user names are unique across clients
  R5  every domain resolves to EXACTLY ONE database:
        db == first label of the host (www. stripped)  e.g. beta.nomowsoft.com → beta
        OR db == full host                              e.g. super.droob.com → super.droob.com
      Zero matches → tenant unreachable. Two+ matches → ambiguous (data hazard).
  R6  catalog entries are well-formed: each has a 'repo'; the key 'common' is
      reserved for the common_addon_repo clone directory
  R7  every client addon_repos entry is a string referencing an existing
      catalog key (the old inline {repo,branch,path} form is rejected —
      entitlements are rendered from these references)
  R8  'domain' is required and must be a syntactically valid hostname
      (DOMAIN_RE) — this is a security boundary, not just hygiene:
      onboard_client.py derives 'database' from 'domain' and feeds both
      into generated YAML/tfvars text and a comma-joined
      `gcloud run jobs execute --args=` string, so characters outside a
      hostname charset must never reach either
  R9  contact_email, when present, looks like an email address
  R10 selected_addons is a subset of the client's own addon_repos —
      auto-install can't select something the client isn't entitled to
  R11 database name must fit Postgres/Cloud SQL's 63-byte NAMEDATALEN
      limit — they truncate silently otherwise, which R5 would eventually
      catch as an opaque "host matches NO database" failure; this gives
      the real reason up front
  R12 client_slug must be a valid RFC1035-style label (lowercase
      letters/digits/hyphens, starting with a letter, not ending in a
      hyphen) — it's baked directly into the per-tenant GCS bucket, Cloud
      Run Job names, and Secret Manager secret IDs, all of which reject
      anything else with a raw GCP API error instead of this clear one.
      Bans underscores as a side effect, which also makes db_user
      (slug.replace('-', '_')) collision-free between distinct slugs.
  R13 resource names derived from client_slug (the GCS attachments bucket,
      the longest Cloud Run Job name) must fit GCP's 63-character RFC1035
      limit — checked against the actual computed name, not a guessed slug
      length cap, since the budget depends on how long gcp_project is too

Usage: python3 scripts/validate_clients.py [path/to/clients.yaml]
Exit code 1 with a per-violation message on failure.
"""

import os
import re
import sys

import yaml

DEFAULT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "clients", "clients.yaml",
)

# Standard DNS label: 1-63 chars, alphanumeric, hyphens not at either end.
_DNS_LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"

# Full hostname (the client-owned 'domain' field): 2+ dot-separated DNS
# labels. Deliberately strict — 'domain' feeds into onboard_client.py's
# generated clients.yaml/tfvars text AND (via _first_label -> database) a
# comma-joined `gcloud run jobs execute --args=` string, so anything outside
# this charset (commas, quotes, newlines, other shell/YAML/argv
# metacharacters) must never be accepted here.
DOMAIN_RE = re.compile(rf"^{_DNS_LABEL}(?:\.{_DNS_LABEL})+$")

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# client_slug: RFC1035-style label — lowercase letters/digits/hyphens, must
# start with a letter, must not end with a hyphen. It's used verbatim in the
# per-tenant GCS bucket name, Cloud Run Job names, and Secret Manager secret
# IDs (R12); none of those accept uppercase or underscores.
SLUG_RE = re.compile(r"^[a-z][a-z0-9-]*[a-z0-9]$")

GCP_RESOURCE_NAME_LIMIT = 63


def _host(domain):
    return domain[4:] if domain.startswith("www.") else domain


def _first_label(domain):
    return _host(domain).split(".")[0]


def _effective_domain(c):
    """The hostname this client actually serves on."""
    return c.get("domain")


def _find_duplicates(items):
    seen, dupes = set(), set()
    for item in items:
        if item in seen:
            dupes.add(item)
        seen.add(item)
    return sorted(dupes)


def validate(config, raw_text=None):
    """Returns a list of violation messages (empty = valid)."""
    errors = []
    clients = config.get("clients") or {}

    # R1 — duplicate slugs: yaml.safe_load keeps only the last duplicate key,
    # so this must be detected on the raw text, not the parsed dict.
    if raw_text:
        slugs = re.findall(r"^  ([A-Za-z0-9_-]+):\s*$", raw_text, re.MULTILINE)
        for slug in _find_duplicates(slugs):
            errors.append(
                f"R1 duplicate client slug '{slug}' — YAML silently keeps only the "
                "last definition; earlier ones are ignored"
            )

    domains = [_effective_domain(c) for c in clients.values() if _effective_domain(c)]
    databases = [c["database"] for c in clients.values() if c.get("database")]
    db_users = [c["db_user"] for c in clients.values() if c.get("db_user")]

    # R2/R3/R4 — cross-client uniqueness
    for domain in _find_duplicates(domains):
        errors.append(f"R2 duplicate domain '{domain}' used by more than one client")
    for db in _find_duplicates(databases):
        errors.append(f"R3 duplicate database name '{db}' used by more than one client")
    for user in _find_duplicates(db_users):
        errors.append(f"R4 duplicate db_user '{user}' used by more than one client")

    # R5 — every domain must resolve to exactly one database under ^(%d|%h)$
    for slug, c in clients.items():
        domain = _effective_domain(c)
        if not domain:
            continue
        host, label = _host(domain), _first_label(domain)
        matches = [db for db in databases if db in (label, host)]
        own_db = c.get("database")
        if not matches:
            errors.append(
                f"R5 [{slug}] host '{host}' matches NO database — name its database "
                f"'{label}' (subdomain convention) or '{host}' (full-domain, for collisions); "
                f"currently '{own_db}'"
            )
        elif len(matches) > 1:
            errors.append(
                f"R5 [{slug}] host '{host}' is AMBIGUOUS — matches databases {matches}; "
                "rename the colliding tenants' databases to their full domains"
            )
        elif matches[0] != own_db:
            errors.append(
                f"R5 [{slug}] host '{host}' resolves to database '{matches[0]}' which "
                f"belongs to another client (its own database is '{own_db}')"
            )

    # R6 — catalog well-formedness
    catalog = config.get("catalog") or {}
    if not isinstance(catalog, dict):
        errors.append("R6 'catalog' must be a mapping of <dir-name> → {repo, branch}")
        catalog = {}
    for key, spec in catalog.items():
        if key == "common":
            errors.append("R6 catalog key 'common' is reserved for common_addon_repo")
        if not isinstance(spec, dict) or not spec.get("repo"):
            errors.append(f"R6 catalog entry '{key}' must define a 'repo'")
        if isinstance(spec, dict) and "branch" in spec and not isinstance(spec["branch"], str):
            errors.append(
                f"R6 catalog entry '{key}' has a non-string 'branch' ({spec['branch']!r}) — "
                "YAML parses an unquoted version like 18.0 as a float; quote it "
                "(branch: '18.0')"
            )

    # R7 — client entitlements reference catalog keys
    for slug, c in clients.items():
        for entry in c.get("addon_repos") or []:
            if not isinstance(entry, str):
                errors.append(
                    f"R7 [{slug}] addon_repos entries must be catalog keys (strings); "
                    f"got {type(entry).__name__} — move the repo definition to the "
                    "top-level 'catalog' section and reference its key here"
                )
            elif entry not in catalog:
                errors.append(
                    f"R7 [{slug}] addon_repos references unknown catalog key '{entry}' "
                    f"(known: {sorted(catalog) or '(none)'})"
                )

    # R8 — domain is required and must be a valid hostname.
    for slug, c in clients.items():
        domain = c.get("domain")
        if not domain:
            errors.append(f"R8 [{slug}] must set 'domain'")
        elif not isinstance(domain, str) or not DOMAIN_RE.match(domain):
            errors.append(
                f"R8 [{slug}] domain '{domain}' is not a valid hostname "
                "(lowercase DNS labels separated by dots, hyphens not at either "
                "end of a label)"
            )

    # R9 — contact_email, when present, looks like an email address
    for slug, c in clients.items():
        email = c.get("contact_email")
        if email is not None and not (isinstance(email, str) and EMAIL_RE.match(email)):
            errors.append(f"R9 [{slug}] contact_email '{email}' is not a valid email address")

    # R10 — selected_addons must be a subset of the client's own entitlements
    for slug, c in clients.items():
        entitled = set(c.get("addon_repos") or [])
        for entry in c.get("selected_addons") or []:
            if entry not in entitled:
                errors.append(
                    f"R10 [{slug}] selected_addons references '{entry}' which isn't in "
                    f"this client's own addon_repos (entitled: {sorted(entitled) or '(none)'})"
                )

    # R11 — database name must fit Postgres/Cloud SQL's 63-byte NAMEDATALEN
    # limit (onboard_client.py derives it from the full domain, which can
    # exceed 63 bytes for long hostnames).
    for slug, c in clients.items():
        db = c.get("database")
        if isinstance(db, str) and len(db.encode()) > 63:
            errors.append(
                f"R11 [{slug}] database name '{db}' is {len(db.encode())} bytes, over "
                "Postgres's 63-byte limit — shorten the domain or pass an explicit --database"
            )

    # R12 — client_slug must be a safe RFC1035-style label.
    for slug in clients:
        if not SLUG_RE.match(slug):
            errors.append(
                f"R12 [{slug}] client_slug must be lowercase letters/digits/hyphens, "
                "start with a letter, and not end with a hyphen"
            )

    # R13 — resource names built from client_slug must fit GCP's 63-character
    # limit. Computed from the actual derived name (like R11), not a guessed
    # slug-length cap, since the budget also depends on gcp_project's length.
    for slug, c in clients.items():
        project = c.get("gcp_project")
        if not project:
            continue
        bucket = f"{project}-{slug}-odoo-attachments"
        if len(bucket) > GCP_RESOURCE_NAME_LIMIT:
            errors.append(
                f"R13 [{slug}] GCS bucket name '{bucket}' is {len(bucket)} chars, over "
                "GCP's 63-char limit — shorten client_slug"
            )
        longest_job = f"{slug}-odoo-job-migration"
        if len(longest_job) > GCP_RESOURCE_NAME_LIMIT:
            errors.append(
                f"R13 [{slug}] Cloud Run Job name '{longest_job}' is {len(longest_job)} chars, "
                "over GCP's 63-char limit — shorten client_slug"
            )

    return errors


def validate_file(path=DEFAULT_PATH):
    with open(path) as f:
        raw = f.read()
    errors = validate(yaml.safe_load(raw), raw_text=raw)
    if errors:
        print(f"clients.yaml validation FAILED ({len(errors)} problem(s)):", file=sys.stderr)
        for e in errors:
            print(f"  ✗ {e}", file=sys.stderr)
        sys.exit(1)
    print(f"clients.yaml OK — {len(yaml.safe_load(raw).get('clients') or {})} client(s), "
          "all domains resolve to exactly one database")


if __name__ == "__main__":
    validate_file(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH)
