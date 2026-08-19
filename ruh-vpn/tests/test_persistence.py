import asyncio
import os

from backend.models.server import parse_server
from backend.storage.persistence import load_servers, save_servers
from backend.paths import DATA_DIR


def test_servers_round_trip_with_private_permissions():
    server = parse_server({
        "id": "p1", "name": "n", "protocol": "ssh",
        "host": "example.com", "port": 22, "user": "root", "password": "pw",
    })

    async def run():
        await save_servers([server])
        return await load_servers()

    loaded = asyncio.run(run())
    assert len(loaded) == 1
    assert loaded[0].id == "p1"
    assert loaded[0].password == "pw"  # secrets persist on disk, 0600

    server_files = [p for p in DATA_DIR.iterdir() if p.is_file()]
    assert server_files, "expected persisted files in the data dir"
    for path in server_files:
        assert (os.stat(path).st_mode & 0o777) == 0o600, path
