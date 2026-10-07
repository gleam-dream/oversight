"""Synthetic loopback provider. Memory survives caller/runtime replacement only."""
import http.server
import socket
import sys
import threading

receipts = {}
calls = {}
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def reply(self, status, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_DELETE(self):
        key = self.path.removeprefix("/effect/")
        with lock:
            calls[key] = calls.get(key, 0) + 1
            if key.endswith("/reject"):
                self.reply(409, "policy-rejection")
                return
            receipts.setdefault(key, "receipt:" + key)
            receipt = receipts[key]
        if key.endswith("/drop"):
            # Effect is committed in the fixture before any HTTP response bytes.
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        self.reply(200, receipt)

    def do_GET(self):
        with lock:
            if self.path.startswith("/count/"):
                key = self.path.removeprefix("/count/")
                self.reply(200, str(calls.get(key, 0)))
            else:
                key = self.path.removeprefix("/effect/")
                receipt = receipts.get(key)
                self.reply(200 if receipt else 404, receipt or "absent")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write(str(server.server_port))
server.serve_forever()
