# Pesquisa 08 — IAM: quem pode fazer o quê

## Pontos conferidos
- CLI v2 >= 2.22.0: login SSO usa PKCE por default (abre navegador na mesma máquina). Device code só com flag `--use-device-code`. fonte: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html
- Device code: URL `https://device.sso.<região>.amazonaws.com/` + código (ex. QCFK-N451). Serve p/ máquina sem navegador (SSH, WSL). fonte: idem
- Wizard: `aws configure sso`. Pergunta: SSO session name, SSO start URL, SSO region, SSO registration scopes (`sso:account:access`). Depois escolhe conta, role, region, output, profile name. fonte: idem
- Só sessão: `aws configure sso-session`. Não funciona com config legacy. fonte: idem
- Config gerado: `[profile dev]` com `sso_session`, `sso_account_id`, `sso_role_name`, `region`, `output`; `[sso-session my-sso]` com `sso_region`, `sso_start_url`, `sso_registration_scopes`. fonte: idem
- `sso_region` e `sso_start_url` obrigatórios na seção `sso-session`; sso-session reutilizável por vários profiles. fonte: idem
- Desde 2.22.0 pode usar Issuer URL no lugar de Start URL (console Identity Center, Dashboard ou Settings). fonte: idem
- Login: `aws sso login --profile NOME` ou `aws sso login --sso-session NOME`. Teste: `aws sts get-caller-identity --profile NOME`. Logout: `aws sso logout` (msg "Successfully signed out of all SSO profiles."). fonte: idem
- Token SSO em cache `~/.aws/sso/cache`. Credenciais de role renovadas sozinhas enquanto sessão SSO válida; sessão SSO expirada exige novo `aws sso login`. Config legacy (sem sso-session) não renova token. fonte: idem
- Tela de aprovação mostra client name `botocore-client-...`. fonte: idem
- Docs recomendam permission set `PowerUserAccess` p/ dev; criar com menor privilégio. fonte: idem
- Root: tarefas que só root faz (lista oficial): alterar settings de conta standalone (e-mail, senha, access keys do root); fechar/reabrir conta standalone; restaurar permissões IAM se único admin se trancou; ativar acesso IAM ao Billing; certos tax invoices; registrar como seller no RI Marketplace; configurar MFA Delete no S3; editar/apagar bucket policy que nega todos; apagar SQS policy que nega todos; GovCloud signup. Nome de conta, contatos, Regiões NÃO exigem root. fonte: https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-tasks.html
- MFA no root é enforced por default, mas exige ação do cliente (adicionar no cadastro ou quando pedido no login). fonte: idem
- Root centralizado (Organizations): remove credenciais root de contas-membro; contas novas criadas em Organizations nascem sem credenciais root. fonte: idem
- Root pode ter access keys, mas melhor não criar; docs têm página de apagar. fonte: idem
- Passkey/security key aceitos como MFA p/ root e IAM users (lançado jun/2024). Até 8 dispositivos MFA por usuário. Passkey do root só pelo console. fonte: https://aws.amazon.com/blogs/aws/aws-adds-passkey-multi-factor-authentication-mfa-for-root-and-iam-users/
- Avaliação de políticas: deny explícito em qualquer política (identity, resource, boundary, SCP, RCP) vence qualquer allow. fonte: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
- Mesma conta: identity-based e resource-based combinam por união (um allow basta). Boundary, SCP, RCP e session policy restringem por interseção. Cross-account: os dois lados precisam permitir. fonte: idem
- Nuance: implicit deny em permissions boundary pode limitar grant de resource-based policy conforme o principal ARN citado. fonte: idem

## Preços e limites (consulta out/2026)
- Managed policies anexadas por user/group/role: default 10 (ajustável). fonte: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html
- Tamanho de customer managed policy: 6.144 caracteres (sem contar espaço em branco; não ajustável). fonte: idem
- Inline: user 2.048, group 5.120, role 10.240 caracteres. fonte: idem
- Trust policy da role: default 2.048, máximo 4.096 caracteres. fonte: idem
- Nomes: role 64 caracteres; policy e group 128. fonte: idem
- Role session: DurationSeconds 900 s a máximo da role (1 a 12 h); sem parâmetro = 1 h. fonte: idem
- Roles por conta default 1.000; groups 300; customer managed policies 1.500. Máximos divergem entre espelhos, conferir página oficial antes de citar. fonte: idem

## Casos reais
- Unit 42 (Palo Alto), teste 19/12/2025: chave enviada a repo público GitHub às 18:50:05 UTC. 18:50:15 CloudTrail registra `AttachUserPolicy` com `AWSCompromisedKeyQuarantineV3` (~10 s). 18:50:17 aviso no AWS Health; 18:50:26 e-mail; 18:50:59 caso no Support. Timings de um teste só, não garantia. fonte: https://unit42.paloaltonetworks.com/detecting-exposed-aws-iam-credentials/
- Quarantine não revoga nem desativa a chave: só deny explícito em lista de ações (EC2 RunInstances, criar users/keys, anexar policies, apagar S3 objects, invocar Bedrock...). Fora da lista a chave ainda funciona. Passo seguinte: apagar/rotacionar a chave. fonte: idem
- Histórico da policy: criada 11/08/2020; V2 em 21/04/2021; V3 em 21/08/2024. fonte: idem
- Quirk: no CloudTrail o userIdentity do AttachUserPolicy aparece como o próprio usuário afetado, não como a AWS. fonte: idem
- EleKtra-Leak (Unit 42, out/2023): 474 instâncias EC2 de mineração Monero entre 30/08 e 06/10/2023. Atacantes usaram chaves expostas no GitHub em até 5 minutos. fonte: https://www.darkreading.com/cloud-security/elektra-leak-attackers-harvest-aws-cloud-keys-github-campaign
- Caso Classmethod: chave com PowerUserAccess em repo público; em ~10 min lançaram instâncias p/ minerar Monero; GuardDuty alertou. Resposta: apagar chave, checar CloudTrail em todas as Regiões, apagar recursos, rotacionar demais. fonte: https://dev.classmethod.jp/articles/risk-management-aws-access-key-accidentally-exposed

## Não confirmado
- Estudo Truffle Security 2026 (7.590 IAM users ativos, 929 com quarantine, chaves ainda autenticando): só vi resumo secundário (ITPro). fonte: https://www.itpro.com/security/researchers-warn-thousands-of-active-aws-access-keys-are-publicly-exposed
- Cronograma exato do enforcement de MFA no root (fases, carência): não confirmado em página oficial.
- Valores máximos de cota de roles e customer managed policies (5.000 vs 10.000): fontes divergem.
- Preço do IAM Identity Center: não pesquisado (conceito estável: sem custo adicional).
- Lista exata de ações negadas pela V3: não obtida (Unit 42 cita 61 permissões em 17 serviços na V2; V3 igual, segundo o artigo).
