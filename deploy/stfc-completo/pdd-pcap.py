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

Modo --fs IP:PORTA: captura feita no proprio FreeSWITCH, para separar o tempo dentro dele. A perna A
(OpenSIPS -> FS) e a perna B (bridge, FS -> OpenSIPS) passam pelo mesmo socket e casam pelo DID:
  trying    INVITE A recebido  ate  100 Trying enviado (fila do sofia-sip)
  dialplan  INVITE A recebido  ate  INVITE B enviado (dialplan Lua + MySQL, criacao da perna B)
  fora      INVITE B enviado   ate  200 B recebido (OpenSIPS, atendedor e rede)
  atende    200 B recebido     ate  200 A enviado (o FS atende a perna A)
  total     INVITE A recebido  ate  200 A enviado
  python3 pdd-pcap.py /root/fs2.pcap --fs 200.159.177.162:5070 [--faixa 60]
Captura no FS: tcpdump -i ens192 -nn -s0 -w /root/fs2.pcap 'udp port 5070'

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


def sip_did(pl):
    """(linha inicial, metodo do CSeq, DID) de uma mensagem SIP; DID da R-URI no INVITE, do To nas respostas."""
    first = pl.split(b"\r\n", 1)[0]
    cseq = RE_CSEQ.search(pl)
    method = cseq.group(1).upper() if cseq else b""
    m = RE_RURI.match(first) if first.startswith(b"INVITE ") else RE_TO.search(pl)
    return first, method, (m.group(1).decode(errors="replace") if m else None)


def modo_fs(a):
    """Tempos dentro do FreeSWITCH, com a captura feita nele (veja o cabecalho)."""
    fs_ip, _, fs_port = a.fs.rpartition(":")
    if not fs_ip or not fs_port.isdigit():
        raise SystemExit(f"--fs invalido (use IP:PORTA): {a.fs}")
    fs_port = int(fs_port)
    a_inv, a_100, b_inv, b_200, a_200 = {}, {}, {}, {}, {}
    retrans = defaultdict(int)
    for ts, src, sport, dst, dport, pl in packets(a.pcap):
        entra = dst == fs_ip and dport == fs_port
        sai = src == fs_ip and sport == fs_port
        if not (entra or sai):
            continue
        first, method, did = sip_did(pl)
        if method != b"INVITE" or not did:
            continue
        if first.startswith(b"INVITE "):
            if entra:
                if did in a_inv:
                    retrans[did] += 1                # mesma perna A de novo: o OpenSIPS retransmitiu
                else:
                    a_inv[did] = ts
            elif did in a_inv and did not in b_inv:
                b_inv[did] = ts                      # bridge saindo do FS
        elif first.startswith(b"SIP/2.0 100") and sai and did in a_inv:
            a_100.setdefault(did, ts)
        elif first.startswith(b"SIP/2.0 200"):
            if entra and did in b_inv:
                b_200.setdefault(did, ts)            # 200 da perna B
            elif sai and did in b_200:
                a_200.setdefault(did, ts)            # 200 do FS para a perna A

    dids = [d for d in a_inv if d in a_100 and d in b_inv and d in b_200 and d in a_200]
    if not dids:
        print(f"nenhuma chamada completa na captura (confira --fs {a.fs} e o filtro do tcpdump)")
        return 1
    inicio = min(a_inv[d] for d in dids)
    n_ret = sum(1 for d in dids if retrans[d])
    print(f"captura {a.pcap} no FS {a.fs}: {len(a_inv)} INVITE da perna A, {len(dids)} chamadas completas,"
          f" {n_ret} com INVITE retransmitido pelo OpenSIPS\n")

    nomes = ("trying", "dialplan", "fora", "atende", "total")
    total = defaultdict(list)
    por_faixa = defaultdict(lambda: defaultdict(list))
    for d in dids:
        v = dict(zip(nomes, (a_100[d] - a_inv[d], b_inv[d] - a_inv[d], b_200[d] - b_inv[d],
                             a_200[d] - b_200[d], a_200[d] - a_inv[d])))
        for g in (total, por_faixa[int((a_inv[d] - inicio) // a.faixa)]):
            for k in nomes:
                g[k].append(v[k])
    print("== Tempos por chamada")
    for k in nomes:
        print(resumo(k, total[k]))
    print(f"\n== Por faixa de {a.faixa} s desde o primeiro INVITE (com CPS constante, as simultaneas sobem)")
    print(f"  {'faixa':<12} {'chamadas':>8} {'CPS':>6} {'trying p90':>11} {'dialplan p90':>13}"
          f" {'fora p90':>9} {'atende p50':>11} {'atende p90':>11} {'total p90':>10}")
    for b in sorted(por_faixa):
        g = por_faixa[b]
        print(f"  {b * a.faixa:>4}-{(b + 1) * a.faixa:<6}s {len(g['total']):>8} {len(g['total']) / a.faixa:>6.1f}"
              f" {pct(g['trying'], 90) * 1000:>9.0f}ms {pct(g['dialplan'], 90) * 1000:>11.0f}ms"
              f" {pct(g['fora'], 90) * 1000:>7.0f}ms {statistics.median(g['atende']) * 1000:>9.0f}ms"
              f" {pct(g['atende'], 90) * 1000:>9.0f}ms {pct(g['total'], 90) * 1000:>8.0f}ms")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("pcap")
    ap.add_argument("--gen", default="200.159.177.165", help="IP do gerador (originador e atendedor)")
    ap.add_argument("--uas-port", type=int, default=5090)
    ap.add_argument("--fs", help="IP:PORTA do FreeSWITCH: captura feita no proprio FS (tempos dentro dele)")
    ap.add_argument("--faixa", type=int, default=20, help="tamanho da faixa de tempo, em segundos")
    a = ap.parse_args()
    if a.faixa < 1:
        raise SystemExit("--faixa minimo: 1")
    if a.fs:
        return modo_fs(a)

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
