#!/usr/bin/env python3
"""
flux_zabbix.py - integracao do flux-loadtest com o Zabbix (WEB-1437)

Subcomandos:
  send RUN_DIR      le o diretorio de uma execucao e envia ao Zabbix por trapper,
                    com o timestamp original de cada amostra. Com --follow, acompanha
                    a execucao em andamento (o run do flux-loadtest.sh usa este modo).
  setup             cria o grupo e os hosts (um por servidor do teste + <prefixo>run)
                    e vincula os templates; opcionalmente importa o template YAML. Cria ou
                    atualiza o dashboard "Flux Loadtest - Resultados (<prefixo>)".
  check             testa a API e o trapper.
  bootstrap         (laboratorio) troca a senha inicial do Admin e cria um token de API.

Somente biblioteca padrao do Python 3.9+ (Debian 12: 3.11). Chamado pelo
flux-loadtest.sh; ver "flux-loadtest.sh zabbix --help" e docs/configuracao/zabbix.md.

O que vai para cada chave esta descrito em zabbix/gen_templates.py.
"""

import argparse
import json
import os
import re
import signal
import socket
import ssl
import struct
import sys
import time
import urllib.error
import urllib.request

E_OK, E_USAGE, E_CONFIG, E_DEPS, E_REMOTE = 0, 2, 3, 4, 5

SYS_COLS = [
    "cpu_pct", "cpu_max_core_pct", "cpu_max_core", "iowait_pct", "steal_pct", "softirq_pct", "load1",
    "mem_used_pct", "mem_avail_mb", "swap_used_mb",
    "net_rx_mbps", "net_tx_mbps", "net_rx_pps", "net_tx_pps", "udp_in_err_s", "udp_rcvbuf_err_s",
    "net_rx_drop_s", "net_tx_drop_s", "disk_rd_kbs", "disk_wr_kbs", "disk_busy_pct", "disk_free_pct",
]

ROLE_TEMPLATES = {
    "opensips": ["Flux Loadtest - Sistema", "Flux Loadtest - OpenSIPS"],
    "fs": ["Flux Loadtest - Sistema", "Flux Loadtest - FreeSWITCH"],
    "db": ["Flux Loadtest - Sistema", "Flux Loadtest - MySQL PXC"],
    "web": ["Flux Loadtest - Sistema", "Flux Loadtest - Web"],
    "gen": ["Flux Loadtest - Sistema", "Flux Loadtest - Gerador"],
    "run": ["Flux Loadtest - Execucao"],
}
# Disparo pelo Zabbix: so no host gen com interface agent (itens passivos do zabbix-agentd)
TRIGGER_TEMPLATE = "Flux Loadtest - Disparo"
HOST_GROUP = "Flux Loadtest"
ZBX_WRAPPER = "sudo -n /usr/local/sbin/flux-loadtest-zbx"
SCRIPT_MENU = "Flux Loadtest"
PROFILE_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
TEMPLATE_GROUP = "Templates/Flux Loadtest"

BATCH = 250          # valores por requisicao ao trapper
MAX_PENDING = 200000  # limite de memoria no modo --follow com o Zabbix fora


def log(msg):
    sys.stderr.write(time.strftime("[%H:%M:%S] ") + "zabbix: " + msg + "\n")
    sys.stderr.flush()


def die(code, msg):
    log("ERRO: " + msg)
    sys.exit(code)


def num(v):
    """'3.4' -> 3.4, '12' -> 12, '' -> None, outro texto -> texto."""
    v = v.strip()
    if v == "":
        return None
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    if re.fullmatch(r"-?\d+\.\d*", v):
        return float(v)
    return v


def compact(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


# =========================================================================== trapper


class Sender:
    """Protocolo do zabbix_sender (ZBXD\\x01), sem criptografia."""

    def __init__(self, server, port, timeout=10, dry_run=False):
        self.server, self.port, self.timeout, self.dry_run = server, port, timeout, dry_run
        self.pending = []
        self.processed = self.failed = self.sent = 0

    def add(self, host, key, clock, value):
        if len(self.pending) >= MAX_PENDING:
            self.pending.pop(0)
        sec = int(clock)
        ns = int(round((float(clock) - sec) * 1e9))
        self.pending.append({"host": host, "key": key, "value": value if isinstance(value, str) else compact(value),
                             "clock": sec, "ns": max(0, min(ns, 999999999))})

    def _request(self, data):
        payload = json.dumps({"request": "sender data", "data": data, "clock": int(time.time())}).encode()
        packet = b"ZBXD\x01" + struct.pack("<II", len(payload), 0) + payload
        with socket.create_connection((self.server, self.port), timeout=self.timeout) as s:
            s.sendall(packet)
            hdr = b""
            while len(hdr) < 13:
                chunk = s.recv(13 - len(hdr))
                if not chunk:
                    raise OSError("conexao encerrada pelo servidor")
                hdr += chunk
            if hdr[:4] != b"ZBXD":
                raise OSError("resposta invalida do trapper")
            size = struct.unpack("<I", hdr[5:9])[0]
            body = b""
            while len(body) < size:
                chunk = s.recv(size - len(body))
                if not chunk:
                    break
                body += chunk
        resp = json.loads(body.decode("utf-8", "replace"))
        if resp.get("response") != "success":
            raise OSError("trapper recusou: " + str(resp.get("info", resp)))
        m = re.search(r"processed: (\d+); failed: (\d+)", resp.get("info", ""))
        return (int(m.group(1)), int(m.group(2))) if m else (len(data), 0)

    def flush(self):
        """Envia o pendente. Retorna False se o Zabbix estiver inacessivel (mantem a fila)."""
        while self.pending:
            data = self.pending[:BATCH]
            if self.dry_run:
                for d in data:
                    print(f"{d['host']} {d['key']} {d['clock']} {d['value']}")
                p, f = len(data), 0
            else:
                try:
                    p, f = self._request(data)
                except (OSError, ValueError) as e:
                    log(f"falha no envio para {self.server}:{self.port}: {e} ({len(self.pending)} valores na fila)")
                    return False
            if f:
                log(f"{f} de {len(data)} valores recusados (host ou item inexistente? rode 'zabbix setup')")
            self.processed += p
            self.failed += f
            self.sent += len(data)
            del self.pending[:len(data)]
        return True


# =========================================================================== leitura do RUN_DIR


class Tail:
    """Le apenas linhas completas novas de um arquivo (seguro com escrita em andamento)."""

    def __init__(self, path):
        self.path, self.pos, self.buf = path, 0, ""

    def lines(self):
        try:
            with open(self.path, "r", encoding="utf-8", errors="replace") as f:
                f.seek(self.pos)
                data = f.read()
                self.pos = f.tell()
        except FileNotFoundError:
            return []
        data = self.buf + data
        parts = data.split("\n")
        self.buf = parts.pop()
        return parts


def sipp_ms(v):
    """'HH:MM:SS:uuuuuu' do SIPp -> ms."""
    p = v.split(":")
    if len(p) != 4:
        return None
    try:
        return round((int(p[0]) * 3600 + int(p[1]) * 60 + int(p[2])) * 1000 + int(p[3]) / 1000, 1)
    except ValueError:
        return None


def to_ms(v):
    m = re.fullmatch(r"([\d.]+)(us|ms|s|m)", v.strip())
    if not m:
        return None
    x = float(m.group(1))
    return round({"us": x / 1000, "ms": x, "s": x * 1000, "m": x * 60000}[m.group(2)], 3)


def to_bytes(v):
    m = re.fullmatch(r"([\d.]+)(B|KB|MB|GB|TB)?", v.strip())
    if not m:
        return None
    mult = {None: 1, "B": 1, "KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3, "TB": 1024 ** 4}[m.group(2)]
    return round(float(m.group(1)) * mult)


def parse_wrk(text):
    r = {}
    m = re.search(r"^\s+Latency\s+(\S+)", text, re.M)
    if m:
        r["lat_avg_ms"] = to_ms(m.group(1))
    for p in ("50", "90", "99"):
        m = re.search(rf"^\s+{p}%\s+(\S+)", text, re.M)
        if m:
            r[f"lat_p{p}_ms"] = to_ms(m.group(1))
    m = re.search(r"^\s+(\d+) requests in", text, re.M)
    if m:
        r["requests"] = int(m.group(1))
    m = re.search(r"^Requests/sec:\s+([\d.]+)", text, re.M)
    if m:
        r["rps"] = float(m.group(1))
    m = re.search(r"^Transfer/sec:\s+(\S+)", text, re.M)
    if m:
        r["transfer_bps"] = to_bytes(m.group(1))
    m = re.search(r"Non-2xx or 3xx responses:\s+(\d+)", text)
    r["non2xx"] = int(m.group(1)) if m else 0
    m = re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", text)
    r["socket_errors"] = sum(int(x) for x in m.groups()) if m else 0
    return {k: v for k, v in r.items() if v is not None}


SB_INTERVAL = re.compile(r"^\[ (\d+)s \] .*?tps: ([\d.]+) qps: ([\d.]+) .*?lat \(ms,95%\): ([\d.]+) err/s: ([\d.]+)")


def parse_sysbench_summary(text):
    r = {}
    pats = {
        "tps": r"^\s+transactions:\s+\d+\s+\(([\d.]+) per sec",
        "qps": r"^\s+queries:\s+\d+\s+\(([\d.]+) per sec",
        "errors": r"^\s+ignored errors:\s+(\d+)",
        "reconnects": r"^\s+reconnects:\s+(\d+)",
        "lat_avg_ms": r"^\s+avg:\s+([\d.]+)",
        "lat_max_ms": r"^\s+max:\s+([\d.]+)",
        "lat_p95_ms": r"^\s+95th percentile:\s+([\d.]+)",
    }
    for k, p in pats.items():
        m = re.search(p, text, re.M)
        if m:
            r[k] = num(m.group(1))
    return r


class RunReader:
    def __init__(self, run_dir, prefix, sender):
        self.dir, self.prefix, self.s = run_dir.rstrip("/"), prefix, sender
        self.run_host = prefix + "run"
        self.hosts = {}           # id -> role
        self.metric_tails = {}    # id -> (Tail, header)
        self.sip_tail = Tail(os.path.join(self.dir, "sip", "stats.csv"))
        self.sip_stats = {"hdr": None, "peak_cc": 0, "peak_cps": 0.0, "last": None, "rt_200_c": None}
        self.uas_tail = Tail(os.path.join(self.dir, "uas", "stats.csv"))
        self.uas_stats = {"hdr": None, "last": None}
        self.guard_tail = Tail(os.path.join(self.dir, "guard.log"))
        self.start_tail = Tail(os.path.join(self.dir, "phases-start.tsv"))
        self.phases_tail = Tail(os.path.join(self.dir, "phases.tsv"))
        self.phase_start = {}     # nome -> inicio (fases iniciadas)
        self.phase_end = {}       # nome -> (inicio, fim) (fases concluidas)
        self.sent_keys = set()
        self.sb_tail = Tail(os.path.join(self.dir, "mysql", "run.txt"))
        self.info_sent = False
        self.info = {}

    def path(self, *p):
        return os.path.join(self.dir, *p)

    def once(self, key):
        if key in self.sent_keys:
            return False
        self.sent_keys.add(key)
        return True

    # ------------------------------------------------------------- hosts e metricas
    def load_hosts(self):
        try:
            with open(self.path("hosts.tsv"), encoding="utf-8") as f:
                for line in f:
                    p = line.rstrip("\n").split("\t")
                    if len(p) >= 2 and re.fullmatch(r"[a-z0-9]+", p[0]):
                        self.hosts.setdefault(p[0], p[1])
        except FileNotFoundError:
            pass

    def poll_metrics(self):
        self.load_hosts()
        for hid in self.hosts:
            if hid not in self.metric_tails:
                self.metric_tails[hid] = [Tail(self.path("metrics", hid + ".csv")), None]
            tail = self.metric_tails[hid]
            for line in tail[0].lines():
                cols = line.split(",")
                if tail[1] is None:
                    if cols and cols[0] == "ts":
                        tail[1] = cols
                    continue
                if len(cols) != len(tail[1]) or not cols[0].isdigit():
                    continue
                row = dict(zip(tail[1], cols))
                ts = int(row.pop("ts"))
                sysv, appv = {}, {}
                for k, v in row.items():
                    val = num(v)
                    if val is None or k == "":
                        continue
                    (sysv if k in SYS_COLS else appv)[k] = val
                host = self.prefix + hid
                if sysv:
                    self.s.add(host, "flt.sys", ts, sysv)
                if appv:
                    self.s.add(host, "flt.app", ts, appv)

    # ------------------------------------------------------------- SIPp
    @staticmethod
    def sipp_rows(tail, state):
        """Linhas novas de um stats.csv do SIPp: (ts, g, n), g(col) texto e n(col) numero.
        state["hdr"] guarda o cabecalho entre chamadas (o arquivo cresce durante o run)."""
        for line in tail.lines():
            cols = line.split(";")
            if state["hdr"] is None:
                if "CurrentTime" in cols:
                    state["hdr"] = {c: i for i, c in enumerate(cols)}
                continue
            h = state["hdr"]
            if len(cols) < len(h) - 1:
                continue

            def g(name, cols=cols, h=h):
                i = h.get(name)
                return cols[i] if i is not None and i < len(cols) else ""

            try:
                ts = float(g("CurrentTime").split("\t")[-1])
            except ValueError:
                continue

            def n(name, g=g):
                v = num(g(name))
                return v if isinstance(v, (int, float)) else 0

            yield ts, g, n

    def poll_sip(self):
        for ts, g, n in self.sipp_rows(self.sip_tail, self.sip_stats):
            ok_p, fail_p = n("SuccessfulCall(P)"), n("FailedCall(P)")
            v = {
                "target_rate": n("TargetRate"), "call_rate": n("CallRate(P)"),
                "current_calls": n("CurrentCall"), "total_created": n("TotalCallCreated"),
                "success_p": ok_p, "failed_p": fail_p,
                "failed_pct_p": round(fail_p * 100.0 / (ok_p + fail_p), 2) if ok_p + fail_p else 0,
                "success_c": n("SuccessfulCall(C)"), "failed_c": n("FailedCall(C)"),
                "failed_retrans_c": n("FailedMaxUDPRetrans(C)"),
                "failed_unexpected_c": n("FailedUnexpectedMessage(C)"),
                "failed_recv_timeout_c": n("FailedTimeoutOnRecv(C)"),
                "retrans_p": n("Retransmissions(P)"), "dead_msgs_p": n("DeadCallMsgs(P)"),
                "watchdog_p": n("WatchdogMajor(P)") + n("WatchdogMinor(P)"),
            }
            for key, col in (("rt_100_ms", "ResponseTime1(P)"), ("rt_200_ms", "ResponseTime2(P)"),
                             ("call_length_ms", "CallLength(P)")):
                ms = sipp_ms(g(col))
                if ms is not None:
                    v[key] = ms
            rt_c = sipp_ms(g("ResponseTime2(C)"))
            if rt_c is not None:
                self.sip_stats["rt_200_c"] = rt_c
            self.sip_stats["peak_cc"] = max(self.sip_stats["peak_cc"], v["current_calls"])
            self.sip_stats["peak_cps"] = max(self.sip_stats["peak_cps"], float(v["call_rate"]))
            self.sip_stats["last"] = v
            self.s.add(self.run_host, "flt.sip", ts, v)

    def poll_uas(self):
        """Atendedor (SIPp UAS, DIDs DIRECT-IP): chamadas que o FS entregou a VM de teste."""
        for ts, g, n in self.sipp_rows(self.uas_tail, self.uas_stats):
            ok_p, fail_p = n("SuccessfulCall(P)"), n("FailedCall(P)")
            v = {
                "call_rate": n("CallRate(P)"), "current_calls": n("CurrentCall"),
                "received_c": n("TotalCallCreated"), "success_p": ok_p, "failed_p": fail_p,
                "failed_pct_p": round(fail_p * 100.0 / (ok_p + fail_p), 2) if ok_p + fail_p else 0,
                "success_c": n("SuccessfulCall(C)"), "failed_c": n("FailedCall(C)"),
                "failed_unexpected_c": n("FailedUnexpectedMessage(C)"),
                "failed_recv_timeout_c": n("FailedTimeoutOnRecv(C)"),
            }
            ms = sipp_ms(g("CallLength(P)"))
            if ms is not None:
                v["call_length_ms"] = ms
            self.uas_stats["last"] = v
            self.s.add(self.run_host, "flt.uas", ts, v)

    # ------------------------------------------------------------- fases, guard, resultados
    def poll_phases(self):
        for line in self.start_tail.lines():
            p = line.split("\t")
            if len(p) >= 2 and p[1].isdigit():
                self.phase_start.setdefault(p[0], int(p[1]))
                if self.once(("start", p[0], p[1])):
                    self.s.add(self.run_host, "flt.phase", int(p[1]), p[0])
        for line in self.phases_tail.lines():
            p = line.split("\t")
            if len(p) < 3 or not (p[1].isdigit() and p[2].isdigit()):
                continue
            name, start, end = p[0], int(p[1]), int(p[2])
            self.phase_start.setdefault(name, start)
            self.phase_end.setdefault(name, (start, end))
            if self.once(("start", name, p[1])):
                self.s.add(self.run_host, "flt.phase", start, name)
            if self.once(("end", name, p[2])):
                self.s.add(self.run_host, "flt.phase", end, "-")
            self.on_phase_end(name, start, end)

    def on_phase_end(self, name, start, end):
        if name.startswith("web_"):
            tgt = name[4:]
            try:
                with open(self.path("web", tgt + ".txt"), encoding="utf-8", errors="replace") as f:
                    text = f.read()
            except FileNotFoundError:
                return
            r = parse_wrk(text)
            if r and self.once(("web", tgt)):
                self.s.add(self.run_host, "flt.web", end, {tgt: r})
        elif name == "mysql":
            self.poll_sysbench_intervals()
            try:
                with open(self.path("mysql", "run.txt"), encoding="utf-8", errors="replace") as f:
                    r = parse_sysbench_summary(f.read())
            except FileNotFoundError:
                return
            if r and self.once(("mysql", "summary")):
                self.s.add(self.run_host, "flt.mysql", end, r)

    def poll_sysbench_intervals(self):
        start = self.phase_start.get("mysql")
        if start is None:
            return
        for line in self.sb_tail.lines():
            m = SB_INTERVAL.match(line)
            if m:
                self.s.add(self.run_host, "flt.mysql", start + int(m.group(1)), {
                    "tps_now": float(m.group(2)), "qps_now": float(m.group(3)),
                    "lat95_now_ms": float(m.group(4)), "err_s_now": float(m.group(5))})

    def poll_guard(self):
        for line in self.guard_tail.lines():
            p = line.split("\t")
            if len(p) >= 3 and p[0].isdigit():
                self.s.add(self.run_host, "flt.guard", int(p[0]), " ".join(p[1:]))

    def first_ts(self):
        if self.phase_start:
            return min(self.phase_start.values())
        try:
            return int(os.path.getmtime(self.path("run.env")))
        except OSError:
            return int(time.time())

    def send_info(self):
        if self.info_sent:
            return
        info = {}
        try:
            with open(self.path("run.env"), encoding="utf-8", errors="replace") as f:
                for line in f:
                    if "=" in line:
                        k, v = line.rstrip("\n").split("=", 1)
                        if re.fullmatch(r"[a-z0-9_]+", k):
                            info[k] = v
        except FileNotFoundError:
            return
        m = re.match(r"\d{8}-\d{6}-?(.*)", info.get("execucao", ""))
        info["label"] = (m.group(1) if m else "") or "-"
        self.s.add(self.run_host, "flt.run.info", self.first_ts(), info)
        self.info = info
        self.info_sent = True

    def poll(self):
        self.poll_phases()
        self.send_info()
        self.poll_metrics()
        self.poll_sip()
        self.poll_uas()
        self.poll_guard()
        self.poll_sysbench_intervals()

    def finish(self):
        self.poll()
        if not self.once(("result",)):
            return
        status, motivo = "ok", ""
        try:
            with open(self.path("abort.txt"), encoding="utf-8", errors="replace") as f:
                status, motivo = "interrompido", f.read().strip()
        except FileNotFoundError:
            pass
        ends = [e for _, e in self.phase_end.values()]
        end = max(ends) if ends else int(time.time())
        # execucao e rotulo no mesmo valor do resultado: uma linha por execucao no dashboard
        r = {"status": status, "motivo": motivo or "-", "duracao_s": max(0, end - self.first_ts()),
             "execucao": self.info.get("execucao") or os.path.basename(self.dir),
             "label": self.info.get("label") or "-"}
        last = self.sip_stats["last"]
        if last:
            ok, fail = last["success_c"], last["failed_c"]
            r.update({"sip_criadas": last["total_created"], "sip_sucesso": ok, "sip_falhas": fail,
                      "sip_falha_pct": round(fail * 100.0 / (ok + fail), 2) if ok + fail else 0,
                      "sip_pico_simultaneas": self.sip_stats["peak_cc"],
                      "sip_pico_cps": self.sip_stats["peak_cps"]})
            if self.sip_stats["rt_200_c"] is not None:
                r["sip_invite_200_ms"] = self.sip_stats["rt_200_c"]
        uas = self.uas_stats["last"]
        if uas:
            r.update({"uas_recebidas": uas["received_c"], "uas_sucesso": uas["success_c"],
                      "uas_falhas": uas["failed_c"]})
            if last:
                r["uas_nao_chegaram"] = max(0, last["total_created"] - uas["received_c"])
        self.s.add(self.run_host, "flt.result", end, r)


def cmd_send(a):
    run_dir = a.run_dir.rstrip("/")
    if not os.path.isdir(run_dir):
        die(E_USAGE, f"diretorio de resultado inexistente: {run_dir}")
    marker = os.path.join(run_dir, "zabbix.sent")
    if not a.follow and not a.dry_run and os.path.exists(marker) and not a.force:
        with open(marker, encoding="utf-8", errors="replace") as f:
            prev = f.read().strip()
        die(E_USAGE, f"execucao ja enviada ({prev}); reenviar duplica os valores no Zabbix. Use --force")
    sender = Sender(a.server, a.port, dry_run=a.dry_run)
    reader = RunReader(run_dir, a.prefix, sender)
    if not a.dry_run:
        with open(marker, "w", encoding="utf-8") as f:
            f.write(f"{a.server}:{a.port} prefixo={a.prefix} modo={'ao vivo' if a.follow else 'importacao'} "
                    f"em {time.strftime('%Y-%m-%d %H:%M:%S %z')}\n")

    if a.follow:
        stop = {"flag": False}

        def on_term(signum, frame):
            stop["flag"] = True

        signal.signal(signal.SIGTERM, on_term)
        signal.signal(signal.SIGINT, signal.SIG_IGN)  # o Ctrl+C e tratado pelo flux-loadtest.sh
        log(f"envio ao vivo para {a.server}:{a.port} (prefixo {a.prefix})")
        while not stop["flag"]:
            reader.poll()
            sender.flush()
            if a.pid and not pid_alive(a.pid):
                break
            for _ in range(int(a.interval * 10)):
                if stop["flag"]:
                    break
                time.sleep(0.1)
    reader.finish()
    ok = False
    for attempt in range(3 if not a.dry_run else 1):
        if sender.flush():
            ok = True
            break
        time.sleep(2 * (attempt + 1))
    log(f"enviados {sender.sent}, processados {sender.processed}, recusados {sender.failed}"
        + ("" if ok else f", nao enviados {len(sender.pending)}"))
    if not ok:
        return E_REMOTE
    return 1 if sender.failed else E_OK


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


# =========================================================================== API


class Api:
    def __init__(self, url, token=None, insecure=False, timeout=30):
        self.url, self.token, self.timeout = url, token, timeout
        self.ctx = ssl._create_unverified_context() if insecure else None
        self.id = 0

    def call(self, method, params=None, auth=True):
        self.id += 1
        body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params or {}, "id": self.id}).encode()
        headers = {"Content-Type": "application/json-rpc"}
        if auth and self.token:
            headers["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(self.url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout, context=self.ctx) as r:
                resp = json.loads(r.read().decode("utf-8", "replace"))
        except urllib.error.URLError as e:
            raise RuntimeError(f"API inacessivel ({self.url}): {e}") from None
        if "error" in resp:
            err = resp["error"]
            raise RuntimeError(f"{method}: {err.get('message')} {err.get('data', '')}".strip())
        return resp["result"]


def read_token(path):
    if not path:
        die(E_CONFIG, "ZABBIX_API_TOKEN_FILE nao definido")
    try:
        st = os.stat(path)
        if st.st_mode & 0o077:
            log(f"AVISO: {path} deveria ter permissao 0600")
        with open(path, encoding="utf-8") as f:
            tok = f.readline().strip()
    except OSError as e:
        die(E_CONFIG, f"token da API ilegivel: {e}")
    if not re.fullmatch(r"[0-9a-f]{64}", tok):
        die(E_CONFIG, f"token da API invalido em {path} (esperado: 64 hexadecimais)")
    return tok


def import_template(api, path):
    with open(path, encoding="utf-8") as f:
        source = f.read()
    yes = {"createMissing": True, "updateExisting": True}
    rules = {
        "template_groups": yes, "templates": yes, "valueMaps": dict(yes, deleteMissing=True),
        "items": dict(yes, deleteMissing=True), "triggers": dict(yes, deleteMissing=True),
        "graphs": dict(yes, deleteMissing=True), "templateLinkage": {"createMissing": True},
        "templateDashboards": dict(yes, deleteMissing=True), "discoveryRules": dict(yes, deleteMissing=True),
    }
    api.call("configuration.import", {"format": "yaml", "rules": rules, "source": source})
    log(f"template importado: {path}")


def enabled_profiles(directory):
    """Perfis com ZABBIX_ENABLED=1 (mesma regra do bin/flux-loadtest-zbx list), ordenados:
    lista de (nome, CPS_CHOICES); CPS_CHOICES vazio = perfil de CPS fixo."""
    profiles = []
    try:
        files = sorted(os.listdir(directory))
    except OSError as e:
        die(E_CONFIG, f"diretorio de perfis ilegivel: {e}")
    for fn in files:
        name = fn[:-5] if fn.endswith(".conf") else ""
        if not PROFILE_RE.fullmatch(name):
            continue
        try:
            with open(os.path.join(directory, fn), encoding="utf-8") as f:
                lines = [l.strip().strip("\r") for l in f]
        except OSError:
            continue
        if any(l in ("ZABBIX_ENABLED=1", 'ZABBIX_ENABLED="1"') for l in lines):
            choices = [l.split("=", 1)[1].strip("\"'") for l in lines if l.startswith("CPS_CHOICES=")]
            profiles.append((name, choices[-1] if choices else ""))
    return profiles


def ensure_agent_interface(api, hostid, addr):
    """Interface agent (passiva, porta 10050) no host; atualiza o IP se mudou."""
    cur = api.call("hostinterface.get", {"hostids": hostid, "filter": {"type": 1},
                                         "output": ["interfaceid", "ip", "main"]})
    if cur:
        main = next((i for i in cur if i["main"] == "1"), cur[0])
        if main["ip"] != addr:
            api.call("hostinterface.update", {"interfaceid": main["interfaceid"], "ip": addr})
            log(f"interface agent atualizada para {addr}")
        return
    api.call("hostinterface.create", {"hostid": hostid, "type": 1, "main": 1, "useip": 1,
                                      "ip": addr, "dns": "", "port": "10050"})
    log(f"interface agent criada: {addr}:10050")


def setup_scripts(api, gid, a):
    """Scripts globais do menu Flux Loadtest (manual host action, executados pelo agent do
    host gen). Identificados por nome + menu: criados ou atualizados (idempotente)."""
    profiles = enabled_profiles(a.profiles_dir)
    usrgrp = "0"
    if a.script_usrgrp:
        g = api.call("usergroup.get", {"filter": {"name": [a.script_usrgrp]}, "output": ["usrgrpid"]})
        if not g:
            die(E_CONFIG, f"grupo de usuarios inexistente no Zabbix: {a.script_usrgrp}")
        usrgrp = g[0]["usrgrpid"]
    # execute_on agent: o Zabbix 7.2 fixa o timeout do script em 30s (o plan usa timeout 25)
    base = {"type": 0, "execute_on": 0, "scope": 2, "menu_path": SCRIPT_MENU, "groupid": gid,
            "usrgrpid": usrgrp, "host_access": 3}
    fixed = [name for name, choices in profiles if not choices]
    pick = {"manualinput": 1, "manualinput_validator_type": 1,
            "manualinput_validator": ",".join(fixed)}  # lista: o primeiro e o padrao
    specs = [
        dict(base, name="Iniciar perfil", command=f"{ZBX_WRAPPER} start {{MANUALINPUT}}",
             manualinput_prompt="Perfil do flux-loadtest a iniciar", **pick,
             confirmation="Iniciar o perfil {MANUALINPUT} em PRODUCAO? A carga atinge os servidores reais.",
             description="Inicia o perfil numa unidade systemd no servidor de testes e retorna na hora."),
        dict(base, name="Plano (dry-run)", command=f"{ZBX_WRAPPER} plan {{MANUALINPUT}}",
             manualinput_prompt="Perfil para ver o plano", **pick,
             description="Mostra o plano do run (--dry-run), sem executar nada."),
        dict(base, name="Parar teste", command=f"{ZBX_WRAPPER} stop",
             confirmation="Parar o teste em execucao? A parada e suave: cooldown e relatorio seguem.",
             description="SIGINT no flux-loadtest.sh (como o Ctrl+C): codigo 6 no resultado."),
        dict(base, name="Estado", command=f"{ZBX_WRAPPER} state",
             description="Execucao em andamento e ultimo resultado de cada perfil (JSON)."),
    ]
    if not profiles:
        log(f"AVISO: nenhum perfil com ZABBIX_ENABLED=1 em {a.profiles_dir}: scripts de perfil nao criados")
    if not fixed:
        specs = [s for s in specs if "manualinput" not in s]
    # Perfil com CPS_CHOICES: um manualinput por script, entao o par e por perfil e a lista e de CPS
    for name, choices in profiles:
        if not choices:
            continue
        cps = {"manualinput": 1, "manualinput_validator_type": 1, "manualinput_validator": choices}
        specs += [
            dict(base, name=f"Iniciar {name} (CPS)", command=f"{ZBX_WRAPPER} start {name} {{MANUALINPUT}}",
                 manualinput_prompt="CPS alvo do teste", **cps,
                 confirmation=f"Iniciar o perfil {name} a {{MANUALINPUT}} CPS em PRODUCAO? A carga atinge os servidores reais.",
                 description="Inicia o perfil com o CPS escolhido numa unidade systemd no servidor de testes e retorna na hora."),
            dict(base, name=f"Plano {name} (CPS)", command=f"{ZBX_WRAPPER} plan {name} {{MANUALINPUT}}",
                 manualinput_prompt="CPS para ver o plano", **cps,
                 description="Mostra o plano do run (--dry-run) e os limites dos FS para o CPS escolhido, sem executar nada."),
        ]
    current = {(s["name"], s["menu_path"]): s["scriptid"] for s in
               api.call("script.get", {"output": ["scriptid", "name", "menu_path"],
                                       "filter": {"menu_path": [SCRIPT_MENU]}})}
    for spec in specs:
        sid = current.get((spec["name"], SCRIPT_MENU))
        if sid:
            api.call("script.update", dict(spec, scriptid=sid))
            log(f"script atualizado: {SCRIPT_MENU}/{spec['name']}")
        else:
            api.call("script.create", spec)
            log(f"script criado: {SCRIPT_MENU}/{spec['name']}")
    if profiles:
        log(f"perfis no menu: {', '.join(name for name, _ in profiles)} (o agent so aceita os do include gerado por flux-loadtest-zbx agent-conf)")


# Dashboard global de resultados. Tipos de campo de widget da API do Zabbix 7.x.
WF_INT, WF_STR, WF_GROUP, WF_ITEM = 0, 1, 2, 4
DASH_COLS = 72  # grade do dashboard no Zabbix 7.x
RESULT_COLUMNS = [
    ("Execucao", "flt.result[execucao]"), ("Status", "flt.result[status]"),
    ("Criadas", "flt.result[sip_criadas]"), ("Falhas (%)", "flt.result[sip_falha_pct]"),
    ("Pico simultaneas", "flt.result[sip_pico_simultaneas]"), ("Pico CPS", "flt.result[sip_pico_cps]"),
    ("INVITE -> 200", "flt.result[sip_invite_200_ms]"),
    ("Nao chegaram ao atendedor", "flt.result[uas_nao_chegaram]"), ("Motivo", "flt.result[motivo]"),
]


def wfield(ftype, name, value):
    return {"type": ftype, "name": name, "value": value}


def svggraph(name, x, y, datasets, w=DASH_COLS // 2, h=5):
    """Grafico por padrao de host e de nome de item: vale para qualquer prefixo e host novo."""
    fields = [wfield(WF_INT, "legend_lines", 2)]
    for i, (hosts, items, color, axis) in enumerate(datasets):
        fields += [wfield(WF_INT, f"ds.{i}.dataset_type", 1), wfield(WF_STR, f"ds.{i}.color", color),
                   wfield(WF_INT, f"ds.{i}.axisy", axis)]
        fields += [wfield(WF_STR, f"ds.{i}.hosts.{j}", hst) for j, hst in enumerate(hosts)]
        fields += [wfield(WF_STR, f"ds.{i}.items.{j}", it) for j, it in enumerate(items)]
    if any(d[3] for d in datasets):
        fields.append(wfield(WF_INT, "righty", 1))
    return {"type": "svggraph", "name": name, "x": x, "y": y, "width": w, "height": h,
            "view_mode": 0, "fields": fields}


def problems_widget(name, x, y, h, gid, lines):
    """Problemas do grupo Flux Loadtest. show_suppressed: os hosts flt-* ficam numa manutencao com
    coleta (sem alertas ao suporte) e, sem ele, os problemas do teste nao aparecem no widget.
    show 2 (historico): os gatilhos recuperam por nodata no fim do teste e, no modo padrao (recentes),
    sumiriam do dashboard minutos depois; o historico mantem os resolvidos para ler a execucao."""
    return {"type": "problems", "name": name, "x": x, "y": y, "width": DASH_COLS, "height": h, "view_mode": 0,
            "fields": [wfield(WF_GROUP, "groupids.0", gid), wfield(WF_INT, "show", 2),
                       wfield(WF_INT, "show_lines", lines),
                       wfield(WF_INT, "show_suppressed", 1), wfield(WF_INT, "show_tags", 3),
                       wfield(WF_STR, "tag_priority", "componente,tipo"), wfield(WF_INT, "show_opdata", 1)]}


def dashboard_pages(p, gid, result_items):
    """Paginas do dashboard. p = prefixo dos hosts; result_items = {chave: itemid} do host run."""
    run, half = p + "run*", DASH_COLS // 2
    cols = []
    for i, (label, key) in enumerate((c for c in RESULT_COLUMNS if c[1] in result_items)):
        cols += [wfield(WF_STR, f"columns.{i}.name", label), wfield(WF_ITEM, f"columns.{i}.itemid", result_items[key])]
    resultado = [
        {"type": "itemhistory", "name": "Resultado de cada execucao", "x": 0, "y": 0, "width": DASH_COLS,
         "height": 7, "view_mode": 0,
         "fields": cols + [wfield(WF_INT, "layout", 1), wfield(WF_INT, "show_lines", 50),
                            wfield(WF_INT, "show_timestamp", 1)]},
        svggraph("CPS: alvo e realizado", 0, 7, [([run], ["SIPp: CPS alvo", "SIPp: CPS no periodo"], "2774A4", 0)]),
        svggraph("Chamadas simultaneas", half, 7, [([run], ["SIPp: chamadas simultaneas",
                                                         "Atendedor: chamadas simultaneas"], "1A7C11", 0)]),
        svggraph("INVITE -> 100 e INVITE -> 200", 0, 12, [([run], ["SIPp: INVITE -> 100*", "SIPp: INVITE -> 200*"],
                                                           "F63100", 0)]),
        svggraph("Falhas e retransmissoes por periodo", half, 12,
                 [([run], ["SIPp: falhas no periodo (% das encerradas)"], "F63100", 0),
                  ([run], ["SIPp: retransmissoes no periodo"], "A54F10", 1)]),
        problems_widget("Problemas do teste de carga", 0, 17, 4, gid, 25),
    ]
    # Gargalos: problema (gatilho tipo=gargalo ou sintoma) e, por componente, a carga contra o sintoma.
    # Leitura no ZABBIX.md (deploy/stfc-completo), secao "Onde esta o gargalo".
    fs, os_, db = p + "fs*", p + "opensips*", p + "db*"
    gargalos = [
        problems_widget("Gargalos e sintomas (tags componente e tipo; inclui os suprimidos pela manutencao)",
                        0, 0, 6, gid, 50),
        svggraph("SIP: INVITE -> 200 (esq.) x chamadas simultaneas (dir.)", 0, 6,
                 [([run], ["SIPp: INVITE -> 200*"], "F63100", 0),
                  ([run], ["SIPp: chamadas simultaneas"], "2774A4", 1)]),
        svggraph("FreeSWITCH: tempo de resposta em ms (esq.) x sessoes e handles do banco % do max (dir.)", half, 6,
                 [([fs], ["FreeSWITCH: tempo de resposta do fs_cli*", "FreeSWITCH: tempo do show calls count*"], "F63100", 0),
                  ([fs], ["FreeSWITCH: sessoes (% do max_sessions)",
                          "FreeSWITCH: handles do banco em uso (% do max-db-handles)"], "2774A4", 1)]),
        svggraph("Thread mais carregada por processo (100 = 1 nucleo)", 0, 11,
                 [([p + "*"], ["FreeSWITCH: thread mais carregada*", "OpenSIPS: thread mais carregada*",
                               "MySQL: thread mais carregada*", "SIPp: thread mais carregada*"], "6C59DC", 0)]),
        svggraph("OpenSIPS: ocupacao em % (esq.) x dialogos ativos (dir.)", half, 11,
                 [([os_], ["OpenSIPS: load", "OpenSIPS: destino do load_balancer mais cheio",
                           "OpenSIPS: memoria compartilhada usada"], "F63100", 0),
                  ([os_], ["OpenSIPS: dialogos ativos"], "2774A4", 1)]),
        svggraph("MySQL: latencia media em ms (esq.) x consultas por segundo (dir.)", 0, 16,
                 [([db], ["MySQL: latencia media das consultas"], "F63100", 0),
                  ([db], ["MySQL: consultas"], "2774A4", 1)]),
        svggraph("MySQL: consultas executando e conexoes % do max (esq.) x flow control % (dir.)", half, 16,
                 [([db], ["MySQL: threads em execucao", "MySQL: conexoes (% do max_connections)"], "A54F10", 0),
                  ([db], ["PXC: replicacao pausada por flow control"], "F63100", 1)]),
        svggraph("Rede: descartes por servidor (por segundo)", 0, 21,
                 [([p + "*"], ["Erros de buffer de recepcao UDP", "Descartes na interface (recepcao)"], "F63100", 0)]),
        svggraph("CPU: total x nucleo mais carregado x espera de disco (%)", half, 21,
                 [([p + "*"], ["CPU total", "CPU do nucleo mais carregado", "CPU iowait"], "2774A4", 0)]),
    ]
    servidores = [
        svggraph("CPU total por servidor", 0, 0, [([p + "*"], ["CPU total"], "2774A4", 0)]),
        svggraph("Memoria usada por servidor", half, 0, [([p + "*"], ["Memoria usada"], "6C59DC", 0)]),
        svggraph("FreeSWITCH: sessoes e chamadas", 0, 5,
                 [([p + "fs*"], ["FreeSWITCH: sessoes", "FreeSWITCH: chamadas"], "1A7C11", 0)]),
        svggraph("OpenSIPS: memoria compartilhada e dialogos", half, 5,
                 [([p + "opensips*"], ["OpenSIPS: memoria compartilhada usada"], "F63100", 0),
                  ([p + "opensips*"], ["OpenSIPS: dialogos ativos", "OpenSIPS: transacoes em uso"], "2774A4", 1)]),
        svggraph("MySQL: consultas e CPU", 0, 10,
                 [([p + "db*"], ["MySQL: consultas"], "A54F10", 0), ([p + "db*"], ["MySQL: CPU*"], "6C59DC", 1)]),
        svggraph("Pacotes recebidos por servidor", half, 10, [([p + "*"], ["Pacotes recebidos"], "AC8C14", 0)]),
    ]
    return [{"name": "Resultados", "widgets": resultado}, {"name": "Gargalos", "widgets": gargalos},
            {"name": "Servidores", "widgets": servidores}]


def setup_dashboard(api, prefix, gid):
    """Dashboard global "Flux Loadtest - Resultados (<prefixo>)": criado ou atualizado (idempotente).
    Graficos por padrao de host e item; a tabela de resultados usa os itens do host <prefixo>run."""
    name = f"Flux Loadtest - Resultados ({prefix})"
    run = api.call("host.get", {"filter": {"host": [prefix + "run"]}, "output": ["hostid"]})
    result_items = {}
    if run:
        for i in api.call("item.get", {"hostids": run[0]["hostid"], "output": ["itemid", "key_"],
                                       "filter": {"key_": [k for _, k in RESULT_COLUMNS]}}):
            result_items[i["key_"]] = i["itemid"]
    missing = [k for _, k in RESULT_COLUMNS if k not in result_items]
    if missing:
        log("AVISO: itens ausentes no host " + prefix + "run (" + ", ".join(missing)
            + "): reimporte o template (--import-template); a tabela fica sem essas colunas")
    spec = {"name": name, "display_period": 60, "auto_start": 0, "pages": dashboard_pages(prefix, gid, result_items)}
    found = api.call("dashboard.get", {"filter": {"name": [name]}, "output": ["dashboardid"]})
    if found:
        api.call("dashboard.update", dict(spec, dashboardid=found[0]["dashboardid"]))
        log(f"dashboard atualizado: {name}")
    else:
        api.call("dashboard.create", spec)
        log(f"dashboard criado: {name}")


def cmd_setup(a):
    api = Api(a.api_url, read_token(a.token_file), a.insecure)
    log(f"API {a.api_url}: Zabbix {api.call('apiinfo.version', auth=False)}")
    if a.template:
        import_template(api, a.template)
    groups = api.call("hostgroup.get", {"filter": {"name": [HOST_GROUP]}, "output": ["groupid"]})
    gid = groups[0]["groupid"] if groups else api.call("hostgroup.create", {"name": HOST_GROUP})["groupids"][0]
    names = sorted({t for ts in ROLE_TEMPLATES.values() for t in ts} | ({TRIGGER_TEMPLATE} if a.gen_agent else set()))
    tpls = {t["host"]: t["templateid"] for t in
            api.call("template.get", {"filter": {"host": names}, "output": ["host"]})}
    missing = [n for n in names if n not in tpls]
    if missing:
        die(E_CONFIG, "templates ausentes no Zabbix: " + ", ".join(missing) + " (use --template para importar)")

    specs = [("run", "run", "", "execucao")]
    for h in a.host:
        p = h.split(":", 3)
        if len(p) < 2 or p[1] not in ROLE_TEMPLATES or not re.fullmatch(r"[a-z0-9]+", p[0]):
            die(E_USAGE, f"--host invalido: {h} (esperado id:papel[:endereco[:nome]])")
        specs.append((p[0], p[1], p[2] if len(p) > 2 else "", p[3] if len(p) > 3 else ""))

    for hid, role, addr, label in specs:
        host = a.prefix + hid
        agent = role == "gen" and a.gen_agent
        if agent:
            addr = a.gen_agent
        visible = f"{host} ({label or role}{', ' + addr if addr else ''})"
        links = [{"templateid": tpls[t]} for t in ROLE_TEMPLATES[role] + ([TRIGGER_TEMPLATE] if agent else [])]
        macros = []
        if role == "gen" and a.gen_cpu_max:
            macros.append({"macro": "{$FLT.CPU.MAX}", "value": str(a.gen_cpu_max)})
        found = api.call("host.get", {"filter": {"host": [host]}, "output": ["hostid"]})
        if found:
            hostid = found[0]["hostid"]
            api.call("host.update", {"hostid": hostid, "name": visible})
            if agent:
                ensure_agent_interface(api, hostid, addr)
            api.call("host.massadd", {"hosts": [{"hostid": hostid}], "templates": links,
                                      "groups": [{"groupid": gid}]})
            for m in macros:
                cur = api.call("usermacro.get", {"hostids": hostid, "filter": {"macro": m["macro"]}})
                if cur:
                    api.call("usermacro.update", {"hostmacroid": cur[0]["hostmacroid"], "value": m["value"]})
                else:
                    api.call("usermacro.create", dict(m, hostid=hostid))
            log(f"host atualizado: {host}")
        else:
            iface = [{"type": 1, "main": 1, "useip": 1, "ip": addr, "dns": "", "port": "10050"}] if agent else []
            api.call("host.create", {"host": host, "name": visible, "groups": [{"groupid": gid}],
                                     "templates": links, "macros": macros, "interfaces": iface,
                                     "tags": [{"tag": "flux-loadtest", "value": role}],
                                     "description": "Criado pelo flux-loadtest (WEB-1437). Dados por trapper."})
            log(f"host criado: {host}")
    if a.scripts:
        if not a.gen_agent:
            die(E_USAGE, "--scripts exige --gen-agent IP (os scripts rodam no agent do host gen)")
        setup_scripts(api, gid, a)
    try:
        setup_dashboard(api, a.prefix, gid)
    except RuntimeError as e:
        # hosts e templates ja estao prontos; o dashboard depende de permissao do usuario do token
        log(f"AVISO: dashboard nao criado: {e}")
        return E_REMOTE
    return E_OK


def cmd_check(a):
    rc = E_OK
    if a.api_url:
        try:
            api = Api(a.api_url, read_token(a.token_file) if a.token_file else None, a.insecure)
            log(f"API {a.api_url}: Zabbix {api.call('apiinfo.version', auth=False)}")
            if a.token_file:
                hosts = api.call("host.get", {"search": {"host": a.prefix}, "startSearch": True, "output": ["host"]})
                log(f"hosts com prefixo {a.prefix}: {', '.join(sorted(h['host'] for h in hosts)) or 'nenhum (rode zabbix setup)'}")
        except RuntimeError as e:
            log(f"AVISO: {e}")
            rc = E_REMOTE
    if a.server:
        s = Sender(a.server, a.port)
        s.add(a.prefix + "run", "flt.phase", time.time(), "-")
        if s.flush():
            log(f"trapper {a.server}:{a.port}: ok (processados {s.processed}, recusados {s.failed})")
            if s.failed:
                log("AVISO: valor recusado: o host " + a.prefix + "run nao existe ou nao tem o template")
                rc = E_REMOTE
        else:
            rc = E_REMOTE
    return rc


def cmd_bootstrap(a):
    """Laboratorio: senha inicial do Admin -> senha do .env; cria o token de API."""
    api = Api(a.api_url, insecure=a.insecure)
    with open(a.new_password_file, encoding="utf-8") as f:
        newpw = f.readline().strip()
    if len(newpw) < 8:
        die(E_CONFIG, "senha nova muito curta")
    # O frontend responde antes de o server terminar de criar o schema: tenta por ate 5 min.
    changed = None
    last = ""
    for _ in range(60):
        try:
            api.token = api.call("user.login", {"username": a.user, "password": newpw}, auth=False)
            changed = True
            break
        except RuntimeError as e:
            last = str(e)
        try:
            api.token = api.call("user.login", {"username": a.user, "password": a.password}, auth=False)
            changed = False
            break
        except RuntimeError as e:
            last = str(e)
        time.sleep(5)
    if changed is None:
        die(E_REMOTE, f"login na API do Zabbix falhou por 5 min ({a.api_url}): {last}")
    if not changed:
        uid_ = api.call("user.get", {"filter": {"username": a.user}, "output": ["userid"]})[0]["userid"]
        api.call("user.update", {"userid": uid_, "current_passwd": a.password, "passwd": newpw})
        log(f"senha do {a.user} trocada")
        api.token = api.call("user.login", {"username": a.user, "password": newpw}, auth=False)
    # A imagem oficial cria o host "Zabbix server" monitorado por agente, que nao existe no
    # container: desativado para nao gerar o alerta permanente de agente indisponivel.
    for h in api.call("host.get", {"filter": {"host": ["Zabbix server"], "status": 0}, "output": ["hostid"]}):
        api.call("host.update", {"hostid": h["hostid"], "status": 1})
        log("host padrao 'Zabbix server' desativado (sem agente no laboratorio)")
    uid_ = api.call("user.get", {"filter": {"username": a.user}, "output": ["userid"]})[0]["userid"]
    found = api.call("token.get", {"filter": {"name": a.token_name, "userid": uid_}, "output": ["tokenid"]})
    tid = found[0]["tokenid"] if found else api.call("token.create", {"name": a.token_name, "userid": uid_})["tokenids"][0]
    tok = api.call("token.generate", [tid])[0]["token"]
    old = os.umask(0o077)
    try:
        with open(a.token_file, "w", encoding="utf-8") as f:
            f.write(tok + "\n")
    finally:
        os.umask(old)
    log(f"token de API gravado em {a.token_file}")
    return E_OK


# =========================================================================== CLI


def main():
    ap = argparse.ArgumentParser(description="Integracao do flux-loadtest com o Zabbix")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common_api(p):
        p.add_argument("--api-url", default=os.environ.get("ZABBIX_API_URL", ""))
        p.add_argument("--token-file", default=os.environ.get("ZABBIX_API_TOKEN_FILE", ""))
        p.add_argument("--insecure", action="store_true", help="nao valida o certificado HTTPS da API")

    def common_trap(p):
        p.add_argument("--server", default=os.environ.get("ZABBIX_SERVER", ""))
        p.add_argument("--port", type=int, default=int(os.environ.get("ZABBIX_PORT", "10051")))
        p.add_argument("--prefix", default=os.environ.get("ZABBIX_HOST_PREFIX", "flt-"))

    p = sub.add_parser("send", help="envia uma execucao ao Zabbix")
    p.add_argument("run_dir")
    common_trap(p)
    p.add_argument("--follow", action="store_true", help="acompanha a execucao em andamento")
    p.add_argument("--pid", type=int, default=0, help="com --follow: encerra quando este processo terminar")
    p.add_argument("--interval", type=float, default=2.0)
    p.add_argument("--dry-run", action="store_true", help="mostra os valores sem enviar")
    p.add_argument("--force", action="store_true", help="reenvia uma execucao ja enviada")

    p = sub.add_parser("setup", help="cria grupo e hosts e vincula os templates")
    common_api(p)
    p.add_argument("--prefix", default=os.environ.get("ZABBIX_HOST_PREFIX", "flt-"))
    p.add_argument("--host", action="append", default=[], help="id:papel[:endereco[:nome]] (repetivel)")
    p.add_argument("--template", help="importa este YAML antes")
    p.add_argument("--gen-cpu-max", type=int, default=0)
    p.add_argument("--gen-agent", default="", help="IP do zabbix-agentd do servidor de testes: interface "
                   "agent e template de disparo no host gen")
    p.add_argument("--scripts", action="store_true", help="cria/atualiza os scripts do menu Flux Loadtest")
    p.add_argument("--script-usrgrp", default="", help="grupo de usuarios que pode executar os scripts")
    p.add_argument("--profiles-dir", default="/etc/flux-loadtest/profiles.d")

    p = sub.add_parser("check", help="testa a API e o trapper")
    common_api(p)
    common_trap(p)

    p = sub.add_parser("bootstrap", help="laboratorio: troca a senha do Admin e cria token")
    common_api(p)
    p.add_argument("--user", default="Admin")
    p.add_argument("--password", default="zabbix", help="senha inicial da imagem oficial")
    p.add_argument("--new-password-file", required=True)
    p.add_argument("--token-name", default="flux-loadtest")

    a = ap.parse_args()
    if a.cmd == "send" and not a.server and not a.dry_run:
        die(E_CONFIG, "ZABBIX_SERVER nao definido")
    if a.cmd in ("setup", "bootstrap") and not a.api_url:
        die(E_CONFIG, "ZABBIX_API_URL nao definido")
    if a.cmd == "setup" and a.gen_agent and not re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", a.gen_agent):
        die(E_USAGE, f"--gen-agent invalido: {a.gen_agent} (IPv4)")
    if a.cmd == "bootstrap" and not a.token_file:
        die(E_CONFIG, "--token-file obrigatorio")
    handler = {"send": cmd_send, "setup": cmd_setup, "check": cmd_check, "bootstrap": cmd_bootstrap}[a.cmd]
    try:
        sys.exit(handler(a))
    except RuntimeError as e:
        die(E_REMOTE, str(e))


if __name__ == "__main__":
    main()
