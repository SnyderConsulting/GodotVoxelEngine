#!/usr/bin/env python3

import json
import socket
import time
from typing import Any, Dict, List, Optional


def send_json_line(sock: socket.socket, obj: Dict[str, Any]) -> Dict[str, Any]:
    line = json.dumps(obj, separators=(",", ":")) + "\n"
    sock.sendall(line.encode("utf-8"))
    buf = b""
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("automation server closed connection")
        buf += chunk
    resp_line, _rest = buf.split(b"\n", 1)
    return json.loads(resp_line.decode("utf-8"))


class AutomationClient:
    def __init__(
        self,
        host: str,
        port: int,
        token: str = "",
        *,
        connect_timeout_s: float = 2.0,
        call_timeout_s: float = 5.0,
        start_id: int = 1,
        call_retries: int = 0,
        retry_delay_s: float = 0.1,
        record_log: bool = False,
    ):
        self._sock = socket.create_connection((host, port), timeout=connect_timeout_s)
        self._sock.settimeout(call_timeout_s)
        self._id = start_id
        self._default_retries = max(0, int(call_retries))
        self._retry_delay_s = max(0.0, float(retry_delay_s))
        self.log: List[Dict[str, Any]] = []
        self._record_log = bool(record_log)
        if token:
            auth_resp = send_json_line(self._sock, {"id": 0, "method": "auth", "params": {"token": token}})
            if self._record_log:
                self.log.append({
                    "t": time.time(),
                    "req": {"id": 0, "method": "auth", "params": {"token": token}},
                    "resp": auth_resp,
                })
            if not auth_resp.get("ok"):
                raise RuntimeError(f"auth failed: {auth_resp}")

    def close(self) -> None:
        try:
            self._sock.close()
        except Exception:
            pass

    def call(
        self,
        method: str,
        params: Optional[Dict[str, Any]] = None,
        *,
        retries: Optional[int] = None,
    ) -> Dict[str, Any]:
        if params is None:
            params = {}
        attempts = (self._default_retries if retries is None else max(0, int(retries))) + 1
        last_exc: Optional[Exception] = None
        for attempt in range(attempts):
            self._id += 1
            req = {"id": self._id, "method": method, "params": params}
            try:
                resp = send_json_line(self._sock, req)
                if self._record_log:
                    self.log.append({"t": time.time(), "req": req, "resp": resp})
                if not resp.get("ok"):
                    raise RuntimeError(f"automation error: {resp.get('error')}")
                return resp
            except socket.timeout as exc:
                last_exc = exc
                if attempt + 1 < attempts:
                    time.sleep(self._retry_delay_s)
            except Exception as exc:
                last_exc = exc
                if attempt + 1 < attempts:
                    time.sleep(self._retry_delay_s)
        raise RuntimeError(last_exc) if last_exc is not None else RuntimeError("automation call failed")

    def call_result(
        self,
        method: str,
        params: Optional[Dict[str, Any]] = None,
        *,
        retries: Optional[int] = None,
    ) -> Any:
        return self.call(method, params, retries=retries).get("result")
