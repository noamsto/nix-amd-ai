#!/usr/bin/env python3
"""Raw-bytes streaming probe for #199.

capture.py <port> <ollama_chat|openai_chat> <out.bin> [read_timeout_s]

Sends one streaming chat request over a raw socket and reads until the server
closes the connection or the read timeout fires, then prints one JSON line of
facts about the bytes. The timeout is essential on the red build: after the
generate() exception the server neither writes an error nor closes the socket
(#194 only releases the slot), so a plain read-until-EOF would hang.
"""
import json
import socket
import sys

port = int(sys.argv[1])
endpoint = sys.argv[2]
out = sys.argv[3]
timeout = float(sys.argv[4]) if len(sys.argv) > 4 else 15.0

if endpoint == "ollama_chat":
    path = "/api/chat"
elif endpoint == "openai_chat":
    path = "/v1/chat/completions"
else:
    raise SystemExit("bad endpoint: " + endpoint)

payload = json.dumps({
    "model": "llama3.2:1b",
    "messages": [{"role": "user", "content":
                  "Write a very long, detailed essay about the history of the "
                  "ocean, at least 2000 words."}],
    "stream": True,
}).encode()
request = (
    ("POST %s HTTP/1.1\r\n" % path).encode()
    + b"Host: 127.0.0.1\r\n"
    + b"Content-Type: application/json\r\n"
    + ("Content-Length: %d\r\n" % len(payload)).encode()
    + b"Connection: close\r\n\r\n"
    + payload
)

sock = socket.create_connection(("127.0.0.1", port), timeout=30)
sock.settimeout(timeout)
sock.sendall(request)
data = b""
try:
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
except socket.timeout:
    pass
finally:
    sock.close()

with open(out, "wb") as fh:
    fh.write(data)

low = data.lower()
generic_error = b"Internal error" in data or b"Invalid request" in data or b"Max length reached" in data
print(json.dumps({
    "endpoint": endpoint,
    "bytes": len(data),
    "http200": data.startswith(b"HTTP/1.1 200"),
    "error_event": b'"error"' in low and generic_error,
    "terminator": data.endswith(b"0\r\n\r\n"),
    "sse_done": b"[done]" in low,
    "leaked_injection_text": b"injected mid-stream" in low,
}))
