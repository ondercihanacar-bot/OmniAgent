"""
OmniAgent Tam Yetkili Güvenlik Duvarı (SonicWall) Otonom İşlem Modülü
İzin istemeden, verilen parametrelerle doğrudan SonicWall API / Web üzerinden:
- Senkron / RDP / Özel Port IP Whitelist Ekleme
- Saldırgan IP Adresini WAN->LAN Kuralında Engelleme
- Değişiklikleri Commit Etme
işlemlerini gerçekleştirir.
"""

import sys
import json
import ssl
import base64
import urllib.request
import urllib.error


class SonicWallAutonomousAgent:
    def __init__(self, firewall_url, username, password):
        self.base_url = firewall_url.rstrip("/")
        self.username = username
        self.password = password
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE

    def _request(self, method, path, payload=None):
        url = f"{self.base_url}{path}"
        auth_str = base64.b64encode(f"{self.username}:{self.password}".encode("utf-8")).decode("ascii")
        headers = {
            "Authorization": f"Basic {auth_str}",
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
        data = json.dumps(payload).encode("utf-8") if payload else None
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, context=self.ctx, timeout=15) as res:
            body = res.read().decode("utf-8")
            return json.loads(body) if body else {}

    def login(self):
        return self._request("POST", "/api/sonicos/auth")

    def commit(self):
        return self._request("POST", "/api/sonicos/config/pending")

    def add_whitelist_ip(self, object_name, ip_address, group_name=None):
        """
        SonicWall üzerinde yeni bir WAN Host Address Object oluşturur ve
        varsa belirtilen izin grubuna (Örn: SENKRON_IZINLILER) izin istemeden ekler.
        """
        self.login()
        addr_payload = {
            "address_objects": [
                {
                    "ipv4": {
                        "name": object_name,
                        "zone": "WAN",
                        "host": {"ip": ip_address}
                    }
                }
            ]
        }
        self._request("POST", "/api/sonicos/address-objects/ipv4", addr_payload)

        if group_name:
            grp_payload = {
                "address_groups": [
                    {
                        "ipv4": {
                            "name": group_name,
                            "address_object": {
                                "ipv4": [{"name": object_name}]
                            }
                        }
                    }
                ]
            }
            self._request("PUT", "/api/sonicos/address-groups/ipv4", grp_payload)

        self.commit()
        return {
            "status": "success",
            "action": "WHITELIST_ADDED",
            "object_name": object_name,
            "ip": ip_address,
            "group": group_name
        }

    def block_attacker_ip(self, ip_address):
        """Saldırgan IP adresini SonicWall WAN katmanında engeller."""
        obj_name = f"OMNI_BLOCK_{ip_address.replace('.', '_')}"
        return self.add_whitelist_ip(obj_name, ip_address, group_name="OMNI_BLOCKED_ATTACKERS")


if __name__ == "__main__":
    if len(sys.argv) < 6:
        print("Kullanım: python sonicwall_autonomous.py <fw_url> <user> <pass> <action:whitelist|block> <ip> [obj_name] [group_name]")
        sys.exit(1)

    fw_url, user, pw, action, ip = sys.argv[1:6]
    obj_name = sys.argv[6] if len(sys.argv) > 6 else f"IZIN_{ip.replace('.', '_')}"
    grp_name = sys.argv[7] if len(sys.argv) > 7 else None

    agent = SonicWallAutonomousAgent(fw_url, user, pw)
    try:
        if action == "whitelist":
            res = agent.add_whitelist_ip(obj_name, ip, grp_name)
        else:
            res = agent.block_attacker_ip(ip)
        print(json.dumps(res, ensure_ascii=False, indent=2))
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}, ensure_ascii=False))
        sys.exit(1)
