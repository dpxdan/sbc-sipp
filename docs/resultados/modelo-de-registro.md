# Modelo de registro

Um registro por degrau executado. Copie para o caderno da campanha (ou para a issue no Linear) e
preencha a partir do `report.txt`, do `capacidade.csv` e do dashboard.

## Registro do degrau

```markdown
### <label> - <AAAA-MM-DD HH:MM>

**Meta:** <ex.: 3000 simultâneas a 10 CPS>
**Comando:** `./flux-loadtest.sh run ... --label <label>`
**Limites aplicados:** <ex.: fs-limites.sh aplicar 150 4200 nos 2 FS; max do lb_list conferido>
**Diretório:** /var/lib/flux-loadtest/results/<AAAAMMDD-HHMMSS>-<label>

**Validade**
- Código de saída: <0 | 6 (motivo do abort.txt)>
- CPU do gerador (pico): <%>   Relógio (maior diferença): <s>
- Pico de CPS / alvo: <x / y>   Tempo no alvo: <s>

**Resultado SIP**
| Criadas | Sucesso | Falhas (%) | Pico simultâneas (esperado) | INVITE -> 100 | INVITE -> 200 |
|---|---|---|---|---|---|
| | | | ( CPS x hold = ) | ms | ms |

Falhas por motivo: <ex.: 18 x 503 Maximum Calls In Progress>
Atendedor: recebidas <n>, originadas que não chegaram <n>, sem BYE <n>

**Servidores (pico na fase sip)**
| Servidor | CPU | Núcleo/thread mais carregado | Indicador do serviço |
|---|---|---|---|
| fs1 | % | | fs_sessions_pct %, fs_idle_cpu min |
| fs2 | % | | |
| opensips | % | | os_lb_max_pct %, os_shm_used_pct % |
| db1 / db2 | % | | db_stmt_avg_ms, fc_paused % |
| gen | % | sipp_max_thread_pct | |

**Recuperação:** cooldown igual ao baseline? <sim/não: o que sobrou>
**Alertas da capacidade:** <lista ou "nenhum">

**Veredito:** <Atingido | Atingido com ressalva | Parcial | Não atingido | Não atingível | Inconclusivo>
**Gargalo:** <componente> - **Evidência:** <métrica e valor>
**Próxima ação:** <subir para X | repetir com Y | ajuste Z antes>
```

## Resumo da campanha

```markdown
| Meta | Resultado | Medido | O que limitou |
|---|---|---|---|
| | | | |

**Capacidade atual:** <CPS sustentável> / <simultâneas sem falha>
**Gargalos, em ordem:** 1. ... 2. ...
**Alterações em produção ainda ativas:** <lista com reversão>
**Pendências e decisões:** <lista, com o responsável>
```

## Boas práticas de registro

- Um veredito por degrau, com **uma** evidência numérica. "Parece lento" não é evidência.
- Registre o critério usado quando ele diferir do [semáforo](como-interpretar.md#6-semaforo-por-indicador).
- Separe medida de projeção: "medido 31% a 50 CPS" e "projeção: 75% perto de 100 CPS".
- Anote toda alteração feita em produção e a reversão dela no mesmo registro.
- Guarde o `.tar.gz` da execução junto com o registro.
