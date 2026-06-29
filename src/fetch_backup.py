"""SSH to Odoo.sh, download newest backup, upload to GCS.

Uses SSH+SCP via subprocess instead of Paramiko/SFTP. Odoo.sh does not support
SFTP (protocol errors), but SCP with the -O flag (legacy protocol) works.
The SSH private key is fetched from Secret Manager and written to a temp file
for the duration of the connection.
"""
import logging
import os
import subprocess
import tempfile
from datetime import datetime, timezone

from google.api_core.exceptions import PreconditionFailed
from google.cloud import secretmanager, storage


log = logging.getLogger(__name__)

SSH_OPTS = [
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=30",
    "-o", "LogLevel=ERROR",
]


def _write_ssh_key() -> str:
    """Fetch SSH key from Secret Manager, write to temp file, return path."""
    client = secretmanager.SecretManagerServiceClient()
    project = os.environ["GCP_PROJECT"]
    name = f"projects/{project}/secrets/odoo-sh-ssh-key/versions/latest"
    response = client.access_secret_version(request={"name": name})
    key_data = response.payload.data

    key_file = tempfile.NamedTemporaryFile(delete=False, prefix="odoo_ssh_", mode="wb")
    key_file.write(key_data)
    key_file.close()
    os.chmod(key_file.name, 0o600)
    return key_file.name


def _ssh_cmd(key_path: str) -> list[str]:
    return ["ssh", "-i", key_path] + SSH_OPTS


def fetch() -> str:
    """Pulls latest backup from Odoo.sh, uploads to GCS, returns local path."""
    host = os.environ["ODOO_SSH_HOST"]
    user = os.environ["ODOO_SSH_USER"]
    bucket_name = os.environ["GCS_BUCKET"]
    target = f"{user}@{host}"

    key_path = _write_ssh_key()
    try:
        # Step 1: List backups and find the newest .sql.gz
        log.info("Listing backups on %s", host)
        result = subprocess.run(
            _ssh_cmd(key_path) + [target,
                "ls -t ~/backup.daily/*.sql.gz 2>/dev/null | head -1"],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0 or not result.stdout.strip():
            raise RuntimeError(
                f"Failed to list backups via SSH (rc={result.returncode}): "
                f"{result.stderr.strip()}"
            )
        remote_path = result.stdout.strip()
        filename = os.path.basename(remote_path)
        log.info("Newest backup: %s", filename)

        # Step 2: Check backup freshness (mtime)
        result = subprocess.run(
            _ssh_cmd(key_path) + [target,
                f"stat -c %Y {remote_path}"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode == 0 and result.stdout.strip():
            mtime = int(result.stdout.strip())
            age_hours = (datetime.now(timezone.utc) -
                         datetime.fromtimestamp(mtime, timezone.utc)
                         ).total_seconds() / 3600
            if age_hours > 36:
                raise RuntimeError(
                    f"Newest backup is {age_hours:.1f}h old ({filename}). "
                    "Expected <36h. Aborting to avoid loading stale data."
                )
            log.info("Backup age: %.1fh", age_hours)

        # Step 3: SCP download (legacy protocol with -O flag)
        local_path = f"/tmp/{filename}"
        log.info("Downloading via SCP to %s", local_path)
        subprocess.run(
            ["scp", "-O", "-i", key_path] + SSH_OPTS +
            [f"{target}:{remote_path}", local_path],
            check=True, timeout=600,
        )

        # Step 4: Upload to GCS archive
        date_prefix = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        gcs_key = f"odoo/{date_prefix}/{filename}"
        blob = storage.Client().bucket(bucket_name).blob(gcs_key)
        try:
            blob.upload_from_filename(local_path, if_generation_match=0)
            log.info("Uploaded to gs://%s/%s", bucket_name, gcs_key)
        except PreconditionFailed:
            log.info("Backup already archived at gs://%s/%s", bucket_name, gcs_key)

        return local_path

    finally:
        os.unlink(key_path)
