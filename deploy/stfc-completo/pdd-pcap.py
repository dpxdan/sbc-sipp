#!/usr/bin/env python3
"""
pdd-pcap.py - onde fica o atraso pos-discagem (INVITE -> 200) do teste de carga (WEB-1437)

Le a captura SIP feita no gerador (.165) durante um degrau e mede, por chamada (DID):
  ida    INVITE do originador -> OpenSIPS  ate  INVITE do bridge chegando ao atendedor
         (OpenSIPS, load_balancer, dialplan Lua + MySQL, bridge)
  volta  200 do atendedor  ate  200 chegando ao originador (FS e OpenSIPS repassando)
  total  INVITE do originador ate o 200 dele
Agrupa por FreeSWITCH (Via do INVITE do bridge) e por faixa de tempo (a carga sobe na rampa).

Uso (no .165, somente leitura):
  python3 pdd-pcap.py /root/degrau.pcap [--gen 200.159.177.165] [--uas-port 5090] [--faixa 20]

Captura: tcpdump -i ens192 -nn -s0 -w /root/degrau.pcap 'udp port 5060 or udp port 5090'
So biblioteca padrao (le pcap Ethernet ou Linux cooked, IPv4/UDP, com ou sem VLAN).
"""

import argparse
import re
import statistics
import struct
import sys
from collections import defaultdict

RE_RURI = re.compile(rb"^INVITE sip:([^@;>\s]+)@", re.I)
RE_TO = re.compile(rb"^(?:To|t):\s*[^\r\n]*?sip:([^@;>\s]+)@", re.I | re.M)
RE_CSEQ = re.compile(rb"^CSeq:\s*\d+\s+(\w+)", re.I | re.M)
RE_VIA = re.compile(rb"^(?:Via|v):\s*SIP/2\.0/\w+\s+([^;,\s]+)", re.I | re.M)


def packets(path):
    """(ts, src_ip, src_port, dst_ip, dst_port, payload) de cada UDP/IPv4 do pcap."""
    with open(path, "rb") as f:
        gh = f.read(24)
        if len(gh) < 24:
            raise SystemExit("pcap vazio ou invalido")
        magic = gh[:4]
        if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
            end = "<"
        elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
            end = ">"
        else:
            raise SystemExit("formato nao suportado (use pcap, nao pcapng: tcpdump -w)")
        nano = magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d")
        linktype = struct.unpack(end + "I", gh[20:24])[0]
        while True:
            rh = f.read(16)
            if len(rh) < 16:
                return
            sec, frac, incl, _ = struct.unpack(end + "IIII", rh)
            data = f.read(incl)
            ts = sec + frac / (1e9 if nano else 1e6)
            if linktype == 1:            # Ethernet
                off, etype = 14, struct.unpack(">H", data[12:14])[0]
                while etype in (0x8100, 0x88A8) and len(data) >= off + 4:
                    etype = struct.unpack(">H", data[off + 2:off + 4])[0]
                    off += 4
            elif linktype == 113:        # Linux cooked (-i any)
                off, etype = 16, struct.unpack(">H", data[14:16])[0]
            else:
                raise SystemExit(f"linktype {linktype} nao suportado (capture com -i <interface>)")
            if etype != 0x0800 or len(data) < off + 20:
                continue
            ihl = (data[off] & 0x0F) * 4
            if data[off + 9] != 17:
                continue
            src = ".".join(str(b) for b in data[off + 12:off + 16])
            dst = ".".join(str(b) for b in data[off + 16:off + 20])
            u = off + ihl
            if len(data) < u + 8:
                continue
            sport, dport = struct.unpack(">HH", data[u:u + 4])
            yield ts, src, sport, dst, dport, data[u + 8:]


def pct(values, p):
    if not values:
        return 0.0
    s = sorted(values)
    k = min(len(s) - 1, max(0, int(round(p / 100.0 * (len(s) - 1)))))
    return s[k]


def resumo(nome, values):
    if not values:
        return f"  {nome:<22} sem dados"
    ms = [v * 1000 for v in values]
    return (f"  {nome:<22} n={len(ms):<6} mediana={statistics.median(ms):8.1f}  p90={pct(ms, 90):8.1f}"
            f"  p99={pct(ms, 99):8.1f}  max={max(ms):8.1f} ms")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("pcap")
    ap.add_argument("--gen", default="200.159.177.165", help="IP do gerador (originador e atendedor)")
    ap.add_argument("--uas-port", type=int, default=5090)
    ap.add_argument("--faixa", type=int, default=20, help="tamanho da faixa de tempo, em segundos")
    a = ap.parse_args()

    t0, t1, t2, t3, node = {}, {}, {}, {}, {}
    for ts, src, sport, dst, dport, pl in packets(a.pcap):
        first = pl.split(b"\r\n", 1)[0]
        cseq = RE_CSEQ.search(pl)
        if not cseq or cseq.group(1).upper() != b"INVITE":
            continue
        if first.startswith(b"INVITE "):
            m = RE_RURI.match(first)
            if not m:
                continue
            did = m.group(1).decode(errors="replace")
            if src == a.gen and dport != a.uas_port and did not in t0:
                t0[did] = ts                         # originador -> OpenSIPS
            elif dst == a.gen and dport == a.uas_port and did not in t1:
                t1[did] = ts                         # bridge chegando ao atendedor
                vias = [v.decode(errors="replace") for v in RE_VIA.findall(pl)]
                # Via de cima = OpenSIPS; a seguinte = o FreeSWITCH que fez o bridge
                node[did] = vias[1] if len(vias) > 1 else (vias[0] if vias else "?")
        elif first.startswith(b"SIP/2.0 200"):
            m = RE_TO.search(pl)
            if not m:
                continue
            did = m.group(1).decode(errors="replace")
            if src == a.gen and sport == a.uas_port and did not in t2:
                t2[did] = ts                         # 200 do atendedor
            elif dst == a.gen and dport != a.uas_port and did not in t3:
                t3[did] = ts                         # 200 chegando ao originador

    dids = [d for d in t0 if d in t1 and d in t2 and d in t3]
    if not dids:
        print("nenhuma chamada completa na captura (confira --gen e o filtro do tcpdump)")
        return 1
    inicio = min(t0[d] for d in dids)
    print(f"captura {a.pcap}: {len(t0)} INVITE do originador, {len(dids)} chamadas completas\n")

    por_no = defaultdict(lambda: {"ida": [], "volta": [], "total": []})
    por_faixa = defaultdict(lambda: {"ida": [], "volta": [], "total": []})
    for d in dids:
        ida, volta, total = t1[d] - t0[d], t3[d] - t2[d], t3[d] - t0[d]
        for g in (por_no[node[d]], por_faixa[int((t0[d] - inicio) // a.faixa)]):
            g["ida"].append(ida)
            g["volta"].append(volta)
            g["total"].append(total)

    print("== Por FreeSWITCH (Via do bridge)")
    for n in sorted(por_no):
        print(f"-- {n}")
        for k in ("ida", "volta", "total"):
            print(resumo(k, por_no[n][k]))
    print(f"\n== Por faixa de {a.faixa} s desde o primeiro INVITE (a rampa sobe o CPS)")
    print(f"  {'faixa':<12} {'chamadas':>8} {'CPS':>6} {'ida p50':>9} {'ida p90':>9} {'volta p50':>10} {'total p50':>10} {'total p90':>10}")
    for b in sorted(por_faixa):
        g = por_faixa[b]
        print(f"  {b * a.faixa:>4}-{(b + 1) * a.faixa:<6}s {len(g['total']):>8} {len(g['total']) / a.faixa:>6.1f}"
              f" {statistics.median(g['ida']) * 1000:>8.0f}ms {pct(g['ida'], 90) * 1000:>8.0f}ms"
              f" {statistics.median(g['volta']) * 1000:>9.0f}ms {statistics.median(g['total']) * 1000:>9.0f}ms"
              f" {pct(g['total'], 90) * 1000:>9.0f}ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
