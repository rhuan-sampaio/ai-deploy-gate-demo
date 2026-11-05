#!/usr/bin/env bash
# Change Request (ITSM) do deploy, via Table API.
#   change.sh create          abre (ou reaproveita) um Normal Change com as evidências e pede aprovação
#   change.sh wait            aguarda a aprovação; sai com erro se rejeitado, cancelado ou expirado
#   change.sh implement       passa o Change para Implement
#   change.sh note "texto"    grava uma work note
#   change.sh close           Review -> Closed (successful)
#   change.sh fail "motivo"   em Implement: Closed (unsuccessful); antes disso: Canceled
# Variáveis: SN_INSTANCE, SN_USER, SN_PASS, SN_ASSIGNMENT_GROUP (nome ou sys_id), AI_ASSET_TAG, VERSAO,
#            RUN_URL, CHANGE_SYS_ID (exceto create), WAIT_MINUTES (padrão 30), POLL_SECONDS (padrão 15)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=/api/now/table/change_request
RUN_URL=${RUN_URL:-local}

chg_url() { echo "$SN_BASE_URL/now/sow/record/change_request/$1"; }   # Service Operations Workspace
patch()   { sn PATCH "$T/$CHANGE_SYS_ID?sysparm_fields=number,state,approval" "$1"; }
le()      { sn GET "$T/$CHANGE_SYS_ID?sysparm_fields=number,state,approval" | jq -c '.result'; }
nota()    { patch "$(jq -n --arg n "$1" '{work_notes: $n}')" > /dev/null || echo "::warning::Não foi possível gravar a work note"; }

create() {
  local corr="github:${GITHUB_REPOSITORY:-local}:run-${GITHUB_RUN_ID:-$$}"
  local gate=$OUT/gate-result.json evalr=$OUT/eval-report.json
  [ -f "$gate" ] || echo '{}' > "$gate"
  [ -f "$evalr" ] || echo '{}' > "$evalr"

  # Reexecução do mesmo run (re-run de jobs): reaproveita o Change em vez de abrir outro
  local existente
  existente=$(sn GET "$T?sysparm_query=$(urlenc "correlation_id=$corr^active=true")&sysparm_fields=sys_id,number,state&sysparm_limit=1" | jq -c '.result[0] // empty')
  if [ -n "$existente" ]; then
    CHANGE_SYS_ID=$(jq -r '.sys_id' <<<"$existente")
    echo "Reaproveitando $(jq -r '.number' <<<"$existente") (mesmo run do pipeline)"
  else
    local grupo=${SN_ASSIGNMENT_GROUP:-}
    if [ -n "$grupo" ] && ! [[ $grupo =~ ^[0-9a-f]{32}$ ]]; then
      grupo=$(sn GET "/api/now/table/sys_user_group?sysparm_query=$(urlenc "name=$grupo")&sysparm_fields=sys_id&sysparm_limit=1" | jq -r '.result[0].sys_id // empty')
      [ -n "$grupo" ] || echo "::warning::Grupo \"$SN_ASSIGNMENT_GROUP\" não encontrado; Change sem grupo de atribuição"
    fi
    local corpo
    corpo=$(jq -n --slurpfile g "$gate" --slurpfile e "$evalr" \
      --arg tag "${AI_ASSET_TAG:-}" --arg ver "${VERSAO:-}" --arg run "$RUN_URL" --arg corr "$corr" --arg grupo "$grupo" \
      --arg ini "$(date -u -d '+10 min' '+%Y-%m-%d %H:%M:%S')" --arg fim "$(date -u -d '+70 min' '+%Y-%m-%d %H:%M:%S')" '
      ($g[0]) as $g | ($e[0]) as $e
      # Display name do AI Control Tower termina com a versão registrada ("Agente X 0.1.0")
      | (($g.ai_system // $tag) | capture("^(?<nome>.*?)\\s+v?(?<v>[0-9]+(\\.[0-9]+)+)$") // {nome: ($g.ai_system // $tag), v: null}) as $id
      | $id.nome as $sis
      | (if $id.v then "\($id.v) → \($ver)" else $ver end) as $versoes
      # Risco do AI System (1 High, 2 Medium, 3 Low, 6 Critical) -> risco e impacto do Change
      | (($g.checks.risk_classification // "") | capture("^(?<c>[0-9]+)").c // "") as $rc
      | ({"6": {risk: "2", impact: "1", rotulo: "Critical"}, "1": {risk: "2", impact: "1", rotulo: "High"},
          "2": {risk: "3", impact: "2", rotulo: "Medium"},   "3": {risk: "4", impact: "3", rotulo: "Low"}}[$rc] // null) as $rk
      | {
          type: "normal", category: "Software",
          short_description: "Deploy do AI System \($sis) \($versoes) (pipeline GitHub Actions)",
          description: ([
            "Deploy solicitado pelo pipeline: \($run)", "",
            "AI System: \($sis)", "Asset tag: \($tag)",
            "Versão: \(if $id.v then "registrada no AI Control Tower \($id.v), nova \($ver)" else $ver end)",
            "Risco e impacto do Change herdados da classificação do AI System: \($rk.rotulo // "não mapeado")", "",
            "GATE AI CONTROL TOWER: \(if $g.allowed then "LIBERADO" else "BLOQUEADO" end) em \($g.evaluated_at // "-")",
            "  Status do ciclo de vida: \($g.checks.lifecycle_status // "-")",
            "  Classificação de risco: \($g.checks.risk_classification // "-")",
            "  Última avaliação de risco: \($g.checks.latest_risk_assessment // "-")",
            "  Compliance: \($g.checks.compliance // "-")", "",
            "AVALIAÇÃO DO MODELO: \(if $e.aprovado then "APROVADA" else "-" end) (\($e.conjunto // "-"))",
            ( ($e.metricas // [])[] | "  \(.rotulo): \(.valor) (limite \(.limite)) \(if .ok then "OK" else "FORA DO LIMITE" end)" ),
            "", "Evidências completas anexadas: gate-result.json e eval-report.json"
          ] | join("\n")),
          justification: "Nova versão do AI System \($sis), liberada pelo gate de governança do AI Control Tower e aprovada na avaliação automatizada do modelo.",
          implementation_plan: "Publicação automatizada pelo pipeline GitHub Actions após a aprovação deste Change. O gate do AI Control Tower é revalidado imediatamente antes do deploy.",
          backout_plan: "Reexecutar o pipeline com a versão anterior do AI System.",
          test_plan: "Avaliação automatizada do modelo (métricas e limites na descrição) e gate de governança com 8 regras.",
          risk_impact_analysis: "Risco do AI System no AI Control Tower: \($g.checks.risk_classification // "-"). Sub-aprovações de Privacidade e Jurídico concluídas.",
          start_date: $ini, end_date: $fim,
          correlation_id: $corr, correlation_display: "GitHub Actions"
        }
        + (if $rk then {risk: $rk.risk, impact: $rk.impact} else {} end)
        + (if $grupo != "" then {assignment_group: $grupo} else {} end)')
    local criado
    criado=$(sn POST "$T?sysparm_fields=sys_id,number,state" "$corpo" | jq -c '.result')
    CHANGE_SYS_ID=$(jq -r '.sys_id' <<<"$criado")
    echo "Criado $(jq -r '.number' <<<"$criado")"
    sn_attach change_request "$CHANGE_SYS_ID" "$gate" gate-result.json || echo "::warning::Falha ao anexar gate-result.json"
    sn_attach change_request "$CHANGE_SYS_ID" "$evalr" eval-report.json || echo "::warning::Falha ao anexar eval-report.json"
  fi

  # Pede aprovação (equivale ao botão "Request Approval": New -> Assess)
  local atual
  atual=$(le)
  if [ "$(jq -r '.state' <<<"$atual")" = "-5" ]; then
    patch '{"state":"-4"}' > /dev/null || true
    atual=$(le)
    [ "$(jq -r '.state' <<<"$atual")" = "-4" ] ||
      echo "::warning::O ServiceNow não aceitou a transição automática para Assess. Clique em \"Request Approval\" no Change para seguir a demo."
  fi

  local num url st
  num=$(jq -r '.number' <<<"$atual"); url=$(chg_url "$CHANGE_SYS_ID"); st=$(estado "$(jq -r '.state' <<<"$atual")")
  output sys_id "$CHANGE_SYS_ID"; output number "$num"; output url "$url"
  local info
  info=$(sn GET "$T/$CHANGE_SYS_ID?sysparm_display_value=true&sysparm_fields=short_description,risk,impact" | jq -c '.result' || echo '{}')
  summary <<EOF
### 📋 Change Request aberto: [$num]($url)

$(jq -r '.short_description // ""' <<<"$info")

| | |
|---|---|
| Tipo | Normal |
| Risco · Impacto | $(jq -r '"\(.risk // "-") · \(.impact // "-")"' <<<"$info") — herdados da classificação do AI System ($(jq -r '.checks.risk_classification // "-"' "$gate")) |
| Estado | **$st** — aguardando aprovação no ServiceNow |
| Janela planejada | $(date -u -d '+10 min' '+%d/%m %H:%M') – $(date -u -d '+70 min' '+%H:%M') UTC |
| Evidências anexadas | gate-result.json · eval-report.json |
| Rastreabilidade | correlation_id \`github:${GITHUB_REPOSITORY:-local}:run-${GITHUB_RUN_ID:-$$}\` |

EOF
}

wait_approval() {
  : "${CHANGE_SYS_ID:?}"
  local limite=$(( $(date +%s) + ${WAIT_MINUTES:-30} * 60 )) intervalo=${POLL_SECONDS:-15}
  local anterior="" linhas="" r st ap num
  echo "Aguardando aprovação (até ${WAIT_MINUTES:-30} min, consulta a cada ${intervalo}s)..."
  while :; do
    r=$(le) || { sleep "$intervalo"; continue; }
    st=$(jq -r '.state' <<<"$r"); ap=$(jq -r '.approval' <<<"$r"); num=$(jq -r '.number' <<<"$r")
    if [ "$st|$ap" != "$anterior" ]; then
      echo "$(date -u '+%H:%M:%S') $num  estado=$(estado "$st")  aprovação=$ap"
      linhas+="| $(date -u '+%H:%M:%S') UTC | $(estado "$st") | $ap |"$'\n'
      anterior="$st|$ap"
    fi
    if [ "$ap" = "approved" ] && [[ $st =~ ^(-2|-1)$ ]]; then resultado=aprovado; break; fi
    if [ "$ap" = "rejected" ]; then resultado=rejeitado; break; fi
    if [[ $st =~ ^(3|4)$ ]]; then resultado="encerrado ($(estado "$st"))"; break; fi
    if [ "$(date +%s)" -ge "$limite" ]; then resultado=expirado; break; fi
    sleep "$intervalo"
  done

  local aprovadores
  aprovadores=$(sn GET "/api/now/table/sysapproval_approver?sysparm_query=$(urlenc "sysapproval=$CHANGE_SYS_ID^ORDERBYsys_updated_on")&sysparm_display_value=true&sysparm_exclude_reference_link=true&sysparm_fields=approver,state,sys_updated_on" |
    jq -r '.result[] | "| \(.approver | if type == "object" then .display_value else . end) | \(.state) | \(.sys_updated_on) |"' 2>/dev/null || true)
  summary <<EOF
### $( [ "$resultado" = aprovado ] && echo "✅" || echo "⛔" ) Aprovação do Change [$num]($(chg_url "$CHANGE_SYS_ID")): $resultado

**Linha do tempo**

| Hora | Estado | Aprovação |
|---|---|---|
${linhas}
**Aprovadores**

| Aprovador | Decisão | Quando |
|---|---|---|
${aprovadores:-| — | — | — |}

EOF
  case $resultado in
    aprovado) nota "Change aprovado. Pipeline retomado para o deploy: $RUN_URL" ;;
    expirado) nota "Pipeline encerrou a espera pela aprovação após ${WAIT_MINUTES:-30} min. Reexecute o job de aprovação para retomar: $RUN_URL"
              echo "::error::Change não aprovado dentro de ${WAIT_MINUTES:-30} min"; exit 1 ;;
    *)        echo "::error::Change $num $resultado: deploy não autorizado"; exit 1 ;;
  esac
}

implement() {
  local st
  st=$(le | jq -r '.state')
  if [ "$st" = "-2" ]; then
    patch "$(jq -n --arg n "Deploy iniciado pelo pipeline: $RUN_URL" '{state: "-1", work_notes: $n}')" > /dev/null ||
      echo "::warning::Não foi possível passar o Change para Implement"
  else
    nota "Deploy iniciado pelo pipeline: $RUN_URL"
  fi
  echo "Change em $(estado "$(le | jq -r '.state')")"
}

close_ok() {
  local nome; nome=$(sed -E 's/ v?[0-9]+(\.[0-9]+)+$//' <<<"${AI_SYSTEM:-$AI_ASSET_TAG}")
  local notas="AI System $nome ${VERSAO:-} publicado com sucesso pelo pipeline. Gate do AI Control Tower revalidado antes do deploy. Execução: $RUN_URL"
  patch "$(jq -n --arg n "$notas" '{state: "0", work_notes: $n}')" > /dev/null || echo "::warning::Transição para Review recusada"
  patch "$(jq -n --arg n "$notas" '{state: "3", close_code: "successful", close_notes: $n}')" > /dev/null ||
    echo "::warning::Não foi possível fechar o Change automaticamente; feche-o no ServiceNow"
  local r; r=$(le)
  summary <<EOF
### 🏁 Change [$(jq -r '.number' <<<"$r")]($(chg_url "$CHANGE_SYS_ID")) — $(estado "$(jq -r '.state' <<<"$r")")

Fechado como **successful** com a URL desta execução nas notas de fechamento.

EOF
}

fail_change() {
  local motivo="$1 Execução: $RUN_URL" st
  st=$(le | jq -r '.state')
  if [ "$st" = "-1" ]; then
    patch "$(jq -n --arg n "$motivo" '{state: "0", work_notes: $n}')" > /dev/null || true
    patch "$(jq -n --arg n "$motivo" '{state: "3", close_code: "unsuccessful", close_notes: $n}')" > /dev/null ||
      echo "::warning::Não foi possível fechar o Change como unsuccessful"
  else
    patch "$(jq -n --arg n "$motivo" '{state: "4", work_notes: $n}')" > /dev/null ||
      { echo "::warning::Não foi possível cancelar o Change"; nota "$motivo"; }
  fi
  echo "Change em $(estado "$(le | jq -r '.state')")"
}

case ${1:-} in
  create)    create ;;
  wait)      wait_approval ;;
  implement) : "${CHANGE_SYS_ID:?}"; implement ;;
  note)      : "${CHANGE_SYS_ID:?}"; nota "${2:?texto}" ;;
  close)     : "${CHANGE_SYS_ID:?}"; close_ok ;;
  fail)      : "${CHANGE_SYS_ID:?}"; fail_change "${2:-Deploy não concluído.}" ;;
  *) echo "uso: $0 create|wait|implement|note|close|fail"; exit 2 ;;
esac
