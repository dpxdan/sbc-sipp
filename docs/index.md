# sbc-sipp — Flux Loadtest

Ferramenta de teste de carga do FluxSBC, executada a partir de uma VM de teste.
Gera tráfego SIP com SIPp, carga HTTP com wrk e, opcionalmente, carga MySQL com sysbench.
Durante a execução, coleta métricas dos servidores por SSH e produz relatórios e dados brutos.

## Componentes

| Caminho | Responsabilidade |
| --- | --- |
| `flux-loadtest.sh` | Orquestra configuração de chaves, verificações, smoke tests, carga e relatórios. |
| `lib/` | Coleta de métricas e integração com Zabbix. |
| `scenarios/` | Modelos SIPp de originador e atendedor de chamadas. |
| `profiles/` | Exemplos de perfis de carga. |
| `install/` | Instalação e preparação dos servidores por papel. |
| `lab/` | Laboratórios Docker e VMs Debian 12. |
| `deploy/` | Runbooks, configurações e scripts específicos do ambiente STFC. |
| `zabbix/` e `bin/flux-loadtest-zbx` | Templates e disparo de perfis pelo Zabbix. |

## Fluxo geral

1. Preparar a VM de teste e os acessos aos servidores.
2. Configurar os destinos, DIDs e o perfil de carga.
3. Conferir conectividade e executar um smoke test.
4. Executar a carga com coleta de métricas e limites de segurança.
5. Analisar o relatório, os dados brutos e as métricas no Zabbix, quando configurado.

O tráfego SIP pode passar pelo OpenSIPS e ser distribuído aos FreeSWITCH,
ou ser enviado diretamente a um FreeSWITCH. A carga web cobre nginx e PHP-FPM;
a carga ativa no banco é opcional.

## Documentação existente

Os procedimentos detalhados permanecem nos documentos do repositório:

- [Guia principal](https://github.com/dpxdan/sbc-sipp/blob/master/README.md)
- [Instalação e preparação](https://github.com/dpxdan/sbc-sipp/blob/master/install/README.md)
- [Laboratório Docker](https://github.com/dpxdan/sbc-sipp/blob/master/lab/README.md)
- [Laboratório em VMs](https://github.com/dpxdan/sbc-sipp/blob/master/lab/vm/README.md)
- [Teste completo STFC](https://github.com/dpxdan/sbc-sipp/blob/master/deploy/stfc-completo/README.md)

## Editar e visualizar esta documentação

Na raiz do repositório:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install mkdocs
mkdocs serve
```

Abra o endereço indicado pelo comando. Para gerar o site estático:

```bash
mkdocs build --strict
```

Adicione novas páginas Markdown em `docs/` e registre-as em `nav` no `mkdocs.yml`.
