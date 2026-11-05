# Demo: deploy de AI System com gate do AI Control Tower + Change Request

Pipeline do GitHub Actions (conta pessoal, sem licença extra) que só publica um AI System quando
**a avaliação do modelo passa**, **o gate do AI Control Tower libera** e **um Normal Change do ITSM é aprovado**.
Usa apenas a Table API e o Scripted REST API do gate (Fase 4).

```
1 · Avaliação do modelo ─▶ 2 · Gate AI Control Tower ─▶ 3 · Change Request ─▶ 4 · Aprovação do Change ─▶ 5 · Deploy
    métricas x limites        8 regras (Fase 4/6)         Normal + evidências     pipeline pausado           revalida gate,
                                                          anexadas                até aprovar no SN          Implement → Closed
```

O que aparece na tela: o grafo dos 5 jobs no Actions, a aba **Summary** com as tabelas de métricas, das
8 regras do gate, da linha do tempo e dos aprovadores do Change; e, no ServiceNow, o Change com descrição,
evidências anexadas e work notes de cada passo do pipeline.

## 1. ServiceNow

1. **Usuário de integração** (ex.: `github.integration`, *Web service access only*) com as roles
   `itil` e `sn_ai_governance.integration.rest`.
2. **Grupo de atribuição** para o Change (ex.: *Change Management*) — opcional, mas as aprovações do
   modelo Normal costumam depender dele. Inclua o usuário que vai aprovar na demo.
3. Confirme o caminho do gate: `/api/<namespace>/aict_gate/check` (na PoC: `/api/cabs4/aict_gate/check`).
4. Para a tabela de regras ficar com ✅/⛔ por linha, a resposta do gate precisa trazer `failed_rules`
   (o Script Include já calcula). Se o recurso REST montar a resposta campo a campo, acrescente
   `failed_rules: r.failed_rules`. Sem isso o pipeline funciona, só mostra os motivos em lista.

## 2. GitHub (conta pessoal)

1. Crie um repositório **privado** e envie estes arquivos (`.github/workflows`, `scripts`, `model`).
2. *Settings › Secrets and variables › Actions*:

| Tipo | Nome | Exemplo |
|---|---|---|
| Secret | `SN_INSTANCE` | `minhainstancia.service-now.com` |
| Secret | `SN_USER` / `SN_PASS` | usuário de integração |
| Variable | `SN_GATE_PATH` | `/api/cabs4/aict_gate/check` |
| Variable | `AI_ASSET_TAG` | `AIS13325836258511679488` (A — caminho feliz) |
| Variable | `SN_ASSIGNMENT_GROUP` | `Change Management` (nome ou sys_id) |
| Variable | `WAIT_MINUTES` | `30` (tempo máximo esperando a aprovação) |

3. *Actions › Deploy de AI System › Run workflow*.

Custo: o plano gratuito tem 2.000 min/mês em repositório privado; cada execução usa poucos minutos
(a espera pela aprovação conta tempo de runner).

## 3. Roteiro da demonstração (~10 min)

| # | Execução | O que mostrar |
|---|---|---|
| 1 | **T1** (`AIS10911031685572882487`) | Para no job 2: regras 1, 4 e 5 bloqueando. **Nenhum Change é aberto** — a governança barra antes do ITSM. |
| 2 | **B** (`AIS06266503406245446548`) | Para no job 2 só pela **regra 8**: 9 controles de LGPD/TEL sem atestação (3/12). Passa em tudo o mais, inclusive já está *Deployed* — compliance é exigido mesmo assim. |
| 3 | **A** (`AIS13325836258511679488`) com *Simular avaliação reprovada* | Para no job 1: métrica fora do limite, nada chega ao ServiceNow. |
| 4 | **A**, versão `1.4.0` | Jobs 1–3 verdes (12/12 controles conformes); o job 4 fica girando. Abra o CHG pelo link do Summary: descrição com o gate e as métricas, anexos, estado Assess. Aprove no ServiceNow (Assess e, conforme o modelo, Authorize). Volte ao GitHub: o job 4 conclui, o 5 revalida o gate, publica e fecha o Change. Mostre as work notes no ServiceNow. |
| 5 (opcional) | **A** de novo e **rejeite** o Change | O job 4 falha com "rejeitado"; nada é publicado. |

Variação longa: atestar os 9 controles do B (DPO: LGPD-01..04/07/08 conforme os donos; Jurídico: LGPD-05/06 e TEL-01) e rodar o B de novo para mostrar o bloqueio virando liberação.

Bom ponto de discussão no passo 3: o gate é **revalidado** antes do deploy, porque a governança pode mudar
durante a espera pela aprovação (ex.: o Uso e finalidade alterado dispara a regra 7).

## 4. Problemas comuns

| Sintoma | Causa provável |
|---|---|
| Aviso "não aceitou a transição para Assess" | O modelo de change da instância exige campos ou passos extras. Clique em **Request Approval** no Change; o pipeline continua esperando normalmente. |
| Change fica em Assess sem aprovador | Grupo de atribuição sem membros ou sem gerente, conforme a política de aprovação Normal. |
| HTTP 403 no gate | Falta a role `sn_ai_governance.integration.rest` no usuário de integração. |
| HTTP 403 no Change | Falta `itil` (ou ACL restritiva em `change_request`). |
| Change não fecha sozinho | Política de fechamento exige campos extras; feche manualmente — a URL da execução está nas notas. |

## 5. Arquivos

- `.github/workflows/ai-deploy.yml` — os 5 jobs
- `scripts/eval.sh` — avaliação (simulada): métricas em `model/<asset tag>.json`, limites em `model/thresholds.json` (AI System sem arquivo não passa)
- `scripts/gate.sh` — consulta o gate e monta a tabela das 8 regras (evolução do `deploy-gate.sh`)
- `scripts/change.sh` — `create`, `wait`, `implement`, `note`, `close`, `fail`. O risco e o impacto do Change são herdados da classificação do AI System (Critical → Very High/1, High → High/1, Medium → Moderate/2, Low → Low/3)
- `scripts/lib.sh` — chamadas REST, resumo do job e saídas

Em produção: trocar autenticação básica por OAuth (client credentials) e trocar a avaliação simulada pela
execução real do conjunto de avaliação do modelo.

## 6. Validação (05/11/2026)

| Execução | AI System | Resultado |
|---|---|---|
| #1 | B — Resumo de atendimento | ⛔ Job 2: regra 8 (3/12 controles avaliados; 9 de LGPD/TEL sem atestação). Nenhum Change aberto. |
| #2 | A — Agente de contestação | ✅ 5/5 jobs em 6m38s: Change aberto, aprovado no ServiceNow (espera de 5m26s), gate revalidado, deploy e Change fechado. |
