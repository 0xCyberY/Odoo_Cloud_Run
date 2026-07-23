import logging

_logger = logging.getLogger(__name__)

STORAGE_CODE = "gcs_att"


def post_init_hook(env):
    """Ensure the fs.storage record that GCS attachment storage binds to exists.

    IMPORTANT: the actual backend configuration — protocol (gcs), the bucket
    (directory_path), credentials (options), and use_as_default_for_attachments
    — is NOT stored on this record. With the OCA ``server_environment`` module
    installed (it is, as a dependency of fs_storage; running_env=prod), those
    fs_storage fields are *server-env driven*: they are read at runtime from the
    ``SERVER_ENV_CONFIG`` env var (section ``[fs_storage.gcs_att]``), which
    terraform/shared renders onto every Cloud Run service. They are NOT database
    columns. This hook therefore only needs to create the record with the
    matching ``code`` so the server-env config attaches to it.

    History / why this matters (see README §16): an earlier version of this hook
    tried to write ``protocol``/``directory_path``/``options``/
    ``use_as_default_for_attachments`` directly onto the record. Because those
    are server-env fields (no DB column), Odoo silently dropped the writes, GCS
    was never configured, and every attachment — including web asset bundles —
    was written to the *ephemeral* Cloud Run local filestore. Styling then broke
    on every service revision roll / cold start. Do not reintroduce that; the
    backend config belongs in SERVER_ENV_CONFIG (terraform/shared/main.tf).
    """
    storage = env["fs.storage"].search([("code", "=", STORAGE_CODE)], limit=1)
    if storage:
        _logger.info("fs.storage '%s' already present", STORAGE_CODE)
        return
    env["fs.storage"].create({"name": "GCS Attachments", "code": STORAGE_CODE})
    _logger.info(
        "Created fs.storage '%s' (backend config comes from SERVER_ENV_CONFIG, "
        "section [fs_storage.%s])", STORAGE_CODE, STORAGE_CODE,
    )
