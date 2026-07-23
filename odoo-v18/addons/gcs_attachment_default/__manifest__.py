# License AGPL-3.0 or later (http://www.gnu.org/licenses/agpl.html)
{
    "name": "GCS Attachment Storage (fs.storage record)",
    "summary": "Create the fs.storage record (code=gcs_att) that fs_attachment "
    "binds to; the GCS backend config is supplied via SERVER_ENV_CONFIG "
    "(server_environment), NOT this module — see README §16",
    "version": "18.0.1.0.0",
    "author": "Nomowsoft",
    "website": "https://github.com/0xCyberY",
    "license": "AGPL-3",
    "category": "Technical",
    "depends": ["fs_attachment"],
    "external_dependencies": {"python": ["gcsfs"]},
    "post_init_hook": "post_init_hook",
    "installable": True,
}
