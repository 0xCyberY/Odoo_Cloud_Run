#!/usr/bin/env bash
# scripts/tf.sh
#
# Wraps terraform for the two stacks (terraform/, terraform/shared/) so
# neither hardcodes a GCP project or state bucket in version control. Both
# are derived from whatever project `gcloud` currently has active — the
# state bucket is always <project>-tf-state, matching this repo's convention.
#
# Usage:
#   scripts/tf.sh shared init
#   scripts/tf.sh shared apply -target=google_artifact_registry_repository.odoo_repo
#   scripts/tf.sh root init
#   scripts/tf.sh root apply -var-file=clients/acme-corp.tfvars
#
# `root` and `shared` map to terraform/ and terraform/shared/ respectively.
# Every arg after the stack name is passed straight through to `terraform`.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <root|shared> <terraform-args...>" >&2
  exit 1
fi

STACK="$1"
shift

case "$STACK" in
  root)   DIR="terraform" ;;
  shared) DIR="terraform/shared" ;;
  *)
    echo "Unknown stack '$STACK' — expected 'root' or 'shared'" >&2
    exit 1
    ;;
esac

PROJECT="$(gcloud config get-value project 2>/dev/null)"
if [ -z "$PROJECT" ]; then
  echo "[error] no active gcloud project — run: gcloud config set project <id>" >&2
  exit 1
fi

# Application Default Credentials carry their own "quota project", separate
# from `gcloud config`'s active project — GCS/other API calls get billed and
# quota-attributed to whichever project ADC says, NOT the target project. A
# stale ADC quota project (e.g. left over from a previous `gcloud auth
# application-default login` on a different project) causes a confusing
# "billing account not in good standing" error that has nothing to do with
# the actual target project's billing. Keep it in sync on every invocation.
gcloud auth application-default set-quota-project "$PROJECT" >/dev/null

export TF_VAR_gcp_project="$PROJECT"

if [ "$1" = "init" ]; then
  shift
  exec terraform -chdir="$DIR" init -reconfigure "-backend-config=bucket=${PROJECT}-tf-state" "$@"
fi

exec terraform -chdir="$DIR" "$@"
