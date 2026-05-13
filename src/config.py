"""Environment configuration."""
import os


GCP_PROJECT = os.environ["GCP_PROJECT"]
GCS_BUCKET = os.environ["GCS_BUCKET"]
ODOO_SSH_HOST = os.environ["ODOO_SSH_HOST"]
ODOO_SSH_USER = os.environ["ODOO_SSH_USER"]
BQ_DATASET = os.environ.get("BQ_DATASET", "dl_odoo")
PG_DATABASE = os.environ.get("PG_DATABASE", "odoo_restore")
PG_USER = os.environ.get("PG_USER", "postgres")
PG_SOCKET_DIR = os.environ.get("PG_SOCKET_DIR", "/var/run/postgresql")
