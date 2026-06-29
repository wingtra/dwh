#!/usr/bin/env python3
"""Grant dataset-scoped BigQuery write access using dataset ACLs."""
import argparse
import json
import subprocess
import sys
import urllib.request
from urllib.error import HTTPError


def _request(url: str, token: str, method: str, payload: dict | None = None) -> dict:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        print(body, file=sys.stderr)
        raise


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--member", required=True)
    parser.add_argument("--role", required=True)
    args = parser.parse_args()

    token = subprocess.check_output(
        ["gcloud", "auth", "print-access-token"],
        text=True,
    ).strip()
    base_url = (
        "https://bigquery.googleapis.com/bigquery/v2/projects/"
        f"{args.project}/datasets/{args.dataset}"
    )
    dataset = _request(base_url, token, "GET")
    access_entries = dataset.setdefault("access", [])

    if args.role != "roles/bigquery.dataEditor":
        raise ValueError(f"Unsupported dataset ACL role mapping: {args.role}")
    if not args.member.startswith("serviceAccount:"):
        raise ValueError(f"Unsupported member for dataset ACL mapping: {args.member}")

    entry = {
        "role": "WRITER",
        "userByEmail": args.member.removeprefix("serviceAccount:"),
    }
    if entry not in access_entries:
        access_entries.append(entry)
        _request(base_url, token, "PATCH", {"access": access_entries})
    print(f"Granted dataset WRITER on {args.project}:{args.dataset} to {args.member}")


if __name__ == "__main__":
    main()
