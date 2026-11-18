import base64

from backend.subscription.parsers import parse_share_link


def test_vless_link():
    link = (
        "vless://11111111-2222-3333-4444-555555555555@example.com:443"
        "?type=ws&security=tls&sni=cdn.example.com&path=%2Fws#My%20VLESS"
    )
    data = parse_share_link(link)
    assert data is not None
    assert data["protocol"] == "vless"
    assert data["address"] == "example.com"
    assert data["port"] == 443
    assert data["uuid"] == "11111111-2222-3333-4444-555555555555"
    assert data["transport"] == "ws"
    assert data["security"] == "tls"


def test_ss_link():
    userinfo = base64.urlsafe_b64encode(b"aes-256-gcm:secretpw").decode().rstrip("=")
    data = parse_share_link(f"ss://{userinfo}@example.com:8388#SS")
    assert data is not None
    assert data["protocol"] == "shadowsocks"
    assert data["method"] == "aes-256-gcm"
    assert data["password"] == "secretpw"
    assert data["port"] == 8388


def test_socks5_link():
    data = parse_share_link("socks5://user:pw@example.com:1080#S5")
    assert data is not None
    assert data["protocol"] == "socks5"
    assert data["port"] == 1080


def test_unsupported_link():
    assert parse_share_link("trojan://whatever@example.com:443") is None
    assert parse_share_link("not a link") is None
    assert parse_share_link("") is None
