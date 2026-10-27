# Segurança

## Limites de segurança (guard)

A cada `SAMPLE_INTERVAL`, durante as fases de carga, o script lê a última amostra de cada servidor e
compara com os limites `GUARD_*`. Quando um limite fica estourado por `GUARD_HITS` amostras
**seguidas**:

1. a carga para de forma suave (SIPp com um `SIGUSR1`; `wrk` e `sysbench` com `SIGTERM`);
2. as fases seguintes são canceladas;
3. o cooldown roda normalmente, e o relatório registra o motivo em "Limites de segurança" e em
   `abort.txt`;
4. o script termina com código 6.

| Limite | Chave | Padrão | STFC |
|---|---|---|---|
| CPU de um servidor | `GUARD_MAX_CPU_PCT` | 85% | 75% |
| CPU do gerador | `GUARD_MAX_GEN_CPU_PCT` | 90% | 70% |
| Memória | `GUARD_MAX_MEM_PCT` | 90% | 85% |
| Disco livre | `GUARD_MIN_DISK_FREE_PCT` | 15% | 15% |
| Falha SIP no período (mín. 10 chamadas) | `GUARD_MAX_FAIL_PCT` | 5% | 2% |
| Flow control do PXC | `GUARD_MAX_WSREP_FC_PCT` | 10% | 10% |
| Tamanho mínimo do cluster | `GUARD_MIN_WSREP_CLUSTER_SIZE` | desligado | 2 |
| Núcleo mais carregado | `GUARD_MAX_CORE_PCT` | desligado | desligado |
| Réplica assíncrona | `GUARD_MAX_REPL_LAG` | 30 s | (não se aplica ao PXC) |

No PXC, também interrompem o teste: nó fora de Synced (`wsrep_estado`) e nó sem quórum
(`wsrep_sem_quorum`).

Ctrl+C tem o mesmo efeito; um segundo Ctrl+C encerra a carga imediatamente.

!!! note "O guard não vigia tudo"
    A memória compartilhada do OpenSIPS, o `load_balancer` e o tempo de resposta do FS não param o
    teste; eles aparecem nos gatilhos do Zabbix e no relatório. Acompanhe a página Gargalos durante
    degraus de CPS alto.

## Credenciais

| Credencial | Como é tratada |
|---|---|
| Chave SSH | Ed25519 0600 na VM; instalada com `from=`, `no-pty` e sem encaminhamentos; `keys revoke` remove |
| Senha do `fs_cli` | `--fs-password` (digitada, sem eco) ou `FS_CLI_PASSWORD_FILE` (0600; o script avisa se outros usuários puderem ler) |
| Senha do MySQL (coleta) | Fica no servidor de banco (`--defaults-extra-file`); o script não a conhece |
| Senha do sysbench | Arquivo 0600 na VM; vai na linha de comando do `sysbench` (visível no `ps` da VM) |
| Token da API do Zabbix | Arquivo 0600 na VM; revogar ao fim da campanha |
| Cookie de sessão web | Sessão anônima, apagada no fim da fase web |

A senha do `fs_cli` trafega **só pelo stdin do SSH**: não aparece na linha de comando do `ssh`, no
`console.log`, no `run.env` nem no pacote de resultados. No servidor, ela entra como `fs_cli -p ...`
e fica visível em `/proc/<pid>/cmdline` para outros usuários locais durante cada chamada. Se isso
não for aceitável, deixe `FS_CLI_PASSWORD_FILE` vazio e crie no servidor o `~/.fs_cli_conf` do
usuário que roda o `fs_cli` (com `sudo`, `/root/.fs_cli_conf`), com permissão 0600:

```
[default]
password => SENHA
```

Para gravar a senha em arquivo sem passar pelo histórico do shell:

```bash
install -m 0600 /dev/null /etc/flux-loadtest/fs_cli.pass
```

```bash
read -r -s -p "Senha: " p && printf '%s\n' "$p" > /etc/flux-loadtest/fs_cli.pass && unset p
```

!!! warning "Senha exposta durante a campanha"
    Se a senha do event socket aparecer num terminal ou log durante o diagnóstico, troque-a nos FS e
    atualize os `resources` do `load_balancer` (`lb_reload`) na mesma janela.

## Dados sensíveis nos resultados

- `sip/` e as capturas `*.pcap` contêm DIDs e cabeçalhos SIP.
- `snapshots/` contêm o estado dos serviços (`status`, `lb_list`).
- Guarde os pacotes `.tar.gz` com o mesmo cuidado dos logs de produção e apague as capturas depois da
  análise.

## Trapper do Zabbix

O envio por trapper não usa criptografia (sem TLS/PSK). Use em rede interna ou por um proxy Zabbix
local à VM de teste.
