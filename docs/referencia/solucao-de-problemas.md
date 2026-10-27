# Solução de problemas

## SIP

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `smoke`: resposta 403 | Origem não autorizada no OpenSIPS ou bloqueada pelo Event Guard | IP (público, se houver NAT) na tabela `address`, grupo 10, e `address_reload`; whitelist do Event Guard |
| `smoke`: resposta 401 ou 407 | Origem fora da ACL do FS (destino direto) | Liberar o IP em `acl_lb_networks` ([FreeSWITCH direto](../execucao/fs-direto.md)) |
| Resposta 404 ou 480 | DID inexistente, sem destino, ou DID para ramal | Conferir o DID no banco: `call_type = 2` e `extensions` |
| Resposta 502, 503 ou 408 com atendedor | FS não alcança `IP:UAS_PORT` da VM (firewall, IP errado, atendedor parado) | `check` mostra a porta; liberar SIP e RTP dos FS para a VM; conferir `extensions` |
| "Originadas que nao chegaram aqui" > 0 | Chamadas recusadas antes do bridge (OpenSIPS, dialplan, limite de canais) | Ver "Falhas por motivo" do originador e o log do FS |
| Atendedor: "sem BYE no prazo" | FS não repassou o BYE (perda de pacote, FS sobrecarregado, route set) | Ver `uas/errors.log` e a CPU dos FS |
| `503 Maximum Calls In Progress` | `max-sessions` do FS atingido | `fs-limites.sh mostrar`; aplicar 1,4 x simultâneas |
| `503 No FreeSWITCH Available` | `load_balancer` sem destino com capacidade | `lb_list`; esperar ~30 s depois do `fs-limites.sh aplicar`; FS lento à sondagem |
| Resposta 503 (outra) | Limite de canais do DID/conta | Conferir `maxchannels` da conta e do DID |
| Timeout de retransmissão | Firewall, porta SIP errada, IP bloqueado pelo fail2ban, servidor lento | Testar a porta; whitelist do Event Guard |
| "receive timeout ... jumping to label" no `errors.log` | **Não é erro**: fim do hold | Nada; o relatório conta como "fim do hold" |
| BYE remoto antes do hold com `-M none` | Timeout de mídia do FS menor que o hold | `capacidade --hold <s>` alerta; aumentar o `rtp-timeout-sec` ou usar `-M rtp` |

## Coleta e guard

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `check`: "fs_cli sem resposta" | Senha do event socket ou permissão | `--fs-password`, `FS_CLI_PASSWORD_FILE` ou `sudo` no `FS_CLI_CMD` |
| Colunas `fs_*` vazias no relatório | `run` sem a senha do `fs_cli` | `--fs-password` ou `FS_CLI_PASSWORD_FILE` também no `run` |
| `db_stmt_avg_ms` vazia | Usuário de coleta sem `SELECT` no `performance_schema` | `GRANT SELECT ON performance_schema.* ...` |
| Colunas `ngx_*` e `fpm_*` vazias | Páginas de status não liberadas | `prepare web --apply-status` ou configuração manual |
| Interrompido por `disco_livre` | Partição do FS ou do MySQL abaixo de 15% | Liberar espaço; não baixar o limite |
| Interrompido por `wsrep_estado` ou `wsrep_sem_quorum` | Nó dessincronizado ou sem quórum | Verificar o cluster antes de repetir (`wsrep_local_state_comment`, `wsrep_cluster_status`) |
| Interrompido por `flow_control` | Um nó não acompanha as escritas | Comparar `db_wsrep_recv_queue` dos dois nós; disco e CPU do nó atrasado |
| `udp_rcvbuf_err_s` alto na VM com `--media rtp` | O rtpstream do SIPp não consome o RTP devolvido | Esperado; não afeta o teste |
| Aviso de `ulimit -n` | Limite de arquivos baixo | Rodar como root ou `prepare gen` (limits) |
| Aviso de coletor sem dados | Coletor sem dados novos há mais de 4 intervalos | Ver `metrics/<host>.err` e o SSH do servidor |

## Acesso

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `keys test` falha depois de funcionar | IP público mudou (NAT) | `keys deploy --from NOVO_IP` |
| SSH recusado depois do `deploy` por senha | fail2ban bloqueou por tentativas erradas | Whitelist do IP; conferir o jail do sshd |
| `prepare` parece travado | Pergunta `SIM` escondida por um filtro na saída | Rodar sem filtro (`grep`) na saída |

## Carga web e MySQL

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `--tests mysql` não conecta | VIP fora do alcance da VM | Rodar o sysbench de uma VM na rede interna |
| `wrk`: "Servname not supported for ai_socktype" | Debian mínimo sem `/etc/services` | O script já passa a porta na URL; instale o `netbase` para uso manual |
| Página PHP com HTTP 500 e "authentication method unknown to the client" | PHP 7.3 sem `caching_sha2_password` (padrão do MySQL 8.4) | Usuário da aplicação com `mysql_native_password` |

## Zabbix

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `zabbix.log`: "valores recusados" | Host ou item inexistente | `zabbix setup --import-template`; conferir `ZABBIX_HOST_PREFIX` |
| `zabbix send`: "execucao ja enviada" | Já enviada ao vivo ou importada | `--force` só se os valores não chegaram |
| Item sem "último valor" depois da importação | O Zabbix só mostra último valor das últimas 24 h | Ver o histórico ou os gráficos no período da execução |
| `AVISO: dashboard nao criado` | Usuário do token sem permissão de dashboard | Dar a permissão e rodar o `setup` de novo |
| Perfil aparece no menu, mas o agent recusa | Perfil novo sem `AllowKey` no include | Rodar de novo o `prepare zabbix-agent` |
