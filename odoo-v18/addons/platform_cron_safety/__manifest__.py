# License AGPL-3.0 or later (http://www.gnu.org/licenses/agpl.html)
{
    "name": "Platform Cron Thread Safety",
    "summary": "Monkeypatch: safe registries-dict snapshot in ThreadedServer.cron_thread "
    "(fixes a 'RuntimeError: OrderedDict mutated during iteration' crash that "
    "permanently kills a cron thread on the shared multi-tenant Cron Runner)",
    "version": "18.0.1.0.0",
    "author": "Nomowsoft",
    "website": "https://github.com/0xCyberY",
    "license": "AGPL-3",
    "category": "Technical",
    "depends": ["base"],
    "installable": True,
}
