"""build_ruleset must never let untrusted text into the nft program.

The ruleset text is executed by nft with root privileges, and server
addresses can come from untrusted subscriptions.
"""

from backend.service.kill_switch import TABLE_NAME, build_ruleset


def test_ipv4_with_port():
    rs = build_ruleset(["203.0.113.7"], 443)
    assert "        ip daddr 203.0.113.7 tcp dport 443 accept\n" in rs
    assert f"table inet {TABLE_NAME}" in rs


def test_ipv6_goes_to_ip6_rule():
    rs = build_ruleset(["2001:db8::1"], 8443)
    assert "        ip6 daddr 2001:db8::1 tcp dport 8443 accept\n" in rs
    assert "ip daddr 2001:db8::1" not in rs


def test_ip_without_port():
    rs = build_ruleset(["203.0.113.7"], None)
    assert "        ip daddr 203.0.113.7 accept\n" in rs


def test_multiple_ips():
    rs = build_ruleset(["203.0.113.7", "2001:db8::1"], 443)
    assert "ip daddr 203.0.113.7 tcp dport 443 accept" in rs
    assert "ip6 daddr 2001:db8::1 tcp dport 443 accept" in rs


def test_domain_is_dropped():
    rs = build_ruleset(["evil.example.com"], 443)
    assert "evil.example.com" not in rs


def test_newline_injection_is_dropped():
    payload = "1.2.3.4\ndelete table inet filter\n"
    rs = build_ruleset([payload], 443)
    assert "delete table inet filter" not in rs
    # and the payload as a whole must not appear either
    assert payload not in rs


def test_non_canonical_ip_is_reemitted_canonically():
    rs = build_ruleset(["2001:0DB8:0000:0000:0000:0000:0000:0001"], None)
    assert "ip6 daddr 2001:db8::1 accept" in rs


def test_ports_are_coerced_to_int():
    rs = build_ruleset(["1.2.3.4"], "443")
    assert "tcp dport 443 accept" in rs
    rs2 = build_ruleset(None, None, extra_allow_tcp=["11080", 11081])
    assert "tcp dport { 11080, 11081 } accept" in rs2


def test_no_server_lines_without_ips():
    rs = build_ruleset(None, None)
    assert "daddr" not in rs.split("chain input")[0].replace(
        "ip daddr 192.168.0.0/16 accept", ""
    ).replace("ip daddr 10.0.0.0/8 accept", "").replace(
        "ip daddr 172.16.0.0/12 accept", ""
    )
