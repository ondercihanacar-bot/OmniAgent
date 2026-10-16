import urllib.request
import json
import time

url = "https://omniagent-hub.onrender.com/api/tasks/create"
headers = {
    "Content-Type": "application/json",
    "X-Admin-Password": "2213"
}

cmd = 'Remove-Item -Path "C:\\OmniAgent\\offline_outage.json" -Force -ErrorAction SilentlyContinue; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; (New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/ondercihanacar-bot/OmniAgent/main/agent/OmniAgent.ps1", "C:\\OmniAgent\\OmniAgent.ps1"); Write-Output "OmniAgent basariyla guncellendi."'

payload = {
    "server_id": "ALL",
    "command": cmd,
    "timeout_sec": 30
}

req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers)
resp = urllib.request.urlopen(req)
print(resp.read().decode("utf-8"))
