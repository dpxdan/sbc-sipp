# Glossário

| Termo | Significado |
|---|---|
| Atendedor | O segundo SIPp, na VM de teste (`UAS_PORT`), que recebe o bridge do FS e atende |
| Baseline | Fase só de coleta antes da carga; referência para comparar |
| BYE remoto | Chamada encerrada pelo lado do FS antes do fim do hold |
| Capacidade (foto) | Registro de limites e uso de cada servidor antes, no pico e depois (`capacidade.csv`) |
| Cooldown | Fase só de coleta depois da carga; mostra se o ambiente voltou ao normal |
| CPS | Chamadas por segundo criadas pelo originador |
| Degrau | Uma execução com uma carga fixa (CPS, hold, janela) |
| DIRECT-IP | Tipo de DID (`call_type = 2`) que encaminha para `IP:porta` em `extensions` |
| Drenagem (`sip_drain`) | Fase sem chamadas novas, esperando as ativas terminarem |
| Fim do hold | Chamada encerrada pela VM ao fim de `--hold`: o caminho normal |
| Flow control | Mecanismo do Galera/PXC que pausa a replicação quando um nó não acompanha as escritas |
| Gerador | A VM de teste (`gen`), onde rodam os SIPp, o `wrk` e o `sysbench` |
| Guard | Os limites de segurança que param a carga de forma suave |
| Hold | Tempo que a chamada fica atendida antes do BYE (`-H`) |
| INVITE -> 100 | Tempo até o 100 Trying (RTD 1 do SIPp) |
| INVITE -> 200 | Tempo até o 200 OK, o atraso pós-discagem (PDD) visto pela operadora (RTD 2) |
| Janela | Tempo de envio de chamadas novas (`-w`) |
| `load_balancer` | Módulo do OpenSIPS que distribui as chamadas de operadora entre os FS |
| Originador | O SIPp que envia os INVITE (UAC) |
| PDD | Post-dial delay; aqui, o INVITE -> 200 |
| Perfil | Arquivo com os parâmetros de um `run`, para disparo pelo Zabbix |
| Perna A / perna B | A sessão de entrada no FS e a sessão do bridge para o atendedor |
| Piloto | Primeiro `run`, de carga mínima, para validar coleta e caminho |
| PXC | Percona XtraDB Cluster (MySQL com replicação síncrona Galera) |
| Rampa | Subida do CPS do valor inicial ao alvo (`--cps-start`, `--ramp-step`, `--ramp-interval`) |
| Regime | Período em que o CPS está no alvo e as simultâneas estabilizaram em CPS x hold |
| Sessão | Um canal no FreeSWITCH; cada chamada de teste usa 2 |
| Simultâneas | Chamadas ativas ao mesmo tempo; em regime, CPS x hold |
| `sps` | `sessions-per-second` do FreeSWITCH: conta sessões, não chamadas |
| Trapper | Tipo de item do Zabbix que recebe valores enviados pelo cliente |
| VIP | Endereço do banco gerenciado pelo keepalived (`172.17.4.100` no STFC) |
| Wrapper | `bin/flux-loadtest-zbx`, que o zabbix-agentd chama para iniciar e parar perfis |
