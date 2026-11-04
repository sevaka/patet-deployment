#!/usr/bin/env python3
from pathlib import Path

path = Path("/etc/nginx/conf.d/patet.am.conf")
text = path.read_text()
if "location /socket.io/" in text:
    print("already present")
    raise SystemExit(0)

needle = "\tlocation ~ ^/(api|swagger) {"
if needle not in text:
    raise SystemExit("nginx api location not found")

snippet = """\tlocation /socket.io/ {
                proxy_pass http://localhost:57303;
                proxy_http_version 1.1;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection 'upgrade';
                proxy_set_header Host $host;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_cache_bypass $http_upgrade;
                proxy_read_timeout 3600s;
        }

"""
path.write_text(text.replace(needle, snippet + needle, 1))
print("inserted /socket.io/ location")
