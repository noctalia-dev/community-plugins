from backend.models.server import (
    SENSITIVE_FIELDS,
    parse_server,
    server_to_dict,
    server_to_public_dict,
)


def test_public_dict_strips_secrets():
    server = parse_server({
        "id": "s1", "name": "n", "protocol": "vless",
        "address": "example.com", "port": 443,
        "uuid": "11111111-2222-3333-4444-555555555555",
    })
    full = server_to_dict(server)
    public = server_to_public_dict(server)
    assert full["uuid"]
    for key in SENSITIVE_FIELDS:
        assert key not in public
    assert public["address"] == "example.com"
    assert public["port"] == 443


def test_public_dict_ssh_password():
    server = parse_server({
        "id": "s2", "name": "n", "protocol": "ssh",
        "host": "example.com", "port": 22, "user": "root", "password": "pw",
    })
    public = server_to_public_dict(server)
    assert "password" not in public
    assert public["user"] == "root"


def test_socks_alias():
    server = parse_server({
        "id": "s3", "name": "n", "protocol": "socks",
        "host": "example.com", "port": 1080,
    })
    assert server.protocol == "socks5"
