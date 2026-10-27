# Limitações

## Da ferramenta

- Os timestamps são gerados em cada servidor: mantenha NTP/chrony ativo.
- As métricas de rede somam todas as interfaces, exceto `lo`.
- O consumo de cada thread é atribuído ao último núcleo em que ela rodou no intervalo.
- O cenário cobre INVITE para DID (DIRECT-IP com atendedor, ou atendido no FS); não registra ramais.
  O registro de devices é validado à parte (`lab/sip/register.xml`).
- O envio ao Zabbix não usa criptografia: use em rede interna ou por um proxy local.
- Os templates são gerados no formato do Zabbix 7.2 (produção: 7.2.3). O mesmo YAML entra num 7.4;
  `zabbix/gen_templates.py --version` muda só o cabeçalho.
- SIPp 3.6.1: um segundo `SIGUSR1` trava o processo, e a saída suave às vezes não termina; o script
  contorna as duas coisas (veja [Parada suave](../execucao/fluxo.md#parada-suave)).

## Da foto de capacidade

- O `media_timeout` definido no dialplan ou no Lua não aparece.
- As portas UDP na faixa RTP são contadas por servidor (no `.163`, OpenSIPS e FS dividem a máquina).
- A idade do `core.db` e os arquivos abertos dependem de o usuário SSH ler o diretório do banco e
  `/proc/PID/fd`.

## Do método

- O teste mede o sistema com o tráfego real ao lado. Dois degraus iguais em horários diferentes podem
  dar números diferentes: anote o tráfego real do preflight.
- Projeções lineares (CPU, banco) não substituem um degrau. Elas indicam onde testar.
- O laboratório valida funcionamento, não capacidade.
