# Resumo 24 — Custos e arquitetura

## Conceitos explicados (não reexplicar depois)
- consolidated billing: conta de gerenciamento paga organização inteira
- 3 medidores: tempo ligado, volume guardado, movimento; Rangô ~US$ 0,60/h só por existir
- Cost Explorer: console grátis, API cobrada, atualiza 24 h, previsão 18 meses/3 meses; `get-cost-and-usage` LINKED_ACCOUNT/SERVICE/USAGE_TYPE, máx. 2 group-by, fim exclusivo; "EC2 - Other" = EBS, snapshots, NAT, entre AZs
- cost allocation tags: ativar na gerenciamento (`update-cost-allocation-tags-status`), até 24 h; `componente$` vazio; `aws:cloudformation:stack-name`; backfill 12 meses só se recurso já tinha tag; `Tags.of` analogia middleware
- budgets: monitorar grátis, 2 com ações grátis; FORECASTED vs ACTUAL; não bloqueia; budget actions
- Cost Anomaly Detection: 10 dias histórico, até 24 h
- tabela endpoints vs NAT (7 em 2 AZs ~US$ 100,80; 1 AZ ~50,40; 1 NAT ~36 + GB)
- saída: S3 → CloudFront grátis, 1 TB pay-as-you-go
- Savings Plans 4 tipos, Compute 66%, EC2 Instance 72%, Database; comprometer piso
- Spot até 90%, aviso 2 min, rebalance; Fargate Spot ARM desde set/2024
- Well-Architected 6 pilares, 5 princípios custo, Well-Architected Tool; 75% dev/test 40/168 h

## Estado do Rangô ao fim
- dezembro (fatura 4/jan/2027; 1º mês inteiro nas contas do cap. 23): US$ 687,18 (prod 434,70, homolog 231,28); NAT Diego 30/nov, EBS 26/nov; 6.812 pedidos, taxa R$ 0,50; custo/pedido ~US$ 0,10 → estimativa ~0,06 (~US$ 430/mês)
- stack: `producao = ambiente == "producao"`; tags `projeto`/`ambiente`/`componente` (find_child ServicoApi, AlbApi, TabelaEntregas, TabelaFluxo); `CfnBudget` `rango-{ambiente}-mensal` (cdk.json `orcamento_producao` 320, `orcamento_homologacao` 110); `subnets_endpoints` (homolog 1 AZ); cluster `enable_fargate_capacity_providers`; homolog FARGATE_SPOT + `scale_on_schedule` Noite 20h/Manha 8h MON-FRI America/Sao_Paulo; behavior `/fotos/*` OAC bucket importado + policy manual; config `url_publica` → `URL_PUBLICA`
- `frontend/src/reduzirFoto.ts` (JPEG 0,82, 1280 px); `listar_fotos` sem presigned GET, lista o bucket (`list_objects_v2` prefixo, `s3:ListBucket` em `fotos/*` na `role_app`), Valkey sem `fotos:{r}`
- removidos: NAT do Diego (homolog) + rota + EIP, EBS 100 GiB, snapshots antigos e zona velha em rango-estudos, alarme US$ 10, Zero spend; `rango-mensal` → US$ 450; anomaly monitor
- produção segue no ar; checklist de destruição no fim

## Casos reais e exemplos usados
- Maciej Pocwierz bucket vazio 2024 (~US$ 1.300, 403 cobrado, mudança maio/2024)
- Diego `CreateNatGateway` 9/nov via CloudTrail; pasta com 31 e-mails

## Promessas feitas
- fim do livro; pendências na tabela de pilares: Multi-AZ, RDS Proxy, auth entregador, WAF Count→Block
