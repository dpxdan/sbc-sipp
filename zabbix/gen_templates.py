#!/usr/bin/env python3
"""
gen_templates.py - gera zabbix/flux-loadtest-templates.yaml (WEB-1437)

Os templates descrevem os dados que o lib/flux_zabbix.py envia por trapper:

  flt.sys     JSON com as colunas de sistema de metrics/<id>.csv (todos os servidores)
  flt.app     JSON com as colunas do servico (processos + fs_*/os_*/db_*/ngx_*/fpm_*)
  flt.sip     JSON por linha do sip/stats.csv do SIPp            (host <prefixo>run)
  flt.uas     JSON por linha do uas/stats.csv do atendedor       (host <prefixo>run)
  flt.web     JSON por alvo do wrk (web/<alvo>.txt)               (host <prefixo>run)
  flt.mysql   JSON do sysbench (intervalos e resumo)              (host <prefixo>run)
  flt.run.info, flt.phase, flt.guard, flt.result                  (host <prefixo>run)

Template "Disparo" (host <prefixo>gen, interface agent): itens passivos do zabbix-agentd do
servidor de testes (UserParameter do bin/flux-loadtest-zbx agent-conf):

  flt.runner.state          JSON do estado (execucao em andamento e ultimo resultado por perfil)
  flt.profiles.discovery    descoberta dos perfis habilitados (LLD {#PROFILE}, {#DESC}, {#TESTS})

O disparo em si sao scripts globais (lib/flux_zabbix.py setup --scripts), nao itens.

Cada item final e DEPENDENT do master, extraido por JSONPath; campo ausente no JSON
descarta o valor (um mesmo master serve a varios papeis e alvos).

Uso: python3 zabbix/gen_templates.py [--version 7.2] > zabbix/flux-loadtest-templates.yaml

Padrao 7.2: versao do Zabbix de producao (7.2.3). O import aceita o formato da propria
versao ou de versoes anteriores, entao o YAML 7.2 tambem entra num Zabbix 7.4.
Somente biblioteca padrao (sem PyYAML): o YAML e escrito com aspas simples em todos os
textos, que e o formato aceito pelo import do Zabbix.
"""

import argparse
import sys
import uuid

NS = uuid.UUID("6f1c2b8e-1437-4f6b-9a3e-5b1f0c0d1437")
GROUP = "Templates/Flux Loadtest"

T_SYS = "Flux Loadtest - Sistema"
T_FS = "Flux Loadtest - FreeSWITCH"
T_OS = "Flux Loadtest - OpenSIPS"
T_DB = "Flux Loadtest - MySQL PXC"
T_WEB = "Flux Loadtest - Web"
T_GEN = "Flux Loadtest - Gerador"
T_RUN = "Flux Loadtest - Execucao"
T_TRIG = "Flux Loadtest - Disparo"

# Cores das series nos graficos
COLORS = ["1A7C11", "F63100", "2774A4", "A54F10", "FC6EA3", "6C59DC", "AC8C14", "611F27"]


def uid(*parts):
    """UUID estavel entre geracoes, no formato v4 exigido pelo import do Zabbix 7.x."""
    return uuid.UUID(bytes=uuid.uuid5(NS, "|".join(parts)).bytes, version=4).hex


# --------------------------------------------------------------------- definicoes
# item: (coluna, nome, unidade, multiplicador, tipo)   tipo: F=FLOAT U=UNSIGNED C=CHAR T=TEXT
def it(col, name, units="", mult=None, vtype="F", desc="", valuemap=None):
    return {"col": col, "name": name, "units": units, "mult": mult, "vtype": vtype,
            "desc": desc, "valuemap": valuemap}


SYS_ITEMS = [
    it("cpu_pct", "CPU total", "%"),
    it("cpu_max_core_pct", "CPU do nucleo mais carregado", "%"),
    it("cpu_max_core", "Nucleo mais carregado", "", None, "U"),
    it("iowait_pct", "CPU iowait", "%"),
    it("steal_pct", "CPU steal", "%"),
    it("softirq_pct", "CPU softirq", "%"),
    it("load1", "Load average (1 min)"),
    it("mem_used_pct", "Memoria usada", "%"),
    it("mem_avail_mb", "Memoria disponivel", "B", "1048576"),
    it("swap_used_mb", "Swap usada", "B", "1048576"),
    it("net_rx_mbps", "Rede recebida", "bps", "1000000"),
    it("net_tx_mbps", "Rede enviada", "bps", "1000000"),
    it("net_rx_pps", "Pacotes recebidos", "pps"),
    it("net_tx_pps", "Pacotes enviados", "pps"),
    it("udp_in_err_s", "Erros de entrada UDP", "/s"),
    it("udp_rcvbuf_err_s", "Erros de buffer de recepcao UDP", "/s"),
    it("disk_rd_kbs", "Disco leitura", "Bps", "1024"),
    it("disk_wr_kbs", "Disco escrita", "Bps", "1024"),
    it("disk_busy_pct", "Disco ocupado", "%"),
    it("disk_free_pct", "Disco livre (particao vigiada)", "%"),
]


def proc_items(proc, label):
    return [
        it(f"{proc}_cpu_pct", f"{label}: CPU (100 = 1 nucleo)", "%"),
        it(f"{proc}_rss_mb", f"{label}: memoria RSS", "B", "1048576"),
        it(f"{proc}_threads", f"{label}: threads", "", None, "U"),
    ]


FS_ITEMS = proc_items("freeswitch", "FreeSWITCH") + [
    it("fs_calls", "FreeSWITCH: chamadas", "", None, "U"),
    it("fs_sessions", "FreeSWITCH: sessoes", "", None, "U"),
    it("fs_sps", "FreeSWITCH: sessoes por segundo", "", None, "U"),
    it("fs_idle_cpu", "FreeSWITCH: CPU ociosa (min idle cpu)", "%"),
]

OS_ITEMS = proc_items("opensips", "OpenSIPS") + [
    it("os_active_dlg", "OpenSIPS: dialogos ativos", "", None, "U"),
    it("os_early_dlg", "OpenSIPS: dialogos em early", "", None, "U"),
    it("os_tm_inuse", "OpenSIPS: transacoes em uso", "", None, "U"),
    it("os_rcv_req_s", "OpenSIPS: requisicoes recebidas", "/s"),
    it("os_failed_dlg_total", "OpenSIPS: dialogos com falha (acumulado)", "", None, "U"),
    it("os_drop_req_total", "OpenSIPS: requisicoes descartadas (acumulado)", "", None, "U"),
    it("os_shm_used_pct", "OpenSIPS: memoria compartilhada usada", "%"),
    it("os_load", "OpenSIPS: load", "%"),
]

DB_ITEMS = proc_items("mysqld", "MySQL") + [
    it("db_qps", "MySQL: consultas", "qps"),
    it("db_select_s", "MySQL: SELECT", "/s"),
    it("db_insert_s", "MySQL: INSERT", "/s"),
    it("db_update_s", "MySQL: UPDATE", "/s"),
    it("db_threads_running", "MySQL: threads em execucao", "", None, "U"),
    it("db_threads_connected", "MySQL: conexoes", "", None, "U"),
    it("db_slow_total", "MySQL: consultas lentas (acumulado)", "", None, "U"),
    it("db_row_lock_waits_total", "MySQL: esperas de lock de linha (acumulado)", "", None, "U"),
    it("db_repl_lag", "MySQL: atraso da replica assincrona (-1 = sem replica)", "s"),
    it("db_repl_ok", "MySQL: replica assincrona ativa (-1 = sem replica)", "", None, "F",
       valuemap="Flux Loadtest - replica"),
    it("db_wsrep_recv_queue", "PXC: fila de recepcao", "", None, "U"),
    it("db_wsrep_send_queue", "PXC: fila de envio", "", None, "U"),
    it("db_wsrep_fc_paused_pct", "PXC: replicacao pausada por flow control", "%"),
    it("db_wsrep_cluster_size", "PXC: nos no cluster", "", None, "U"),
    it("db_wsrep_state", "PXC: estado do no", "", None, "U", valuemap="Flux Loadtest - wsrep state"),
    it("db_wsrep_primary", "PXC: componente Primary", "", None, "U", valuemap="Flux Loadtest - sim/nao"),
    it("db_vip", "PXC: VIP do keepalived neste no", "", None, "U", valuemap="Flux Loadtest - sim/nao"),
]

WEB_ITEMS = proc_items("nginx", "nginx") + proc_items("php_fpm", "PHP-FPM") + [
    it("ngx_active", "nginx: conexoes ativas", "", None, "U"),
    it("ngx_rps", "nginx: requisicoes", "rps"),
    it("ngx_writing", "nginx: conexoes escrevendo", "", None, "U"),
    it("ngx_waiting", "nginx: conexoes em espera", "", None, "U"),
    it("fpm_active", "PHP-FPM: processos ativos", "", None, "U"),
    it("fpm_idle", "PHP-FPM: processos ociosos", "", None, "U"),
    it("fpm_listen_queue", "PHP-FPM: fila de conexoes", "", None, "U"),
    it("fpm_rps", "PHP-FPM: conexoes aceitas", "rps"),
    it("fpm_max_children_total", "PHP-FPM: max children atingido (acumulado)", "", None, "U"),
    it("fpm_slow_total", "PHP-FPM: requisicoes lentas (acumulado)", "", None, "U"),
]

GEN_ITEMS = proc_items("sipp", "SIPp") + proc_items("wrk", "wrk") + proc_items("sysbench", "sysbench")

SIP_ITEMS = [
    it("target_rate", "SIPp: CPS alvo"),
    it("call_rate", "SIPp: CPS no periodo"),
    it("current_calls", "SIPp: chamadas simultaneas", "", None, "U"),
    it("total_created", "SIPp: chamadas criadas (acumulado)", "", None, "U"),
    it("success_p", "SIPp: sucesso no periodo", "", None, "U"),
    it("failed_p", "SIPp: falhas no periodo", "", None, "U"),
    it("failed_pct_p", "SIPp: falhas no periodo (% das encerradas)", "%"),
    it("success_c", "SIPp: sucesso (acumulado)", "", None, "U"),
    it("failed_c", "SIPp: falhas (acumulado)", "", None, "U"),
    it("failed_retrans_c", "SIPp: falhas por timeout de retransmissao UDP (acumulado)", "", None, "U"),
    it("failed_unexpected_c", "SIPp: falhas por resposta inesperada (acumulado)", "", None, "U"),
    it("failed_recv_timeout_c", "SIPp: falhas por timeout de recepcao (acumulado)", "", None, "U"),
    it("retrans_p", "SIPp: retransmissoes no periodo", "", None, "U"),
    it("dead_msgs_p", "SIPp: mensagens de chamadas encerradas no periodo", "", None, "U"),
    it("watchdog_p", "SIPp: alertas de watchdog no periodo", "", None, "U"),
    it("rt_100_ms", "SIPp: INVITE -> 100 (media do periodo)", "ms"),
    it("rt_200_ms", "SIPp: INVITE -> 200 (media do periodo)", "ms"),
    it("call_length_ms", "SIPp: duracao media das chamadas do periodo", "ms"),
]

# Atendedor (SIPp UAS na VM de teste, DIDs DIRECT-IP): chamadas que o FS entregou
UAS_ITEMS = [
    it("call_rate", "Atendedor: chamadas recebidas por segundo no periodo"),
    it("current_calls", "Atendedor: chamadas simultaneas", "", None, "U"),
    it("received_c", "Atendedor: chamadas recebidas (acumulado)", "", None, "U"),
    it("success_p", "Atendedor: sucesso no periodo", "", None, "U"),
    it("failed_p", "Atendedor: falhas no periodo", "", None, "U"),
    it("failed_pct_p", "Atendedor: falhas no periodo (% das encerradas)", "%"),
    it("success_c", "Atendedor: sucesso (acumulado)", "", None, "U"),
    it("failed_c", "Atendedor: falhas (acumulado)", "", None, "U"),
    it("failed_unexpected_c", "Atendedor: falhas por mensagem inesperada (acumulado)", "", None, "U"),
    it("failed_recv_timeout_c", "Atendedor: falhas sem BYE no prazo (acumulado)", "", None, "U"),
    it("call_length_ms", "Atendedor: duracao media das chamadas do periodo", "ms"),
]

RUN_INFO_ITEMS = [
    ("execucao", "Execucao: identificador"),
    ("label", "Execucao: rotulo"),
    ("testes", "Execucao: testes"),
    ("sip_destino", "Execucao: destino SIP"),
    ("cps", "Execucao: CPS e rampa"),
    ("hold_s", "Execucao: hold (s)"),
    ("janela_s", "Execucao: janela (s)"),
    ("midia", "Execucao: midia"),
    ("limite_simultaneas", "Execucao: limite de simultaneas"),
    ("dids", "Execucao: DIDs"),
    ("atendedor", "Execucao: atendedor (UAS)"),
    ("vm_teste", "Execucao: VM de teste"),
]

RESULT_ITEMS = [
    it("execucao", "Resultado: execucao", vtype="C"),
    it("label", "Resultado: rotulo", vtype="C"),
    it("status", "Resultado: status (ok / interrompido)", vtype="C"),
    it("motivo", "Resultado: motivo da interrupcao", vtype="T"),
    it("duracao_s", "Resultado: duracao", "s", None, "U"),
    it("sip_criadas", "Resultado: chamadas criadas", "", None, "U"),
    it("sip_sucesso", "Resultado: chamadas com sucesso", "", None, "U"),
    it("sip_falhas", "Resultado: chamadas com falha", "", None, "U"),
    it("sip_falha_pct", "Resultado: falhas (%)", "%"),
    it("sip_pico_simultaneas", "Resultado: pico de simultaneas", "", None, "U"),
    it("sip_pico_cps", "Resultado: pico de CPS"),
    it("sip_invite_200_ms", "Resultado: INVITE -> 200 (media da execucao)", "ms"),
    it("uas_recebidas", "Resultado: chamadas recebidas pelo atendedor", "", None, "U"),
    it("uas_sucesso", "Resultado: atendedor com sucesso", "", None, "U"),
    it("uas_falhas", "Resultado: atendedor com falha", "", None, "U"),
    it("uas_nao_chegaram", "Resultado: originadas que nao chegaram ao atendedor", "", None, "U"),
]

WEB_TARGETS = [("static", "estatico"), ("php", "PHP"), ("extra", "extra")]
WEB_FIELDS = [
    it("rps", "requisicoes por segundo", "rps"),
    it("transfer_bps", "transferencia", "Bps"),
    it("lat_avg_ms", "latencia media", "ms"),
    it("lat_p50_ms", "latencia p50", "ms"),
    it("lat_p90_ms", "latencia p90", "ms"),
    it("lat_p99_ms", "latencia p99", "ms"),
    it("requests", "requisicoes", "", None, "U"),
    it("non2xx", "respostas nao 2xx/3xx", "", None, "U"),
    it("socket_errors", "erros de socket", "", None, "U"),
]

MYSQL_ITEMS = [
    it("tps_now", "sysbench: transacoes (intervalo)", "tps"),
    it("qps_now", "sysbench: consultas (intervalo)", "qps"),
    it("lat95_now_ms", "sysbench: latencia p95 (intervalo)", "ms"),
    it("err_s_now", "sysbench: erros (intervalo)", "/s"),
    it("tps", "sysbench: transacoes (resumo)", "tps"),
    it("qps", "sysbench: consultas (resumo)", "qps"),
    it("lat_avg_ms", "sysbench: latencia media (resumo)", "ms"),
    it("lat_p95_ms", "sysbench: latencia p95 (resumo)", "ms"),
    it("lat_max_ms", "sysbench: latencia maxima (resumo)", "ms"),
    it("errors", "sysbench: erros ignorados (resumo)", "", None, "U"),
    it("reconnects", "sysbench: reconexoes (resumo)", "", None, "U"),
]

VALUEMAPS = {
    "Flux Loadtest - wsrep state": [("1", "Joining"), ("2", "Donor/Desynced"), ("3", "Joined"),
                                    ("4", "Synced")],
    "Flux Loadtest - sim/nao": [("0", "nao"), ("1", "sim")],
    "Flux Loadtest - replica": [("-1", "sem replica"), ("0", "parada"), ("1", "ativa")],
}

# --------------------------------------------------------------------- YAML


def q(s):
    """Escalar YAML com aspas simples."""
    return "'" + str(s).replace("'", "''") + "'"


class Y:
    def __init__(self):
        self.lines = []

    def add(self, indent, text):
        self.lines.append("  " * indent + text)


VTYPE = {"F": "FLOAT", "U": "UNSIGNED", "C": "CHAR", "T": "TEXT"}


def master_item(y, tpl, key, name, desc, tags):
    y.add(3, f"- uuid: {uid(tpl, key)}")
    y.add(4, f"name: {q(name)}")
    y.add(4, "type: TRAP")
    y.add(4, f"key: {q(key)}")
    y.add(4, "delay: '0'")
    y.add(4, "history: '0'")
    y.add(4, "trends: '0'")
    y.add(4, "value_type: TEXT")
    y.add(4, f"description: {q(desc)}")
    tags_block(y, 4, tags)


def tags_block(y, indent, tags):
    if not tags:
        return
    y.add(indent, "tags:")
    for k, v in tags:
        y.add(indent + 1, f"- tag: {q(k)}")
        y.add(indent + 2, f"value: {q(v)}")


def dep_item(y, tpl, master, key, path, d, tags, triggers=None):
    vt = VTYPE[d["vtype"]]
    y.add(3, f"- uuid: {uid(tpl, key)}")
    y.add(4, f"name: {q(d['name'])}")
    y.add(4, "type: DEPENDENT")
    y.add(4, f"key: {q(key)}")
    y.add(4, "delay: '0'")
    y.add(4, "history: 90d")
    if vt in ("CHAR", "TEXT"):
        y.add(4, "trends: '0'")
    y.add(4, f"value_type: {vt}")
    if d["units"]:
        y.add(4, f"units: {q(d['units'])}")
    if d["desc"]:
        y.add(4, f"description: {q(d['desc'])}")
    if d["valuemap"]:
        y.add(4, "valuemap:")
        y.add(5, f"name: {q(d['valuemap'])}")
    y.add(4, "preprocessing:")
    y.add(5, "- type: JSONPATH")
    y.add(6, "parameters:")
    y.add(7, f"- {q(path)}")
    y.add(6, "error_handler: DISCARD_VALUE")
    if d["mult"]:
        y.add(5, "- type: MULTIPLIER")
        y.add(6, "parameters:")
        y.add(7, f"- {q(d['mult'])}")
    y.add(4, "master_item:")
    y.add(5, f"key: {q(master)}")
    tags_block(y, 4, tags)
    if triggers:
        y.add(4, "triggers:")
        for t in triggers:
            trigger_block(y, 5, tpl, t)


def trigger_block(y, indent, tpl, t):
    y.add(indent, f"- uuid: {uid(tpl, 'trigger', t['name'])}")
    y.add(indent + 1, f"expression: {q(t['expr'])}")
    if t.get("recovery"):
        y.add(indent + 1, "recovery_mode: RECOVERY_EXPRESSION")
        y.add(indent + 1, f"recovery_expression: {q(t['recovery'])}")
    y.add(indent + 1, f"name: {q(t['name'])}")
    if t.get("opdata"):
        y.add(indent + 1, f"opdata: {q(t['opdata'])}")
    y.add(indent + 1, f"priority: {t.get('priority', 'AVERAGE')}")
    if t.get("desc"):
        y.add(indent + 1, f"description: {q(t['desc'])}")
    y.add(indent + 1, "manual_close: 'YES'")
    tags_block(y, indent + 1, t.get("tags", [("scope", "loadtest")]))


def guard(tpl, key, op, macro, name, priority="HIGH", hits=3, desc=""):
    """Gatilho no padrao do guard do flux-loadtest: N amostras seguidas fora do limite.
    Recupera quando volta ao normal ou quando os dados param (fim do teste)."""
    ref = f"/{tpl}/{key}"
    if op == ">":
        expr = f"min({ref},#{hits})>{macro}"
        rec = f"max({ref},#{hits})<={macro} or nodata({ref},{{$FLT.NODATA}})=1"
    else:
        expr = f"max({ref},#{hits})<{macro}"
        rec = f"min({ref},#{hits})>={macro} or nodata({ref},{{$FLT.NODATA}})=1"
    return {"expr": expr, "recovery": rec, "name": name, "priority": priority,
            "opdata": "{ITEM.LASTVALUE1}", "desc": desc}


def graph(tpl, name, keys, gtype=None):
    return {"tpl": tpl, "name": name, "keys": keys, "type": gtype}


# --------------------------------------------------------------------- templates


def build():
    templates = []

    # ---------------- Sistema
    sys_trig = {
        "cpu_pct": [guard(T_SYS, "flt.sys[cpu_pct]", ">", "{$FLT.CPU.MAX}",
                          "CPU acima de {$FLT.CPU.MAX}% por 3 amostras em {HOST.NAME}")],
        "mem_used_pct": [guard(T_SYS, "flt.sys[mem_used_pct]", ">", "{$FLT.MEM.MAX}",
                               "Memoria acima de {$FLT.MEM.MAX}% por 3 amostras em {HOST.NAME}")],
        "disk_free_pct": [guard(T_SYS, "flt.sys[disk_free_pct]", "<", "{$FLT.DISK.FREE.MIN}",
                                "Disco livre abaixo de {$FLT.DISK.FREE.MIN}% em {HOST.NAME}")],
        "udp_rcvbuf_err_s": [guard(T_SYS, "flt.sys[udp_rcvbuf_err_s]", ">", "0",
                                   "Descarte de UDP por buffer de recepcao cheio em {HOST.NAME}",
                                   "WARNING", desc="net.core.rmem_max/rmem_default insuficientes para o volume SIP/RTP.")],
    }
    templates.append({
        "name": T_SYS,
        "desc": "Metricas de sistema do coletor do flux-loadtest (metrics/<id>.csv), enviadas por trapper "
                "na chave flt.sys. Vincular a todos os hosts do teste.",
        "master": ("flt.sys", "Amostra de sistema (JSON)"),
        "items": SYS_ITEMS, "triggers": sys_trig,
        "macros": [("{$FLT.CPU.MAX}", "85", "GUARD_MAX_CPU_PCT (no gerador: GUARD_MAX_GEN_CPU_PCT)"),
                   ("{$FLT.MEM.MAX}", "90", "GUARD_MAX_MEM_PCT"),
                   ("{$FLT.DISK.FREE.MIN}", "15", "GUARD_MIN_DISK_FREE_PCT"),
                   ("{$FLT.NODATA}", "5m", "Sem dados por este tempo = fim do teste (recupera os problemas)")],
        "graphs": [
            graph(T_SYS, "Flux LT: CPU", ["cpu_pct", "cpu_max_core_pct", "iowait_pct", "softirq_pct", "steal_pct"]),
            graph(T_SYS, "Flux LT: memoria", ["mem_used_pct"]),
            graph(T_SYS, "Flux LT: rede (bps)", ["net_rx_mbps", "net_tx_mbps"]),
            graph(T_SYS, "Flux LT: rede (pps)", ["net_rx_pps", "net_tx_pps"]),
            graph(T_SYS, "Flux LT: disco", ["disk_rd_kbs", "disk_wr_kbs"]),
        ],
        "tag": "sistema",
    })

    # ---------------- FreeSWITCH
    templates.append({
        "name": T_FS,
        "desc": "FreeSWITCH no flux-loadtest (fs_cli status/show calls count). Chave flt.app.",
        "master": ("flt.app", "Amostra do servico (JSON)"),
        "items": FS_ITEMS,
        "triggers": {
            "fs_idle_cpu": [guard(T_FS, "flt.app[fs_idle_cpu]", "<", "{$FLT.FS.IDLE.MIN}",
                                  "FreeSWITCH com CPU ociosa abaixo de {$FLT.FS.IDLE.MIN}% em {HOST.NAME}")],
            "fs_sessions": [guard(T_FS, "flt.app[fs_sessions]", ">", "{$FLT.FS.SESSIONS.MAX}",
                                  "FreeSWITCH perto de max-sessions em {HOST.NAME}", "WARNING",
                                  desc="Ajuste {$FLT.FS.SESSIONS.MAX} para 90% do max-sessions do switch.conf.xml.")],
        },
        "macros": [("{$FLT.FS.IDLE.MIN}", "10", "min idle cpu do FreeSWITCH"),
                   ("{$FLT.FS.SESSIONS.MAX}", "900", "90% de max-sessions (repositorio: 1000)"),
                   ("{$FLT.NODATA}", "5m", "Sem dados por este tempo = fim do teste")],
        "graphs": [graph(T_FS, "Flux LT: FreeSWITCH chamadas", ["fs_calls", "fs_sessions", "fs_sps"]),
                   graph(T_FS, "Flux LT: FreeSWITCH CPU", ["freeswitch_cpu_pct", "fs_idle_cpu"])],
        "tag": "freeswitch",
    })

    # ---------------- OpenSIPS
    templates.append({
        "name": T_OS,
        "desc": "OpenSIPS no flux-loadtest (MI get_statistics). Chave flt.app.",
        "master": ("flt.app", "Amostra do servico (JSON)"),
        "items": OS_ITEMS,
        "triggers": {
            "os_shm_used_pct": [guard(T_OS, "flt.app[os_shm_used_pct]", ">", "{$FLT.OS.SHM.MAX}",
                                      "OpenSIPS com memoria compartilhada acima de {$FLT.OS.SHM.MAX}% em {HOST.NAME}")],
        },
        "macros": [("{$FLT.OS.SHM.MAX}", "80", "shmem:real_used_size / total_size"),
                   ("{$FLT.NODATA}", "5m", "Sem dados por este tempo = fim do teste")],
        "graphs": [graph(T_OS, "Flux LT: OpenSIPS dialogos", ["os_active_dlg", "os_early_dlg", "os_tm_inuse"]),
                   graph(T_OS, "Flux LT: OpenSIPS requisicoes", ["os_rcv_req_s"])],
        "tag": "opensips",
    })

    # ---------------- MySQL / PXC
    templates.append({
        "name": T_DB,
        "desc": "MySQL / Percona XtraDB Cluster no flux-loadtest (SHOW GLOBAL STATUS). Chave flt.app.",
        "master": ("flt.app", "Amostra do servico (JSON)"),
        "items": DB_ITEMS,
        "triggers": {
            "db_wsrep_cluster_size": [guard(T_DB, "flt.app[db_wsrep_cluster_size]", "<", "{$FLT.WSREP.SIZE.MIN}",
                                            "PXC com menos de {$FLT.WSREP.SIZE.MIN} nos em {HOST.NAME}", "HIGH")],
            "db_wsrep_fc_paused_pct": [guard(T_DB, "flt.app[db_wsrep_fc_paused_pct]", ">", "{$FLT.WSREP.FC.MAX}",
                                             "PXC pausado por flow control acima de {$FLT.WSREP.FC.MAX}% em {HOST.NAME}")],
            "db_wsrep_primary": [guard(T_DB, "flt.app[db_wsrep_primary]", "<", "1",
                                       "PXC fora do componente Primary em {HOST.NAME}", "DISASTER")],
        },
        "macros": [("{$FLT.WSREP.SIZE.MIN}", "2", "GUARD_MIN_WSREP_CLUSTER_SIZE"),
                   ("{$FLT.WSREP.FC.MAX}", "10", "GUARD_MAX_WSREP_FC_PCT"),
                   ("{$FLT.NODATA}", "5m", "Sem dados por este tempo = fim do teste")],
        "graphs": [graph(T_DB, "Flux LT: MySQL consultas", ["db_qps", "db_select_s", "db_insert_s", "db_update_s"]),
                   graph(T_DB, "Flux LT: MySQL threads", ["db_threads_running", "db_threads_connected"]),
                   graph(T_DB, "Flux LT: PXC filas", ["db_wsrep_recv_queue", "db_wsrep_send_queue",
                                                      "db_wsrep_fc_paused_pct"])],
        "valuemaps": ["Flux Loadtest - wsrep state", "Flux Loadtest - sim/nao", "Flux Loadtest - replica"],
        "tag": "mysql",
    })

    # ---------------- Web
    templates.append({
        "name": T_WEB,
        "desc": "nginx + PHP-FPM no flux-loadtest (stub_status e fpm-status). Chave flt.app.",
        "master": ("flt.app", "Amostra do servico (JSON)"),
        "items": WEB_ITEMS,
        "triggers": {
            "fpm_listen_queue": [guard(T_WEB, "flt.app[fpm_listen_queue]", ">", "0",
                                       "PHP-FPM com fila de conexoes em {HOST.NAME}", "WARNING")],
        },
        "macros": [("{$FLT.NODATA}", "5m", "Sem dados por este tempo = fim do teste")],
        "graphs": [graph(T_WEB, "Flux LT: nginx / PHP-FPM requisicoes", ["ngx_rps", "fpm_rps"]),
                   graph(T_WEB, "Flux LT: PHP-FPM processos", ["fpm_active", "fpm_idle", "fpm_listen_queue"])],
        "tag": "web",
    })

    # ---------------- Gerador
    templates.append({
        "name": T_GEN,
        "desc": "Processos da VM de teste (SIPp, wrk, sysbench). Chave flt.app. "
                "Defina {$FLT.CPU.MAX} = GUARD_MAX_GEN_CPU_PCT no host (o setup do flux-loadtest faz isso).",
        "master": ("flt.app", "Amostra do servico (JSON)"),
        "items": GEN_ITEMS, "triggers": {},
        "macros": [],
        "graphs": [graph(T_GEN, "Flux LT: geradores CPU", ["sipp_cpu_pct", "wrk_cpu_pct", "sysbench_cpu_pct"])],
        "tag": "gerador",
    })

    return templates


def run_template():
    """Template da execucao: varios masters, montado a parte."""
    items = []  # (master, key, path, d, triggers)
    for col, name in RUN_INFO_ITEMS:
        items.append(("flt.run.info", f"flt.run[{col}]", f"$.{col}", it(col, name, vtype="C"), None))
    sip_trig = {
        "failed_pct_p": [{
            "expr": f"min(/{T_RUN}/flt.sip[failed_pct_p],#3)>{{$FLT.SIP.FAIL.MAX}}",
            "recovery": f"max(/{T_RUN}/flt.sip[failed_pct_p],#3)<={{$FLT.SIP.FAIL.MAX}} "
                        f"or nodata(/{T_RUN}/flt.sip[failed_pct_p],{{$FLT.NODATA}})=1",
            "name": "Falhas SIP acima de {$FLT.SIP.FAIL.MAX}% por 3 periodos", "priority": "HIGH",
            "opdata": "{ITEM.LASTVALUE1}"}],
        "watchdog_p": [{
            "expr": f"last(/{T_RUN}/flt.sip[watchdog_p])>0",
            "recovery": f"last(/{T_RUN}/flt.sip[watchdog_p])=0 or nodata(/{T_RUN}/flt.sip[watchdog_p],{{$FLT.NODATA}})=1",
            "name": "SIPp com watchdog (VM de teste sobrecarregada)", "priority": "WARNING",
            "desc": "Os numeros do SIPp deixam de ser confiaveis: reduza a carga ou aumente a VM de teste."}],
    }
    for d in SIP_ITEMS:
        items.append(("flt.sip", f"flt.sip[{d['col']}]", f"$.{d['col']}", d, sip_trig.get(d["col"])))
    for d in UAS_ITEMS:
        items.append(("flt.uas", f"flt.uas[{d['col']}]", f"$.{d['col']}", d, None))
    for tgt, label in WEB_TARGETS:
        for f in WEB_FIELDS:
            d = dict(f)
            d["name"] = f"wrk {label}: {f['name']}"
            items.append(("flt.web", f"flt.web[{tgt},{f['col']}]", f"$.{tgt}.{f['col']}", d, None))
    for d in MYSQL_ITEMS:
        items.append(("flt.mysql", f"flt.mysql[{d['col']}]", f"$.{d['col']}", d, None))
    res_trig = {
        "status": [{
            "expr": f"find(/{T_RUN}/flt.result[status],,\"like\",\"interrompido\")=1",
            "recovery": f"find(/{T_RUN}/flt.result[status],,\"like\",\"ok\")=1",
            "name": "Teste de carga interrompido pelo guard ou pelo operador",
            "priority": "AVERAGE", "opdata": "{ITEM.LASTVALUE1}"}],
    }
    for d in RESULT_ITEMS:
        items.append(("flt.result", f"flt.result[{d['col']}]", f"$.{d['col']}", d, res_trig.get(d["col"])))
    return items


def emit(version):
    y = Y()
    templates = build()
    y.add(0, "zabbix_export:")
    y.add(1, f"version: {q(version)}")
    y.add(1, "template_groups:")
    y.add(2, f"- uuid: {uid('group', GROUP)}")
    y.add(3, f"name: {q(GROUP)}")
    y.add(1, "templates:")
    graphs = []

    for t in templates:
        tpl = t["name"]
        y.add(2, f"- uuid: {uid('template', tpl)}")
        y.add(3, f"template: {q(tpl)}")
        y.add(3, f"name: {q(tpl)}")
        y.add(3, f"description: {q(t['desc'])}")
        y.add(3, "groups:")
        y.add(4, f"- name: {q(GROUP)}")
        y.add(3, "items:")
        mkey, mname = t["master"]
        master_item(y, tpl, mkey, mname, "Trapper: JSON de uma amostra, enviado pelo flux-loadtest.",
                    [("component", "raw")])
        for d in t["items"]:
            key = f"{mkey}[{d['col']}]"
            dep_item(y, tpl, mkey, key, f"$.{d['col']}", d, [("component", t["tag"])],
                     t["triggers"].get(d["col"]))
        if t["macros"]:
            y.add(3, "macros:")
            for m, v, desc in t["macros"]:
                y.add(4, f"- macro: {q(m)}")
                y.add(5, f"value: {q(v)}")
                y.add(5, f"description: {q(desc)}")
        if t.get("valuemaps"):
            valuemaps_block(y, tpl, t["valuemaps"])
        for g in t["graphs"]:
            graphs.append((tpl, g["name"], [f"{mkey}[{k}]" for k in g["keys"]]))

    # ---------------- Execucao
    tpl = T_RUN
    y.add(2, f"- uuid: {uid('template', tpl)}")
    y.add(3, f"template: {q(tpl)}")
    y.add(3, f"name: {q(tpl)}")
    y.add(3, f"description: {q('Execucao do flux-loadtest (host <prefixo>run): parametros, fase, SIPp, atendedor, wrk, sysbench, eventos do guard e resultado.')}")
    y.add(3, "groups:")
    y.add(4, f"- name: {q(GROUP)}")
    y.add(3, "items:")
    for key, name in [("flt.run.info", "Parametros da execucao (JSON do run.env)"),
                      ("flt.sip", "Amostra do SIPp (JSON do stats.csv)"),
                      ("flt.uas", "Amostra do atendedor SIPp (JSON do uas/stats.csv)"),
                      ("flt.web", "Resultado do wrk (JSON por alvo)"),
                      ("flt.mysql", "sysbench (JSON por intervalo e resumo)"),
                      ("flt.result", "Resultado da execucao (JSON)")]:
        master_item(y, tpl, key, name, "Trapper: JSON enviado pelo flux-loadtest.", [("component", "raw")])
    for key, name, desc in [
        ("flt.phase", "Fase em andamento", "Nome da fase no inicio e '-' no fim (baseline, sip, sip_drain, mysql, web_static, web_php, cooldown)."),
        ("flt.guard", "Eventos do guard", "Linhas do guard.log: fase, metrica fora do limite e contagem."),
    ]:
        y.add(3, f"- uuid: {uid(tpl, key)}")
        y.add(4, f"name: {q(name)}")
        y.add(4, "type: TRAP")
        y.add(4, f"key: {q(key)}")
        y.add(4, "delay: '0'")
        y.add(4, "history: 90d")
        y.add(4, "trends: '0'")
        y.add(4, f"value_type: {'CHAR' if key == 'flt.phase' else 'TEXT'}")
        y.add(4, f"description: {q(desc)}")
        tags_block(y, 4, [("component", "execucao")])
    for master, key, path, d, trig in run_template():
        comp = master.split(".")[1]
        dep_item(y, tpl, master, key, path, d, [("component", comp)], trig)
    y.add(3, "macros:")
    for m, v, desc in [("{$FLT.SIP.FAIL.MAX}", "5", "GUARD_MAX_FAIL_PCT"),
                       ("{$FLT.NODATA}", "5m", "Sem dados por este tempo = fim do teste")]:
        y.add(4, f"- macro: {q(m)}")
        y.add(5, f"value: {q(v)}")
        y.add(5, f"description: {q(desc)}")
    graphs += [
        (tpl, "Flux LT: SIPp CPS", ["flt.sip[target_rate]", "flt.sip[call_rate]"]),
        (tpl, "Flux LT: SIPp simultaneas", ["flt.sip[current_calls]"]),
        (tpl, "Flux LT: SIPp sucesso x falha", ["flt.sip[success_p]", "flt.sip[failed_p]", "flt.sip[retrans_p]"]),
        (tpl, "Flux LT: SIPp tempo de resposta", ["flt.sip[rt_100_ms]", "flt.sip[rt_200_ms]"]),
        (tpl, "Flux LT: originadas x atendidas", ["flt.sip[current_calls]", "flt.uas[current_calls]"]),
        (tpl, "Flux LT: atendedor sucesso x falha", ["flt.uas[success_p]", "flt.uas[failed_p]"]),
        (tpl, "Flux LT: sysbench", ["flt.mysql[tps_now]", "flt.mysql[lat95_now_ms]"]),
    ]

    emit_trigger_template(y)

    y.add(1, "graphs:")
    for tpl, name, keys in graphs:
        y.add(2, f"- uuid: {uid(tpl, 'graph', name)}")
        y.add(3, f"name: {q(name)}")
        y.add(3, "graph_items:")
        for i, k in enumerate(keys):
            y.add(4, f"- sortorder: '{i}'" if i else "- color: " + COLORS[0])
            if i:
                y.add(5, f"color: {COLORS[i % len(COLORS)]}")
            y.add(5, "item:")
            y.add(6, f"host: {q(tpl)}")
            y.add(6, f"key: {q(k)}")
    return "\n".join(y.lines) + "\n"


def jsonpath_dep(y, ind, tpl, key, name, path, vtype, master, units="", desc="", tags=()):
    """Item (ou prototype) dependente com JSONPath no nivel de indentacao ind."""
    y.add(ind, f"- uuid: {uid(tpl, key)}")
    y.add(ind + 1, f"name: {q(name)}")
    y.add(ind + 1, "type: DEPENDENT")
    y.add(ind + 1, f"key: {q(key)}")
    y.add(ind + 1, "delay: '0'")
    y.add(ind + 1, "history: 90d")
    if vtype in ("CHAR", "TEXT"):
        y.add(ind + 1, "trends: '0'")
    y.add(ind + 1, f"value_type: {vtype}")
    if units:
        y.add(ind + 1, f"units: {q(units)}")
    if desc:
        y.add(ind + 1, f"description: {q(desc)}")
    y.add(ind + 1, "preprocessing:")
    y.add(ind + 2, "- type: JSONPATH")
    y.add(ind + 3, "parameters:")
    y.add(ind + 4, f"- {q(path)}")
    y.add(ind + 3, "error_handler: DISCARD_VALUE")
    y.add(ind + 1, "master_item:")
    y.add(ind + 2, f"key: {q(master)}")
    tags_block(y, ind + 1, list(tags))


def emit_trigger_template(y):
    """Template do disparo pelo Zabbix: agent passivo no servidor de testes."""
    tpl = T_TRIG
    st = "flt.runner.state"
    y.add(2, f"- uuid: {uid('template', tpl)}")
    y.add(3, f"template: {q(tpl)}")
    y.add(3, f"name: {q(tpl)}")
    y.add(3, f"description: {q('Disparo de perfis do flux-loadtest pelo Zabbix (host <prefixo>gen com interface agent). Itens do zabbix-agentd (bin/flux-loadtest-zbx); iniciar e parar pelos scripts do menu Flux Loadtest.')}")
    y.add(3, "groups:")
    y.add(4, f"- name: {q(GROUP)}")
    y.add(3, "items:")
    y.add(4, f"- uuid: {uid(tpl, st)}")
    y.add(5, f"name: {q('Estado do disparo (JSON)')}")
    y.add(5, f"key: {q(st)}")
    y.add(5, "delay: 30s")
    y.add(5, "history: 1d")
    y.add(5, "trends: '0'")
    y.add(5, "value_type: TEXT")
    y.add(5, f"description: {q('sudo -n flux-loadtest-zbx state: execucao em andamento e ultimo resultado de cada perfil.')}")
    tags_block(y, 5, [("component", "raw")])
    y.add(5, "triggers:")
    trigger_block(y, 6, tpl, {
        "expr": f"nodata(/{tpl}/{st},{{$FLT.TRIG.NODATA}})=1",
        "name": "Disparo: zabbix-agentd sem estado do flux-loadtest-zbx",
        "priority": "WARNING",
        "desc": "Confira o include do agent (flux-host.sh prepare zabbix-agent), o sudoers e o wrapper.",
        "tags": [("scope", "disparo")]})
    tags = [("component", "disparo")]
    jsonpath_dep(y, 4, tpl, "flt.runner.running", "Teste disparado pelo Zabbix em execucao", "$.running",
                 "UNSIGNED", st, tags=tags)
    y.add(5, "triggers:")
    trigger_block(y, 6, tpl, {
        "expr": f"last(/{tpl}/flt.runner.running)=1",
        "name": "Teste de carga disparado pelo Zabbix em execucao",
        "priority": "INFO",
        "desc": "Informativo: aparece enquanto a unidade flux-loadtest-zbx estiver ativa. Parar: script \"Parar teste\".",
        "tags": [("scope", "disparo")]})
    jsonpath_dep(y, 4, tpl, "flt.runner.profile", "Perfil em execucao", "$.profile", "CHAR", st, tags=tags)
    jsonpath_dep(y, 4, tpl, "flt.runner.started", "Inicio da execucao em andamento", "$.started",
                 "UNSIGNED", st, units="unixtime", tags=tags)
    y.add(3, "macros:")
    y.add(4, f"- macro: {q('{$FLT.TRIG.NODATA}')}")
    y.add(5, f"value: {q('5m')}")
    y.add(5, f"description: {q('Sem estado do agent por este tempo = disparo indisponivel')}")

    y.add(3, "discovery_rules:")
    y.add(4, f"- uuid: {uid(tpl, 'flt.profiles.discovery')}")
    y.add(5, f"name: {q('Perfis do flux-loadtest')}")
    y.add(5, f"key: {q('flt.profiles.discovery')}")
    y.add(5, "delay: 10m")
    y.add(5, "lifetime: 7d")
    y.add(5, f"description: {q('Perfis com ZABBIX_ENABLED=1 em /etc/flux-loadtest/profiles.d (flux-loadtest-zbx discovery).')}")
    y.add(5, "item_prototypes:")
    ptags = [("component", "perfil"), ("profile", "{#PROFILE}")]
    rc_key = "flt.profile.last_rc[{#PROFILE}]"
    for key, name, path, vt, units in [
        (rc_key, "Perfil {#PROFILE}: codigo da ultima execucao", "$.last['{#PROFILE}'].rc", "FLOAT", ""),
        ("flt.profile.last_ts[{#PROFILE}]", "Perfil {#PROFILE}: fim da ultima execucao", "$.last['{#PROFILE}'].ts", "UNSIGNED", "unixtime"),
        ("flt.profile.last_result[{#PROFILE}]", "Perfil {#PROFILE}: resultado do systemd", "$.last['{#PROFILE}'].result", "CHAR", ""),
        ("flt.profile.last_dir[{#PROFILE}]", "Perfil {#PROFILE}: diretorio do resultado", "$.last['{#PROFILE}'].run_dir", "CHAR", ""),
    ]:
        jsonpath_dep(y, 6, tpl, key, name, path, vt, st, units=units, desc="{#DESC} (testes: {#TESTS})", tags=ptags)
        if key == rc_key:
            ref = f"/{tpl}/{rc_key}"
            y.add(7, "trigger_prototypes:")
            for t in [
                {"expr": f"last({ref})=6", "name": "Perfil {#PROFILE}: ultima execucao interrompida (guard ou operador)",
                 "priority": "WARNING", "desc": "Codigo 6: limite de seguranca atingido ou parada pelo script \"Parar teste\". Veja o relatorio no diretorio do resultado.",
                 "tags": [("scope", "disparo")]},
                {"expr": f"last({ref})<>0 and last({ref})<>6", "name": "Perfil {#PROFILE}: ultima execucao falhou (codigo {ITEM.LASTVALUE1})",
                 "priority": "HIGH", "desc": "Codigos: 2 uso, 3 configuracao, 4 dependencia, 5 falha remota, -1 encerrado por sinal. Veja journalctl -u flux-loadtest-zbx.",
                 "tags": [("scope", "disparo")]},
            ]:
                trigger_block(y, 8, tpl, t)


def valuemaps_block(y, tpl, names):
    y.add(3, "valuemaps:")
    for n in names:
        y.add(4, f"- uuid: {uid(tpl, 'valuemap', n)}")
        y.add(5, f"name: {q(n)}")
        y.add(5, "mappings:")
        for v, nv in VALUEMAPS[n]:
            y.add(6, f"- value: {q(v)}")
            y.add(7, f"newvalue: {q(nv)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--version", default="7.2", help="versao do formato de exportacao (padrao 7.2, producao)")
    args = ap.parse_args()
    sys.stdout.write(emit(args.version))


if __name__ == "__main__":
    main()
