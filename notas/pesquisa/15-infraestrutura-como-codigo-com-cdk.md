# Pesquisa 15 — Infraestrutura como código com CDK

## Pontos conferidos
- CDK v1: manutenção 01/06/2022, fim de suporte 01/06/2023. Só v2 (`aws-cdk-lib`). fonte: https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-bootstrap.html
- Python: linguagem "fully supported", estável. App Python exige Python 3.9+. Versão de linguagem suportada só até EOL dela. fonte: https://docs.aws.amazon.com/cdk/v2/guide/work-with-cdk-python.html
- CDK Toolkit (CLI) roda em Node.js. Precisa Node + `cdk` instalado mesmo usando Python. fonte: https://docs.aws.amazon.com/cdk/v2/guide/work-with-cdk-python.html
- Node.js: 18.x suporte acabou 2025-11-30; 20.x acaba 2026-10-30; 22.x até 2027-10-30; 24.x até 2028-10-30. Recomendar 22 ou 24. fonte: https://docs.aws.amazon.com/cdk/v2/guide/node-versions.html
- Projeto novo: `mkdir rango-infra && cd rango-infra && cdk init app --language python`. Hífen da pasta vira underscore. fonte: https://docs.aws.amazon.com/cdk/v2/guide/work-with-cdk-python.html
- Ativar venv: `source .venv/bin/activate` (Mac/Linux); Windows `.venv\Scripts\activate` (doc escreve `.\venv\Scripts\activate`, mas pasta real é `.venv`; `source.bat` também existe). fonte: idem
- Instalar deps: `python -m pip install -r requirements.txt`. Pacote principal: `aws-cdk-lib` (+ `constructs`). Módulos experimentais: `aws-cdk.<servico>-alpha`. fonte: idem
- requirements.txt: fixar versão com `==` (pip sem lockfile). Editar manualmente, não `pip freeze`. fonte: idem
- Import recomendado: `import aws_cdk as cdk`; `import aws_cdk.aws_s3 as s3`; `lambda` vira `lambda_`. Doc mostra `from aws_cdk import App, Construct`, mas `Construct` vem de `from constructs import Construct` (padrão do template). fonte: idem
- Construct: `Classe(scope, id, **props)`; scope e id posicionais; props como kwargs em snake_case. Parâmetro `id` sombreia builtin; template usa `construct_id`. fonte: idem
- Python não checa tipo em tempo de build; erro aparece em runtime na camada JSII. Erros típicos: valor único vs lista; misturar L1 (`CfnXxx`) com L2. Sugestão: pyright/mypy no CI. fonte: idem
- Comandos da CLI atuais: acknowledge, bootstrap, context, deploy, destroy, diff, docs, doctor, drift, flags, import, init, list/ls, metadata, migrate, notices, orphan, publish-assets, refactor, synthesize/synth, watch. fonte: https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd.html
- `cdk synth` gera cloud assembly em `cdk.out` (padrão `--output`) com template por stack. fonte: idem
- `cdk refactor`: preserva recursos já implantados ao renomear/mover construct (evita replace por mudança de logical ID). Comando recente; exige CDK CLI atualizada. `cdk import`: usa CloudFormation resource import. `cdk drift`: detecta drift de recursos do app CDK. `cdk orphan`: separa recursos da stack sem apagar. `cdk watch`: deploy contínuo com hotswap (só dev). fonte: idem
- `cdk deploy --ci` manda logs para stdout (para pipeline). fonte: idem
- Bootstrap: `cdk bootstrap aws://<account-id>/<region>`. Cria stack `CDKToolkit` com bucket S3 + repositório ECR (assets e templates). Bootstrap é por conta+região. fonte: https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-bootstrap.html
- Bootstrap: qualifier padrão `hnb659fds` (sem significado). Role de execução do CloudFormation tem `AdministratorAccess` por padrão; restringir com `--cloudformation-execution-policies`. `--trust` exige essa flag. `--show-template` imprime o template. `--termination-protection` protege a stack. `--public-access-block-configuration` padrão true. `--bootstrap-customer-key` cria CMK (cobrado). fonte: idem
- `cdk bootstrap --express`: modo express do CloudFormation, SEM rollback automático. Não usar no livro como padrão. fonte: idem
- Limites CloudFormation: 500 recursos por template; 200 parâmetros, 200 outputs, 200 mappings; template de até 1 MB via S3; 2.000 stacks por região por conta; nested stacks: 2.500 recursos por operação. Conferir valor da conta: `aws cloudformation describe-account-limits`. fonte: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cloudformation-limits.html
- Rollback: estado `UPDATE_ROLLBACK_FAILED` quando rollback não consegue desfazer (ex.: recurso apagado fora do CloudFormation). Saída: corrigir causa e `aws cloudformation continue-update-rollback --stack-name X`; `--resources-to-skip` só aceita logical IDs em `UPDATE_FAILED`; pulados viram `UPDATE_COMPLETE` e podem divergir do template. fonte: https://docs.aws.amazon.com/cli/latest/reference/cloudformation/continue-update-rollback.html
- Criação que falha: stack fica `ROLLBACK_COMPLETE` e não pode ser atualizada, só apagada (conhecimento prévio, não conferido nesta pesquisa).
- `ec2.Vpc` do CDK cria por padrão NAT Gateway (um por AZ, até `max_azs`=3 por padrão) e subnets públicas+privadas. Para dev: `nat_gateways=1`. NAT custa. fonte: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_ec2/Vpc.html (resultado de busca; conferir antes de citar número)
- `rds.DatabaseInstance` sem `credentials` gera senha e guarda no Secrets Manager. Versão via `rds.PostgresEngineVersion.VER_xx` em `DatabaseInstanceEngine.postgres(version=...)`. Banco deve ficar em VPC; `vpc_subnets` define subnet. fonte: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_rds/README.html

## Preços e limites (global, 10/2026)
- CloudFormation: sem custo para tipos `AWS::*` e `Alexa::*`; paga-se só os recursos. fonte: https://aws.amazon.com/cloudformation/pricing
- Extensões do registry (terceiros/hooks): $0,0009 por operação de handler; 1.000 operações/mês grátis; primeiros 30 s por operação grátis, depois $0,00008 por segundo. fonte: https://aws.amazon.com/cloudformation/pricing
- Bootstrap: bucket S3 e repositório ECR geram custo mínimo de armazenamento; CMK opcional é cobrada. fonte: https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-bootstrap.html

## Não confirmado
- Versão atual exata de `aws-cdk-lib` e do `aws-cdk` CLI (npm mostra 2.11xx em mirrors, mas não verificado). Usar placeholder, ou checar `pip index versions aws-cdk-lib`.
- Versão atual do template de bootstrap (número exato). Não citar.
- Default de `removal_policy` em `DatabaseInstance` (conhecimento prévio: SNAPSHOT para o recurso, mas não conferido). Sempre declarar explicitamente no exemplo.
- Detalhes do drift detection do CloudFormation (tipos de recurso suportados, comando `aws cloudformation detect-stack-drift` / `describe-stack-resource-drifts`) não pesquisados; conferir antes de listar limitações.
- Página oficial de Vpc/RDS v2 não lida; itens de VPC/RDS vêm de resultados de busca (muitos de v1).
