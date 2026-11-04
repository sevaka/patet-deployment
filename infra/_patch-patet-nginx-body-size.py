#!/usr/bin/env python3
from pathlib import Path

path = Path("/etc/nginx/conf.d/patet.am.conf")
text = path.read_text()
if "client_max_body_size" in text:
    print("already present")
    raise SystemExit(0)

# Insert into the HTTPS server block (listen 443), after server_name.
marker = '        server_name patet.am www.patet.am;\n'
# HTTPS block is the second occurrence of this server_name line.
parts = text.split(marker)
if len(parts) < 3:
    raise SystemExit(f"expected 2 server_name markers, found {len(parts) - 1}")

insert = marker + "\n        client_max_body_size 50m;\n"
# Rebuild: keep HTTP block as-is (parts[0]+marker+parts[1]), insert after HTTPS server_name
text = parts[0] + marker + parts[1] + insert + marker.join(parts[2:])
path.write_text(text)
print("inserted client_max_body_size 50m on HTTPS server")
