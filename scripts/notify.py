#!/usr/bin/env python3
"""
scripts/notify.py
Sends notification emails for Odoo SaaS operations (provisioning or module update events).
Set SMTP_CREDS env var as JSON: {"host": ..., "port": ..., "user": ..., "password": ..., "from": ..., "to": ...}
"""

import sys
import argparse
import os
import json
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart


def send_email(smtp_creds: dict, subject: str, body: str):
    msg = MIMEMultipart()
    msg["From"]    = smtp_creds["from"]
    msg["To"]      = smtp_creds["to"]
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain"))

    with smtplib.SMTP_SSL(smtp_creds["host"], int(smtp_creds.get("port", 465))) as server:
        server.login(smtp_creds["user"], smtp_creds["password"])
        server.sendmail(smtp_creds["from"], smtp_creds["to"], msg.as_string())


def main():
    parser = argparse.ArgumentParser(description="Send notifications for client events.")
    parser.add_argument("--client",  required=True,  help="Client slug")
    parser.add_argument("--event",   required=False,  help="Event name (e.g. provisioned)")
    parser.add_argument("--module",  required=False,  help="Odoo module name (for addon updates)")
    parser.add_argument("--status",  required=False,  help="Status of the operation (success/failure)")
    args = parser.parse_args()

    if args.event:
        subject = f"[Odoo SaaS] Client '{args.client}' — {args.event}"
        body    = f"Client '{args.client}' has been successfully {args.event}."
    elif args.module:
        subject = f"[Odoo SaaS] Module update '{args.module}' for '{args.client}' — {args.status}"
        body    = f"Module update for client '{args.client}'.\nModule: {args.module}\nStatus: {args.status}"
    else:
        print("[notify] No event or module specified — nothing to notify.", file=sys.stderr)
        sys.exit(1)

    creds_json = os.environ.get("SMTP_CREDS")
    if creds_json:
        try:
            creds = json.loads(creds_json)
            send_email(creds, subject, body)
            print(f"[notify] Email sent: {subject}")
        except Exception as e:
            print(f"[notify] Failed to send email: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"[notify] SMTP_CREDS not set — logging to stdout only.")
        print(f"[notify] Subject: {subject}")
        print(f"[notify] Body: {body}")


if __name__ == "__main__":
    main()
