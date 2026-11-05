#!/usr/bin/env bash
# Gate de deploy: consulta o AI Control Tower (Scripted REST API "AICT Telco Deploy Gate", Fase 4)
# e publica as 8 regras no resumo do job. Falha o pipeline se o AI System não estiver liberado.
# Uso: gate.sh ["título"]   Variáveis: SN_INSTANCE, SN_USER, SN_PASS, SN_GATE_PATH, AI_ASSET_TAG
#      GATE_FILE (padrão: $OUT_DIR/gate-result.json)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
TITULO=${1:-Gate de governança — AI Control Tower}
: "${SN_GATE_PATH:?defina SN_GATE_PATH (ex.: /api/cabs4/aict_gate/check)}" "${AI_ASSET_TAG:?defina AI_ASSET_TAG}"
GATE_FILE=${GATE_FILE:-$OUT/gate-result.json}

if ! RESP=$(sn GET "${SN_GATE_PATH}?asset_tag=$(urlenc "$AI_ASSET_TAG")" 2> "$OUT/gate-erro.txt"); then
  ERRO=$(sed 's/^::error:://' "$OUT/gate-erro.txt")
  echo "::error::$ERRO"
  summary <<EOF
### ⚠️ $TITULO — não foi possível consultar o ServiceNow

\`$ERRO\`

| Erro | O que verificar |
|---|---|
| \`defina SN_...\` | Secret ou variable não cadastrado(a) no repositório |
| HTTP 401 | \`SN_USER\` / \`SN_PASS\` incorretos, ou usuário bloqueado/sem *Web service access* |
| HTTP 403 | Usuário sem a role \`sn_ai_governance.integration.rest\` |
| HTTP 404 | \`SN_GATE_PATH\` errado (confira o *Base API path* do Scripted REST API) |
| Sem conexão | \`SN_INSTANCE\` errado (use só o host, ex.: \`minhainstancia.service-now.com\`) ou instância hibernando |

EOF
  exit 1
fi
echo "$RESP" | jq '.result' > "$GATE_FILE"

jq -r --arg titulo "$TITULO" --arg tag "$AI_ASSET_TAG" '
  . as $r
  | ($r.failed_rules // null) as $fr
  | def st($n): if $fr == null then (if $r.allowed then "✅" else "·" end)
                elif ($fr | index($n)) != null then "⛔" else "✅" end;
    def esc: tostring | gsub("[|]"; "\\|") | gsub("\n"; " ");
  ($r.checks // {}) as $c
  | "### \(if $r.allowed then "✅" else "⛔" end) \($titulo)", "",
    "**\($r.ai_system // "AI System não encontrado")** · asset tag `\($tag)` · avaliado em \($r.evaluated_at // "-") · **\(if $r.allowed then "LIBERADO" else "BLOQUEADO" end)**", "",
    "| # | Regra | | Situação no ServiceNow |", "|:-:|---|:-:|---|",
    ( [ [1, "Status do ciclo de vida",               ($c.lifecycle_status // "-")],
        [2, "Classificação de risco",                ($c.risk_classification // "-")],
        [3, "Modelos vinculados aprovados",          (($c.models // []) | if length == 0 then "nenhum vinculado" else map("\(.name) (\(.status))") | join("; ") end)],
        [4, "Sub-aprovações DPO e Jurídico",         "\(($c.open_subapprovals // []) | length) pendente(s), \(($c.rejected_subapprovals // []) | length) rejeitada(s)"],
        [5, "Modelo obrigatório (generativo/agêntico)", ($c.asset_type // "-")],
        [6, "Uso e finalidade completo",             (($c.use_purpose_missing_fields // []) | if length == 0 then "completo" else "faltam \(length): \(join(", "))" end)],
        [7, "Risco atualizado",                      ($c.latest_risk_assessment // "nenhuma avaliação concluída")],
        [8, "Compliance (Política de IA – Telco BR)", ($c.compliance // "-")]
      ][] | "| \(.[0]) | \(.[1]) | \(st(.[0])) | \(.[2] | esc) |" ),
    "",
    ( if ($r.reasons // [] | length) > 0 then "**Motivos do bloqueio**", "", ($r.reasons[] | "- \(.)"), "" else empty end ),
    ( if ($c.warnings // [] | length) > 0 then "> ⚠️ \($c.warnings | join(" · "))", "" else empty end )
' "$GATE_FILE" | summary

output allowed "$(jq -r '.allowed' "$GATE_FILE")"
output ai_system "$(jq -r '.ai_system // ""' "$GATE_FILE")"
output governance_sys_id "$(jq -r '.governance_sys_id // ""' "$GATE_FILE")"

if [ "$(jq -r '.allowed' "$GATE_FILE")" != "true" ]; then
  echo "::error::Deploy BLOQUEADO pelo AI Control Tower: $(jq -r '(.reasons // []) | join(" | ")' "$GATE_FILE")"
  exit 1
fi
echo "Deploy LIBERADO pelo AI Control Tower"
