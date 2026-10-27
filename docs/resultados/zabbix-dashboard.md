# Dashboard do Zabbix

O `zabbix setup` cria ou atualiza o dashboard global **Flux Loadtest - Resultados (`<prefixo>`)**.
Configuração em [Zabbix](../configuracao/zabbix.md).

## Páginas

| Página | Widgets | Para quem |
|---|---|---|
| Resultados | Tabela com uma linha por execução (execução, status, criadas, falhas %, pico de simultâneas, pico de CPS, INVITE -> 200 médio, originadas que não chegaram, motivo); gráficos de CPS alvo e realizado, simultâneas, INVITE -> 100/200, falhas e retransmissões; problemas do grupo | Gestão, NOC |
| Gargalos | Problemas com as tags `componente` e `tipo` (inclusive os suprimidos pela manutenção); gráficos de carga contra sintoma | Voz, banco, infra |
| Servidores | CPU e memória por servidor, sessões e chamadas dos FS, memória, diálogos e transações do OpenSIPS, consultas e CPU do MySQL, pacotes | Infra, NOC |

Para ver uma execução antiga, escolha o período dela no seletor de tempo do dashboard. O Zabbix só
mostra "último valor" de dados das últimas 24 h: para execuções importadas, use o histórico ou os
gráficos com o período certo.

## Página Gargalos

Os problemas trazem duas tags:

| Tag | Valores | Significado |
|---|---|---|
| `tipo` | `sintoma` | O efeito visto pelo SIPp: atendimento lento, retransmissões, falhas |
| `tipo` | `gargalo` | O recurso que está no limite |
| `componente` | `freeswitch`, `opensips`, `mysql`, `rede`, `cpu`, `memoria`, `disco`, `web`, `gerador`, `sip` | Onde está o recurso |

Leitura: um problema `tipo=sintoma` (ex.: "Atendimento lento: INVITE -> 200 acima de 1000 ms")
aberto ao mesmo tempo que um `tipo=gargalo` aponta a causa. Os gráficos da página cruzam carga e
sintoma:

| Gráfico | Pergunta |
|---|---|
| INVITE -> 200 x simultâneas | O atraso cresce com a carga ou com o tempo? |
| Tempo de resposta do FS x sessões | O FS fica lento antes do limite de sessões? |
| Thread mais carregada por processo | Alguma thread está perto de um núcleo inteiro? |
| Ocupação do OpenSIPS e do `load_balancer` | Os destinos estão cheios? |
| Latência e fila do MySQL | O banco acompanha? |
| Descartes de rede | Há perda no kernel ou na interface? |
| CPU por núcleo | Algum núcleo satura antes do total? |

A tabela sintoma -> gargalo completa está em
[Como interpretar](como-interpretar.md#4-onde-esta-o-gargalo).

## Gatilhos e macros

Os gatilhos seguem o guard, com a mesma regra de 3 amostras seguidas. As macros podem ser ajustadas
por host.

| Gatilho | Macro (padrão) |
|---|---|
| CPU, memória, disco livre, espera de disco | `{$FLT.CPU.MAX}` (85), `{$FLT.MEM.MAX}` (90), `{$FLT.DISK.FREE.MIN}` (15), `{$FLT.IOWAIT.MAX}` (20) |
| Descarte de UDP por buffer cheio, descarte na interface | —, `{$FLT.NET.DROP.MAX}` (0) |
| FS: CPU ociosa, sessões, handles do banco, thread, `status`/`show calls count` lentos | `{$FLT.FS.IDLE.MIN}` (10), `{$FLT.FS.SESSIONS.PCT}` (90), `{$FLT.FS.DBH.PCT}` (80), `{$FLT.THREAD.MAX}` (85), `{$FLT.FS.PROBE.MAX}` (500 ms) |
| OpenSIPS: memória, workers, `load_balancer`, processo, descartes, diálogos com falha | `{$FLT.OS.SHM.MAX}` (80), `{$FLT.OS.LOAD.MAX}` (70), `{$FLT.OS.LB.MAX}` (85), `{$FLT.THREAD.MAX}` (85) |
| PXC: tamanho, flow control, fora do Primary | `{$FLT.WSREP.SIZE.MIN}` (2), `{$FLT.WSREP.FC.MAX}` (10) |
| MySQL: latência, consultas executando, conexões, thread, locks, lentas | `{$FLT.DB.LAT.MAX}` (20 ms), `{$FLT.DB.RUNNING.MAX}` (8), `{$FLT.DB.CONN.MAX}` (80), `{$FLT.THREAD.MAX}` (85) |
| PHP-FPM com fila | — |
| Gerador: SIPp perto de 100% de um núcleo | `{$FLT.THREAD.MAX}` (85) |
| Falhas SIP, INVITE -> 200, retransmissões, watchdog do SIPp | `{$FLT.SIP.FAIL.MAX}` (5), `{$FLT.SIP.PDD.MAX}` (1000 ms), `{$FLT.SIP.RETRANS.MAX}` (20) |
| Execução interrompida | — (recupera na próxima execução `ok`) |

- Os gatilhos de contador (descartes do OpenSIPS, diálogos com falha, locks, lentas) disparam quando
  o contador sobe entre duas amostras.
- `{$FLT.DB.RUNNING.MAX}` deve ser ajustado ao número de núcleos do banco.
- Os problemas se recuperam quando o valor volta ao normal ou quando os dados param por
  `{$FLT.NODATA}` (5 min, fim do teste). Os widgets de problemas das páginas Resultados e Gargalos
  ficam no modo histórico: os resolvidos continuam listados (status RESOLVED), com a hora de início e
  de fim, para comparar com a linha da execução na tabela de resultados.
